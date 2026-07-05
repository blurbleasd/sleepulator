import SwiftUI

struct HomeView: View {
    @ObservedObject var audio: AudioEngine
    /// Held UNobserved (plain `let`), passed down to `MixDrawer` which observes it. HomeView's only
    /// reactive use of mix state is the "Resume · …" status (`lastMix`), and `lastMix` is written
    /// only in `saveLastMix()` (pauseAll/stopAll) — which always flips `audio` state HomeView
    /// already observes, so the status still refreshes via that re-render. Observing `mixStore`
    /// here would mean saving a *preset* (a `savedPresets` change) re-renders this whole body,
    /// including the live Metal backdrop — a main-thread/GPU burst that can starve the real-time
    /// audio render thread and make the bed stutter mid-save. The preset list re-renders inside
    /// `MixDrawer`, which is where it belongs.
    let mixStore: MixStore
    /// Drives the Podcasts-tab deep link when the user taps the (empty) podcast layer.
    @Binding var selectedTab: Int
    /// One-time first-run coachmark: points at "Build mix" so a new user discovers that the app
    /// layers noise + binaural + podcasts. Set once the user dismisses it (or builds a mix).
    @AppStorage("hasCompletedFirstRun") private var hasCompletedFirstRun = false
    @State private var showTimerActionSheet = false
    @State private var isPlayPressed = false
    @State private var showBreathing = false
    @State private var showMix = false
    /// Opt-in ~1-minute breathing wind-down before a Sleep session starts.
    @AppStorage("breathingOnRamp") private var breathingOnRamp = false
    @State private var showOnRamp = false
    /// The deferred "begin playback" action, run after the on-ramp completes (or is skipped over).
    @State private var pendingStart: (() -> Void)?
    // Ambient screensaver: while playing in Sleep mode, the controls fade after a spell of
    // no interaction, leaving just the sky + moon. A tap brings them back. The flag lives on
    // `audio` so ContentView's tab bar + mini-player can fade with the home chrome.
    @State private var idleFade: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Shared gyro source for parallax scenes. Plain held instance (not observed); started only
    /// while a motion-using scene is on screen and not dimmed (see `reconcileMotion`).
    @State private var tiltSource = TiltSource()

    /// CoreMotion runs only when the visible scene actually reads tilt and the screen isn't
    /// occluded — honors the "costs nothing on the all-night dimmed screen" invariant. Reduce
    /// Motion disables parallax entirely.
    private func reconcileMotion() {
        // Stop the gyro whenever the scene is frozen for any reason (dimmed, backgrounded, or
        // low-luminance/Always-On), not just the night-dim veil.
        tiltSource.setActive(currentScene.usesMotion && !scenesFrozen && !reduceMotion)
    }

    /// Scenes (and CoreMotion) settle to a static frame whenever the screen is occluded by the
    /// night-dim veil, the app isn't active (backgrounded / app-switcher), or the display is in a
    /// low-luminance / Always-On state. Previously freezing was gated on the sleep-timer veil alone,
    /// so a no-timer session animated at full rate all night. This is purely additive — it only
    /// adds reasons to freeze, never removes the veil case.
    private var scenesFrozen: Bool {
        audio.screenDimmed || scenePhase != .active || isLuminanceReduced
    }

    // Selected backdrop scene per mode (persisted). Changing it re-renders the home; the
    // Build-mix drawer writes these via SceneSelector.
    @AppStorage("sceneSleep") private var sleepSceneId = "night-sky"
    @AppStorage("sceneFocus") private var focusSceneId = "energy"

    private var currentScene: any AmbientScene {
        let mood: SceneMood = audio.focusMode ? .focus : .sleep
        return SceneRegistry.scene(id: audio.focusMode ? focusSceneId : sleepSceneId, mood: mood)
    }

