import Foundation
import AVFoundation
import MediaPlayer

/// Proof-of-concept native audio engine for Sleepulator.
///
/// The point of this spike is to prove the things the PWA fights iOS on:
///  • all-night background audio with the screen locked that never dies,
///  • gapless, infinite ambient/binaural (generated in real time — no WAV loops),
///  • real per-layer volume + a timer fade,
///  • lock-screen Now Playing controls,
///  • automatic resume after an interruption (a phone call) — the PWA's open "Gap 2".
///
/// It is intentionally small and not yet production-hardened (see notes in the
/// render blocks). If this feels rock-solid on your phone overnight, the full
/// rewrite is worth it; the UI is the easy part.
final class AudioEngine: ObservableObject {

    private let engine = AVAudioEngine()
    private var noiseNode: AVAudioSourceNode!
    private var binauralNode: AVAudioSourceNode!
    private let player = AVPlayer()

    // MARK: UI-facing state (main thread)
    @Published var noiseOn = false      { didSet { noiseGain = noiseOn ? Float(noiseVolume) : 0 } }
    @Published var binauralOn = false   { didSet { binGain = binauralOn ? Float(binVolume) : 0 } }
    @Published var noiseVolume = 0.5    { didSet { if noiseOn { noiseGain = Float(noiseVolume) } } }
    @Published var binVolume = 0.4      { didSet { if binauralOn { binGain = Float(binVolume) } } }
    @Published var podVolume = 0.8      { didSet { player.volume = Float(podVolume) } }
    @Published var isPodPlaying = false
    @Published var timerRemaining: TimeInterval = 0
    @Published var podTitle = "No episode loaded"

    // MARK: audio-thread state (single audio render thread; plain vars are OK here)
    private var noiseGain: Float = 0
    private var binGain: Float = 0
    private var brownL: Float = 0, brownR: Float = 0
    private var binPhaseL = 0.0, binPhaseR = 0.0
    private var rng: UInt32 = 0x9E3779B9
    private var sampleRate = 48000.0

    // Binaural carrier/beat (delta — deep sleep). Carrier kept low; needs headphones.
    private let carrier = 180.0
    private let beat = 4.0

    private var fadeTimer: Timer?

    init() {
        configureSession()
        sampleRate = AVAudioSession.sharedInstance().sampleRate
        buildGraph()
        startEngine()
        setupRemoteCommands()
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    // MARK: Session — .playback + the background-audio capability = locked all-night audio.
    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
    }

    private func whiteSample() -> Float {
        rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
        return Float(Int32(bitPattern: rng)) / Float(Int32.max)   // ~ -1...1, no locks
    }

    private func buildGraph() {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        // Brown noise: a leaky integrator (matches the PWA generator), mono → both channels.
        noiseNode = AVAudioSourceNode { [weak self] _, _, frameCount, ablPtr -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            let g = self.noiseGain
            for f in 0..<Int(frameCount) {
                self.brownL = (self.brownL + 0.02 * self.whiteSample()) / 1.02
                self.brownR = (self.brownR + 0.02 * self.whiteSample()) / 1.02
                ch0[f] = max(-1, min(1, self.brownL * 3.5 * g))
                ch1[f] = max(-1, min(1, self.brownR * 3.5 * g))
            }
            return noErr
        }

        // Binaural: two phase-accumulated sines, L = carrier-beat/2, R = carrier+beat/2.
        // Infinite and seamless by construction — no loop, no sample-rate floor.
        binauralNode = AVAudioSourceNode { [weak self] _, _, frameCount, ablPtr -> OSStatus in
            guard let self = self else { return noErr }
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            let g = self.binGain
            let dL = 2.0 * .pi * (self.carrier - self.beat / 2) / self.sampleRate
            let dR = 2.0 * .pi * (self.carrier + self.beat / 2) / self.sampleRate
            for f in 0..<Int(frameCount) {
                ch0[f] = Float(sin(self.binPhaseL)) * 0.32 * g
                ch1[f] = Float(sin(self.binPhaseR)) * 0.32 * g
                self.binPhaseL += dL; if self.binPhaseL > 2 * .pi { self.binPhaseL -= 2 * .pi }
                self.binPhaseR += dR; if self.binPhaseR > 2 * .pi { self.binPhaseR -= 2 * .pi }
            }
            return noErr
        }

        engine.attach(noiseNode)
        engine.attach(binauralNode)
        engine.connect(noiseNode, to: engine.mainMixerNode, format: format)
        engine.connect(binauralNode, to: engine.mainMixerNode, format: format)
    }

    private func startEngine() {
        engine.prepare()
        do { try engine.start() } catch { print("Engine start failed:", error) }
    }

    // MARK: Podcast (AVPlayer mixes with the engine at the session level)
    func loadPodcast(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.volume = Float(podVolume)
        podTitle = url.lastPathComponent
        updateNowPlaying()
    }

    func togglePodcast() {
        if isPodPlaying { player.pause() } else { player.play() }
        isPodPlaying.toggle()
        updateNowPlaying()
    }

    func skip(_ seconds: Double) {
        let t = CMTimeGetSeconds(player.currentTime()) + seconds
        player.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600))
    }

    // MARK: Sleep timer — exponential perceptual fade over the final 10 min, then stop.
    func startSleepTimer(minutes: Double) {
        fadeTimer?.invalidate()
        let end = Date().addingTimeInterval(minutes * 60)
        fadeTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self else { return }
            let remaining = end.timeIntervalSinceNow
            self.timerRemaining = max(0, remaining)
            if remaining <= 0 { t.invalidate(); self.stopAll(); return }
            let window = 600.0
            if remaining <= window {
                let r = Float(pow(0.004, 1 - remaining / window))
                self.engine.mainMixerNode.outputVolume = r
                self.player.volume = Float(self.podVolume) * r
            }
        }
    }

    func cancelTimer() {
        fadeTimer?.invalidate(); fadeTimer = nil
        timerRemaining = 0
        engine.mainMixerNode.outputVolume = 1
        player.volume = Float(podVolume)
    }

    func stopAll() {
        noiseOn = false; binauralOn = false
        player.pause(); isPodPlaying = false
        engine.mainMixerNode.outputVolume = 1
        timerRemaining = 0
        updateNowPlaying()
    }

    // MARK: Lock-screen controls
    private func setupRemoteCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget { [weak self] _ in self?.player.play(); self?.isPodPlaying = true; self?.updateNowPlaying(); return .success }
        cc.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); self?.isPodPlaying = false; self?.updateNowPlaying(); return .success }
        cc.skipForwardCommand.preferredIntervals = [15]
        cc.skipForwardCommand.addTarget { [weak self] _ in self?.skip(15); return .success }
        cc.skipBackwardCommand.preferredIntervals = [15]
        cc.skipBackwardCommand.addTarget { [weak self] _ in self?.skip(-15); return .success }
    }

    private func updateNowPlaying() {
        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = podTitle
        info[MPMediaItemPropertyArtist] = "Sleepulator"
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPodPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: Interruption auto-resume — this is the PWA's unsolvable "Gap 2".
    @objc private func handleInterruption(_ n: Notification) {
        guard let info = n.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        if type == .ended {
            let opts = (info[AVAudioSessionInterruptionOptionKey] as? UInt).map { AVAudioSession.InterruptionOptions(rawValue: $0) } ?? []
            if opts.contains(.shouldResume) {
                try? AVAudioSession.sharedInstance().setActive(true)
                if !engine.isRunning { try? engine.start() }
                if isPodPlaying { player.play() }
            }
        }
    }
}
