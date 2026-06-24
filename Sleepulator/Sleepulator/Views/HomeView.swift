import SwiftUI

struct HomeView: View {
    @ObservedObject var audio: AudioEngine
    /// Observed directly so the "Resume · …" status (lastMix) refreshes after Phase 3 dropped the
    /// mixStore objectWillChange forward into AudioEngine.
    @ObservedObject var mixStore: MixStore
    /// Drives the Podcasts-tab deep link when the user taps the (empty) podcast layer.
    @Binding var selectedTab: Int
    /// One-time first-run coachmark: points at "Build mix" so a new user discovers that the app
    /// layers noise + binaural + podcasts. Set once the user dismisses it (or builds a mix).
    @AppStorage("hasCompletedFirstRun") private var hasCompletedFirstRun = false
    @State private var showTimerActionSheet = false
    @State private var isPlayPressed = false
    @State private var showBreathing = false
    @State private var showMix = false
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
        let binLabels = ["delta": "Deep", "theta": "Drift", "alpha": "Relax", "smr": "Calm", "beta": "Concentrate", "gamma": "Focus"]
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
                if mix.noiseOn { p.append(mix.noiseType.capitalized) }
                if mix.binauralOn { p.append(mix.binauralPreset.capitalized) }
                if mix.podcastUrl != nil { p.append("Podcast") }
                return "Resume · \(p.joined(separator: " + "))"
            }
            return "Tap to begin"
        }
    }

    private func heroTap() {
        if audio.isAnythingPlaying {
            audio.toggleMasterTransport()
        } else if let mix = mixStore.lastMix,
                  (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
            audio.resumeMix(mix)
        } else if !hasCompletedFirstRun {
            // First-ever play with nothing to resume: start a layered bed (noise + binaural)
            // instead of a single bare noise, so the first tap shows what the app actually does.
            audio.startDefaultMix()
        } else {
            audio.toggleMasterTransport()
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
                        // play/pauses audio; the ring + readout report the session.
                        FocusHero(audio: audio, pomodoro: audio.pomodoro, pal: pal, tap: heroTap)

                        FocusSessionReadout(pomodoro: audio.pomodoro,
                                            pal: pal,
                                            idleStatus: statusText(),
                                            layers: activeLayers)
                    } else {
                        OrbButton(audio: audio, pal: pal, tap: heroTap)

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
                // Clear the floating mini-player when an episode is loaded (it spans ~114–180pt
                // up from the screen bottom; the controls sit above the tab bar, so they need a
                // generous inset to clear its top). Tune by eye on device.
                .padding(.bottom, audio.hasLoadedEpisode ? 112 : 22)
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
        .sheet(isPresented: $showTimerActionSheet) {
            TimerSelectionSheet(audio: audio, isPresented: $showTimerActionSheet, pal: pal)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showMix) {
            MixDrawer(audio: audio, mixStore: mixStore, pal: pal, onPickEpisode: {
                showMix = false
                selectedTab = 1   // jump to the Podcasts tab to choose an episode
            })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

// The central play orb — the single focal control of the ambient-minimal home. A soft
// breathing glow (ambient, runs even under Reduce Motion) + a clean dark disc.
struct OrbButton: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    let tap: () -> Void
    @State private var pulse = false
    @State private var pressed = false

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            tap()
        }) {
            ZStack {
                Circle().fill(pal.accent.opacity(0.09))
                    .frame(width: 200, height: 200)
                    .blur(radius: 32)
                    .scaleEffect(pulse ? 1.06 : 0.92)
                    .opacity(audio.isAnythingPlaying ? 0.5 : 0.22)
                Circle().fill(Color(white: 0.09).opacity(0.85))
                    .frame(width: 132, height: 132)
                    .overlay(Circle().stroke(pal.accent.opacity(0.35), lineWidth: 1))
                Image(systemName: audio.isAnythingPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46, weight: .medium, design: .rounded))
                    .foregroundColor(pal.accent)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.96 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: pressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .onAppear {
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(audio.isAnythingPlaying ? "Pause all audio" : "Play")
    }
}

// Focus hero — the play orb wrapped in a Pomodoro progress ring. The ring is a faint
// idle track until a session is running, then it depletes over the current phase so
// time-left is the focal element of the screen.
struct FocusHero: View {
    @ObservedObject var audio: AudioEngine
    // Observe the Pomodoro directly — a nested ObservableObject reached via `audio`
    // wouldn't re-render the ring each tick.
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette
    let tap: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .stroke(pal.text.opacity(0.10), lineWidth: 6)
                .frame(width: 214, height: 214)

            if pomodoro.isRunning {
                Circle()
                    // remaining fraction = 1 − elapsed; the arc shrinks as the phase runs out.
                    .trim(from: 0, to: CGFloat(1 - pomodoro.progress))
                    .stroke(pal.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 214, height: 214)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: pomodoro.remaining)
            }

            OrbButton(audio: audio, pal: pal, tap: tap)
        }
        .accessibilityElement(children: .contain)
    }
}