    // Swipe-to-change-backdrop: a left/right swipe anywhere on the home cycles the scene for the
    // current mood and briefly flashes its name. Far cheaper to reach than the buried Backdrop
    // chips in the Build-mix drawer (you can even swipe through scenes from the screensaver).
    @State private var sceneTitleVisible = false
    @State private var sceneTitleHide: DispatchWorkItem?

    private func cycleScene(_ dir: Int) {
        let mood: SceneMood = audio.focusMode ? .focus : .sleep
        let list = SceneRegistry.scenes(for: mood)
        guard list.count > 1 else { return }
        let curId = audio.focusMode ? focusSceneId : sleepSceneId
        let idx = list.firstIndex { $0.id == curId } ?? 0
        let next = list[((idx + dir) % list.count + list.count) % list.count]
        if audio.focusMode { focusSceneId = next.id } else { sleepSceneId = next.id }
        UISelectionFeedbackGenerator().selectionChanged()
        flashSceneTitle()
    }

    private func flashSceneTitle() {
        sceneTitleHide?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { sceneTitleVisible = true }
        let work = DispatchWorkItem {
            withAnimation(.easeIn(duration: 0.6)) { sceneTitleVisible = false }
        }
        sceneTitleHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func scheduleIdleFade() {
        idleFade?.cancel()
        // Sleep mode only — and now regardless of whether audio is playing, so the screen settles
        // to the bare backdrop on its own (Focus keeps its controls + session readout visible).
        guard !audio.focusMode else { return }
        let work = DispatchWorkItem {
            guard !self.audio.focusMode else { return }
            withAnimation(.easeInOut(duration: 0.9)) { self.audio.ambientScreensaver = true }
        }
        idleFade = work
        // Fades quickly after a spell of no interaction; any touch reschedules it (see the
        // simultaneousGesture in body), so it only runs once you've stopped touching the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    private func wakeChrome() {
        idleFade?.cancel()
        if audio.ambientScreensaver {
            withAnimation(.easeInOut(duration: 0.4)) { audio.ambientScreensaver = false }
        }
        scheduleIdleFade()
    }

    var pal: Palette { Palette(focusMode: audio.focusMode) }

    // The currently-playing layers, shown as pills under the orb.
    private var activeLayers: [String] {
        let binLabels = ["delta": "Deep", "theta": "Drift", "alpha": "Relax", "beta": "Concentrate", "gamma": "Focus"]
        var p: [String] = []
        if audio.noiseOn { p.append(audio.noiseType.capitalized) }
        if audio.binauralOn { p.append(binLabels[audio.binauralPreset] ?? audio.binauralPreset.capitalized) }
        if audio.isPodPlaying { p.append("Podcast") }
        return p
    }

    // The mode-aware bottom session control is now the `SessionButton` leaf (below), which
    // observes the timers directly so its countdown stays live without re-rendering HomeView.

    private func statusText() -> String {
        var parts: [String] = []
        if audio.noiseOn { parts.append(audio.noiseType.capitalized) }
        if audio.binauralOn { parts.append(audio.binauralPreset.capitalized) }
        if audio.isPodPlaying { parts.append("Podcast") }
        
        let layers = parts.isEmpty ? "All paused" : parts.joined(separator: " + ")
        
        if audio.isAnythingPlaying {
            // The live "· Nm" countdown is appended by SleepStatusLine (which observes the timer),
            // so statusText stays timer-free and doesn't re-render HomeView each second.
            return layers
        } else {
            if let mix = mixStore.lastMix, (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
                var p: [String] = []
                if mix.noiseOn { p.append(resumeDisplayName(noise: mix.noiseType)) }
                if mix.binauralOn { p.append(resumeDisplayName(binaural: mix.binauralPreset)) }
                if mix.podcastUrl != nil { p.append("Podcast") }
                return "Resume · \(p.joined(separator: " + "))"
            }
            return "Tap to begin"
        }
    }

    // R2 (FOCUS-MODE-SPEC): the label must show what tapping will *actually* resume.
    // `resumeMix` snaps cross-mode sounds into the current palette (reconcileSoundsToMode),
    // so mirror that snap here instead of echoing a stale Sleep mix's sound names in Focus.
    private func resumeDisplayName(noise: String) -> String {
        let palette = audio.focusMode ? AudioEngine.focusNoises : AudioEngine.sleepNoises
        return (palette.contains(noise) ? noise : (palette.first ?? noise)).capitalized
    }
    private func resumeDisplayName(binaural: String) -> String {
        let palette = audio.focusMode ? AudioEngine.focusBinaurals : AudioEngine.sleepBinaurals
        return (palette.contains(binaural) ? binaural : (palette.first ?? binaural)).capitalized
    }

    private func heroTap() {
        // Already playing → just toggle (pause). The on-ramp is only for *beginning* a session.
        if audio.isAnythingPlaying {
            audio.toggleMasterTransport()
            return
        }

        // Resolve how this tap would begin playback.
        let begin: () -> Void
        if let mix = mixStore.lastMix,
           (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
            begin = { audio.resumeMix(mix) }
        } else if !hasCompletedFirstRun {
            // First-ever play with nothing to resume: start a layered bed (noise + binaural)
            // instead of a single bare noise, so the first tap shows what the app actually does.
            begin = { audio.startDefaultMix() }
        } else {
            begin = { audio.toggleMasterTransport() }
        }

        // Optional breathing wind-down before Sleep playback (never in Focus — Pomodoro starts now).
        if breathingOnRamp && !audio.focusMode {
            pendingStart = begin
            showOnRamp = true
        } else {
            begin()
        }
    }

    var body: some View {
        ZStack {
            RadialGradient(
                gradient: Gradient(colors: [pal.glow, pal.bg]),
                center: UnitPoint(x: 0.5, y: 0.82),
                startRadius: 5,
                endRadius: 620
            )
            .ignoresSafeArea()

            // Backdrop is the selected AmbientScene for the current mode (Phase 1 of
            // SCREENSAVER-LIBRARY-SPEC): scenes live behind a protocol + registry, so adding
            // one is "conform + register," not editing this branch. Picked in the Build-mix
            // drawer; selection persists per mode.
            currentScene.makeBackdrop(SceneContext(
                palette: pal,
                reduceMotion: reduceMotion,
                paused: scenesFrozen,
                sleepTimer: audio.sleepTimer,
                pomodoro: audio.pomodoro,
                audioLevel: { [weak audio] in audio?.audioLevel ?? 0 },
                tilt: { tiltSource.tilt }
            ))
            .onAppear { reconcileMotion() }
            .onDisappear { tiltSource.stop() }
            .onChange(of: audio.screenDimmed) { _, _ in reconcileMotion() }
            .onChange(of: scenePhase) { _, _ in reconcileMotion() }
            .onChange(of: isLuminanceReduced) { _, _ in reconcileMotion() }
            .onChange(of: currentScene.id) { _, _ in reconcileMotion() }
            
            // Ambient-minimal foreground: the night sky is the screen. A mode toggle up top,
            // a single central orb (play/pause) with the active sounds as pills, and one
            // "Build mix" control that opens the full mixer in a drawer. Everything detailed
            // is deliberately tucked away.
            VStack(spacing: 0) {
                ModeSwitcher(focusMode: $audio.focusMode, pal: pal)
                    .padding(.horizontal, 40)
                    .padding(.top, 6)

                if let note = audio.playbackNote {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(note).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                    }
                    .foregroundColor(pal.accent)
                    .padding(10)
                    .background(pal.text.opacity(0.05))
                    .cornerRadius(12)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                }

                Spacer()

                VStack(spacing: 20) {
                    if audio.focusMode {
                        // Focus: the depleting Pomodoro ring is the hero. The orb still
                        // play/pauses audio; the ring + readout report the session. Freeze the
                        // ring/orb redraw when backgrounded or low-luminance (Focus never engages
                        // the sleep veil, so scenesFrozen reduces to those two here).
                        FocusHero(audio: audio, pomodoro: audio.pomodoro, pal: pal, tap: heroTap,
                                  paused: scenesFrozen)

                        FocusSessionReadout(pomodoro: audio.pomodoro,
                                            pal: pal,
                                            idleStatus: statusText(),
                                            layers: activeLayers)
                    } else {
                        // Freeze the orb's breath whenever it isn't visible: the chrome has
                        // faded to the screensaver (opacity 0 below) OR the screen is occluded/
                        // backgrounded/low-luminance. Stops the all-night invisible blur composite.
                        OrbButton(audio: audio, pal: pal, tap: heroTap,
                                  paused: audio.ambientScreensaver || scenesFrozen)

                        SleepStatusLine(base: statusText(),
                                        showMinute: audio.isAnythingPlaying,
                                        sleepTimer: audio.sleepTimer,
                                        pal: pal)

                        if !activeLayers.isEmpty {
                            LayerPills(layers: activeLayers, pal: pal)
                        }

                        // Rescued from the old HeroTransport: as the fade is about to cut the
                        // night off, offer a half-asleep one-tap "+15m". Now a leaf observing the
                        // timer directly so its show/hide threshold tracks the live countdown
                        // without re-rendering HomeView each second.
                        BumpTimerButton(sleepTimer: audio.sleepTimer, pal: pal)
                    }
                }

                Spacer()

                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Button(action: {
                            if !hasCompletedFirstRun { hasCompletedFirstRun = true }
                            showMix = true
                        }) {
                            HStack(spacing: 7) {
                                Image(systemName: "slider.horizontal.3")
                                Text("Build mix").font(.subheadline.weight(.semibold))
                            }
                            .foregroundColor(pal.text)
                            .padding(.horizontal, 22).padding(.vertical, 13)
                            .background(Capsule().fill(pal.text.opacity(0.10)))
                            .overlay(Capsule().stroke(pal.accent.opacity(0.28), lineWidth: 0.5))
                        }
                        .frame(minHeight: 44)

                        SessionButton(sleepTimer: audio.sleepTimer,
                                      pomodoro: audio.pomodoro,
                                      focusMode: audio.focusMode,
                                      pal: pal,
                                      onSleepTap: { showTimerActionSheet = true })
                    }

                    // Breathing is a quiet Sleep-mode extra (re-homed from the old hero).
                    if !audio.focusMode {
                        Button(action: { showBreathing = true }) {
                            HStack(spacing: 5) {
                                Image(systemName: "wind")
                                Text("Breathing exercise")
                            }
                            .font(.caption.weight(.medium))
                            .foregroundColor(pal.dim.opacity(0.8))
                        }
                        .frame(minHeight: 36)
                    }
                }
                // The mini-player floats over the bottom in EVERY state (it shows an idle
                // "Nothing playing" bar when nothing's loaded), so the controls need this inset
                // even with no episode — the old `: 22` let the always-present bar cover the
                // "Build mix" button. A constant also stops the row jumping when a podcast
                // loads/unloads. Tune by eye on device.
                .padding(.bottom, 112)
            }
            .opacity(audio.ambientScreensaver ? 0 : 1)
            .allowsHitTesting(!audio.ambientScreensaver)
            .animation(.easeInOut(duration: 0.9), value: audio.ambientScreensaver)
            // Any touch on the live controls is interaction — push the idle countdown back
            // (simultaneous so it doesn't steal taps from the buttons underneath).
            .simultaneousGesture(
                TapGesture().onEnded {
                    if !audio.ambientScreensaver { scheduleIdleFade() }
                }
            )

