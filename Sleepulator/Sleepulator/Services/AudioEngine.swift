import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI

enum AppConfig {
    static let nightLimiterEnabled = true
}

/// Network reachability as its own tiny observable, so views that only care about online/offline
/// (the podcast library) observe just this instead of the whole AudioEngine — keeping unrelated
/// engine publishes (podTitle, transport, settings) from re-rendering the podcast list.
final class Connectivity: ObservableObject {
    @Published var isOnline = true
}

/// Comfort/playback settings bound by SettingsView. Split out of AudioEngine so the settings screen
/// observes just this — unrelated engine publishes (podTitle, transport, chrome) no longer re-render
/// SettingsView. Each setter persists to UserDefaults and notifies AudioEngine (via the `on*`
/// callbacks) to apply the side-effect to the live audio path. AudioEngine keeps computed
/// passthroughs (`audio.skipInterval`, …) so every other reader stays unchanged. Property observers
/// don't fire during `init`, so loading from UserDefaults here is side-effect-free.
final class PlaybackSettings: ObservableObject {
    // Side-effect appliers, wired by AudioEngine in its init.
    var onSkipInterval: ((Double) -> Void)?
    var onStereoWidth: ((Double) -> Void)?
    var onNightLimiter: ((Bool) -> Void)?
    var onLimiterByMode: (() -> Void)?
    var onSleepEQ: ((Bool) -> Void)?
    var onSleepEQIntensity: ((Double) -> Void)?
    var onBeatRouting: (() -> Void)?

    @Published var skipInterval: Double {
        didSet { UserDefaults.standard.set(skipInterval, forKey: "skipInterval"); onSkipInterval?(skipInterval) }
    }
    @Published var stereoWidth: Double {
        didSet { UserDefaults.standard.set(stereoWidth, forKey: "stereoWidth"); onStereoWidth?(stereoWidth) }
    }
    @Published var nightLimiter: Bool {
        didSet { UserDefaults.standard.set(nightLimiter, forKey: "nightLimiterEnabled"); onNightLimiter?(nightLimiter) }
    }
    @Published var limiterByMode: Bool {
        didSet { UserDefaults.standard.set(limiterByMode, forKey: "limiterByMode"); onLimiterByMode?() }
    }
    @Published var sleepEQ: Bool {
        didSet { UserDefaults.standard.set(sleepEQ, forKey: "sleepEQEnabled"); onSleepEQ?(sleepEQ) }
    }
    @Published var sleepEQIntensity: Double {
        didSet { UserDefaults.standard.set(sleepEQIntensity, forKey: "sleepEQIntensity"); onSleepEQIntensity?(sleepEQIntensity) }
    }
    @Published var beatRouting: String {
        didSet { UserDefaults.standard.set(beatRouting, forKey: "beatRouting"); onBeatRouting?() }
    }

    init() {
        let d = UserDefaults.standard
        skipInterval = d.object(forKey: "skipInterval") as? Double ?? 15
        stereoWidth = d.object(forKey: "stereoWidth") as? Double ?? 1.0
        nightLimiter = d.object(forKey: "nightLimiterEnabled") as? Bool ?? AppConfig.nightLimiterEnabled
        limiterByMode = d.object(forKey: "limiterByMode") as? Bool ?? false
        sleepEQ = d.object(forKey: "sleepEQEnabled") as? Bool ?? false
        sleepEQIntensity = d.object(forKey: "sleepEQIntensity") as? Double ?? 1.0
        beatRouting = d.string(forKey: "beatRouting") ?? "auto"
    }

    /// Re-read from UserDefaults after a Backup restore. Reassigning fires didSet, re-persisting
    /// (harmless) and re-applying each side-effect — exactly what restore needs.
    func reload() {
        let d = UserDefaults.standard
        skipInterval = d.object(forKey: "skipInterval") as? Double ?? 15
        stereoWidth = d.object(forKey: "stereoWidth") as? Double ?? 1.0
        nightLimiter = d.object(forKey: "nightLimiterEnabled") as? Bool ?? AppConfig.nightLimiterEnabled
        limiterByMode = d.object(forKey: "limiterByMode") as? Bool ?? false
        sleepEQ = d.object(forKey: "sleepEQEnabled") as? Bool ?? false
        sleepEQIntensity = d.object(forKey: "sleepEQIntensity") as? Double ?? 1.0
        beatRouting = d.string(forKey: "beatRouting") ?? "auto"
    }
}