// Focus session readout — replaces the generic status line in Focus mode. While a
// session runs it shows the phase, the live countdown, and progress through the set;
// idle, it falls back to the same "what's playing" line as Sleep.
struct FocusSessionReadout: View {
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette
    let idleStatus: String
    let layers: [String]

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 12) {
            if pomodoro.isRunning {
                Text(pomodoro.phase == .work ? "Focus" : (pomodoro.restIsLong ? "Long break" : "Break"))
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundColor(pal.accent)

                Text(clock(pomodoro.remaining))
                    .font(.system(size: 40, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(pal.text)
                    .accessibilityLabel("\(clock(pomodoro.remaining)) remaining")

                CycleDots(pomodoro: pomodoro, pal: pal)
            } else {
                Text(idleStatus)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundColor(pal.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                if !layers.isEmpty {
                    LayerPills(layers: layers, pal: pal)
                }
            }
        }
    }
}

// The set-progress dots under the timer — one per work interval before a long break,
// filled as cycles complete.
struct CycleDots: View {
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette

    var body: some View {
        let n = max(1, pomodoro.cyclesBeforeLongBreak)
        let done = pomodoro.completedCycles % n
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(0..<n), id: \.self) { i in
                    Circle()
                        .fill(i < done ? pal.accent : pal.text.opacity(0.18))
                        .frame(width: 7, height: 7)
                }
            }
            Text("Cycle \(min(done + 1, n)) of \(n)")
                .font(.caption2)
                .foregroundColor(pal.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cycle \(min(done + 1, n)) of \(n)")
    }
}

// MARK: - Timer-observing leaves
// These observe the timer services directly (not via `audio`), so their ~1/sec ticks re-render
// only the small leaf — not the whole HomeView. The services are no longer forwarded through
// AudioEngine (see AudioEngine.init), so reading them inline in HomeView.body would otherwise
// show frozen values.

