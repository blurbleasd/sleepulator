import Foundation
import Combine
import AVFoundation
import Network
import SwiftUI
import MusicKit
import os

enum AppConfig {
    /// Default for fresh installs only (a user's explicit Settings toggle, persisted in
    /// UserDefaults, always wins). Per the CLAUDE.md verification gate and
    /// AUDIO-LIMITER-SPEC.md acceptance criteria, the limiter's MTAudioProcessingTap runs on a
    /// real-time thread and must be verified on a real iPhone (installed, screen locked, full
    /// timer run, known loud spot) before shipping enabled by default. Flip to `true` once that
    /// device pass is done and recorded in TESTING.md.
    static let nightLimiterEnabled = false
}

/// Network reachability as its own tiny observable, so views that only care about online/offline
/// (the podcast library) observe just this instead of the whole AudioEngine — keeping unrelated
/// engine publishes (podTitle, transport, settings) from re-rendering the podcast list.
final class Connectivity: ObservableObject {
    @Published var isOnline = true

    // Explicitly nonisolated: the implicit MainActor-isolated deinit aborts on iOS 18.4–26.3
    // runtimes (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}
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

    // Explicitly nonisolated: the implicit MainActor-isolated deinit aborts on iOS 18.4–26.3
    // runtimes (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}

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
    /// Read-only, for tests that check the media-services reset reaches the generative engine.
    var generativeEngineForTesting: GenerativeAudioEngine { genEngine }
    private let podPlayer = PodcastPlayer()
    /// Apple Music as a parallel, Focus-only source. DRM means it can't go through the generative
    /// mixer or the limiter tap — it plays alongside via MusicKit's system player with the session
    /// in `.mixWithOthers`. See APPLE-MUSIC-FOCUS-SPEC.md.
    private let appleMusic = AppleMusicPlayer()
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
        // Persist off the main thread (matches the volume setters). The audio-side apply goes
        // through softSwapPrimaryNoise: while the bed is audibly playing, a hard mid-render
        // generator swap is a timbre jump-cut (noticeable at 3 a.m.), so we dip layer 0 to
        // silence first — the render thread's per-sample declick ramp (~70 ms) makes both
        // edges click-free — then switch at the bottom and ramp back. Off/quiet paths apply
        // immediately, exactly as before.
        didSet {
            let v = noiseType
            storageQueue.async { UserDefaults.standard.set(v, forKey: "noiseType") }
            softSwapPrimaryNoise(from: oldValue)
        }
    }

    /// Monotonic token so rapid re-picks (or any newer engine sync) cancel an in-flight dip.
    private var noiseSwapToken = 0

    /// See `noiseType.didSet`. Timing: gain reaches silence in ~70 ms (declick coefficient
    /// 0.0015/sample @44.1k), so the swap lands at 140 ms with the old sound fully out; the
    /// ramp back up is masked the same way. If the user changes anything else mid-dip, the
    /// resulting syncGenEngine() applies the new type at once — a rare, acceptable race.
    private func softSwapPrimaryNoise(from oldType: String) {
        guard noiseOn, oldType != noiseType else { syncGenEngine(); return }
        noiseSwapToken += 1
        let token = noiseSwapToken
        // Dip: hand the engine the OLD generator at volume 0; declick fades it out.
        var layers = buildNoiseLayers()
        layers[0] = (oldType, 0.0)
        genEngine.setNoiseLayers(layers, on: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
            guard let self, self.noiseSwapToken == token else { return }
            self.syncGenEngine()   // new type, real volume — declick ramps it back in
        }
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
        // Persist off the main thread (matches the volume setters); syncGenEngine() stays
        // synchronous so the beat changes immediately.
        didSet { let v = binauralPreset; storageQueue.async { UserDefaults.standard.set(v, forKey: "binauralPreset") }; syncGenEngine() }
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
    /// The episode the player is on: set by every load (all loads go through `loadPodcast`) and
    /// kept after the queue moves on without it. The player views resolve "now playing" from this,
    /// never from the queue head (see NowPlayingState). nil until the first load.
    @Published private(set) var loadedEpisode: Episode?
    /// The loaded episode wouldn't play. Cleared by the next load.
    @Published private(set) var podcastFailed = false
    /// A load is in flight: set by `loadPodcast`, cleared by the player's first play/pause report
    /// or a failure. The player views show a spinner only while this holds (NowPlayingState.phase),
    /// so a pause before the first time report leaves Play, not a dead spinner.
    @Published private(set) var episodeLoading = false
    /// The loaded episode is a stand-in built by `loadPodcast` (not from the queue): title only.
    private var standInEpisodeId: String?
    /// The Night Limiter couldn't attach to the loaded stream, so it plays unsoftened. Said quietly
    /// in the full player only: as a playback note it raised an amber ⚠ banner on Home and replaced
    /// "Playing" in the mini-player, all night, for a stream that was working. Cleared by the next load.
    @Published private(set) var limiterOffForStream = false
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
    
    @Published var noiseOn = false { didSet { syncGenEngine(); if !isMasterPauseTransition { lastActiveSnapshot.noise = noiseOn }; noteSessionStart(wasPlaying: oldValue || binauralOn || isPodPlaying) } }
    @Published var binauralOn = false { didSet { syncGenEngine(); if !isMasterPauseTransition { lastActiveSnapshot.bin = binauralOn }; noteSessionStart(wasPlaying: noiseOn || oldValue || isPodPlaying) } }
    @Published var isPodPlaying = false { didSet { syncGenEngine(); if !isMasterPauseTransition { lastActiveSnapshot.pod = isPodPlaying }; noteSessionStart(wasPlaying: noiseOn || binauralOn || oldValue) } }

    /// The Home night ring's remembered length in minutes (0 = All night), read when a session
    /// starts. Injectable so tests don't depend on what the simulator's defaults hold.
    var nightLengthProvider: () -> Double = { UserDefaults.standard.double(forKey: "nightLengthMinutes") }

    /// A Sleep session starting from rest honours the night ring however it was started: the orb,
    /// the mixer's switches, a podcast, the lock screen or AirPods, Siri, the resume widget. (It
    /// used to be the orb alone, so the other paths quietly played all night under a ring that
    /// said "45m".) Nothing in Focus (the Pomodoro is its timer), for All night, or when a
    /// countdown is already running: resuming after a pause, an interruption or a podcast stall
    /// keeps the night you set. Main thread only (property didSets); never the render thread.
    private func noteSessionStart(wasPlaying: Bool) {
        guard !wasPlaying, isAnythingPlaying else { return }
        if let m = SessionGuards.timerOnPlay(focusMode: focusMode, lengthMinutes: nightLengthProvider(),
                                             timerActive: sleepTimer.timerRemaining > 0) {
            sleepTimer.startSleepTimer(minutes: m)
        }
    }
    var isAnythingPlaying: Bool { isPodPlaying || noiseOn || binauralOn }
    /// Playing, or loading an episode that will start the moment it lands. The "pause the podcast
    /// if it's playing" calls that aren't a tap on a control showing `isPodPlaying` read this: a
    /// call, headphones out, Pause All, Apple Music. Mid-load `isPodPlaying` is false (or still true
    /// from the episode that just ended), and a pause skipped there was undone by the load.
    var podcastIsPlayingOrStarting: Bool { isPodPlaying || podPlayer.isStartingPlayback }

    // MARK: Apple Music (Focus-only parallel source)
    // Low-frequency toggles, safe to @Published (a track change fires at most once per song, not
    // the 1 Hz churn the coarse-ObservableObject rule warns about). Deliberately NOT part of
    // `isAnythingPlaying` / the master-transport snapshot in v1 — it's a separate, system-owned
    // player, kept out of the resume-snapshot machinery to avoid scope creep.
    @Published var appleMusicOn = false { didSet { syncAllVolumes() } }
    @Published var appleMusicTitle = ""
    /// True once the user has chosen something to play this session (picker CTA vs. on/off toggle).
    var hasAppleMusicSelection: Bool { appleMusic.hasSelection }

    /// How far the generative bed (noise + binaural) ducks while Apple Music plays — option (b) of
    /// the balance model: Apple Music plays at device volume and can't be level-shaped (DRM), so we
    /// pull the *bed* down underneath it instead. 0.45 ≈ −7 dB; tuned by ear, adjust on device.
    static let musicDuckLevel: Double = 0.45
    private var appleMusicDuck: Double { appleMusicOn ? Self.musicDuckLevel : 1.0 }
    
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
    // Focus binaurals: alpha → beta → gamma, a clean low/mid/high progression. SMR (13 Hz) was
    // retired — it's a neurofeedback construct with little binaural-beat-specific evidence and sat
    // as a near-duplicate between alpha and beta. A persisted/saved "smr" is snapped to alpha by
    // reconcileSoundsToMode (and aliased to alpha in AudioMath.getCarrierAndBeat as a backstop).
    static let focusBinaurals = ["alpha", "beta", "gamma"]

    @Published var focusMode: Bool {
        didSet {
            UserDefaults.standard.set(focusMode, forKey: "focusMode")
            // The two timers are mutually exclusive: leaving one mode stops its timer.
            if focusMode { sleepTimer.cancelTimer() } else { pomodoro.stop() }
            // Snap the active sounds into the new mode's palette so nothing cross-mode lingers.
            reconcileSoundsToMode()
            // If the limiter follows the mode, update it (Sleep = on, Focus = off).
            applyLimiterForMode()
            // Apple Music is Focus-only: leaving Focus stops it and reverts the session to
            // exclusive playback so Sleep's all-night behavior (and the limiter) is unaffected.
            if !focusMode { stopAppleMusic() }
        }
    }

    /// Force the active noise + binaural selections into the current mode's palette.
    /// Called on every mode switch and once at launch, so a persisted cross-mode sound
    /// (e.g. brown noise while entering Focus) can't leak across.
    func reconcileSoundsToMode() {
        let noises = focusMode ? Self.focusNoises : Self.sleepNoises
        let binaurals = focusMode ? Self.focusBinaurals : Self.sleepBinaurals
        // Palettes are static and non-empty today, but never crash the all-night path over it:
        // fall back to known-good defaults if a palette is ever accidentally emptied.
        if !noises.contains(noiseType) { noiseType = noises.first ?? "brown" }
        if !binaurals.contains(binauralPreset) { binauralPreset = binaurals.first ?? "delta" }
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
        // ramp. Keep them separate so the master slider responds immediately. The bed (noise +
        // binaural) is additionally ducked under Apple Music — `appleMusicDuck` rides through the
        // master multiplier, so it gets the same per-sample smoothing (a gentle dip/rise, not a
        // jump, when music starts/stops). The podcast isn't ducked: it's paused while music plays.
        genEngine.setMaster(masterMult * appleMusicDuck)
        genEngine.setFade(multiplier: fadeMultiplier)
        // Podcast: the user target (slider × master × mute) and the sleep-timer fade go in as TWO
        // separate factors — mirroring the generative engine's master/fade split above. Folding the
        // fade into the target (the old single `* fadeMultiplier`) meant a fade that reached ~0 left
        // the podcast's stored volume at ~0, so the next play/resume — which only re-runs the
        // fade-IN envelope, never the target — played silently. Keeping them separate lets a resume
        // multiply by an intact target and be audible; the fade rides on top and self-restores.
        podPlayer.setVolume(AudioMath.perceptualGain(podVolume) * masterMult)
        podPlayer.setFade(Float(fadeMultiplier))
    }
    
    init() {
        self.noiseVolume = UserDefaults.standard.object(forKey: "noiseVolume") as? Double ?? 0.4
        self.binVolume = UserDefaults.standard.object(forKey: "binVolume") as? Double ?? 0.3
        self.podVolume = UserDefaults.standard.object(forKey: "podVolume") as? Double ?? 0.7
        
        self.noiseType = NoiseType.migrate(UserDefaults.standard.string(forKey: "noiseType") ?? "brown")
        if let data = UserDefaults.standard.data(forKey: "extraLayers"),
           let layers = try? JSONDecoder().decode([ExtraNoiseLayer].self, from: data) {
            self.extraLayers = layers.prefix(Self.maxExtraLayers).map {
                ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume, muted: $0.muted)
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
        //   - sleepTimer / pomodoro (~1/sec): SessionButton, NightRing, NightLine, BumpTimerButton in
        //     HomeView; FocusHero / FocusSessionReadout / CycleDots; NightDarken in AmbientScene.
        //     ContentView drives its night-dim off `sleepTimer.$timerRemaining` via onReceive.
        //   - playbackProgress (~1/sec): MiniPlayerView + NowPlayingSheet (Phase 1).
        //   - queueManager (user-action): NowPlayingSheet (queue list) + SettingsView (the
        //     Auto-Play / Shuffle toggles) observe it directly.
        //   - mixStore (user-action): HomeView (lastMix) + MixDrawer (savedPresets) observe it.
        pomodoro.chimeFn = { [weak self] in self?.chime.play() }
        // FOCUS-MODE-SPEC R6: breaks *feel* different — the ambient bed dips to ~70% during a
        // rest phase and restores on work/stop. Rides the sleep-timer fade multiplier, which
        // is free here (the two timers are mutually exclusive by mode), so the change gets the
        // same smooth per-sample ramp as the timer fade.
        pomodoro.phaseChangedFn = { [weak self] phase, running in
            guard let self else { return }
            self.fadeMultiplier = (running && phase == .rest) ? 0.7 : 1.0
        }

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
        queueManager.userStartedPlaybackFn = { [weak self] in self?.cancelTailForManualStart() }
        queueManager.pausePodcastFn = { [weak self] in
            guard let self else { return }
            self.podPlayer.pause()
            // Only claim "Queue finished" when it actually is. The sleep-aware hold also lands
            // here (advanceQueue with suppressAutoPlay) with the next episode cued for morning —
            // the old unconditional label lied about a non-empty queue all night.
            if self.queueManager.queue.isEmpty { self.podTitle = "Queue finished" }
        }
        sleepTimer.stopAllFn = { [weak self] in
            self?.stopAll()
        }
        // Ambient tail: at expiry the podcast pauses (keeping episode + position for "Resume
        // Last Night" — saveLastMix captures a loaded-but-paused episode) and the bed plays on
        // for the configured span, continuing the fade. See SleepTimerService.beginTail().
        sleepTimer.stopPodcastFn = { [weak self] in
            // The tail deliberately silences the podcast for the night — a call ending after
            // the handoff must not resurrect it (see podWasPlayingBeforeInterruption).
            self?.podWasPlayingBeforeInterruption = false
            self?.podPlayer.pause()
        }
        sleepTimer.tailEligibleFn = { [weak self] in
            guard let self else { return false }
            // The tail needs an ambient bed AND a podcast in tonight's mix — but not a
            // *still-playing* one: requiring `isPodPlaying` at the exact expiry moment meant
            // an episode that happened to end a couple of minutes early cancelled the
            // configured tail and hard-stopped the bed. `hasLoadedEpisode` survives the
            // episode ending (the player is kept), while still excluding pure-bed nights —
            // whose timers should stop when the user said stop, not gain a near-silent
            // 15–60 min zombie tail. (`stopPodcastFn` is a pause — a no-op when idle.)
            return self.hasLoadedEpisode && (self.noiseOn || self.binauralOn)
        }
        sleepTimer.ambientTailFn = {
            Double(UserDefaults.standard.integer(forKey: "ambientTailMinutes")) * 60.0
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
            DispatchQueue.main.async {
                guard let self else { return }
                self.episodeLoading = false
                // Really playing again (a lock-screen resume, a rebuild): not failed any more.
                if isPlaying { self.podcastFailed = false }
                self.isPodPlaying = isPlaying
                // A stop-with-episode timer only counts on the playback clock; paused, it moves to
                // the wall clock so the night still ends (SleepTimerService.podcastPaused).
                if !isPlaying { self.sleepTimer.podcastPaused() }
            }
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
        
        podPlayer.onPlaybackFailed = { [weak self] episodeId in
            DispatchQueue.main.async { self?.handlePodcastFailure(episodeId: episodeId) }
        }

        // Non-destructive note (buffering, "stream lost", "No podcast audio?"). Unlike
        // onPlaybackFailed, this never changes isPodPlaying. The limiter has its own signal below.
        podPlayer.onPlaybackNote = { [weak self] note in
            DispatchQueue.main.async { self?.playbackNote = note }
        }

        podPlayer.onLimiterUnavailable = { [weak self] in
            DispatchQueue.main.async { self?.handleLimiterUnavailable() }
        }
        
        podPlayer.onQueueAdvance = { [weak self] finishedEpId, didFinish in
            DispatchQueue.main.async {
                guard let self = self else { return }
                // Only a natural end marks the episode played. A failed / stalled-lost stream
                // must NOT be recorded as heard (it would vanish under "hide finished episodes").
                if didFinish, let id = finishedEpId {
                    self.queueManager.markFinished(id)
                }
                // End-of-episode sleep timer: stop everything when this episode ends rather than
                // rolling into the next one. (externalTick normally fires the stop just before the
                // natural end; this covers the exact boundary if the last tick missed it.)
                if self.sleepTimer.isEndOfEpisode {
                    self.sleepTimer.episodeEnded()   // the tail if one's set, else the stop
                    return
                }
                // In the ambient tail the podcast is done for the night: tidy the queue, play nothing.
                // (Auto-advancing here played the next episode under the tail, then cut it off.)
                if self.sleepTimer.inTail {
                    self.queueManager.advanceQueue(finishedEpId: finishedEpId, suppressAutoPlay: true)
                    return
                }
                // Sleep-aware hold: with a sleep timer running you're presumably asleep — burning
                // through the queue marks episodes you never heard as finished. When the option
                // is on, finish the current episode, tidy the queue (head drops, next is cued for
                // morning), and let the ambient bed carry the rest of the night.
                if self.sleepTimer.timerRemaining > 0,
                   UserDefaults.standard.bool(forKey: "holdQueueDuringSleepTimer") {
                    self.queueManager.advanceQueue(finishedEpId: finishedEpId, suppressAutoPlay: true)
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

        // A manual resume during the ambient tail means "I'm awake, keep the podcast going." The
        // tail deliberately paused the podcast and is fading the bed toward ~0; without this, the
        // resumed podcast would inherit that near-zero fade and play silently. Cancelling the timer
        // restores the fade to full (cancelTimer → updateFadeMultFn(1.0)) so the podcast is audible.
        // Gated on `inTail` so a normal pause/resume early in a timer leaves it running untouched.
        podPlayer.onResume = { [weak self] in
            guard let self, self.sleepTimer.inTail else { return }
            Log.timer.notice("podcast resumed during ambient tail — cancelling sleep timer so it's audible")
            self.sleepTimer.cancelTimer()
        }

        // Resume redirect — the fix for "the shown track isn't the one playing." With the
        // sleep-aware hold, an episode that finishes mid-timer advances the QUEUE (head = next,
        // cued for morning) but the PLAYER keeps the finished item. Every resume path — in-app,
        // mini-player, lock screen, post-interruption — would then replay the stale tail while the
        // whole UI (queue, artwork, mini-player) shows the next episode. When the loaded episode is
        // finished AND no longer the head, load the head instead. Deliberately narrow: an unfinished
        // paused episode always resumes in place, and replaying a finished episode the user
        // explicitly re-picked is untouched (playEpisode re-heads the queue, so ids match).
        podPlayer.resumeOverrideFn = { [weak self] in
            // Trigger on the PLAYER's own "this item is spent" flag rather than on a queue
            // comparison. The previous version required `head.id != loadedId`, which missed the
            // end-of-episode sleep timer entirely: that path calls stopAll() and returns WITHOUT
            // advancing the queue, so the finished episode stays BOTH loaded and at the head —
            // and every morning resume replayed its last ~30s (adaptive rewind) under its own
            // stale title. That is the "tracks repeating / position wrong" report.
            guard let self, self.podPlayer.didPlayToEnd else { return false }
            let loadedId = self.podPlayer.currentEpisodeId
            // Drop the spent episode if the queue still has it at the head (the end-of-episode
            // case); the hold case already removed it.
            if let loadedId, self.queueManager.queue.first?.id == loadedId {
                self.queueManager.advanceQueue(finishedEpId: loadedId, suppressAutoPlay: true)
            }
            if let head = self.queueManager.queue.first {
                Log.audio.notice("resume redirected: loaded episode is spent — playing the cued head instead of replaying its tail")
                self.podTitle = head.title
                // `resume: false` — this IS the auto-advance that was deferred, and a newly-cued
                // track starts at 0 (never inherit a stale/poisoned position from the map).
                self.loadPodcast(head.audioUrl, id: head.id, resume: false)
            } else {
                // Nothing cued. Replaying from the START is a sane answer to "play"; replaying
                // the last 30 seconds of an episode you already finished is not.
                Log.audio.notice("resume on a spent episode with an empty queue — restarting it from 0")
                self.podPlayer.seekTo(seconds: 0)
                self.podPlayer.resume()
            }
            return true
        }

        // Apple Music (Focus-only). Republish the system player's coarse state and yield the
        // lock-screen now-playing info to MusicKit while it's playing (one transport owner).
        appleMusic.onPlaybackStateChanged = { [weak self] playing in
            guard let self else { return }
            self.appleMusicOn = playing
            self.podPlayer.suppressNowPlaying = playing
            // When the music stops on its own (track list ended, user paused from the lock screen),
            // drop `.mixWithOthers` so the app returns to exclusive playback.
            if !playing { self.setAppleMusicMixing(false) }
        }
        appleMusic.onNowPlayingChanged = { [weak self] title, _ in
            self?.appleMusicTitle = title
        }
        appleMusic.onNote = { [weak self] note in
            DispatchQueue.main.async { self?.playbackNote = note }
        }

        // Audio-session plumbing is owned by AudioSessionController (Slice A3). It forwards
        // each event here via closures, hopping to the main queue first (AVAudioSession delivers
        // these on an arbitrary system thread) so the handlers can safely touch @Published state
        // and updateParams (main-queue + single-writer on the lock-free param buffer).
        sessionController.onInterruption = { [weak self] note in self?.handleInterruption(note: note) }
        sessionController.onRouteChange = { [weak self] note in self?.handleRouteChange(note: note) }
        sessionController.onAppBackground = { [weak self] in self?.handleAppBackground() }
        sessionController.onOnlineChanged = { [weak self] online in self?.connectivity.isOnline = online }
        sessionController.onMediaServicesReset = { [weak self] in self?.handleMediaServicesReset() }
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
        genEngine.setBinaural(on: binauralOn, volume: AudioMath.perceptualGain(binVolume), preset: binauralPreset)
        syncBeatMode()
        updateEnginePower()
    }

    /// The full ordered noise stack handed to the engine: the primary noise (layer 0) plus any
    /// extra layers (capped). The engine silences everything when `noiseOn` is false.
    private func buildNoiseLayers() -> [(type: String, volume: Double)] {
        // Volumes pass through the perceptual taper here — the single point where slider
        // positions become engine gains. Muted extra layers keep their slot (type + volume
        // preserved for un-mute) at gain 0.
        var layers: [(type: String, volume: Double)] = [(noiseType, AudioMath.perceptualGain(noiseVolume))]
        for l in extraLayers.prefix(Self.maxExtraLayers) {
            layers.append((l.type, (l.muted ?? false) ? 0.0 : AudioMath.perceptualGain(l.volume)))
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

    /// Mute/un-mute an extra layer in place — the layer (and its volume) survives, unlike
    /// `removeExtraLayer`. The engine keeps the slot at gain 0, so un-muting declicks back in.
    func setExtraLayerMuted(_ id: String, _ muted: Bool) {
        guard let i = extraLayers.firstIndex(where: { $0.id == id }) else { return }
        extraLayers[i].muted = muted
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
        // A first load has no AVPlayer until it lands; play then re-arms it (it may have been
        // paused mid-load) rather than starting the queue head over it.
        if podPlayer.hasPlayer || podPlayer.isLoadingItem {
            podPlayer.resume()
        } else if let first = queueManager.queue.first {
            podTitle = first.title
            loadPodcast(first.audioUrl, id: first.id)
        }
    }
    
    func togglePodcast() {
        if isPodPlaying { podPlayer.pause() } else { resumePodcast() }
    }

    /// The player's Next: skip to the next queued episode. Safe by construction: it never deletes
    /// the skipped episode's download or marks it played, and plays the next one even with
    /// Auto-Play off (see `PodcastQueueManager.skipToNext`).
    func skipToNextEpisode() {
        // Not mid-load: a second tap would drop the episode that's only just starting, unheard.
        guard !episodeLoading else { return }
        queueManager.skipToNext(currentId: loadedEpisode?.id)
    }

    /// The player gave up on an item. Ignored unless it's the episode the player is on now: the
    /// callback hops through the main queue, and a failure from an item that's since been replaced
    /// must not paint "Try again" over a working episode. (Internal: the tests drive it directly.)
    func handlePodcastFailure(episodeId: String?) {
        guard episodeId == nil || episodeId == loadedEpisode?.id else { return }
        // The system's reason ("The operation could not be completed") is logged by the player;
        // on screen it only alarmed. The player views offer Try again / Play next.
        playbackNote = NowPlayingState.failedCopy
        podcastFailed = true
        episodeLoading = false
        isPodPlaying = false
    }

    /// The limiter tap couldn't attach to this stream. Only worth a word when the Night Limiter is
    /// actually on (it ships off by default, and the tap still carries volume and the fade).
    func handleLimiterUnavailable() {
        guard podPlayer.nightLimiterEnabled else { return }
        limiterOffForStream = true
    }

    /// Try the loaded episode again after it failed. The failure already took it out of the queue
    /// (advance, not marked played), so this puts it back at the head and reloads it.
    func retryLoadedEpisode() {
        guard let ep = loadedEpisode else { return }
        // A stand-in (Resume Last Night's episode, no longer queued) is retried as it was loaded:
        // queueing it would write a title-only placeholder into queue.json for good.
        if ep.id == standInEpisodeId {
            cancelTailForManualStart()   // a person's pick, like playEpisode's
            loadPodcast(ep.audioUrl, id: ep.id, fallbackTitle: ep.title)
            return
        }
        queueManager.playEpisode(ep)
    }

    // MARK: Apple Music (Focus-only parallel source)

    /// Ask for Apple Music authorization (prompts on first use); for the picker's gating.
    func ensureAppleMusicAuthorized() async -> Bool {
        await appleMusic.ensureAuthorized()
    }

    /// Catalog search for the picker UI.
    func searchAppleMusic(_ term: String) async -> MusicCatalogSearchResponse? {
        await appleMusic.search(term)
    }

    /// Begin (or replace) the Apple Music queue with a chosen item and play it. Authorizes first,
    /// pauses any podcast (one spoken/music transport at a time), and layers `.mixWithOthers` onto
    /// the session so our activation doesn't stop MusicKit's player.
    func startAppleMusic<Item: PlayableMusicItem>(_ item: Item) {
        Task { @MainActor in
            guard await appleMusic.ensureAuthorized() else { return }
            if podcastIsPlayingOrStarting { podPlayer.pause() }
            setAppleMusicMixing(true)
            await appleMusic.play(item)
        }
    }

    /// Toggle the existing Apple Music selection (no-op if nothing chosen yet).
    func toggleAppleMusic() {
        Task { @MainActor in
            if appleMusic.isPlaying {
                appleMusic.pause()
            } else {
                guard appleMusic.hasSelection else { return }
                if podcastIsPlayingOrStarting { podPlayer.pause() }
                setAppleMusicMixing(true)
                await appleMusic.resume()
            }
        }
    }

    /// Stop Apple Music and revert the session to exclusive playback. Safe to call when idle.
    private func stopAppleMusic() {
        appleMusic.stop()
        appleMusicOn = false
        podPlayer.suppressNowPlaying = false
        setAppleMusicMixing(false)
    }

    /// Add/remove `.mixWithOthers` and re-assert the category + activation. `.mixWithOthers` is on
    /// ONLY while Apple Music is the active Focus source; the rest of the time the app keeps
    /// exclusive `.playback` (the all-night Sleep default).
    private func setAppleMusicMixing(_ on: Bool) {
        let desired: AVAudioSession.CategoryOptions = on ? [.mixWithOthers] : []
        guard AudioSessionConfig.options != desired else { return }
        AudioSessionConfig.options = desired
        AudioSessionConfig.applyCategory()
        Log.activateAudioSession("apple music mixing=\(on)")
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
        // An explicit pause between interruption .began/.ended must stick — without this,
        // the .ended resume would override the user's pause (see the flag's doc comment).
        podWasPlayingBeforeInterruption = false
        noiseOn = false
        binauralOn = false
        if podcastIsPlayingOrStarting { podPlayer.pause() }
        if appleMusic.isPlaying { appleMusic.pause() }
        isMasterPauseTransition = false
    }
    
    func saveLastMix() {
        // Capture the last-loaded podcast whenever one is selected in the mixer (an episode is
        // loaded), not only when it happens to be playing at this instant. saveLastMix runs from
        // pauseAll/stopAll, and a sleep-timer terminal stop pauses the player first — the old
        // `isPodPlaying` gate dropped the podcast from the snapshot, so Resume restored nothing.
        let head = queueManager.queue.first
        let hasPodcast = hasLoadedEpisode && head != nil
        // The snapshot names the queue HEAD, so its position must belong to the head too. After a
        // sleep-aware hold the loaded episode (finished, dropped from the queue) diverges from the
        // cued head — pairing the head's URL with the LOADED episode's elapsed told "Resume Last
        // Night" to start the next episode near the END of the previous one. When they diverge,
        // store no position: the cued episode starts fresh, which is what "cued for morning" means.
        // Read the position from the LIVE player, not the 1 Hz `podcastElapsed` UI slice: that
        // slice is 0 in the window between a load and its first observer tick, and a snapshot
        // taken there (backgrounding right after starting an episode) would tell Resume Last
        // Night to restart from the beginning. Anything under 5 s is stored as nil so the
        // saved-position map wins instead — a stored 0 forces a seek to 0 and loses the real spot.
        // Also require the loaded episode to BE the head it's being filed under (a hold-advanced
        // night diverges), else the next episode inherits the previous one's position.
        let loadedIsHead = podPlayer.currentEpisodeId == head?.id
        let livePosition = podPlayer.currentPositionSeconds ?? 0
        // Mid-swap (isLoadingItem) the id is already the new episode's but the position is still
        // the old item's; filing that pair would resume the new episode at the old one's offset.
        let position: Double? = (loadedIsHead && !podPlayer.isLoadingItem && livePosition > 5) ? livePosition : nil
        let mix = SavedMix(
            name: "Last Night",
            noiseOn: noiseOn,
            noiseVolume: noiseVolume,
            noiseType: noiseType,
            binauralOn: binauralOn,
            binVolume: binVolume,
            binauralPreset: binauralPreset,
            podVolume: podVolume,
            podcastUrl: hasPodcast ? head?.audioUrl : nil,
            podcastId: hasPodcast ? head?.id : nil,
            podcastPosition: hasPodcast ? position : nil,
            extraLayers: extraLayers.isEmpty ? nil : extraLayers
        )
        mixStore.saveLast(mix)
    }
    
    func resumeMix(_ mix: SavedMix) {
        self.noiseType = NoiseType.migrate(mix.noiseType)
        self.noiseVolume = mix.noiseVolume
        self.extraLayers = (mix.extraLayers ?? []).prefix(Self.maxExtraLayers).map {
            ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume, muted: $0.muted)
        }
        self.noiseOn = mix.noiseOn
        
        self.binauralPreset = mix.binauralPreset
        self.binVolume = mix.binVolume
        self.binauralOn = mix.binauralOn
        
        self.podVolume = mix.podVolume

        // NOTE: resume deliberately does NOT reconcileSoundsToMode() — resume must faithfully
        // restore exactly what was playing (a tested contract), and a SavedMix carries no mode,
        // so snapping to the *current* mode would corrupt a mix made for the other one. A truly
        // mode-aware resume needs a `mode` field on SavedMix (a backward-compatible schema add);
        // until then, restoring the sound as-saved is the honest behavior.

        if let urlStr = mix.podcastUrl {
            // Seek straight to the snapshot's stored position; fall back to the saved-position map
            // (resume: true) for older snapshots that predate podcastPosition.
            loadPodcast(urlStr, id: mix.podcastId ?? urlStr, resume: true, startAt: mix.podcastPosition,
                        fallbackTitle: "Last night\u{2019}s episode")
        }
    }
    
    /// Load a snapshot's sound picks (types and levels, never on/off) into the idle mixer, so
    /// opening Build mix at rest shows what Play would resume. Home's "Resume · Brown" and a mixer
    /// row reading "Green" used to disagree. Only sounds in the current mode's palette are taken:
    /// the mixer is mode-scoped, and a cross-mode pick stays as it is.
    /// The extra layers come with the noise, built the way `resumeMix` builds them, but only when
    /// the snapshot's whole noise stack is in the palette. A mode round trip drops cross-mode
    /// layers from the mixer while the snapshot keeps them, and a Sleep stack that happens to lead
    /// with pink (in both palettes) mustn't wipe the Focus layers.
    func stageForEditing(_ mix: SavedMix) {
        guard !isAnythingPlaying else { return }
        let noises = focusMode ? Self.focusNoises : Self.sleepNoises
        let binaurals = focusMode ? Self.focusBinaurals : Self.sleepBinaurals
        let noise = NoiseType.migrate(mix.noiseType)
        if noises.contains(noise) {
            if noiseType != noise { noiseType = noise }
            if noiseVolume != mix.noiseVolume { noiseVolume = mix.noiseVolume }
            let layers = (mix.extraLayers ?? []).prefix(Self.maxExtraLayers).map {
                ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume, muted: $0.muted)
            }
            if layers.allSatisfy({ noises.contains($0.type) }), extraLayers != layers { extraLayers = layers }
        }
        if binaurals.contains(mix.binauralPreset) {
            if binauralPreset != mix.binauralPreset { binauralPreset = mix.binauralPreset }
            if binVolume != mix.binVolume { binVolume = mix.binVolume }
        }
    }

    // MARK: Saved sound presets (reusable recipes — no podcast)

    /// A recipe-derived default name for the current soundscape ("Brown + Deep"), used to
    /// prefill the name-it prompt. Never the podcast title — a preset is about the sounds.
    func defaultPresetName() -> String {
        var parts: [String] = []
        if noiseOn {
            parts.append(SoundNames.noise(noiseType))
            parts.append(contentsOf: extraLayers.map { SoundNames.noise($0.type) })
        }
        if binauralOn { parts.append(SoundNames.binaural(binauralPreset)) }
        return parts.isEmpty ? "My Mix" : parts.joined(separator: " + ")
    }

    /// True if saving under `name` would overwrite an existing preset in the current mode —
    /// using the same trim + empty→`defaultPresetName()` fallback and case-insensitive match that
    /// `savePreset` uses, so the UI's "replace existing?" check agrees with what save actually does.
    func presetWouldOverwrite(named name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? defaultPresetName() : trimmed
        let mode = focusMode ? "focus" : "sleep"
        return mixStore.savedPresets.contains {
            $0.mode == mode && $0.name.caseInsensitiveCompare(finalName) == .orderedSame
        }
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
            ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume, muted: $0.muted)
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
        // An explicit stop between interruption .began/.ended must stick: PodcastPlayer.stop()
        // keeps the player, so a stale captured flag would let the .ended resume restart a
        // podcast the user (or the timer's terminal stop) deliberately silenced — full volume,
        // no timer, all night. Invalidate the capture on every deliberate stop.
        podWasPlayingBeforeInterruption = false
        noiseOn = false
        binauralOn = false
        podPlayer.stop()
        stopAppleMusic()
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
                ExtraNoiseLayer(id: $0.id, type: NoiseType.migrate($0.type), volume: $0.volume, muted: $0.muted)
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

    /// `fallbackTitle`: what to call an episode that isn't in the queue (Resume Last Night after
    /// the snapshot's episode left it). Without it the title fell back to `podTitle`, which at a
    /// cold launch is the queue head's: the player showed another episode's name over this audio.
    func loadPodcast(_ urlStr: String, id: String, resume: Bool = true, startAt: TimeInterval? = nil,
                     fallbackTitle: String? = nil) {
        playbackNote = nil
        podcastFailed = false
        limiterOffForStream = false
        episodeLoading = true
        // Resolve the title from the queue by id — the single point of truth for "what's loading."
        // Callers that pre-set podTitle (queueManager.loadPodcastFn) agree with this; callers that
        // didn't (resumeMix / the StartSleepulatorMix intent) used to pass a STALE podTitle into
        // play(), putting last night's episode name on the lock screen while a different episode's
        // audio played. Falls back to the existing podTitle for an episode not in the queue.
        if let ep = queueManager.queue.first(where: { $0.id == id }) {
            podTitle = ep.title
            loadedEpisode = ep
            standInEpisodeId = nil
        } else if loadedEpisode?.id != id {
            let title = fallbackTitle ?? podTitle
            podTitle = title
            loadedEpisode = Episode(id: id, title: title, audioUrl: urlStr)
            standInEpisodeId = id
        }
        // A fresh load invalidates the previous episode's progress NOW. The observer only ticks
        // during playback, so without this a snapshot taken between load and first tick (e.g.
        // saveLastMix on backgrounding) would pair the new episode with the OLD one's elapsed.
        playbackProgress.elapsed = 0
        playbackProgress.duration = 0
        playbackProgress.progress = 0
        let finalUrlStr = resolveAudioUrl(urlStr)
        podPlayer.play(url: finalUrlStr, id: id, title: podTitle, resume: resume, startAt: startAt)
    }

    /// A person chose to start a podcast (a row, a swipe, Up next, Resume, Play All). During the
    /// ambient tail that means "I'm awake": cancel the timer, as `podPlayer.onResume` does for a
    /// resume. A fresh `play()` never fires that hook, so without this the podcast plays at the
    /// tail's near-zero fade and is then stopped. Not on the queue's own auto-advance.
    private func cancelTailForManualStart() {
        guard sleepTimer.inTail else { return }
        Log.timer.notice("podcast started manually during ambient tail — cancelling sleep timer so it's audible")
        sleepTimer.cancelTimer()
    }

    /// Saved episode positions, from the player's in-memory map (fresher than positions.json).
    var savedEpisodePositions: [String: Double] { podPlayer.savedPositions }

    /// Start an episode from the Podcasts tab (the Tonight shelf's Resume, Back 5 min and Up next;
    /// the show page's Resume and Play Latest). `position` is where to start when it isn't loaded
    /// (nil = its saved position); `backUp` starts that much earlier.
    /// - Cancels the ambient tail first (`cancelTailForManualStart`).
    /// - When the episode is already loaded (and settled, not mid-swap), it continues from where
    ///   the player actually is instead of rebuilding the item: stored positions lag the live one.
    ///   If it's spent (played to the end, or within the near-end margin of its real length, e.g.
    ///   after an end-of-episode timer stop), it starts over rather than play a second and advance.
    func resumeEpisode(_ episode: Episode, at position: TimeInterval?, backUp: TimeInterval = 0) {
        cancelTailForManualStart()
        queueManager.moveToHead(episode)
        if podPlayer.hasPlayer, !podPlayer.isLoadingItem, podPlayer.currentEpisodeId == episode.id,
           let live = podPlayer.currentPositionSeconds {
            let length = podcastDuration.isFinite && podcastDuration > 0 ? podcastDuration : episode.duration
            let spent = podPlayer.didPlayToEnd
                || (live >= TonightShelf.minimumResumePosition && !TonightShelf.isResumable(position: live, duration: length))
            if spent {
                podPlayer.seekTo(seconds: 0)
            } else if backUp > 0 {
                podPlayer.seekTo(seconds: max(0, live - backUp))
            }
            if !isPodPlaying { resumePodcast() }
            return
        }
        let startAt = position.map { max(0, $0 - backUp) }
        loadPodcast(episode.audioUrl, id: episode.id, resume: true, startAt: startAt)
    }

    /// Start a sleep timer that ends when the current episode finishes (fading the ambient bed
    /// down over the last stretch). No-op without a loaded episode of known, finite length, so we
    /// never start a timer that would instantly fire on an unknown-duration live stream.
    /// Only while the podcast plays: this timer ticks off the playback clock, so started on a
    /// paused episode it cancelled the night's timer and then never ran out (the sounds played on
    /// all night).
    func startEndOfEpisodeTimer() {
        guard podPlayer.hasPlayer, isPodPlaying, podcastDuration.isFinite, podcastDuration > 5 else { return }
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

    /// Whether the podcast was playing when the interruption began. `.began`'s `pause()` flips
    /// `isPodPlaying` to false, so checking the live flag at `.ended` always read "wasn't
    /// playing" — a phone call or alarm at bedtime permanently silenced the podcast for the
    /// night. Captured at `.began`, consumed at `.ended`. OR-ed on capture so a nested second
    /// `.began` (which sees the already-paused state) can't erase the pending resume.
    /// Main-queue only (AudioSessionController hops every forward to main).
    private var podWasPlayingBeforeInterruption = false

    /// Internal so the tests can deliver an interruption without the audio session.
    func handleInterruption(note: Notification) {
        guard let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        if type == .began {
            // A load in flight counts as playing: it would start the episode as soon as it landed,
            // straight through the call, and the call's end should bring it back.
            let podActive = podcastIsPlayingOrStarting
            Log.timer.notice("interruption began (podWasPlaying=\(podActive, privacy: .public))")
            podWasPlayingBeforeInterruption = podWasPlayingBeforeInterruption || podActive
            genEngine.handleInterruption(shouldResume: false)
            if podActive { podPlayer.pause() }
        } else if type == .ended {
            // A missing options key must not abort recovery: the old early-return here skipped
            // the suspend-cancel, the session reactivation, AND the engine restart — a silent
            // dead bed for the rest of the night. Default to "no options" and recover anyway.
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)

            // A power-save suspend scheduled just before the call must not fire after we
            // restart the engine below — it would silently re-pause the bed mid-night.
            suspendWorkItem?.cancel()
            suspendWorkItem = nil

            // Reactivate the session before resuming whichever source was active. Previously
            // only the generative branch did this, so a podcast-only user got silence.
            Log.activateAudioSession("post-interruption")

            if noiseOn || binauralOn {
                genEngine.handleInterruption(shouldResume: true)
            }

            let willResumePod = options.contains(.shouldResume) && podWasPlayingBeforeInterruption
            Log.timer.notice("interruption ended (shouldResume=\(options.contains(.shouldResume), privacy: .public), resumingPod=\(willResumePod, privacy: .public))")
            if willResumePod {
                podPlayer.resume()
            }
            podWasPlayingBeforeInterruption = false
        }
    }
    
    private func handleRouteChange(note: Notification) {
        guard let reasonValue = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Log.timer.notice("route change: reason=\(reasonValue, privacy: .public) (headphones-gone=\(reason == .oldDeviceUnavailable, privacy: .public))")

        // Headphones unplugged: follow the HIG for spoken media — pause the podcast so a
        // voice doesn't suddenly play out the phone speaker (waking the room). Keep the
        // ambient noise bed going — it's a calibrated, limiter-bounded background you fall
        // asleep to; cutting it would do the opposite of the app's job. The beats stay on too:
        // syncBeatMode() below switches them to isochronic, which (unlike a true binaural beat)
        // actually works on a speaker.
        if reason == .oldDeviceUnavailable {
            if podcastIsPlayingOrStarting { podPlayer.pause() }
            // Headphones went away — also void a pending post-interruption resume, or a call
            // during which the AirPods died would resume the spoken podcast on the SPEAKER
            // (the exact wake-the-room case this pause exists to prevent).
            podWasPlayingBeforeInterruption = false
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

    /// The media server restarted (Apple: re-apply the category, reactivate, recreate players).
    /// Without this the podcast's AVPlayer stays invalid — silent — until the app is relaunched.
    private func handleMediaServicesReset() {
        Log.timer.error("media services were reset — re-asserting the session, rebuilding the podcast player")
        AudioSessionConfig.applyCategory()
        Log.activateAudioSession("media services reset")
        genEngine.handleMediaServicesReset(restart: noiseOn || binauralOn)
        podPlayer.handleMediaServicesReset()
    }

    private func handleAppBackground() {
        podPlayer.flushPositionsToDisk()
        // Capture "Last Night" now, not only on pause/stop: an overnight jetsam while still
        // playing would otherwise leave a stale resume snapshot. saveLast is a synchronous
        // UserDefaults write, so it's durable by the time we suspend.
        saveLastMix()
        // Force any deferred mixes.json write to run — a preset saved in the last half-second
        // must not be lost if the app is jettisoned overnight.
        mixStore.flushPendingWrites()
    }
}