final class AudioEngine: ObservableObject {
    let queueManager = PodcastQueueManager()
    let connectivity = Connectivity()
    /// Comfort/playback settings bound by SettingsView (observed there directly, not via the engine).
    let settings = PlaybackSettings()
    let sleepTimer = SleepTimerService()
    let pomodoro = PomodoroService()
    /// High-frequency podcast position (progress/elapsed/duration). Owned here but its
    /// objectWillChange is deliberately NOT forwarded (see init) — only the now-playing views
    /// observe it, so the ~1/sec time-observer updates don't re-render the whole tree.
    let playbackProgress = PlaybackProgress()
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
    /// Cap on *extra* stacked noise layers (the primary `noiseType` is always layer 0).
    static let maxExtraLayers = kMaxNoiseLayers - 1
    /// Additional simultaneous noise generators stacked on the primary noise (rain + brown, …).
    /// Gated by `noiseOn` like the primary; persisted as JSON; capped at `maxExtraLayers`.
    @Published var extraLayers: [ExtraNoiseLayer] = [] {
        didSet {
            let v = extraLayers
            storageQueue.async {
                if let data = try? JSONEncoder().encode(v) {
                    UserDefaults.standard.set(data, forKey: "extraLayers")
                }
            }
            syncGenEngine()
        }
    }
    @Published var binauralPreset: String {
        didSet { UserDefaults.standard.set(binauralPreset, forKey: "binauralPreset"); syncGenEngine() }
    }
    @Published var playbackSpeed: Double {
        didSet { UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed"); podPlayer.setSpeed(playbackSpeed) }
    }
    /// Seconds the skip-back / skip-forward controls (in-app + lock screen) jump. One of
    /// {10,15,30,45} so the matching SF Symbol (gobackward.N / goforward.N) always exists.
    // The comfort/playback settings below are owned by the `settings` child (PlaybackSettings) so
    // SettingsView observes just that, not the whole engine. These computed passthroughs keep every
    // other reader (NowPlayingSheet, MiniPlayer, lock-screen glyphs, internal logic) unchanged; the
    // setters route to `settings`, whose didSet persists + applies the side-effect via callbacks.
    var skipInterval: Double {
        get { settings.skipInterval } set { settings.skipInterval = newValue }
    }

    /// SF Symbol names for the skip controls. `gobackward.N` / `goforward.N` only exist for a
    /// fixed set of N; fall back to the number-less glyph for any other value (e.g. an odd
    /// figure restored from a hand-edited backup) so the button never renders blank.
    private static let skipGlyphSizes: Set<Int> = [5, 10, 15, 30, 45, 60, 75, 90]
    var skipBackSymbol: String {
        Self.skipGlyphSizes.contains(Int(skipInterval)) ? "gobackward.\(Int(skipInterval))" : "gobackward"
    }
    var skipForwardSymbol: String {
        Self.skipGlyphSizes.contains(Int(skipInterval)) ? "goforward.\(Int(skipInterval))" : "goforward"
    }

    var nightLimiter: Bool {
        get { settings.nightLimiter } set { settings.nightLimiter = newValue }
    }
    /// When on, the Night Limiter follows the mode: ON while sleeping (soften loud spikes so
    /// they don't jolt you awake), OFF while focusing (keep full dynamics).
    var limiterByMode: Bool {
        get { settings.limiterByMode } set { settings.limiterByMode = newValue }
    }

    private func applyLimiterForMode() {
        if limiterByMode { nightLimiter = !focusMode }
    }
    var sleepEQ: Bool {
        get { settings.sleepEQ } set { settings.sleepEQ = newValue }
    }
    var sleepEQIntensity: Double {
        get { settings.sleepEQIntensity } set { settings.sleepEQIntensity = newValue }
    }
    /// Which output the entrainment beats should assume: "auto" (follow the route), "headphones"
    /// (always true binaural), or "speaker" (always isochronic). A true binaural beat collapses
    /// on a speaker, so this picks the speaker-safe isochronic path when there are no headphones.
    var beatRouting: String {
        get { settings.beatRouting } set { settings.beatRouting = newValue }
    }
    
    // Persisted mixes (Last Night resume snapshot + saved sound presets) and their storage live
    // in MixStore (Slice A2). MixStore.objectWillChange is deliberately NOT forwarded (Phase 3):
    // the only views that render mix state observe `mixStore` directly (HomeView reads lastMix,
    // MixDrawer reads savedPresets). The passthroughs below stay for non-reactive internal reads
    // (resumeMix, save flow) — reading them never subscribes a view to mix updates.
    let mixStore: MixStore
    var lastMix: SavedMix? { mixStore.lastMix }
    var savedPresets: [SoundPreset] { mixStore.savedPresets }
    
    @Published var podTitle = "No episode loaded"
    var hasLoadedEpisode: Bool { podPlayer.hasPlayer }
    // Read-only passthroughs to the playbackProgress slice. Plain computed (NOT @Published):
    // reading them never subscribes a view to the 1 Hz progress stream — only PlaybackProgress
    // observers (the now-playing views) do. Internal readers (seek, end-of-episode) and the
    // HomeView visibility check keep compiling unchanged via these names.
    var podcastProgress: Double { playbackProgress.progress }
    var podcastElapsed: Double { playbackProgress.elapsed }
    var podcastDuration: Double { playbackProgress.duration }
    
    /// Passthrough so existing `audio.isOnline` readers keep compiling; the reactive source is the
    /// `connectivity` child, which the library views observe directly.
    var isOnline: Bool { connectivity.isOnline }
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

    /// A heavily smoothed, normalized version of `rmsPower` (~0…1) for audio-reactive ambient
    /// scenes — a slow "breath" that follows the generative bed (fire crackle, ocean swell),
    /// not a jittery meter. Also a plain property on purpose: scenes sample it *live* inside
    /// their own redraw (see `SceneContext.audioLevel`). Pushing it through `@Published` would
    /// reintroduce the exact 20 Hz re-render storm the `rmsPower` comment above describes.
    /// Driven by the generative engine's render callback, so a podcast playing with no noise
    /// bed won't move it — that's an accepted limitation of v1.
    var audioLevel: Double = 0.0
    
    @Published var masterVolume: Double {
        didSet {
            UserDefaults.standard.set(masterVolume, forKey: "masterVolume")
            syncAllVolumes()
        }
    }
    var stereoWidth: Double {
        get { settings.stereoWidth } set { settings.stereoWidth = newValue }
    }
    // Curated sound palettes per mode — Sleep and Focus deliberately share no sounds.
    // Mode-scoped palettes. Pink is the one deliberate cross-mode sound: it has the strongest
    // slow-wave-sleep evidence, so it earns a place in Sleep too (AUDIO-PALETTE-SPEC §3 R5) —
    // a sanctioned exception to the otherwise-strict "modes share no sounds" rule.
    static let sleepNoises = ["brown", "rain", "ocean", "pink", "green", "forest"]
    static let focusNoises = ["pink", "fan", "white", "gray"]
    static let sleepBinaurals = ["delta", "theta"]
    static let focusBinaurals = ["alpha", "smr", "beta", "gamma"]

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
        // Drop any extra layer whose sound isn't in the new mode's palette, so a cross-mode layer
        // can't leak across (same rule the primary noise follows above).
        let filtered = extraLayers.filter { noises.contains($0.type) }
        if filtered.count != extraLayers.count { extraLayers = filtered }
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
        if let data = UserDefaults.standard.data(forKey: "extraLayers"),
           let layers = try? JSONDecoder().decode([ExtraNoiseLayer].self, from: data) {
            self.extraLayers = layers.prefix(Self.maxExtraLayers).map {
                ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume)
            }
        }
        self.binauralPreset = UserDefaults.standard.string(forKey: "binauralPreset") ?? "delta"
        self.playbackSpeed = UserDefaults.standard.object(forKey: "playbackSpeed") as? Double ?? 1.0
        self.masterVolume = UserDefaults.standard.object(forKey: "masterVolume") as? Double ?? 1.0
        self.focusMode = UserDefaults.standard.object(forKey: "focusMode") as? Bool ?? false
        // skipInterval / stereoWidth / nightLimiter / limiterByMode / sleepEQ / sleepEQIntensity /
        // beatRouting are loaded by the `settings` child (PlaybackSettings.init) and reached via
        // computed passthroughs; their side-effect callbacks are wired below.

