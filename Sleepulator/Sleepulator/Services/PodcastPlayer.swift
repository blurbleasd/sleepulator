import Foundation
import AVFoundation
import MediaPlayer
import Combine
import UIKit
import MediaToolbox

struct LimiterState {
    var gain: Float
    var ceiling: Float
    var attackCoef: Float
    var releaseCoef: Float
    var enabled: Float
    var volume: Float
    // Sleep EQ: gentle fixed shelves (treble roll-off + bass trim) for low-volume
    // voice comfort. Shelf gains are constants in process(); the one-pole corner
    // coefficients are derived from the real sample rate in prepare().
    var eqEnabled: Float
    var eqIntensity: Float   // 0 = bypass, 1 = default shelves (-6/-4.4 dB), 2 = aggressive
    var sampleRate: Float
    var aHigh: Float
    var aLow: Float
    var lpHighL: Float
    var lpHighR: Float
    var lpLowL: Float
    var lpLowR: Float
    var player: Unmanaged<PodcastPlayer>?
}

final class PodcastPlayer: NSObject {
    private static let artwork: MPMediaItemArtwork? = {
        guard let img = UIImage(named: "AppIcon") ?? UIImage(named: "icon-512") else { return nil }
        return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }()
    
    private var player: AVPlayer?
    private var timeObserver: Any?
    private let storageQueue = DispatchQueue(label: "app.sleepulator.podstorage", qos: .utility)
    
    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onQueueAdvance: ((String?) -> Void)?
    var onNearEnd: (() -> Void)?
    var onTitleUpdate: ((String) -> Void)?
    var onPlaybackFailed: ((String) -> Void)?
    var onPlaybackNote: ((String?) -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?
    var backgroundTick: (() -> Void)?
    
    private var currentUrl: String?
    private var currentId: String?
    private var currentItem: AVPlayerItem?
    private var currentTitle: String = "No episode loaded"
    private var playbackSpeed: Float = 1.0
    private var currentVolume: Float = 1.0
    private var cachedPositions: [String: Double]?
    private var lastFlushTime = Date.distantPast
    
    private var hasFiredNearEnd = false
    private var preloadedItem: AVPlayerItem?
    
    var nightLimiterEnabled: Bool = true {
        didSet {
            stateLock.lock()
            for state in activeLimiterStates {
                state.pointee.enabled = nightLimiterEnabled ? 1.0 : 0.0
            }
            stateLock.unlock()
        }
    }
    var sleepEQEnabled: Bool = false {
        didSet {
            stateLock.lock()
            for state in activeLimiterStates {
                state.pointee.eqEnabled = sleepEQEnabled ? 1.0 : 0.0
            }
            stateLock.unlock()
        }
    }
    /// How hard the Sleep EQ shelves cut. 0 = bypass, 1.0 = the original fixed shelves
    /// (-6 dB treble / -4.4 dB bass), 2.0 = aggressive roll-off. Live-tunable.
    var sleepEQIntensity: Double = 1.0 {
        didSet {
            stateLock.lock()
            for state in activeLimiterStates {
                state.pointee.eqIntensity = Float(sleepEQIntensity)
            }
            stateLock.unlock()
        }
    }
    fileprivate var activeLimiterStates: [UnsafeMutablePointer<LimiterState>] = []
    fileprivate let stateLock = NSLock()
    
    var hasPlayer: Bool { player?.currentItem != nil }
    
    override init() {
        super.init()
        cachedPositions = StorageManager.shared.load(from: "positions.json") ?? [:]
        setupAudioSession()
        setupRemoteCommands()
    }
    
    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        currentItem?.removeObserver(self, forKeyPath: "status")
        flushPositionsToDisk()
    }
    
    func flushPositionsToDisk() {
        if var positions = cachedPositions {
            if positions.count > 100 {
                let toRemove = positions.keys.filter { $0 != currentId }.prefix(positions.count - 100)
                for key in toRemove { positions.removeValue(forKey: key) }
                cachedPositions = positions
            }
            let toSave = positions
            storageQueue.async {
                StorageManager.shared.save(toSave, to: "positions.json")
            }
        }
    }
    
