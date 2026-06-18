import Foundation
import Combine
import AVFoundation

final class AudioEngine: ObservableObject {
    private let genEngine = GenerativeAudioEngine()
    private let podPlayer = PodcastPlayer()
    
    @Published var isDownloading = false // Deprecated logically since we stream, keeping for UI parity for now.
    
    // MARK: UI-facing state (Persisted via UserDefaults)
    @Published var noiseVolume: Double {
        didSet { UserDefaults.standard.set(noiseVolume, forKey: "noiseVolume"); syncGenEngine() }
    }
    @Published var binVolume: Double {
        didSet { UserDefaults.standard.set(binVolume, forKey: "binVolume"); syncGenEngine() }
    }
    @Published var podVolume: Double {
        didSet { UserDefaults.standard.set(podVolume, forKey: "podVolume"); syncPodPlayer() }
    }
    
    // Removed eqEnabled and podPan
    
    @Published var noiseType: String {
        didSet { UserDefaults.standard.set(noiseType, forKey: "noiseType"); syncGenEngine() }
    }
    @Published var binauralPreset: String {
        didSet { UserDefaults.standard.set(binauralPreset, forKey: "binauralPreset"); syncGenEngine() }
    }
    @Published var playbackSpeed: Double {
        didSet { UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed"); podPlayer.setSpeed(playbackSpeed) }
    }
    
    @Published var queue: [Episode] = [] {
        didSet { if let data = try? JSONEncoder().encode(queue) { UserDefaults.standard.set(data, forKey: "upNextQueue") } }
    }
    
    @Published var timerRemaining: TimeInterval = 0
    @Published var autoPlay: Bool {
        didSet { UserDefaults.standard.set(autoPlay, forKey: "autoPlay") }
    }
    @Published var shuffleQueue: Bool {
        didSet { UserDefaults.standard.set(shuffleQueue, forKey: "shuffleQueue") }
    }
    @Published var duckAmbient: Bool {
        didSet { UserDefaults.standard.set(duckAmbient, forKey: "duckAmbient"); syncGenEngine() }
    }
    
    // Phase 6 Proxies
    @Published var feedProxyUrl: String {
        didSet { UserDefaults.standard.set(feedProxyUrl, forKey: "feedProxyUrl") }
    }
    @Published var audioProxyUrl: String {
        didSet { UserDefaults.standard.set(audioProxyUrl, forKey: "audioProxyUrl") }
    }
    @Published var sleepSafeAudio: Bool {
        didSet { UserDefaults.standard.set(sleepSafeAudio, forKey: "sleepSafeAudio") }
    }
    
    @Published var lastMix: SavedMix?
    @Published var savedPlaylists: [SavedMix] = []
    
    @Published var podTitle = "No episode loaded"
    @Published var isPodPlaying = false {
        didSet { syncGenEngine() }
    }
    
    @Published var noiseOn = false { didSet { syncGenEngine() } }
    @Published var binauralOn = false { didSet { syncGenEngine() } }
    
    private var sleepTimer: Timer?
    private var sleepTimerEnd: Date?
    private var fadeMultiplier: Double = 1.0 {
        didSet { 
            genEngine.setFade(multiplier: fadeMultiplier)
            podPlayer.setVolume(podVolume * fadeMultiplier)
        }
    }
    
    init() {
        self.noiseVolume = UserDefaults.standard.object(forKey: "noiseVolume") as? Double ?? 0.5
        self.binVolume = UserDefaults.standard.object(forKey: "binVolume") as? Double ?? 0.4
        self.podVolume = UserDefaults.standard.object(forKey: "podVolume") as? Double ?? 0.8
        
        self.noiseType = UserDefaults.standard.string(forKey: "noiseType") ?? "brown"
        self.binauralPreset = UserDefaults.standard.string(forKey: "binauralPreset") ?? "delta"
        self.playbackSpeed = UserDefaults.standard.object(forKey: "playbackSpeed") as? Double ?? 1.0
        
        self.autoPlay = UserDefaults.standard.object(forKey: "autoPlay") as? Bool ?? true
        self.shuffleQueue = UserDefaults.standard.object(forKey: "shuffleQueue") as? Bool ?? false
        self.duckAmbient = UserDefaults.standard.object(forKey: "duckAmbient") as? Bool ?? false
        
        self.feedProxyUrl = UserDefaults.standard.string(forKey: "feedProxyUrl") ?? ""
        self.audioProxyUrl = UserDefaults.standard.string(forKey: "audioProxyUrl") ?? ""
        self.sleepSafeAudio = UserDefaults.standard.object(forKey: "sleepSafeAudio") as? Bool ?? false
        
        if let data = UserDefaults.standard.data(forKey: "lastMix"),
           let mix = try? JSONDecoder().decode(SavedMix.self, from: data) {
            self.lastMix = mix
        }
        
        if let data = UserDefaults.standard.data(forKey: "savedPlaylists"),
           let mixes = try? JSONDecoder().decode([SavedMix].self, from: data) {
            self.savedPlaylists = mixes
        }
        
        if let data = UserDefaults.standard.data(forKey: "upNextQueue"),
           let savedQueue = try? JSONDecoder().decode([Episode].self, from: data) {
            self.queue = savedQueue
        }
        
        podPlayer.onPlaybackStateChanged = { [weak self] isPlaying in
            DispatchQueue.main.async { self?.isPodPlaying = isPlaying }
        }
        
        podPlayer.onTitleUpdate = { [weak self] title in
            DispatchQueue.main.async { self?.podTitle = title }
        }
        
        podPlayer.onQueueAdvance = { [weak self] in
            DispatchQueue.main.async { self?.advanceQueue() }
        }
        
        setupAudioSession()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        
        if let first = queue.first { podTitle = first.title }
        
        podPlayer.setSpeed(playbackSpeed)
        syncGenEngine()
        syncPodPlayer()
    }
    
    private func setupAudioSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
    }
    
