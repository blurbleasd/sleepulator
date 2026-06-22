import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI

enum AppConfig {
    static let feedProxyUrl  = "https://sleepulator-feed-proxy.chesteraarfer.workers.dev"
    static let nightLimiterEnabled = true
}

final class AudioEngine: ObservableObject {
    let queueManager = PodcastQueueManager()
    let sleepTimer = SleepTimerService()
    let pomodoro = PomodoroService()
    private var cancellables = Set<AnyCancellable>()

    /// True while the Sleep-mode ambient screensaver is showing (home controls faded).
    /// Lives here so the tab bar + mini-player in ContentView can fade with it. Not persisted.
    @Published var ambientScreensaver = false

    /// True only once the deep night-dim veil has covered the screen. Distinct from
    /// `ambientScreensaver` (controls faded, sky still shown): backdrop scenes keep animating
    /// through the screensaver and freeze only here, when the screen is occluded and the
    /// motion would be a wasted redraw. Not persisted.
    @Published var screenDimmed = false

    private let genEngine = GenerativeAudioEngine()
    private let podPlayer = PodcastPlayer()
    private let chime = ChimePlayer()
    private let storageQueue = DispatchQueue(label: "app.sleepulator.storage", qos: .utility)
    
    // MARK: UI-facing state (Persisted via UserDefaults)
    @Published var noiseVolume: Double {
        didSet { let v = noiseVolume; storageQueue.async { UserDefaults.standard.set(v, forKey: "noiseVolume") }; syncGenEngine() }
    }
    
    @Published var binVolume: Double {
        didSet { let v = binVolume; storageQueue.async { UserDefaults.standard.set(v, forKey: "binVolume") }; syncGenEngine() }
    }
    @Published var podVolume: Double {
        didSet { let v = podVolume; storageQueue.async { UserDefaults.standard.set(v, forKey: "podVolume") }; syncAllVolumes() }
    }
    