/// The mode-aware bottom session control: a Sleep-timer countdown, or the Pomodoro toggle.
struct SessionButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    @ObservedObject var pomodoro: PomodoroService
    let focusMode: Bool
    let pal: Palette
    let onSleepTap: () -> Void

    var body: some View {
        Button(action: {
            if focusMode {
                if pomodoro.isRunning { pomodoro.stop() } else { pomodoro.start() }
            } else {
                onSleepTap()
            }
        }) {
            HStack(spacing: 6) {
                if focusMode {
                    Image(systemName: pomodoro.isRunning ? "stop.fill" : "bolt.fill")
                    Text(pomodoro.isRunning ? "\(Int(pomodoro.remaining / 60))m" : "Focus session")
                } else {
                    Image(systemName: "moon.zzz")
                    Text(sleepTimer.timerRemaining > 0 ? "\(Int(sleepTimer.timerRemaining / 60))m left" : "Sleep timer")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(pal.dim)
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .frame(minHeight: 44)
    }
}

/// The Sleep-mode status line. `base` (the layer/resume/"tap to begin" text) is computed by
/// HomeView and passed in; the live "· Nm" countdown is appended here from the observed timer.
struct SleepStatusLine: View {
    let base: String
    let showMinute: Bool
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette

    var body: some View {
        Text(showMinute && sleepTimer.timerRemaining > 0
             ? "\(base) · \(Int(sleepTimer.timerRemaining / 60))m"
             : base)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundColor(pal.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
    }
}

/// The half-asleep "+15m" bump, shown only in the last 2 minutes of a fixed-duration timer.
struct BumpTimerButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette

    var body: some View {
        if sleepTimer.timerRemaining > 0, sleepTimer.timerRemaining <= 120, !sleepTimer.isEndOfEpisode {
            Button(action: {
                sleepTimer.bumpTimer()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Still awake? +15m").font(.subheadline.weight(.semibold))
                }
                .foregroundColor(pal.bg)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .background(Capsule().fill(pal.accent))
            }
            .frame(minHeight: 44)
            .accessibilityLabel("Still awake, add 15 minutes to the sleep timer")
        }
    }
}

// The active-sound pills shown under the hero — shared by Sleep and idle Focus.
struct LayerPills: View {
    let layers: [String]
    let pal: Palette

    var body: some View {
        HStack(spacing: 8) {
            ForEach(layers, id: \.self) { layer in
                Text(layer)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(pal.accent.opacity(0.16)))
                    .foregroundColor(pal.accent)
            }
        }
    }
}

// One-time first-run nudge: a soft card that tells a new user what makes the app different
// (layering) and points down at the "Build mix" control. Dismissed forever on "Got it" or once
// the user opens the mixer themselves.
struct FirstRunCoachmark: View {
    let pal: Palette
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(pal.accent)
                Text("Layer your own soundscape")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(pal.text)
                Spacer(minLength: 0)
            }
            Text("Tap the orb to start, then open Build mix to stack noise, binaural beats, and your own podcasts — with a sleep timer that fades it all out.")
                .font(.caption)
                .foregroundColor(pal.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(action: dismiss) {
                    Text("Got it")
                        .font(.caption.weight(.bold))
                        .foregroundColor(pal.bg)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(pal.accent))
                }
                .frame(minHeight: 36)
            }

            // A small pointer toward the Build mix control below.
            Image(systemName: "chevron.compact.down")
                .font(.title3)
                .foregroundColor(pal.accent.opacity(0.6))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(pal.bg.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(pal.accent.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        )
        .accessibilityElement(children: .combine)
    }
}

// The "Build mix" drawer — all the detailed controls (mixer, master volume, save / saved
// mixes) live here so the main screen stays calm and art-first.
struct MixDrawer: View {
    @ObservedObject var audio: AudioEngine
    /// Observed directly so the saved-mixes row refreshes when a preset is saved / renamed /
    /// deleted, after Phase 3 dropped the mixStore objectWillChange forward into AudioEngine.
    @ObservedObject var mixStore: MixStore
    let pal: Palette
    /// Called when the user taps the podcast layer with no episode loaded — closes the drawer
    /// and routes to the Podcasts tab.
    var onPickEpisode: () -> Void = {}
    @AppStorage("sceneSleep") private var sleepSceneId = "night-sky"
    @AppStorage("sceneFocus") private var focusSceneId = "energy"
    @State private var showNameDialog = false
    @State private var draftName = ""

    private var currentMode: String { audio.focusMode ? "focus" : "sleep" }
    private var modePresets: [SoundPreset] { mixStore.savedPresets.filter { $0.mode == currentMode } }
    private var canSaveMix: Bool { audio.noiseOn || audio.binauralOn }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Your mix")
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(pal.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)

                MixPanel(audio: audio, pal: pal, onPickEpisode: onPickEpisode)

                HomeBottomBar(audio: audio, pal: pal)
                    .padding(.top, 4)

                if canSaveMix {
                    Button(action: {
                        draftName = audio.defaultPresetName()
                        showNameDialog = true
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.square.on.square")
                            Text("Save mix").font(.subheadline.bold())
                        }
                        .foregroundColor(pal.accent)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(pal.accent.opacity(0.1))
                        .cornerRadius(12)
                    }
                }

                if !modePresets.isEmpty {
                    SavedMixesList(audio: audio, presets: modePresets, pal: pal)
                }

                SceneSelector(mood: audio.focusMode ? .focus : .sleep,
                              selectedId: audio.focusMode ? $focusSceneId : $sleepSceneId,
                              pal: pal)
            }
            .padding(.vertical, 22)
        }
        .background(pal.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert("Name your mix", isPresented: $showNameDialog) {
            TextField("Mix name", text: $draftName)
            Button("Save") {
                audio.savePreset(named: draftName)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Save this soundscape to reuse it anytime.")
        }
    }
}