        // Migration: if old sleepSafeAudio exists, remove old proxy settings
        if UserDefaults.standard.object(forKey: "sleepSafeAudio") != nil {
            UserDefaults.standard.removeObject(forKey: "sleepSafeAudio")
            UserDefaults.standard.removeObject(forKey: "audioProxyUrl")
        }
        
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
        

        // No child objectWillChange is forwarded into the engine (Phase 3 completes this).
        // Forwarding makes ANY child publish invalidate every view holding `audio`. Each child's
        // reactive consumers observe the child directly instead:
        //   - sleepTimer / pomodoro (~1/sec): SessionButton, SleepStatusLine, BumpTimerButton in
        //     HomeView; FocusHero / FocusSessionReadout / CycleDots; NightDarken in AmbientScene.
        //     ContentView drives its night-dim off `sleepTimer.$timerRemaining` via onReceive.
        //   - playbackProgress (~1/sec): MiniPlayerView + NowPlayingSheet (Phase 1).
        //   - queueManager (user-action): NowPlayingSheet (queue list) + SettingsView (the
        //     Auto-Play / Shuffle toggles) observe it directly.
        //   - mixStore (user-action): HomeView (lastMix) + MixDrawer (savedPresets) observe it.
        pomodoro.chimeFn = { [weak self] in self?.chime.play() }