    @Published var noiseType: String {
        didSet { UserDefaults.standard.set(noiseType, forKey: "noiseType"); syncGenEngine() }
    }
    @Published var binauralPreset: String {
        didSet { UserDefaults.standard.set(binauralPreset, forKey: "binauralPreset"); syncGenEngine() }
    }
    @Published var playbackSpeed: Double {
        didSet { UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed"); podPlayer.setSpeed(playbackSpeed) }
    }
    
    // Phase 6 Proxies
    @Published var feedProxyUrl: String {
        didSet { UserDefaults.standard.set(feedProxyUrl, forKey: "feedProxyUrl") }
    }
    @Published var nightLimiter: Bool {
        didSet {
            UserDefaults.standard.set(nightLimiter, forKey: "nightLimiterEnabled")
            podPlayer.nightLimiterEnabled = nightLimiter
        }
    }
    /// When on, the Night Limiter follows the mode: ON while sleeping (soften loud spikes so
    /// they don't jolt you awake), OFF while focusing (keep full dynamics).
    @Published var limiterByMode: Bool {
        didSet {
            UserDefaults.standard.set(limiterByMode, forKey: "limiterByMode")
            applyLimiterForMode()
        }
    }

    private func applyLimiterForMode() {
        if limiterByMode { nightLimiter = !focusMode }
    }
    @Published var sleepEQ: Bool {
        didSet {
            UserDefaults.standard.set(sleepEQ, forKey: "sleepEQEnabled")
            podPlayer.sleepEQEnabled = sleepEQ
        }
    }
    @Published var sleepEQIntensity: Double {
        didSet {
            UserDefaults.standard.set(sleepEQIntensity, forKey: "sleepEQIntensity")
            podPlayer.sleepEQIntensity = sleepEQIntensity
        }
    }
    
    // Persisted mixes (Last Night resume snapshot + saved sound presets) and their storage live
    // in MixStore (Slice A2). Exposed here as read-only passthroughs; MixStore.objectWillChange
    // is forwarded in init so views re-render when a preset is saved, renamed, or deleted.
    private let mixStore: MixStore
    var lastMix: SavedMix? { mixStore.lastMix }
    var savedPresets: [SoundPreset] { mixStore.savedPresets }
    
    @Published var podTitle = "No episode loaded"
    var hasLoadedEpisode: Bool { podPlayer.hasPlayer }
    @Published var podcastProgress: Double = 0.0
    @Published var podcastElapsed: Double = 0.0
    @Published var podcastDuration: Double = 1.0
    
    @Published var isOnline = true
    @Published var playbackNote: String?
    /// Audio-session plumbing (activation, interruption/route/background observers, network
    /// monitor) lives in AudioSessionController (Slice A3); AudioEngine keeps the policy.
    private let sessionController = AudioSessionController()
    /// Tokens for the block-based observers AudioEngine still owns directly
    /// (StartSleepulatorMix / SetSleepulatorTimer), removed in deinit.
    private var notificationTokens: [NSObjectProtocol] = []
    
    private var lastActiveSnapshot: (noise: Bool, bin: Bool, pod: Bool) = (false, false, false)
    private var isMasterPauseTransition = false
    
    @Published var noiseOn = false { didSet { syncGenEngine(); if !isMasterPauseTransition { lastActiveSnapshot.noise = noiseOn } } }
    @Published var binauralOn = false { didSet { syncGenEngine(); if !isMasterPauseTransition { lastActiveSnapshot.bin = binauralOn } } }
    @Published var isPodPlaying = false { didSet { syncGenEngine(); if !isMasterPauseTransition { lastActiveSnapshot.pod = isPodPlaying } } }
    var isAnythingPlaying: Bool { isPodPlaying || noiseOn || binauralOn }
    
    // Not @Published: no view renders this, and the RMS tap fires ~20×/sec. Publishing it
    // invalidated HomeView + every child holding `audio` 20 times a second all night for a
    // value nothing displays. Kept as a plain property in case a future visual wants it.
    var rmsPower: Double = 0.0
    
    @Published var masterVolume: Double {
        didSet {
            UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
            syncAllVolumes()
        }
    }
    @Published var stereoWidth: Double {
        didSet {
            UserDefaults.standard.set(stereoWidth, forKey: "stereoWidth")
            genEngine.setWidth(stereoWidth)
        }
    }
    // Curated sound palettes per mode — Sleep and Focus deliberately share no sounds.
    static let sleepNoises = ["brown", "rain", "ocean"]
    static let focusNoises = ["pink", "fan", "white"]
    static let sleepBinaurals = ["delta", "theta"]
    static let focusBinaurals = ["alpha", "gamma"]

    @Published var focusMode: Bool {
        didSet {
            UserDefaults.standard.set(focusMode, forKey: "focusMode")
            // The two timers are mutually exclusive: leaving one mode stops its timer.
            if focusMode { sleepTimer.cancelTimer() } else { pomodoro.stop() }
            // Snap the active sounds into the new mode's palette so nothing cross-mode lingers.
            reconcileSoundsToMode()
            // If the limiter follows the mode, update it (Sleep = on, Focus = off).
            applyLimiterForMode()
        }
    }

    /// Force the active noise + binaural selections into the current mode's palette.
    /// Called on every mode switch and once at launch, so a persisted cross-mode sound
    /// (e.g. brown noise while entering Focus) can't leak across.
    func reconcileSoundsToMode() {
        let noises = focusMode ? Self.focusNoises : Self.sleepNoises
        let binaurals = focusMode ? Self.focusBinaurals : Self.sleepBinaurals
        if !noises.contains(noiseType) { noiseType = noises.first! }
        if !binaurals.contains(binauralPreset) { binauralPreset = binaurals.first! }
    }
    @Published var isMuted: Bool = false { didSet { syncAllVolumes() } }
    
    private var fadeMultiplier: Double = 1.0 {
        didSet { syncAllVolumes() }
    }
    
    func toggleMute() {
        isMuted.toggle()
    }
    
    private func syncAllVolumes() {
        let masterMult = isMuted ? 0.0 : masterVolume
        // Master is a fast, per-sample-smoothed multiplier; the timer fade is the slow
        // ramp. Keep them separate so the master slider responds immediately.
        genEngine.setMaster(masterMult)
        genEngine.setFade(multiplier: fadeMultiplier)
        podPlayer.setVolume(podVolume * masterMult * fadeMultiplier)
    }
    
    init() {
        self.noiseVolume = UserDefaults.standard.object(forKey: "noiseVolume") as? Double ?? 0.4
        self.binVolume = UserDefaults.standard.object(forKey: "binVolume") as? Double ?? 0.3
        self.podVolume = UserDefaults.standard.object(forKey: "podVolume") as? Double ?? 0.7
        
        self.noiseType = NoiseType.migrate(UserDefaults.standard.string(forKey: "noiseType") ?? "brown")
        self.binauralPreset = UserDefaults.standard.string(forKey: "binauralPreset") ?? "delta"
        self.playbackSpeed = UserDefaults.standard.object(forKey: "playbackSpeed") as? Double ?? 1.0
        self.masterVolume = UserDefaults.standard.object(forKey: "masterVolume") as? Double ?? 1.0
        self.stereoWidth = UserDefaults.standard.object(forKey: "stereoWidth") as? Double ?? 1.0
        self.focusMode = UserDefaults.standard.object(forKey: "focusMode") as? Bool ?? false
        
        let savedFeed = UserDefaults.standard.string(forKey: "feedProxyUrl")
        self.feedProxyUrl = (savedFeed?.isEmpty == false) ? savedFeed! : AppConfig.feedProxyUrl
        
        // Migration: if old sleepSafeAudio exists, remove old proxy settings
        if UserDefaults.standard.object(forKey: "sleepSafeAudio") != nil {
            UserDefaults.standard.removeObject(forKey: "sleepSafeAudio")
            UserDefaults.standard.removeObject(forKey: "audioProxyUrl")
        }
        
        self.nightLimiter = UserDefaults.standard.object(forKey: "nightLimiterEnabled") as? Bool ?? AppConfig.nightLimiterEnabled
        self.limiterByMode = UserDefaults.standard.object(forKey: "limiterByMode") as? Bool ?? false
        self.sleepEQ = UserDefaults.standard.object(forKey: "sleepEQEnabled") as? Bool ?? false
        self.sleepEQIntensity = UserDefaults.standard.object(forKey: "sleepEQIntensity") as? Double ?? 1.0
        // podPlayer.nightLimiterEnabled / .sleepEQEnabled are pushed below, after all
        // stored properties are initialized (reading a @Published mid-init is disallowed).
        
        // Legacy -> file-store migration (lastMix, mixes, library seed, episode positions),
        // extracted to PersistenceMigrator (Slice A1). It owns the fragile launch-time legacy
        // reads and hands back the values to seed @Published state below.
        let migrated = PersistenceMigrator().run()
        self.mixStore = MixStore(lastMix: migrated.lastMix,
                                 savedPresets: migrated.savedPresets,
                                 storageQueue: storageQueue)
        if let positions = migrated.migratedPositions {
            // podPlayer loaded an empty positions map at its own init (it's constructed
            // before this body runs); hand it the migrated data so the first flush to disk
            // can't overwrite positions.json with that empty map.
            podPlayer.setPositions(positions)
        }
        

        queueManager.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        sleepTimer.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        pomodoro.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        mixStore.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        pomodoro.chimeFn = { [weak self] in self?.chime.play() }
        
        queueManager.loadPodcastFn = { [weak self] url, id, title in
            self?.podTitle = title
            self?.loadPodcast(url, id: id)
        }
        queueManager.pausePodcastFn = { [weak self] in
            self?.podPlayer.pause()
            self?.podTitle = "Queue finished"
        }
        sleepTimer.stopAllFn = { [weak self] in
            self?.stopAll()
        }
        sleepTimer.updateFadeMultFn = { [weak self] mult in
            self?.fadeMultiplier = mult
        }
        
        genEngine.onRMSUpdate = { [weak self] power in
            self?.rmsPower = power
            // Noise-only keep-alive for the sleep timer: without a podcast there's no
            // AVPlayer time-observer feeding backgroundTick, so the fade/terminal-stop would
            // ride only the GCD timer (which iOS can curtail). The RMS tap fires whenever the
            // engine renders, giving the timer the same belt-and-suspenders as the pod path.
            self?.sleepTimer.backgroundTick()
        }

        genEngine.onEngineError = { [weak self] msg in
            DispatchQueue.main.async { self?.playbackNote = msg }
        }

        podPlayer.onPlaybackStateChanged = { [weak self] isPlaying in
            DispatchQueue.main.async { self?.isPodPlaying = isPlaying }
        }
        
        podPlayer.onTitleUpdate = { [weak self] title in
            DispatchQueue.main.async { self?.podTitle = title }
        }
        
        podPlayer.onTimeUpdate = { [weak self] elapsed, duration in
            DispatchQueue.main.async {
                self?.podcastElapsed = elapsed
                self?.podcastDuration = duration
                if duration > 0 {
                    self?.podcastProgress = elapsed / duration
                }
            }
        }
        
        podPlayer.onPlaybackFailed = { [weak self] errorMsg in
            DispatchQueue.main.async {
                self?.playbackNote = "Failed: \(errorMsg)"
                self?.isPodPlaying = false
            }
        }

        // Non-destructive note (e.g. limiter couldn't attach to a stream). Unlike
        // onPlaybackFailed, this never changes isPodPlaying — the audio is fine.
        podPlayer.onPlaybackNote = { [weak self] note in
            DispatchQueue.main.async { self?.playbackNote = note }
        }
        
        podPlayer.onQueueAdvance = { [weak self] finishedEpId in
            DispatchQueue.main.async {
                if let id = finishedEpId {
                    self?.queueManager.markFinished(id)
                }
                self?.queueManager.advanceQueue(finishedEpId: finishedEpId)
            }
        }
        
        podPlayer.onNearEnd = { [weak self] in
            DispatchQueue.main.async {
                guard let self = self, self.queueManager.autoPlay, !self.queueManager.shuffleQueue, self.queueManager.queue.count > 1 else { return }
                let nextEp = self.queueManager.queue[1]
                let url = self.resolveAudioUrl(nextEp.audioUrl)
                self.podPlayer.preload(url: url)
            }
        }
        
        podPlayer.backgroundTick = { [weak self] in
            self?.sleepTimer.backgroundTick()
        }
        
        // Audio-session plumbing is owned by AudioSessionController (Slice A3). It forwards
        // each event here via closures; the handler policy below is unchanged and still runs
        // on the notification's posting thread (the controller registers selector-based,
        // queue-less, exactly as before).
        sessionController.onInterruption = { [weak self] note in self?.handleInterruption(note: note) }
        sessionController.onRouteChange = { [weak self] note in self?.handleRouteChange(note: note) }
        sessionController.onAppBackground = { [weak self] in self?.handleAppBackground() }
        sessionController.onOnlineChanged = { [weak self] online in self?.isOnline = online }
        sessionController.start()
        
        notificationTokens.append(NotificationCenter.default.addObserver(forName: Notification.Name("StartSleepulatorMix"), object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if !self.isAnythingPlaying {
                if let last = self.lastMix {
                    self.resumeMix(last)
                } else {
                    self.noiseOn = true
                    self.binauralOn = true
                }
            }
        })
        
        notificationTokens.append(NotificationCenter.default.addObserver(forName: Notification.Name("SetSleepulatorTimer"), object: nil, queue: .main) { [weak self] note in
            if let mins = note.userInfo?["minutes"] as? Int {
                self?.sleepTimer.startSleepTimer(minutes: mins)
            }
        })
        
        if let first = queueManager.queue.first { podTitle = first.title }
        
        podPlayer.setSpeed(playbackSpeed)
        podPlayer.nightLimiterEnabled = nightLimiter
        podPlayer.sleepEQEnabled = sleepEQ
        podPlayer.sleepEQIntensity = sleepEQIntensity
        syncGenEngine()
        genEngine.setWidth(stereoWidth)
        syncAllVolumes()
        reconcileSoundsToMode()
        applyLimiterForMode()
    }

    deinit {
        // The session observers + network monitor are owned and torn down by
        // AudioSessionController. AudioEngine only removes the block-based observers it still
        // owns directly (StartSleepulatorMix / SetSleepulatorTimer). Created/destroyed per
        // test, so leaving them registered would leak observers across instances.
        notificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func syncGenEngine() {
        genEngine.setNoise(on: noiseOn, volume: noiseVolume, type: noiseType)
        genEngine.setBinaural(on: binauralOn, volume: binVolume, preset: binauralPreset)
        updateEnginePower()
    }

    private var suspendWorkItem: DispatchWorkItem?
    /// Run the generative engine only while noise or binaural is on. When both are off
    /// we suspend it (after the fade-out finishes) so it isn't rendering silence all
    /// night; we resume immediately when either turns back on.
    private func updateEnginePower() {
        suspendWorkItem?.cancel()
        suspendWorkItem = nil
        if noiseOn || binauralOn {
            genEngine.resumeIfNeeded()
        } else {
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, !self.noiseOn, !self.binauralOn else { return }
                self.genEngine.suspendEngine()
            }
            suspendWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work) // > the ~0.24s gain fade
        }
    }