/// A minimal backdrop picker for the current mode — chips of the available scenes, the
/// selected one highlighted. Writes the per-mode @AppStorage key, which re-renders the home.
/// The "simple toggle" the screensaver spec calls for until there are enough scenes to want a
/// full grid picker.
struct SceneSelector: View {
    let mood: SceneMood
    @Binding var selectedId: String
    let pal: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backdrop")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(pal.text)
                .padding(.horizontal, 20)

            // Horizontally scrollable so the row holds any number of backdrops without
            // overflowing on a phone. Edge padding lives on the inner HStack so it bleeds
            // to the screen edges as it scrolls.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SceneRegistry.scenes(for: mood), id: \.id) { scene in
                        let on = scene.id == selectedId
                        Button {
                            selectedId = scene.id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Text(scene.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(on ? pal.accent.opacity(0.18) : pal.text.opacity(0.06)))
                                .overlay(Capsule().stroke(on ? pal.accent.opacity(0.55) : .clear, lineWidth: 1))
                                .foregroundColor(on ? pal.accent : pal.dim)
                        }
                        .accessibilityLabel("\(scene.title) backdrop\(on ? ", selected" : "")")
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A calm night sky for Sleep mode, built to lull rather than impress: faint stars in varied
/// colour temperature over a soft Milky Way haze, the whole field drifting down very slowly
/// while a gentle collective "breath" rises and falls the brightness on a slow sleep cadence.
/// One TimelineView/Canvas loop (~30fps); freezes only when the deep night-dim veil has
/// occluded the screen. Runs regardless of system Reduce Motion. No bright focal point.
struct StarfieldView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false

    private struct Star {
        let x, y, r, baseOpacity: Double
        let tint: Color
        let bright: Bool
        let twAmp, twSpeed, twPhase: Double
    }

    private static let coolWhite = Color(red: 0.93, green: 0.95, blue: 1.0)
    private static let warmStar  = Color(red: 1.0,  green: 0.86, blue: 0.66)
    private static let blueStar  = Color(red: 0.74, green: 0.84, blue: 1.0)

    // Tuning knobs — all slow on purpose (a sleep aid, not a screensaver demo).
    private static let driftPeriod: Double = 300    // seconds to drift one screen-height down
    private static let breathPeriod: Double = 9     // seconds per breath (brightness rise + fall)
    private static let breathDepth: Double = 0.22   // how much the breath dims the field at the trough

    private static let stars: [Star] = build()

    private static func build() -> [Star] {
        var rng: UInt64 = 0x5EED5160_0DECAF01
        func n() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        func tint() -> Color { let t = n(); return t < 0.66 ? coolWhite : (t < 0.88 ? warmStar : blueStar) }
        var out: [Star] = []
        // Scattered field — cube the brightness so most stars are dim and only a few brighter.
        for _ in 0..<90 {
            let mag = pow(n(), 3.0)
            out.append(Star(x: n(), y: n(),
                            r: 0.5 + mag * 2.2,
                            baseOpacity: 0.22 + mag * 0.6,
                            tint: tint(),
                            bright: mag > 0.88,
                            twAmp: 0.25 + n() * 0.45, twSpeed: 0.5 + n() * 1.2, twPhase: n() * 6.283))
        }
        // A denser diagonal Milky Way swath of faint stars.
        for _ in 0..<40 {
            let u = n()
            let mag = pow(n(), 4.0)
            out.append(Star(x: 0.08 + u * 0.86,
                            y: 0.06 + u * 0.5 + (n() - 0.5) * 0.16,
                            r: 0.4 + mag * 0.9,
                            baseOpacity: 0.12 + mag * 0.34,
                            tint: coolWhite,
                            bright: false,
                            twAmp: 0.2 + n() * 0.3, twSpeed: 0.4 + n() * 0.8, twPhase: n() * 6.283))
        }
        return out
    }