    private func syncGenEngine() {
        genEngine.setNoise(on: noiseOn, volume: noiseVolume, type: noiseType)
        genEngine.setBinaural(on: binauralOn, volume: binVolume, preset: binauralPreset)
        genEngine.setDucking(enabled: duckAmbient, isPodPlaying: isPodPlaying)
    }
    
    private func syncPodPlayer() {
        podPlayer.setVolume(podVolume * fadeMultiplier)
    }

    // MARK: Queue Logic
    func playEpisode(_ episode: Episode) {
        if !queue.contains(where: { $0.id == episode.id }) { queue.insert(episode, at: 0) }
        else { queue.removeAll(where: { $0.id == episode.id }); queue.insert(episode, at: 0) }
        podTitle = episode.title
        loadPodcast(episode.audioUrl)
    }

    func addToQueue(_ episode: Episode) {
        if !queue.contains(where: { $0.id == episode.id }) { queue.append(episode) }
    }

    func advanceQueue() {
        if !self.queue.isEmpty { self.queue.removeFirst() }
        
        if !self.autoPlay || self.queue.isEmpty {
            self.podPlayer.pause()
            self.podTitle = "Queue finished"
            return
        }
        
        let nextIndex = self.shuffleQueue ? Int.random(in: 0..<self.queue.count) : 0
        let next = self.queue[nextIndex]
        
        if self.shuffleQueue {
            self.queue.remove(at: nextIndex)
            self.queue.insert(next, at: 0)
        }
        
        self.podTitle = next.title
        self.loadPodcast(next.audioUrl)
    }
    
    func togglePodcast() {
        _ = podPlayer.toggle()
    }
    
    func saveLastMix() {
        let mix = SavedMix(
            name: "Last Night",
            noiseOn: noiseOn,
            noiseVolume: noiseVolume,
            noiseType: noiseType,
            binauralOn: binauralOn,
            binVolume: binVolume,
            binauralPreset: binauralPreset,
            podVolume: podVolume,
            podcastUrl: isPodPlaying ? queue.first?.audioUrl : nil
        )
        self.lastMix = mix
        if let data = try? JSONEncoder().encode(mix) {
            UserDefaults.standard.set(data, forKey: "lastMix")
        }
    }
    
    func resumeMix(_ mix: SavedMix) {
        self.noiseType = mix.noiseType
        self.noiseVolume = mix.noiseVolume
        self.noiseOn = mix.noiseOn
        
        self.binauralPreset = mix.binauralPreset
        self.binVolume = mix.binVolume
        self.binauralOn = mix.binauralOn
        
        self.podVolume = mix.podVolume
        
        if let urlStr = mix.podcastUrl {
            loadPodcast(urlStr)
        }
    }

    func stopAll() {
        saveLastMix()
        noiseOn = false
        binauralOn = false
        podPlayer.stop()
        cancelTimer()
    }

    // MARK: Podcast playback
    func loadPodcast(_ urlStr: String) {
        var finalUrlStr = urlStr
        if sleepSafeAudio && !audioProxyUrl.isEmpty {
            if let encoded = urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                finalUrlStr = "\(audioProxyUrl)\(encoded)"
            }
        }
        
        if let origUrl = URL(string: urlStr), let cached = AudioDownloader.shared.getCachedUrl(for: origUrl) {
            finalUrlStr = cached.absoluteString
        }
        
        podPlayer.play(url: finalUrlStr, title: podTitle)
    }

    func seekPodcast(seconds: TimeInterval) {
        podPlayer.seek(seconds: seconds)
    }

    // MARK: Interruption
    @objc private func handleInterruption(note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            genEngine.handleInterruption(shouldResume: false)
            if isPodPlaying { podPlayer.pause() }
        } else if type == .ended {
            guard let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            if options.contains(.shouldResume) {
                genEngine.handleInterruption(shouldResume: true)
                if isPodPlaying { podPlayer.resume() }
            }
        }
    }
    
    @objc private func handleRouteChange(note: Notification) {
        guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        if reason == .oldDeviceUnavailable {
            if binauralOn { binauralOn = false }
        }
    }

    // MARK: Timer
    func startSleepTimer(minutes: Int) {
        cancelTimer()
        sleepTimerEnd = Date().addingTimeInterval(Double(minutes) * 60)
        self.timerRemaining = Double(minutes) * 60
        self.fadeMultiplier = 1.0
        
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let end = self.sleepTimerEnd else { return }
            let remaining = end.timeIntervalSince(Date())
            self.timerRemaining = remaining
            
            if remaining <= 0 {
                self.stopAll()
                self.cancelTimer()
            } else {
                self.fadeMultiplier = Double(AudioMath.getFadeMultiplier(timerRemaining: remaining))
            }
        }
    }

    func bumpTimer() {
        if let currentEnd = sleepTimerEnd {
            sleepTimerEnd = currentEnd.addingTimeInterval(15 * 60)
            self.timerRemaining += 15 * 60
            
            // If we bumped it back above 10 minutes, restore the volume fully.
            if self.timerRemaining > 600 {
                self.fadeMultiplier = 1.0
            }
        }
    }

    func cancelTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEnd = nil
        timerRemaining = 0
        fadeMultiplier = 1.0
    }
}