    func resumePodcast() {
        if podPlayer.hasPlayer {
            podPlayer.resume()
        } else if let first = queueManager.queue.first {
            podTitle = first.title
            loadPodcast(first.audioUrl, id: first.id)
        }
    }
    
    func togglePodcast() {
        if isPodPlaying { podPlayer.pause() } else { resumePodcast() }
    }
    
    func toggleMasterTransport() {
        if isAnythingPlaying {
            lastActiveSnapshot = (noiseOn, binauralOn, isPodPlaying)
            pauseAll()
        } else {
            let snap = lastActiveSnapshot
            if !snap.noise && !snap.bin && !snap.pod {
                noiseOn = true
            } else {
                if snap.noise { noiseOn = true }
                if snap.bin   { binauralOn = true }
                if snap.pod   { resumePodcast() }
            }
        }
    }
    
    func pauseAll() {
        isMasterPauseTransition = true
        saveLastMix()
        noiseOn = false
        binauralOn = false
        if isPodPlaying { podPlayer.pause() }
        isMasterPauseTransition = false
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
            podcastUrl: isPodPlaying ? queueManager.queue.first?.audioUrl : nil,
            podcastId: isPodPlaying ? queueManager.queue.first?.id : nil
        )
        mixStore.saveLast(mix)
    }
    
    func resumeMix(_ mix: SavedMix) {
        self.noiseType = NoiseType.migrate(mix.noiseType)
        self.noiseVolume = mix.noiseVolume
        self.noiseOn = mix.noiseOn
        
        self.binauralPreset = mix.binauralPreset
        self.binVolume = mix.binVolume
        self.binauralOn = mix.binauralOn
        
        self.podVolume = mix.podVolume
        
        if let urlStr = mix.podcastUrl {
            loadPodcast(urlStr, id: mix.podcastId ?? urlStr)
        }
    }
    
    // MARK: Saved sound presets (reusable recipes — no podcast)

    /// A recipe-derived default name for the current soundscape ("Brown + Delta"), used to
    /// prefill the name-it prompt. Never the podcast title — a preset is about the sounds.
    func defaultPresetName() -> String {
        var parts: [String] = []
        if noiseOn { parts.append(noiseType.capitalized) }
        if binauralOn { parts.append(binauralPreset.capitalized) }
        return parts.isEmpty ? "My Mix" : parts.joined(separator: " + ")
    }

    /// Save the current ambient recipe as a named preset for this mode. A same-name preset in
    /// the same mode is overwritten, not duplicated. Captures the current backdrop too.
    func savePreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultPresetName() : trimmed
        let mode = focusMode ? "focus" : "sleep"
        var preset = SoundPreset(
            name: finalName, mode: mode,
            noiseOn: noiseOn, noiseType: noiseType, noiseVolume: noiseVolume,
            binauralOn: binauralOn, binauralPreset: binauralPreset, binVolume: binVolume,
            sceneId: UserDefaults.standard.string(forKey: mode == "focus" ? "sceneFocus" : "sceneSleep"))
        if let existing = mixStore.savedPresets.first(where: {
            $0.mode == mode && $0.name.caseInsensitiveCompare(finalName) == .orderedSame
        }) {
            preset.id = existing.id              // overwrite in place
            mixStore.replacePreset(preset)
        } else {
            mixStore.addPreset(preset)
        }
    }

    /// Apply a saved preset: swap in its sounds + binaural (+ its backdrop, if any). Leaves any
    /// playing podcast untouched — a preset only changes the ambient layer.
    func applyPreset(_ p: SoundPreset) {
        noiseType = NoiseType.migrate(p.noiseType)
        noiseVolume = p.noiseVolume
        noiseOn = p.noiseOn

        binauralPreset = p.binauralPreset
        binVolume = p.binVolume
        binauralOn = p.binauralOn

        if let scene = p.sceneId {
            UserDefaults.standard.set(scene, forKey: p.mode == "focus" ? "sceneFocus" : "sceneSleep")
        }
    }

    func renamePreset(_ p: SoundPreset, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mixStore.renamePreset(p.id, to: trimmed)
    }

    func deletePreset(_ p: SoundPreset) {
        mixStore.deletePreset(p)
    }

    func stopAll() {
        saveLastMix()
        noiseOn = false
        binauralOn = false
        podPlayer.stop()
        sleepTimer.cancelTimer()
    }

    // MARK: Podcast playback
    private func resolveAudioUrl(_ urlStr: String) -> String {
        if let origUrl = URL(string: urlStr), let cached = AudioDownloader.shared.getCachedUrl(for: origUrl) {
            return cached.absoluteString
        }
        return urlStr
    }

    func loadPodcast(_ urlStr: String, id: String) {
        playbackNote = nil
        let finalUrlStr = resolveAudioUrl(urlStr)
        podPlayer.play(url: finalUrlStr, id: id, title: podTitle)
    }

    func seekPodcast(seconds: TimeInterval) {
        podPlayer.seek(seconds: seconds)
    }
    
    func seekPodcast(to progress: Double) {
        let seconds = progress * podcastDuration
        podPlayer.seekTo(seconds: seconds)
    }

    func playAll(_ episodes: [Episode]) {
        queueManager.playAll(episodes)
    }
    
    var finishedEpisodes: Set<String> {
        return queueManager.finishedEpisodes
    }
    
    var autoPlay: Bool {
        get { queueManager.autoPlay }
        set { queueManager.autoPlay = newValue }
    }
    
    var shuffleQueue: Bool {
        get { queueManager.shuffleQueue }
        set { queueManager.shuffleQueue = newValue }
    }
    
    var deleteOnCompletion: Bool {
        get { queueManager.deleteOnCompletion }
        set { queueManager.deleteOnCompletion = newValue }
    }
    
    var hideFinishedEpisodes: Bool {
        get { queueManager.hideFinishedEpisodes }
        set { queueManager.hideFinishedEpisodes = newValue }
    }
    
    // MARK: - Queue Delegation
    // MARK: Interruption
    private func handleInterruption(note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        
        if type == .began {
            genEngine.handleInterruption(shouldResume: false)
            if isPodPlaying { podPlayer.pause() }
        } else if type == .ended {
            guard let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            // A power-save suspend scheduled just before the call must not fire after we
            // restart the engine below — it would silently re-pause the bed mid-night.
            suspendWorkItem?.cancel()
            suspendWorkItem = nil

            // Reactivate the session before resuming whichever source was active. Previously
            // only the generative branch did this, so a podcast-only user got silence.
            try? AVAudioSession.sharedInstance().setActive(true)

            if noiseOn || binauralOn {
                genEngine.handleInterruption(shouldResume: true)
            }

            if options.contains(.shouldResume) {
                if isPodPlaying { podPlayer.resume() }
            }
        }
    }
    
    private func handleRouteChange(note: Notification) {
        guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }
        
        // Headphones unplugged: follow the HIG for spoken media — pause the podcast so a
        // voice doesn't suddenly play out the phone speaker (waking the room). Keep the
        // ambient noise bed going — it's a calibrated, limiter-bounded background you fall
        // asleep to; cutting it would do the opposite of the app's job. Binaural is
        // meaningless on a mono speaker, so drop it.
        if reason == .oldDeviceUnavailable {
            if binauralOn { binauralOn = false }
            if isPodPlaying { podPlayer.pause() }
        }

        // Any route transition (Bluetooth / dock / CarPlay connect, etc.) can silently stop
        // the engine without a clean configuration-change rebuild. Re-assert it if the bed
        // should still be playing — resumeIfNeeded() no-ops when already running.
        if noiseOn || binauralOn {
            genEngine.resumeIfNeeded()
        }
    }

    private func handleAppBackground() {
        podPlayer.flushPositionsToDisk()
    }
}