    var body: some View {
        ZStack {
            hazeBand
            if paused {
                Canvas { ctx, size in Self.draw(ctx, size, t: 0) }      // occluded: one static frame
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    Canvas { ctx, size in Self.draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    // Soft luminous band behind the Milky Way (static — drawn once, not per frame).
    private var hazeBand: some View {
        GeometryReader { geo in
            Ellipse()
                .fill(Color.white.opacity(0.03))
                .frame(width: geo.size.width * 1.5, height: geo.size.height * 0.26)
                .rotationEffect(.degrees(-22))
                .position(x: geo.size.width * 0.5, y: geo.size.height * 0.28)
                .blur(radius: 40)
        }
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        // Collective breath: a slow brightness envelope (1.0 at the top of the breath).
        let breath = 1.0 - breathDepth * (0.5 - 0.5 * cos(t * 2 * .pi / breathPeriod))
        // Field drift: everything sinks slowly, wrapping top <-> bottom.
        let drift = (t / driftPeriod).truncatingRemainder(dividingBy: 1.0)

        for s in stars {
            var yy = (s.y + drift).truncatingRemainder(dividingBy: 1.0)
            if yy < 0 { yy += 1 }
            let edge = min(1.0, min(yy, 1 - yy) / 0.06)               // fade the wrap seam
            let twinkle = 1.0 - s.twAmp * (0.5 - 0.5 * cos(t * s.twSpeed + s.twPhase))
            let op = s.baseOpacity * breath * edge * twinkle
            let x = s.x * size.width
            let y = yy * size.height
            if s.bright {
                let g = s.r * 2.4
                ctx.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2)),
                         with: .radialGradient(Gradient(colors: [s.tint.opacity(op * 0.5), .clear]),
                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: g))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: x - s.r, y: y - s.r, width: s.r * 2, height: s.r * 2)),
                     with: .color(s.tint.opacity(op)))
        }
    }
}

// A rare delight: every few minutes a meteor streaks across the sky and fades. Schedules
// itself with random gaps, and runs regardless of Reduce Motion (a deliberate dog-food
// choice). The self-rescheduling loop is cancelled on disappear so it can't outlive the view.
struct ShootingStarView: View {
    @State private var progress: CGFloat = 0
    @State private var active = false
    @State private var seed = 0
    @State private var pending: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            streak(in: geo.size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { schedule(first: true) }
        .onDisappear { pending?.cancel(); pending = nil }
    }

    private func streak(in size: CGSize) -> some View {
        let startX = size.width * (0.12 + 0.6 * frac(seed))
        let startY = size.height * (0.06 + 0.16 * frac(seed &* 7 &+ 3))
        let len = size.width * 0.55
        let x = startX + progress * len
        let y = startY + progress * len * 0.42
        return Capsule()
            .fill(LinearGradient(
                gradient: Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.9)]),
                startPoint: .leading, endPoint: .trailing))
            .frame(width: 66, height: 2)
            .rotationEffect(.degrees(22.8))
            .position(x: x, y: y)
            .opacity(active ? 1 : 0)
    }

    private func schedule(first: Bool) {
        let delay = first ? Double.random(in: 10...22) : Double.random(in: 90...210)
        let appear = DispatchWorkItem {
            seed &+= 1
            progress = 0
            active = true
            withAnimation(.easeIn(duration: 0.9)) { progress = 1 }
            let hide = DispatchWorkItem {
                active = false
                progress = 0
                schedule(first: false)
            }
            pending = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: hide)
        }
        pending = appear
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: appear)
    }

    // Cheap deterministic 0…1 hash so each meteor starts somewhere different.
    private func frac(_ n: Int) -> CGFloat {
        let v = sin(Double(n) * 12.9898) * 43758.5453
        return CGFloat(v - v.rounded(.down))
    }
}

// Focus backdrop — a slow-rotating cool "energy" sweep over the deep-indigo gradient.
// Energizing without being distracting; static under Reduce Motion.
struct FocusBackdrop: View {
    let accent: Color
    let reduceMotion: Bool
    @State private var rotate = false

