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
    /// The mini-player's Now Playing sheet (owned by ContentView): a presentation over Home, so
    /// the screensaver must not fade Home, the tab bar and the mini-player behind it.
    var nowPlayingPresented: Bool = false
    /// Bumped by ContentView on every mini-player tap: Home interaction, pushes the countdown back.
    var miniPlayerTouches: Int = 0
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
    /// Run once the timer sheet has finished dismissing — the on-ramp cover can't present while
    /// the sheet is still on screen.
    @State private var afterTimerSheet: (() -> Void)?
    /// A mode switch waiting on its confirm (a live session would end or change; see SessionGuards).
    @State private var modeSwitchRequest: PendingModeSwitch?
    /// The night ring's remembered length in minutes (0 = All night). Play honours it in Sleep.
    /// Its own key, defaulting to All night, so nobody's Play quietly starts timing out on update.
    @AppStorage("nightLengthMinutes") private var nightLength: Double = 0
    /// A ring drag is live: the left/right scene swipe stands down for that touch.
    @State private var ringDragging = false
    /// Run once the Build-mix sheet has finished dismissing (it hands off to Breathing).
    @State private var afterMixSheet: (() -> Void)?
    // Ambient screensaver: while a session plays, the controls fade after a spell of no
    // interaction, leaving just the sky + moon. A tap brings them back. The flag lives on
    // `audio` so ContentView's tab bar + mini-player can fade with the home chrome. When it may
    // engage is `HomeScreensaverPolicy`'s call.
    @State private var idleFade: DispatchWorkItem?
    /// Mirrors `audio.pomodoro.isRunning` — the Pomodoro isn't forwarded through `audio`, so
    /// HomeView would otherwise never re-render when a silent Focus session starts or stops.
    @State private var pomodoroRunning = false
    /// True while Home is the on-screen tab. Input changes fire onChange even when another tab is
    /// showing; a fade scheduled then would publish `ambientScreensaver` from off-screen.
    @State private var homeVisible = false
    /// Safe-area insets while the tab bar shows, and the live ones. The screensaver hides the tab
    /// bar, which shrinks the bottom inset; `chromeLift` pads that difference back so the controls
    /// hold their position instead of dropping onto the mini-player as they fade in and out.
    @State private var anchoredInsets = EdgeInsets()
    @State private var liveInsets = EdgeInsets()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverOn
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControlOn
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Reduce Transparency: the sheets go opaque instead of letting the scene show through.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
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
        SceneDiagnostics.shared.activeScene = currentScene.id   // tag F3 render samples with the visible scene
        SceneDiagnostics.shared.frozen = scenesFrozen
        SceneDiagnostics.shared.reduceMotion = reduceMotion
    }

    /// Scenes (and CoreMotion) settle to a static frame whenever the screen is occluded by the
    /// night-dim veil, the app isn't active (backgrounded / app-switcher), or the display is in a
    /// low-luminance / Always-On state — or the user turned off the app-level "Ambient motion"
    /// setting. Previously freezing was gated on the sleep-timer veil alone, so a no-timer session
    /// animated at full rate all night. This is purely additive — it only adds reasons to freeze,
    /// never removes the veil case.
    private var scenesFrozen: Bool {
        audio.screenDimmed || scenePhase != .active || isLuminanceReduced || !ambientMotion
    }

    // Selected backdrop scene per mode (persisted). Changing it re-renders the home; the
    // Build-mix drawer writes these via SceneSelector.
    @AppStorage("sceneSleep") private var sleepSceneId = "night-sky"
    @AppStorage("sceneFocus") private var focusSceneId = "current"
    /// App-level "Ambient motion" override (Settings ▸ Display). ON by default = the current behavior;
    /// OFF stills the backdrop to a static frame. An explicit control on top of system Reduce Motion,
    /// which by convention only gates parallax (SCREENSAVER-LIBRARY-SPEC §5) — the app toggle is the
    /// home for the user who wants the scene itself to hold still.
    @AppStorage("ambientMotion") private var ambientMotion = true

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

    private var sessionActive: Bool {
        HomeScreensaverPolicy.sessionActive(audioPlaying: audio.isAnythingPlaying,
                                            appleMusicOn: audio.appleMusicOn,
                                            pomodoroRunning: pomodoroRunning)
    }
    private var assistiveTechRunning: Bool { voiceOverOn || switchControlOn }
    private var presentingFromHome: Bool {
        showMix || showTimerActionSheet || showBreathing || showOnRamp || nowPlayingPresented
            || modeSwitchRequest != nil
    }
    private var mayFade: Bool {
        HomeScreensaverPolicy.mayFade(sessionActive: sessionActive,
                                      assistiveTechRunning: assistiveTechRunning,
                                      presenting: presentingFromHome)
    }

    private var chromeLift: EdgeInsets {
        HomeScreensaverPolicy.chromeLift(anchored: anchoredInsets, live: liveInsets)
    }

    private func scheduleIdleFade() {
        idleFade?.cancel()
        guard homeVisible, mayFade else { return }
        // Both modes settle to the bare backdrop after a spell of no interaction (delays in
        // HomeScreensaverPolicy). Any change to a mayFade input cancels or reschedules this item,
        // so it can't fire on stale conditions.
        let delay = HomeScreensaverPolicy.idleDelay(focusMode: audio.focusMode)
        let work = DispatchWorkItem {
            guard self.homeVisible else { return }   // @State: reads the live value, not the copy's
            withAnimation(.easeInOut(duration: 0.9)) { self.audio.ambientScreensaver = true }
        }
        idleFade = work
        // Any touch reschedules it (see the simultaneousGesture in body), so it only runs once
        // you've stopped touching the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func wakeChrome() {
        idleFade?.cancel()
        if audio.ambientScreensaver {
            // Sleep eyes are dark-adapted: bring the controls up slowly rather than snapping them
            // on. They take taps immediately; only the light ramps.
            withAnimation(.easeOut(duration: audio.focusMode ? 0.4 : 1.0)) { audio.ambientScreensaver = false }
        }
        scheduleIdleFade()
    }

    var pal: Palette { Palette(focusMode: audio.focusMode) }

    // The currently-playing layers, shown as pills under the orb.
    private var activeLayers: [String] {
        var p: [String] = []
        if audio.noiseOn { p.append(SoundNames.noise(audio.noiseType)) }
        if audio.binauralOn { p.append(SoundNames.binaural(audio.binauralPreset)) }
        if audio.isPodPlaying { p.append("Podcast") }
        return p
    }

    // The mode-aware bottom session control is now the `SessionButton` leaf (below), which
    // observes the timers directly so its countdown stays live without re-rendering HomeView.

    private func statusText() -> String {
        var parts: [String] = []
        if audio.noiseOn { parts.append(SoundNames.noise(audio.noiseType)) }
        if audio.binauralOn { parts.append(SoundNames.binaural(audio.binauralPreset)) }
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
        return SoundNames.noise(palette.contains(noise) ? noise : (palette.first ?? noise))
    }
    private func resumeDisplayName(binaural: String) -> String {
        let palette = audio.focusMode ? AudioEngine.focusBinaurals : AudioEngine.sleepBinaurals
        return SoundNames.binaural(palette.contains(binaural) ? binaural : (palette.first ?? binaural))
    }

    /// How beginning playback from rest would go: resume the last mix, the first-run layered bed,
    /// or the transport's own resume (which always lands on at least the noise bed).
    private func resolveBegin() -> () -> Void {
        if let mix = mixStore.lastMix,
           (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
            return { audio.resumeMix(mix) }
        } else if !hasCompletedFirstRun {
            // First-ever play with nothing to resume: start a layered bed (noise + binaural)
            // instead of a single bare noise, so the first tap shows what the app actually does.
            return { audio.startDefaultMix() }
        }
        return { audio.toggleMasterTransport() }
    }

    private func heroTap() {
        // Already playing → just toggle (pause). The on-ramp is only for *beginning* a session.
        if audio.isAnythingPlaying {
            audio.toggleMasterTransport()
            return
        }

        let begin = withNightLength(resolveBegin())
        // Optional breathing wind-down before Sleep playback (never in Focus — Pomodoro starts now).
        if breathingOnRamp && !audio.focusMode {
            pendingStart = begin
            showOnRamp = true
        } else {
            begin()
        }
    }

    /// In Sleep, beginning playback also starts the night ring's timer (unless the ring is on All
    /// night, or a countdown is already running from before a pause).
    private func withNightLength(_ begin: @escaping () -> Void) -> () -> Void {
        guard !audio.focusMode else { return begin }
        let length = nightLength
        return {
            begin()
            if let m = SessionGuards.timerOnPlay(lengthMinutes: length,
                                                 timerActive: audio.sleepTimer.timerRemaining > 0) {
                audio.sleepTimer.startSleepTimer(minutes: m)
            }
        }
    }

    /// "Play & start timer" from the timer sheet: begin the mix (through the breathing on-ramp
    /// when it's on), then the countdown — so a sleep timer never runs over silence. With the
    /// on-ramp, the countdown starts when the mix does, not while you're still breathing.
    private func playAndStartTimer(minutes: Int) {
        let begin = resolveBegin()
        let session = {
            begin()
            audio.sleepTimer.startSleepTimer(minutes: minutes)
        }
        if breathingOnRamp && !audio.focusMode {
            pendingStart = session
            afterTimerSheet = { showOnRamp = true }
        } else {
            session()
        }
    }

    /// The mode switcher asks; a live session gets a confirm first (SessionGuards).
    private func requestMode(_ focus: Bool) {
        let warning = SessionGuards.modeSwitchWarning(
            toFocus: focus,
            sleepTimerActive: audio.sleepTimer.timerRemaining > 0,
            sleepSoundsPlaying: !audio.focusMode && audio.isAnythingPlaying,
            pomodoroRunning: pomodoroRunning)
        guard let warning else { applyMode(focus); return }
        let request = PendingModeSwitch(toFocus: focus, warning: warning)
        if showMix {
            // The half-height mixer leaves the switch tappable, but a confirm can't present over
            // the sheet (it silently failed and left the request stuck, holding the screensaver
            // off). Close the mixer, then ask.
            afterMixSheet = { modeSwitchRequest = request }
            showMix = false
        } else {
            modeSwitchRequest = request
        }
    }

    private func applyMode(_ focus: Bool) {
        if reduceMotion { audio.focusMode = focus }
        else { withAnimation(.easeInOut(duration: 0.2)) { audio.focusMode = focus } }
    }

    private var buildMixButton: some View {
        Button(action: {
            if !hasCompletedFirstRun { hasCompletedFirstRun = true }
            showMix = true
        }) {
            HStack(spacing: 7) {
                Image(systemName: "slider.horizontal.3")
                Text("Build mix").font(.subheadline.weight(.semibold))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundColor(pal.text)
            .padding(.horizontal, 22).padding(.vertical, 13)
            .background(Capsule().fill(pal.text.opacity(0.10)))
            .overlay(Capsule().stroke(pal.accent.opacity(0.28), lineWidth: 0.5))
        }
        .frame(minHeight: 44)
    }

    private var focusSessionButton: some View {
        SessionButton(sleepTimer: audio.sleepTimer,
                      pomodoro: audio.pomodoro,
                      focusMode: audio.focusMode,
                      pal: pal,
                      onSleepTap: { showTimerActionSheet = true })
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
            .onChange(of: ambientMotion) { _, _ in reconcileMotion() }   // stop CoreMotion when motion is off
            
            // Ambient-minimal foreground: the night sky is the screen. A mode toggle up top,
            // a single central orb (play/pause) with the active sounds as pills, and one
            // "Build mix" control that opens the full mixer in a drawer. Everything detailed
            // is deliberately tucked away.
            VStack(spacing: 0) {
                ModeSwitcher(focusMode: audio.focusMode, pal: pal,
                             quiet: !audio.focusMode && (sessionActive || audio.sleepTimer.timerRemaining > 0),
                             onSelect: requestMode)
                    // Attached here, not on the root, so iOS 26's popover-style dialog points at
                    // the switch that raised it.
                    .confirmationDialog(modeSwitchRequest?.warning.title ?? "",
                                        isPresented: Binding(get: { modeSwitchRequest != nil },
                                                             set: { if !$0 { modeSwitchRequest = nil } }),
                                        titleVisibility: .visible,
                                        presenting: modeSwitchRequest) { request in
                        Button(request.warning.confirm, role: .destructive) { applyMode(request.toFocus) }
                        Button(request.warning.cancel, role: .cancel) {}
                    } message: { request in
                        Text(request.warning.message)
                    }
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
                        // The orb inside the night ring: tap the disc to play, drag the ring's
                        // handle to set how long the night runs (Play honours it).
                        ZStack {
                            OrbButton(audio: audio, pal: pal, tap: heroTap,
                                      paused: audio.ambientScreensaver || scenesFrozen,
                                      idleStatus: statusText())
                                .anchorPreference(key: CoachmarkAnchorKey.self, value: .bounds) { [.orb: $0] }
                            NightRing(sleepTimer: audio.sleepTimer, pal: pal,
                                      playing: audio.isAnythingPlaying,
                                      lengthMinutes: $nightLength,
                                      dragging: $ringDragging,
                                      openOptions: { showTimerActionSheet = true })
                        }

                        NightLine(resumeText: statusText(),
                                  playing: audio.isAnythingPlaying,
                                  lengthMinutes: nightLength,
                                  sleepTimer: audio.sleepTimer,
                                  pal: pal,
                                  openOptions: { showTimerActionSheet = true })

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
                    if audio.focusMode {
                        // Side by side when they fit; stacked at large text sizes, where the row
                        // used to wrap "Build / mix" and run off the screen edge.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { buildMixButton; focusSessionButton }
                            VStack(spacing: 6) { buildMixButton; focusSessionButton }
                        }
                    } else {
                        // Sleep's timer lives on the orb's ring, so Build mix stands alone.
                        buildMixButton
                    }
                }
                .frame(maxWidth: .infinity)
                .anchorPreference(key: CoachmarkAnchorKey.self, value: .bounds) { [.mixRow: $0] }
                // Clear of the floating mini-player by its measured height, when it shows on Home
                // (Focus, or a podcast playing). Frozen through the screensaver, which hides the
                // tab bar under the controls (chromeLift holds their position then).
                .padding(.bottom, 16)
                .miniPlayerClearance(frozen: audio.ambientScreensaver)
            }
            // First-run coachmark: a single dismissible card pointing down at "Build mix" so a new
            // user discovers the layering. It fills the band between the orb's disc and the Build
            // mix row, measured from both (a fixed offset can't fit every phone and text size),
            // and picks a layout that fits it — so it never covers the orb its copy says to tap,
            // nor the row it points at. Inside the chrome stack, so it rides the chrome's fade.
            .overlayPreferenceValue(CoachmarkAnchorKey.self) { anchors in
                if !hasCompletedFirstRun && !audio.focusMode,
                   let orb = anchors[.orb], let mixRow = anchors[.mixRow] {
                    GeometryReader { proxy in
                        let room = CoachmarkLayout.room(orb: proxy[orb], mixRowTop: proxy[mixRow].minY)
                        FirstRunCoachmark(pal: pal) {
                            withAnimation(.easeInOut(duration: 0.3)) { hasCompletedFirstRun = true }
                        }
                        .padding(.horizontal, 28)
                        .frame(width: proxy.size.width, height: room.height, alignment: .bottom)
                        .offset(y: room.top)
                    }
                    .transition(.opacity)
                }
            }
            // Hold position while the screensaver has the tab bar hidden (see `chromeLift`).
            .padding(.top, chromeLift.top)
            .padding(.bottom, chromeLift.bottom)
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
        .onGeometryChange(for: EdgeInsets.self) { $0.safeAreaInsets } action: { insets in
            liveInsets = insets
            // Anchor only while the tab bar shows, so the lift is exactly what hiding it took away.
            if !audio.ambientScreensaver { anchoredInsets = insets }
        }
        // A small home-screen gesture vocabulary, simultaneous so it coexists with the orb press
        // and the idle-fade tap:
        //   • swipe left/right  → cycle the backdrop for the current mood,
        //   • swipe up          → open the Build-mix sheet (the full mixer, one gesture away).
        // Both count as interaction (wake chrome / reset the idle countdown).
        .simultaneousGesture(
            DragGesture(minimumDistance: 24)
                .onEnded { v in
                    guard !ringDragging else { return }   // that touch was setting the night
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
        .onAppear {
            homeVisible = true
            scheduleIdleFade()
        }
        // Leaving Home (tab switch, sheet, etc.): kill the pending idle-fade so the screensaver
        // can't engage while another tab is showing and hide its tab bar (the "stuck off Home" bug).
        .onDisappear {
            homeVisible = false
            idleFade?.cancel()
        }
        // Every mayFade input cancels or reschedules on change — the pending fade never outlives
        // the conditions it was scheduled under.
        .onReceive(audio.pomodoro.$isRunning) { pomodoroRunning = $0 }
        .onChange(of: sessionActive) { _, active in
            // A session ending on its own (sleep timer, AirPods out, an interruption) must not
            // light the room: if the screen has already faded it stays dark until a tap, and
            // visible controls simply stay put. Only the pending fade is dropped.
            if active { scheduleIdleFade() } else { idleFade?.cancel() }
        }
        // A mini-player tap is interaction with the Home screen too.
        .onChange(of: miniPlayerTouches) { _, _ in
            if !audio.ambientScreensaver { scheduleIdleFade() }
        }
        // VoiceOver / Switch Control turned on mid-screensaver: bring every control back now.
        .onChange(of: assistiveTechRunning) { _, _ in wakeChrome() }
        // A sheet opening cancels the countdown; closing one wakes the chrome and restarts it.
        .onChange(of: presentingFromHome) { _, _ in wakeChrome() }
        .onChange(of: audio.focusMode) { _, _ in
            // Switching mood counts as interaction: bring the chrome back and restart the idle
            // countdown so the new mood's screensaver timing (Sleep fast / Focus longer) applies.
            wakeChrome()
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
        .sheet(isPresented: $showTimerActionSheet, onDismiss: {
            let next = afterTimerSheet
            afterTimerSheet = nil
            next?()
        }) {
            TimerSelectionSheet(audio: audio, isPresented: $showTimerActionSheet, pal: pal,
                                playAndStart: playAndStartTimer)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                // Let the home scene drift dimly behind the sheet so the glass panels have real
                // moving content to refract — the difference between a flat box and real glass.
                .presentationBackground(pal.bg.opacity(reduceTransparency ? 1 : 0.72))
        }
        .sheet(isPresented: $showMix, onDismiss: {
            let next = afterMixSheet
            afterMixSheet = nil
            next?()
        }) {
            MixDrawer(audio: audio, mixStore: mixStore, pal: pal, onPickEpisode: {
                showMix = false
                selectedTab = 1   // jump to the Podcasts tab to choose an episode
            }, onBreathing: {
                // Breathing is a full-screen cover; it can only present once the sheet is gone.
                afterMixSheet = { showBreathing = true }
                showMix = false
            })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(pal.bg.opacity(reduceTransparency ? 1 : 0.72))
                // Scene-visible half-sheet (the "easy + pleasant" mixer ask): at .medium the home
                // scene above stays BRIGHT and LIVE — no dimming scrim, still tappable — so you can
                // hear-and-see the mix while you adjust it. Dragging up to .large re-dims so the full
                // editor (saved mixes, scene picker) has the screen. iOS 16.4+ / target is iOS 17.
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }
}

/// A mode switch held for its confirm.
struct PendingModeSwitch {
    let toFocus: Bool
    let warning: SessionGuards.ModeSwitchWarning
}