    /// Replace the in-memory positions. Used by AudioEngine's one-time migration, which
    /// writes positions.json *after* this player already loaded an empty map at its own
    /// init — without this, the first flush would write the empty map back over the
    /// freshly-migrated file and erase "resume where I fell asleep."
    func setPositions(_ positions: [String: Double]) {
        cachedPositions = positions
    }

    private func setupAudioSession() {
        // Setup consolidated natively in AudioEngine or GenerativeAudioEngine
    }
    
    func preload(url: String) {
        guard let nsurl = URL(string: url) else { return }
        let item = AVPlayerItem(url: nsurl)
        preloadedItem = item
        
        Task { @MainActor in
            await attachLimiterTap(to: item)
        }
    }
    
    func play(url: String, id: String, title: String) {
        // Resolve the item FIRST so a malformed URL returns *before* we touch the KVO
        // observer. Otherwise we'd remove the observer, bail on the guard, and leave
        // currentItem unbalanced — crashing the next play() with "observer not registered"
        // (an all-night auto-advancing queue hitting one bad enclosure killed the app).
        let playerItem: AVPlayerItem
        if let pre = preloadedItem, (pre.asset as? AVURLAsset)?.url.absoluteString == url {
            playerItem = pre
            preloadedItem = nil
        } else {
            guard let nsurl = URL(string: url) else { return }
            playerItem = AVPlayerItem(url: nsurl)
        }

        currentUrl = url
        currentId = id
        currentTitle = title
        hasFiredNearEnd = false

        currentItem?.removeObserver(self, forKeyPath: "status")
        self.currentItem = playerItem
        
        NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(itemDidFinishPlaying), name: .AVPlayerItemDidPlayToEndTime, object: playerItem)
        
        playerItem.addObserver(self, forKeyPath: "status", options: [.new, .old], context: nil)
        
        Task { @MainActor in
            if playerItem.audioMix == nil {
                let success = await attachLimiterTap(to: playerItem)
                if !success {
                    // Benign: the tap can't attach to some streams (HLS / no audio track).
                    // Playback continues unprocessed — surface a gentle, non-destructive
                    // note. Do NOT use onPlaybackFailed, which flips the transport to
                    // "paused" and shows a red "Failed:" banner for a working stream.
                    onPlaybackNote?("Volume limiter off for this stream")
                }
            }
            
            if player == nil {
                player = AVPlayer(playerItem: playerItem)
                player?.automaticallyWaitsToMinimizeStalling = true
                
                let interval = CMTime(seconds: 1.0, preferredTimescale: 1000)
                timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
                    guard let self = self, let epId = self.currentId else { return }
                    self.cachedPositions?[epId] = time.seconds
                    
                    if let item = self.currentItem {
                        let duration = item.duration.seconds
                        if duration.isFinite {
                            self.onTimeUpdate?(time.seconds, duration)
                            if (duration - time.seconds) <= 30.0, !self.hasFiredNearEnd {
                                self.hasFiredNearEnd = true
                                self.onNearEnd?()
                            }
                        }
                    }
                    
                    if Date().timeIntervalSince(self.lastFlushTime) > 30.0 {
                        self.lastFlushTime = Date()
                        self.flushPositionsToDisk()
                    }
                    
                    self.backgroundTick?()
                }
            } else {
                player?.replaceCurrentItem(with: playerItem)
            }
            
            if let positions = cachedPositions,
               let savedTime = positions[id], savedTime > 5.0 {
                await player?.seek(to: CMTime(seconds: savedTime - 2.0, preferredTimescale: 1000))
            }
            