            // Once the controls have faded, a transparent layer catches the next tap to
            // bring them back. The sky + moon stay visible underneath — the screensaver.
            if audio.ambientScreensaver {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture { wakeChrome() }
                    .accessibilityLabel("Show controls")
                    .accessibilityAddTraits(.isButton)
            }

            // First-run coachmark: a single dismissible card pointing down at "Build mix" so a
            // new user discovers the layering. Never shown once dismissed, or while the screen
            // has faded to the ambient screensaver.
            if !hasCompletedFirstRun && !audio.focusMode && !audio.ambientScreensaver {
                VStack {
                    Spacer()
                    FirstRunCoachmark(pal: pal) {
                        withAnimation(.easeInOut(duration: 0.3)) { hasCompletedFirstRun = true }
                    }
                    .padding(.horizontal, 28)
                    // Sit just above the Build mix / timer row.
                    .padding(.bottom, audio.hasLoadedEpisode ? 188 : 96)
                }
                .transition(.opacity)
            }

            // Transient backdrop name, shown for ~1.6s after a swipe changes the scene.
            if sceneTitleVisible {
                VStack {
                    Text(currentScene.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .tracking(1.0)
                        .foregroundColor(pal.text)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(Capsule().fill(pal.text.opacity(0.10)))
                        .overlay(Capsule().stroke(pal.accent.opacity(0.25), lineWidth: 0.5))
                        .padding(.top, 70)
                    Spacer()
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        // A small home-screen gesture vocabulary, simultaneous so it coexists with the orb press
        // and the idle-fade tap:
        //   • swipe left/right  → cycle the backdrop for the current mood,
        //   • swipe up          → open the Build-mix sheet (the full mixer, one gesture away).
        // Both count as interaction (wake chrome / reset the idle countdown).
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    let dx = v.translation.width, dy = v.translation.height
                    if abs(dx) > abs(dy) * 1.3 && abs(dx) > 48 {
                        if audio.ambientScreensaver { wakeChrome() } else { scheduleIdleFade() }
                        cycleScene(dx < 0 ? 1 : -1)               // swipe left → next scene
                    } else if dy < -60 && abs(dy) > abs(dx) * 1.3 {
                        if audio.ambientScreensaver { wakeChrome() }
                        if !hasCompletedFirstRun { hasCompletedFirstRun = true }
                        showMix = true                            // swipe up → open the mixer
                    }
                }
        )
        .onAppear { scheduleIdleFade() }
        // Leaving Home (tab switch, sheet, etc.): kill the pending idle-fade so the screensaver
        // can't engage while another tab is showing and hide its tab bar (the "stuck off Home" bug).
        .onDisappear { idleFade?.cancel() }
        .onChange(of: audio.isAnythingPlaying) { _, playing in
            if playing { scheduleIdleFade() } else { wakeChrome() }
        }
        .onChange(of: audio.focusMode) { _, focus in
            // Never screensaver while focusing — the session readout must stay visible.
            if focus { idleFade?.cancel(); withAnimation { audio.ambientScreensaver = false } }
            else { scheduleIdleFade() }
        }
        .fullScreenCover(isPresented: $showBreathing) {
            BreathingView(isPresented: $showBreathing)
        }
        .fullScreenCover(isPresented: $showOnRamp) {
            BreathingOnRampView(
                onBegin: {
                    showOnRamp = false
                    let start = pendingStart
                    pendingStart = nil
                    start?()
                },
                onCancel: {
                    showOnRamp = false
                    pendingStart = nil
                }
            )
        }
        .sheet(isPresented: $showTimerActionSheet) {
            TimerSelectionSheet(audio: audio, isPresented: $showTimerActionSheet, pal: pal)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // Let the home scene drift dimly behind the sheet so the glass panels have real
                // moving content to refract — the difference between a flat box and real glass.
                .presentationBackground(pal.bg.opacity(0.72))
        }
        .sheet(isPresented: $showMix) {
            MixDrawer(audio: audio, mixStore: mixStore, pal: pal, onPickEpisode: {
                showMix = false
                selectedTab = 1   // jump to the Podcasts tab to choose an episode
            })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(pal.bg.opacity(0.72))
        }
    }
}