    var body: some View {
        // GeometryReader's footprint is always the proposed (screen) size — it never grows
        // to fit the oversized/blurred glow, so the ZStack can't be widened (which was
        // shoving the centered content off both edges). The glow is positioned at center.
        GeometryReader { geo in
            AngularGradient(
                gradient: Gradient(colors: [
                    accent.opacity(0.0), accent.opacity(0.30), accent.opacity(0.05),
                    accent.opacity(0.22), accent.opacity(0.0)
                ]),
                center: .center
            )
            .frame(width: 640, height: 640)
            .blur(radius: 90)
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .opacity(0.75)
            .position(x: geo.size.width / 2, y: geo.size.height / 2 - 30)
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            // Runs regardless of Reduce Motion — a slow blurred glow drift is ambient, not the
            // vestibular kind of motion, and Focus should feel alive even with Reduce Motion on.
            withAnimation(.linear(duration: 36).repeatForever(autoreverses: false)) {
                rotate = true
            }
        }
    }
}

// Prominent two-segment Sleep | Focus selector. The active segment fills with the accent.
struct ModeSwitcher: View {
    @Binding var focusMode: Bool
    let pal: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "Sleep", icon: "moon.stars.fill", isActive: !focusMode) {
                if focusMode { setMode(false) }
            }
            segment(title: "Focus", icon: "bolt.fill", isActive: focusMode) {
                if !focusMode { setMode(true) }
            }
        }
        .padding(4)
        .background(Capsule().fill(pal.text.opacity(0.08)))
        .frame(maxWidth: .infinity)
    }

    private func setMode(_ focus: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        if reduceMotion { focusMode = focus }
        else { withAnimation(.easeInOut(duration: 0.2)) { focusMode = focus } }
    }

    private func segment(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundColor(isActive ? pal.bg : pal.dim)
            .background(Capsule().fill(isActive ? pal.accent : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

struct MixPanel: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    var onPickEpisode: () -> Void = {}

    /// The noise sounds available in the current mode (Sleep vs Focus palettes share no sounds).
    private var noisePalette: [String] {
        audio.focusMode ? ["pink", "fan", "white", "gray"] : ["brown", "rain", "ocean", "pink", "green", "forest"]
    }

    var body: some View {
        VStack(spacing: 10) {
            WarmMixerRow(
                icon: "waveform.path.ecg",
                title: audio.noiseType.capitalized,
                isOn: $audio.noiseOn,
                volume: $audio.noiseVolume,
                pal: pal,
                options: noisePalette,
                selection: $audio.noiseType
            )
            .glassPanel()

            // Stacked extra noise layers (rain + brown, …). Only shown while the noise bed is on,
            // since the layers play *with* it; toggling a layer's switch off removes it.
            if audio.noiseOn {
                ForEach(audio.extraLayers) { layer in
                    WarmMixerRow(
                        icon: "plus.circle",
                        title: layer.type.capitalized,
                        isOn: .constant(true),
                        volume: Binding(
                            get: { layer.volume },
                            set: { audio.setExtraLayerVolume(layer.id, $0) }
                        ),
                        pal: pal,
                        onToggle: { audio.removeExtraLayer(layer.id) },
                        options: noisePalette,
                        selection: Binding(
                            get: { layer.type },
                            set: { audio.setExtraLayerType(layer.id, $0) }
                        )
                    )
                    .glassPanel()
                }

                if audio.extraLayers.count < AudioEngine.maxExtraLayers {
                    Button(action: {
                        audio.addExtraLayer()
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }) {
                        Label("Add sound", systemImage: "plus.circle")
                            .font(.system(.subheadline, design: .rounded).weight(.semibold))
                            .foregroundColor(pal.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add another sound layer")
                }
            }

            WarmMixerRow(
                icon: "headphones",
                title: "Binaural (\(audio.binauralPreset.capitalized))",
                isOn: $audio.binauralOn,
                volume: $audio.binVolume,
                pal: pal,
                options: audio.focusMode ? ["alpha", "smr", "beta", "gamma"] : ["delta", "theta"],
                optionLabels: ["delta":"Deep","theta":"Drift","alpha":"Relax","smr":"Calm","beta":"Concentrate","gamma":"Focus"],
                selection: $audio.binauralPreset
            )
            .glassPanel()
            
            // Podcast is on/off + volume like the other layers — episode picking lives in the
            // Library tab and the mini-player, not an impractical inline dropdown. With no episode
            // loaded the toggle has nothing to play, so the row becomes a clear call-to-action that
            // routes to the Podcasts tab instead of a switch that silently does nothing.
            if audio.hasLoadedEpisode {
                WarmMixerRow(
                    icon: "mic.fill",
                    title: audio.isPodPlaying ? audio.podTitle : "Podcast",
                    isOn: $audio.isPodPlaying,
                    volume: $audio.podVolume,
                    pal: pal,
                    onToggle: { audio.togglePodcast() }
                )
                .glassPanel()
            } else {
                Button(action: onPickEpisode) {
                    HStack(spacing: 12) {
                        Image(systemName: "mic.fill")
                            .frame(minWidth: 30)
                            .foregroundColor(pal.dim)
                            .font(.title3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Podcast")
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(pal.dim)
                            Text("Choose an episode")
                                .font(.caption)
                                .foregroundColor(pal.dim.opacity(0.7))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundColor(pal.dim.opacity(0.7))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .glassPanel()
                .accessibilityLabel("Podcast, no episode loaded")
                .accessibilityHint("Opens the Podcasts tab to choose an episode")
            }
        }
        .padding(.horizontal, 20)
    }
}

// Master volume + mute, pinned to the bottom thumb zone (the control you reach for
// half-asleep in bed). Bedtime-aware fill so it doesn't glow on true black.
struct HomeBottomBar: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    @AppStorage("bedtimeMode") private var bedtimeMode = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { audio.toggleMute() }) {
                Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .imageScale(.large)
                    // Muted reads through the struck-speaker glyph; a dimmed tone keeps the night
                    // UI calm (red carried a false "error/danger" charge for a benign state).
                    .foregroundColor(audio.isMuted ? pal.dim : pal.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(audio.isMuted ? "Unmute" : "Mute")

            VolumeBar(value: $audio.masterVolume, accent: pal.accent)
                .accessibilityLabel("Master volume")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background {
            if bedtimeMode {
                Capsule().fill(Color.white.opacity(0.06))
            } else {
                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            }
        }
        .padding(.horizontal, 16)
    }
}

struct SavedMixesList: View {
    @ObservedObject var audio: AudioEngine
    let presets: [SoundPreset]
    let pal: Palette
    @State private var renaming: SoundPreset?
    @State private var draftName = ""

    private func mixSummary(_ p: SoundPreset) -> String {
        var parts: [String] = []
        if p.noiseOn { parts.append(p.noiseType.capitalized) }
        if p.binauralOn { parts.append(p.binauralPreset.capitalized) }
        return parts.isEmpty ? "Silent" : parts.joined(separator: " + ")
    }

    // A horizontal row of compact preset cards — tap to apply (sounds swap, any podcast keeps
    // playing), long-press to rename or delete.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved mixes")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(pal.dim)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(presets, id: \.id) { (mix: SoundPreset) in
                        Button(action: {
                            audio.applyPreset(mix)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(mix.name)
                                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                    .foregroundColor(pal.text)
                                    .lineLimit(1)
                                Text(mixSummary(mix))
                                    .font(.caption2)
                                    .foregroundColor(pal.dim)
                                    .lineLimit(1)
                            }
                            .frame(width: 132, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(pal.accent.opacity(0.12)))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(pal.accent.opacity(0.22), lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { draftName = mix.name; renaming = mix } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            Button(role: .destructive) { audio.deletePreset(mix) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel("Apply mix \(mix.name)")
                        .accessibilityHint("Long press to rename or delete")
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .alert("Rename mix", isPresented: Binding(get: { renaming != nil },
                                                  set: { if !$0 { renaming = nil } })) {
            TextField("Mix name", text: $draftName)
            Button("Save") {
                if let m = renaming { audio.renamePreset(m, to: draftName) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}

struct WarmMixerRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    @Binding var volume: Double
    let pal: Palette
    var onToggle: (() -> Void)? = nil
    
    var options: [String] = []
    var optionLabels: [String: String]? = nil
    var selection: Binding<String>? = nil
    var customMenu: AnyView? = nil

    @Environment(\.dynamicTypeSize) private var typeSize

    private var rowToggle: some View {
        Toggle("", isOn: Binding(
            get: { isOn },
            set: { newValue in
                if let action = onToggle { action() }
                else { isOn = newValue }
            }
        ))
        .labelsHidden()
        .toggleStyle(SwitchToggleStyle(tint: pal.accent))
        .accessibilityLabel(Text(title))   // VoiceOver: identify which layer this switch is
    }

    @ViewBuilder private var iconAndTitle: some View {
        Image(systemName: icon)
            .frame(minWidth: 30)
            .foregroundColor(isOn ? pal.accent : pal.dim)
            .font(.title3)
            .accessibilityHidden(true)

        if let custom = customMenu {
            custom
        } else {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(isOn ? pal.text : pal.dim)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .layoutPriority(1)
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            // At accessibility text sizes the fixed-width UISwitch can't share a row with a
            // grown title — drop it to a second line instead of truncating the title.
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) { iconAndTitle; Spacer() }
                    HStack { Spacer(); rowToggle }
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    iconAndTitle
                    Spacer()
                    rowToggle
                }
            }

            // Volume + sound picker appear only when the layer is ON, so an idle layer is a
            // single tight row instead of a tall panel — big space win when most are off.
            if isOn {
                VolumeBar(value: $volume, accent: pal.accent, onEditingChanged: { editing in
                    if editing { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    else { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                })
                .accessibilityLabel(Text("\(title) volume"))

                if let sel = selection, !options.isEmpty {
                    ChipRow(options: options, labels: optionLabels, selection: sel, palette: pal)
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}

struct TimerSelectionSheet: View {
    @ObservedObject var audio: AudioEngine
    @Binding var isPresented: Bool
    let pal: Palette
    @AppStorage("timerMinutes") private var timerMinutes = 30.0

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }

    var body: some View {
        VStack(spacing: 22) {
            Text("Sleep Timer")
                .font(.title2.bold())
                .foregroundColor(pal.text)

            Text("Fade out smoothly over…")
                .foregroundColor(pal.dim)

            // Presets now *select* a duration (they no longer fire-and-dismiss), so tapping one
            // and then nudging the slider is a single coherent flow ending in one Start button.
            HStack(spacing: 12) {
                ForEach([15, 30, 45, 60], id: \.self) { mins in
                    let selected = Int(timerMinutes) == mins
                    Button(action: {
                        timerMinutes = Double(mins)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }) {
                        Text("\(mins)m")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(selected ? pal.accent.opacity(0.25) : Color(white: 0.15))
                            .foregroundColor(selected ? pal.accent : pal.text)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? pal.accent.opacity(0.7) : .clear, lineWidth: 1))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }

            VStack(spacing: 8) {
                Text("\(Int(timerMinutes)) minutes")
                    .font(.headline)
                    .foregroundColor(pal.text)
                    .monospacedDigit()

                Slider(value: $timerMinutes, in: 5...120, step: 5)
                    .tint(pal.accent)
            }
            .padding(.horizontal, 40)

            // Single commit for the duration timer.
            Button(action: {
                audio.sleepTimer.startSleepTimer(minutes: Int(timerMinutes))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isPresented = false
            }) {
                Text(timerActive ? "Restart Timer" : "Start Timer")
                    .font(.headline.bold())
                    .foregroundColor(pal.bg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding()
                    .background(pal.accent)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)

            // "End of episode" — only when a podcast with a known, finite length is loaded (so
            // the button can't silently no-op before the duration is known, or on a live stream).
            // A genuinely different timer kind, so it stays its own one-tap action.
            if audio.hasLoadedEpisode, audio.podcastDuration.isFinite, audio.podcastDuration > 5 {
                Button(action: {
                    audio.startEndOfEpisodeTimer()
                    isPresented = false
                }) {
                    Label("Stop at end of episode", systemImage: "text.append")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(pal.accent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.accent.opacity(0.6), lineWidth: 1))
                }
            }

            // Cancel an already-running timer — previously there was no way out except starting a
            // new one. Only shown when a timer is actually counting down.
            if timerActive {
                Button(action: {
                    audio.sleepTimer.cancelTimer()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isPresented = false
                }) {
                    Label("Turn off timer", systemImage: "moon.zzz")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(pal.dim)
                        .frame(minHeight: 44)
                }
            }

            Spacer()
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg.ignoresSafeArea())
    }
}