        // PlaybackSettings holds the values + persistence; these callbacks apply each change to the
        // live audio path (the side-effects that used to live in the engine's @Published didSets).
        settings.onSkipInterval = { [weak self] v in self?.podPlayer.skipInterval = v }
        settings.onStereoWidth = { [weak self] v in self?.genEngine.setWidth(v) }
        settings.onNightLimiter = { [weak self] v in self?.podPlayer.nightLimiterEnabled = v }
        settings.onLimiterByMode = { [weak self] in self?.applyLimiterForMode() }
        settings.onSleepEQ = { [weak self] v in self?.podPlayer.sleepEQEnabled = v }
        settings.onSleepEQIntensity = { [weak self] v in self?.podPlayer.sleepEQIntensity = v }
        settings.onBeatRouting = { [weak self] in self?.syncBeatMode() }

        queueManager.loadPodcastFn = { [weak self] url, id, title, resume in
            self?.podTitle = title
            self?.loadPodcast(url, id: id, resume: resume)
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
            guard let self else { return }
            self.rmsPower = power
            // Low-pass into a slow, organic level for audio-reactive scenes (TiltSource's
            // discipline: smooth at the source, never publish). Gentle gain then clamp; the
            // ~0.08 factor at ~20 Hz gives a ~0.6 s breath. Tuned by ear — adjust on device.
            let target = min(1.0, max(0.0, power * 3.0))
            self.audioLevel += (target - self.audioLevel) * 0.08
            // Noise-only keep-alive for the sleep timer: without a podcast there's no
            // AVPlayer time-observer feeding backgroundTick, so the fade/terminal-stop would
            // ride only the GCD timer (which iOS can curtail). The RMS tap fires whenever the
            // engine renders, giving the timer the same belt-and-suspenders as the pod path.
            self.sleepTimer.backgroundTick()
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
                guard let self = self else { return }
                self.playbackProgress.elapsed = elapsed
                self.playbackProgress.duration = duration
                if duration > 0 {
                    self.playbackProgress.progress = elapsed / duration
                }
                // Drive an "end of episode" sleep timer off the real playback clock, scaled by
                // playback speed so the countdown reflects wall-clock time to the episode's end.
                if duration > 0, self.sleepTimer.isEndOfEpisode {
                    let speed = max(0.1, self.playbackSpeed)
                    self.sleepTimer.externalTick(remaining: max(0, (duration - elapsed) / speed))
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
                guard let self = self else { return }
                if let id = finishedEpId {
                    self.queueManager.markFinished(id)
                }
                // End-of-episode sleep timer: stop everything when this episode ends rather than
                // rolling into the next one. (externalTick normally fires the stop just before the
                // natural end; this covers the exact boundary if the last tick missed it.)
                if self.sleepTimer.isEndOfEpisode {
                    self.stopAll()
                    return
                }
                self.queueManager.advanceQueue(finishedEpId: finishedEpId)
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
        // each event here via closures, hopping to the main queue first (AVAudioSession delivers
        // these on an arbitrary system thread) so the handlers can safely touch @Published state
        // and updateParams (main-queue + single-writer on the lock-free param buffer).
        sessionController.onInterruption = { [weak self] note in self?.handleInterruption(note: note) }
        sessionController.onRouteChange = { [weak self] note in self?.handleRouteChange(note: note) }
        sessionController.onAppBackground = { [weak self] in self?.handleAppBackground() }
        sessionController.onOnlineChanged = { [weak self] online in self?.connectivity.isOnline = online }
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

        // Interactive Live Activity buttons (LiveActivityIntent posts these from the lock screen).
        notificationTokens.append(NotificationCenter.default.addObserver(forName: Notification.Name("BumpSleepulatorTimer"), object: nil, queue: .main) { [weak self] _ in
            self?.sleepTimer.bumpTimer()
        })
        notificationTokens.append(NotificationCenter.default.addObserver(forName: Notification.Name("StopSleepulatorTimer"), object: nil, queue: .main) { [weak self] _ in
            self?.stopAll()
        })
        
        if let first = queueManager.queue.first { podTitle = first.title }
        
        podPlayer.setSpeed(playbackSpeed)
        podPlayer.skipInterval = skipInterval
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

    /// True when beats should render isochronically (speaker-safe) rather than as a true binaural.
    var isochronicActive: Bool {
        switch beatRouting {
        case "headphones": return false                        // force true binaural
        case "speaker":    return true                         // force isochronic
        default:           return !Self.binauralCapableRoute()  // auto: binaural only with headphones
        }
    }

    /// Whether the current output route can carry a true binaural beat (per-ear isolation).
    private static func binauralCapableRoute() -> Bool {
        let caps: Set<AVAudioSession.Port> = [.headphones, .bluetoothA2DP, .bluetoothLE, .usbAudio]
        return AVAudioSession.sharedInstance().currentRoute.outputs.contains { caps.contains($0.portType) }
    }

    private func syncBeatMode() {
        genEngine.setBeatMode(isochronic: isochronicActive)
    }

    private func syncGenEngine() {
        genEngine.setNoiseLayers(buildNoiseLayers(), on: noiseOn)
        genEngine.setBinaural(on: binauralOn, volume: binVolume, preset: binauralPreset)
        syncBeatMode()
        updateEnginePower()
    }

    /// The full ordered noise stack handed to the engine: the primary noise (layer 0) plus any
    /// extra layers (capped). The engine silences everything when `noiseOn` is false.
    private func buildNoiseLayers() -> [(type: String, volume: Double)] {
        var layers: [(type: String, volume: Double)] = [(noiseType, noiseVolume)]
        for l in extraLayers.prefix(Self.maxExtraLayers) {
            layers.append((l.type, l.volume))
        }
        return layers
    }

    // MARK: Extra noise layers (stacked simultaneous sounds)

    /// Add an extra noise layer, defaulting to a palette sound not already in the stack.
    func addExtraLayer() {
        guard extraLayers.count < Self.maxExtraLayers else { return }
        let palette = focusMode ? Self.focusNoises : Self.sleepNoises
        let used = Set([noiseType] + extraLayers.map { $0.type })
        let type = palette.first(where: { !used.contains($0) }) ?? palette.first ?? "brown"
        extraLayers.append(ExtraNoiseLayer(type: type, volume: 0.3))
    }

    func removeExtraLayer(_ id: String) {
        extraLayers.removeAll { $0.id == id }
    }

    func setExtraLayerType(_ id: String, _ type: String) {
        guard let i = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        extraLayers[i].type = type
    }

    func setExtraLayerVolume(_ id: String, _ volume: Double) {
        guard let i = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        extraLayers[i].volume = volume
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
    
    /// First-run "show me the magic" start: bring up a layered noise + binaural bed (using the
    /// stored defaults — brown + delta for Sleep) so the very first tap demonstrates that the app
    /// *layers* sounds, rather than playing a single bare noise. Used only when there's nothing
    /// playing and no last mix to resume.
    func startDefaultMix() {
        noiseOn = true
        binauralOn = true
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
        // Capture the last-loaded podcast whenever one is selected in the mixer (an episode is
        // loaded), not only when it happens to be playing at this instant. saveLastMix runs from
        // pauseAll/stopAll, and a sleep-timer terminal stop pauses the player first — the old
        // `isPodPlaying` gate dropped the podcast from the snapshot, so Resume restored nothing.
        let hasPodcast = hasLoadedEpisode && queueManager.queue.first != nil
        let mix = SavedMix(
            name: "Last Night",
            noiseOn: noiseOn,
            noiseVolume: noiseVolume,
            noiseType: noiseType,
            binauralOn: binauralOn,
            binVolume: binVolume,
            binauralPreset: binauralPreset,
            podVolume: podVolume,
            podcastUrl: hasPodcast ? queueManager.queue.first?.audioUrl : nil,
            podcastId: hasPodcast ? queueManager.queue.first?.id : nil,
            podcastPosition: hasPodcast ? podcastElapsed : nil,
            extraLayers: extraLayers.isEmpty ? nil : extraLayers
        )
        mixStore.saveLast(mix)
    }
    
    func resumeMix(_ mix: SavedMix) {
        self.noiseType = NoiseType.migrate(mix.noiseType)
        self.noiseVolume = mix.noiseVolume
        self.extraLayers = (mix.extraLayers ?? []).prefix(Self.maxExtraLayers).map {
            ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume)
        }
        self.noiseOn = mix.noiseOn
        
        self.binauralPreset = mix.binauralPreset
        self.binVolume = mix.binVolume
        self.binauralOn = mix.binauralOn
        
        self.podVolume = mix.podVolume
        
        if let urlStr = mix.podcastUrl {
            // Seek straight to the snapshot's stored position; fall back to the saved-position map
            // (resume: true) for older snapshots that predate podcastPosition.
            loadPodcast(urlStr, id: mix.podcastId ?? urlStr, resume: true, startAt: mix.podcastPosition)
        }
    }
    
    // MARK: Saved sound presets (reusable recipes — no podcast)

    /// A recipe-derived default name for the current soundscape ("Brown + Delta"), used to
    /// prefill the name-it prompt. Never the podcast title — a preset is about the sounds.
    func defaultPresetName() -> String {
        var parts: [String] = []
        if noiseOn {
            parts.append(noiseType.capitalized)
            parts.append(contentsOf: extraLayers.map { $0.type.capitalized })
        }
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
            sceneId: UserDefaults.standard.string(forKey: mode == "focus" ? "sceneFocus" : "sceneSleep"),
            extraLayers: extraLayers.isEmpty ? nil : extraLayers)
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
        extraLayers = (p.extraLayers ?? []).prefix(Self.maxExtraLayers).map {
            ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume)
        }

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

    /// Reload all persisted state after a Backup restore so the new data takes effect WITHOUT an
    /// app relaunch. Flushes pending writes first (the import writes are async) so reads can't
    /// race them, re-seeds the persisted @Published settings from UserDefaults, reloads the
    /// file-backed stores, and tells the library view to refresh.
    func reloadAfterRestore() {
        StorageManager.shared.flush()
        let d = UserDefaults.standard

        noiseVolume = d.object(forKey: "noiseVolume") as? Double ?? 0.4
        binVolume = d.object(forKey: "binVolume") as? Double ?? 0.3
        podVolume = d.object(forKey: "podVolume") as? Double ?? 0.7
        noiseType = NoiseType.migrate(d.string(forKey: "noiseType") ?? "brown")
        if let data = d.data(forKey: "extraLayers"),
           let layers = try? JSONDecoder().decode([ExtraNoiseLayer].self, from: data) {
            extraLayers = layers.prefix(Self.maxExtraLayers).map {
                ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume)
            }
        } else {
            extraLayers = []
        }
        binauralPreset = d.string(forKey: "binauralPreset") ?? "delta"
        playbackSpeed = d.object(forKey: "playbackSpeed") as? Double ?? 1.0
        masterVolume = d.object(forKey: "masterVolume") as? Double ?? 1.0
        // skipInterval / stereoWidth / beatRouting / nightLimiter / limiterByMode / sleepEQ /
        // sleepEQIntensity live on the settings child; reload re-reads + re-applies them.
        settings.reload()
        focusMode = d.object(forKey: "focusMode") as? Bool ?? false   // didSet reconciles palette

        mixStore.reloadFromDisk()
        queueManager.reloadFromDisk()
        podPlayer.reloadPositions()

        reconcileSoundsToMode()
        applyLimiterForMode()

        // The library is owned by LibraryView's @State; nudge it to re-read library.json.
        NotificationCenter.default.post(name: Notification.Name("SleepulatorLibraryReload"), object: nil)
    }