            player?.volume = currentVolume   // apply saved volume to the fresh item
            player?.play()
            player?.rate = playbackSpeed
            onPlaybackStateChanged?(true)
            onTitleUpdate?(title)
            updateNowPlaying(isPlaying: true)
        }
    }
    
    func toggle() -> Bool {
        guard let player = player else { return false }
        if player.timeControlStatus == .playing {
            player.pause()
            onPlaybackStateChanged?(false)
            updateNowPlaying(isPlaying: false)
            return false
        } else {
            return resume()
        }
    }
    
    @discardableResult
    func resume() -> Bool {
        guard let player = player else { return false }
        // Ensure the session is active before playing. After an interruption ended, the
        // generative branch may not have reactivated it (podcast-only mode), and a
        // lock-screen "play" would otherwise produce silence.
        try? AVAudioSession.sharedInstance().setActive(true)
        player.play()
        player.rate = playbackSpeed
        onPlaybackStateChanged?(true)
        updateNowPlaying(isPlaying: true)
        return true
    }
    
    func pause() {
        player?.pause()
        flushPositionsToDisk()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }
    
    func stop() {
        player?.pause()
        flushPositionsToDisk()
        onPlaybackStateChanged?(false)
        updateNowPlaying(isPlaying: false)
    }
    
    func seek(seconds: TimeInterval) {
        guard let player = player else { return }
        let currentTime = player.currentTime()
        let newTime = CMTimeAdd(currentTime, CMTime(seconds: seconds, preferredTimescale: 1000))
        player.seek(to: newTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
        }
    }
    
    func seekTo(seconds: TimeInterval) {
        guard let player = player else { return }
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
        }
    }
    
    func setSpeed(_ speed: Double) {
        playbackSpeed = Float(speed)
        if player?.timeControlStatus == .playing {
            player?.rate = playbackSpeed
        }
    }
    
    func setVolume(_ volume: Double) {
        currentVolume = Float(volume)
        player?.volume = currentVolume   // fallback for streams where the tap can't attach
        stateLock.lock()
        for state in activeLimiterStates { state.pointee.volume = currentVolume }
        stateLock.unlock()
    }
    
    @objc private func itemDidFinishPlaying() {
        let finishedId = currentId
        if let id = finishedId {
            cachedPositions?.removeValue(forKey: id)
            flushPositionsToDisk()
        }
        onQueueAdvance?(finishedId)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "status", let item = object as? AVPlayerItem {
            if item.status == .failed {
                let errorMsg = item.error?.localizedDescription ?? "Unknown error"
                print("AVPlayerItem failed: \(errorMsg)")
                onPlaybackFailed?(errorMsg)
                onQueueAdvance?(currentId)
            }
        }
    }
    
    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // Distinct play/pause (not toggle): when the system or CarPlay sends an explicit
        // "play" while already playing — common right after a route change — a toggle would
        // pause, the opposite of the request, and desync the lock-screen transport.
        center.playCommand.addTarget { [weak self] _ in
            self?.resume() == true ? .success : .commandFailed
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self, self.player != nil else { return .commandFailed }
            self.pause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            let _ = self?.toggle()
            return .success
        }
        center.skipForwardCommand.addTarget { [weak self] _ in
            self?.seek(seconds: 15)
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        
        center.skipBackwardCommand.addTarget { [weak self] _ in
            self?.seek(seconds: -15)
            return .success
        }
        center.skipBackwardCommand.preferredIntervals = [15]
        
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self, let positionEvent = event as? MPChangePlaybackPositionCommandEvent, let player = self.player else { return .commandFailed }
            player.seek(to: CMTime(seconds: positionEvent.positionTime, preferredTimescale: 1000)) { _ in
                self.updateNowPlaying(isPlaying: player.timeControlStatus == .playing)
            }
            return .success
        }
    }
    
    private func updateNowPlaying(isPlaying: Bool) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Sleepulator",
            MPMediaItemPropertyAlbumTitle: "Sleepulator"
        ]
        if let art = Self.artwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackSpeed : 0.0
        
        if let player = player {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = CMTimeGetSeconds(player.currentTime())
            if let duration = player.currentItem?.duration, duration.isNumeric {
                info[MPMediaItemPropertyPlaybackDuration] = CMTimeGetSeconds(duration)
            }
        }
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    
    // MARK: - Night Limiter Tap
    
    @discardableResult
    private func attachLimiterTap(to item: AVPlayerItem) async -> Bool {
        do {
            let result = try await withThrowingTaskGroup(of: AVAssetTrack?.self) { group in
                group.addTask {
                    try await item.asset.loadTracks(withMediaType: .audio).first
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    throw CancellationError()
                }
                let firstResult = try await group.next()
                group.cancelAll()
                return firstResult
            }
            
            if let track = result {
                let params = AVMutableAudioMixInputParameters(track: track)
                if let tap = makeLimiterTap() {
                    params.audioTapProcessor = tap
                    let mix = AVMutableAudioMix()
                    mix.inputParameters = [params]
                    item.audioMix = mix
                    return true
                }
            }
        } catch {
            // Timeout or track load failure
        }
        return false
    }
    
    private func makeLimiterTap() -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            init: { tap, clientInfo, tapStorageOut in
                let state = UnsafeMutablePointer<LimiterState>.allocate(capacity: 1)
                state.initialize(to: LimiterState(gain: 1.0, ceiling: 0.71, attackCoef: 0.01, releaseCoef: 0.0005, enabled: 1.0, volume: 1.0, eqEnabled: 0.0, eqIntensity: 1.0, sampleRate: 48000, aHigh: 0.4076, aLow: 0.0207, lpHighL: 0, lpHighR: 0, lpLowL: 0, lpLowR: 0, player: nil))
                tapStorageOut.pointee = UnsafeMutableRawPointer(state)

                if let clientInfo = clientInfo {
                    let player = Unmanaged<PodcastPlayer>.fromOpaque(clientInfo)
                    state.pointee.player = player

                    let p = player.takeUnretainedValue()
                    p.stateLock.lock()
                    p.activeLimiterStates.append(state)
                    state.pointee.enabled = p.nightLimiterEnabled ? 1.0 : 0.0
                    state.pointee.eqEnabled = p.sleepEQEnabled ? 1.0 : 0.0
                    state.pointee.eqIntensity = Float(p.sleepEQIntensity)
                    state.pointee.volume = p.currentVolume
                    p.stateLock.unlock()
                }
            },
            finalize: { tap in
                let tapStorage = MTAudioProcessingTapGetStorage(tap)
                let state = tapStorage.assumingMemoryBound(to: LimiterState.self)
                
                if let playerUnmanaged = state.pointee.player {
                    let player = playerUnmanaged.takeUnretainedValue()
                    player.stateLock.lock()
                    player.activeLimiterStates.removeAll(where: { $0 == state })
                    player.stateLock.unlock()
                }
                
                state.deinitialize(count: 1)
                state.deallocate()
            },
            prepare: { tap, maxFrames, format in
                // Off the audio thread: derive the Sleep EQ one-pole corner coefficients
                // from the real stream sample rate (~4 kHz treble shelf, ~160 Hz bass shelf).
                let sr = Float(format.pointee.mSampleRate)
                guard sr > 0 else { return }
                let storage = MTAudioProcessingTapGetStorage(tap)
                let state = storage.assumingMemoryBound(to: LimiterState.self)
                let twoPi: Float = 2 * .pi
                state.pointee.sampleRate = sr
                state.pointee.aHigh = 1 - exp(-twoPi * 4000 / sr)
                state.pointee.aLow  = 1 - exp(-twoPi * 160 / sr)
            },
            unprepare: { tap in },
            process: { tap, numberFrames, flags, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                if status != noErr { return }
                
                let tapStorage = MTAudioProcessingTapGetStorage(tap)
                let state = tapStorage.assumingMemoryBound(to: LimiterState.self)

                // Volume is applied here (not via AVPlayer.volume, which a PostEffects tap
                // bypasses). Limiting is applied only when enabled, but volume always.
                let limiterOn = state.pointee.enabled != 0.0
                let eqOn = state.pointee.eqEnabled != 0.0
                let aHigh = state.pointee.aHigh
                let aLow = state.pointee.aLow
                let vol = state.pointee.volume
                // Shelf "keep" fractions scale with the intensity slider: at 1.0 they equal
                // the original fixed shelves (0.5 treble / 0.6 bass); 0 = bypass, 2 = aggressive.
                let eqIntensity = state.pointee.eqIntensity
                let trebleKeep = max(0.0 as Float, 1.0 - 0.5 * eqIntensity)
                let bassKeep   = max(0.0 as Float, 1.0 - 0.4 * eqIntensity)

                let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                guard abl.count > 0 else { return }
                
                let isInterleaved = (abl.count == 1 && abl[0].mNumberChannels == 2)
                let isStereo = isInterleaved || abl.count > 1
                
                guard let ch0 = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                let ch1: UnsafeMutablePointer<Float>?
                
                if isInterleaved {
                    ch1 = ch0 + 1
                } else if isStereo {
                    ch1 = abl[1].mData?.assumingMemoryBound(to: Float.self)
                } else {
                    ch1 = nil
                }
                
                let frames = Int(numberFrames)
                let stride0 = isInterleaved ? 2 : 1
                let stride1 = isInterleaved ? 2 : 1
                
                for f in 0..<frames {
                    var valL = ch0[f * stride0]
                    var valR = isStereo ? ch1![f * stride1] : valL

                    if eqOn {
                        // Treble roll-off: one-pole LP, keep 50% of the high part (-6 dB shelf).
                        state.pointee.lpHighL += (valL - state.pointee.lpHighL) * aHigh
                        valL = state.pointee.lpHighL + (valL - state.pointee.lpHighL) * trebleKeep
                        // Bass trim: reduce sub-low content to 60% (-4.4 dB shelf below ~160 Hz).
                        state.pointee.lpLowL += (valL - state.pointee.lpLowL) * aLow
                        valL = (valL - state.pointee.lpLowL) + state.pointee.lpLowL * bassKeep
                        if abs(state.pointee.lpHighL) < 1e-15 { state.pointee.lpHighL = 0 }
                        if abs(state.pointee.lpLowL) < 1e-15 { state.pointee.lpLowL = 0 }

                        if isStereo {
                            state.pointee.lpHighR += (valR - state.pointee.lpHighR) * aHigh
                            valR = state.pointee.lpHighR + (valR - state.pointee.lpHighR) * trebleKeep
                            state.pointee.lpLowR += (valR - state.pointee.lpLowR) * aLow
                            valR = (valR - state.pointee.lpLowR) + state.pointee.lpLowR * bassKeep
                            if abs(state.pointee.lpHighR) < 1e-15 { state.pointee.lpHighR = 0 }
                            if abs(state.pointee.lpLowR) < 1e-15 { state.pointee.lpLowR = 0 }
                        }
                    }

                    if limiterOn {
                        var peak = max(abs(valL), abs(valR))
                        if peak < 1e-7 { peak = 0 }

                        let targetGain: Float = (peak * state.pointee.gain > state.pointee.ceiling && peak > 0) ? (state.pointee.ceiling / peak) : 1.0
                        let coef = (targetGain < state.pointee.gain) ? state.pointee.attackCoef : state.pointee.releaseCoef
                        state.pointee.gain += (targetGain - state.pointee.gain) * coef

                        valL = max(-1, min(1, valL * state.pointee.gain))
                        valR = max(-1, min(1, valR * state.pointee.gain))
                    }

                    valL *= vol
                    valR *= vol

                    ch0[f * stride0] = valL
                    if isStereo { ch1![f * stride1] = valR }
                }
            }
        )
        
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault,
            &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects,
            &tap
        )
        
        if status == noErr {
            return tap
        }
        return nil
    }
}