    // MARK: Podcast playback
    private func resolveAudioUrl(_ urlStr: String) -> String {
        if let origUrl = URL(string: urlStr), let cached = AudioDownloader.shared.getCachedUrl(for: origUrl) {
            return cached.absoluteString
        }
        return urlStr
    }

    func loadPodcast(_ urlStr: String, id: String, resume: Bool = true, startAt: TimeInterval? = nil) {
        playbackNote = nil
        let finalUrlStr = resolveAudioUrl(urlStr)
        podPlayer.play(url: finalUrlStr, id: id, title: podTitle, resume: resume, startAt: startAt)
    }

    /// Start a sleep timer that ends when the current episode finishes (fading the ambient bed
    /// down over the last stretch). No-op without a loaded episode of known, finite length, so we
    /// never start a timer that would instantly fire on an unknown-duration live stream.
    func startEndOfEpisodeTimer() {
        guard podPlayer.hasPlayer, podcastDuration.isFinite, podcastDuration > 5 else { return }
        let speed = max(0.1, playbackSpeed)
        let remaining = max(1, (podcastDuration - podcastElapsed) / speed)
        sleepTimer.startEndOfEpisode(remaining: remaining)
    }

    func seekPodcast(seconds: TimeInterval) {
        podPlayer.seek(seconds: seconds)
    }
    
    func seekPodcast(to progress: Double) {
        // Snaps near-start scrubs to exactly 0:00 and guards a non-finite duration (see AudioMath).
        guard let seconds = AudioMath.scrubTargetSeconds(progress: progress, duration: podcastDuration) else { return }
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
        // asleep to; cutting it would do the opposite of the app's job. The beats stay on too:
        // syncBeatMode() below switches them to isochronic, which (unlike a true binaural beat)
        // actually works on a speaker.
        if reason == .oldDeviceUnavailable {
            if isPodPlaying { podPlayer.pause() }
        }

        // Any route transition re-picks true-binaural (headphones) vs isochronic (speaker).
        syncBeatMode()

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
