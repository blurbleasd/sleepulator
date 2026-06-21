import SwiftUI

struct HomeView: View {
    @ObservedObject var audio: AudioEngine
    @State private var showTimerActionSheet = false
    @State private var isPlayPressed = false
    @State private var showBreathing = false
    @State private var showMix = false
    // Ambient screensaver: while playing in Sleep mode, the controls fade after a spell of
    // no interaction, leaving just the sky + moon. A tap brings them back. The flag lives on
    // `audio` so ContentView's tab bar + mini-player can fade with the home chrome.
    @State private var idleFade: DispatchWorkItem?
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private func scheduleIdleFade() {
        idleFade?.cancel()
        guard !audio.focusMode, audio.isAnythingPlaying else { return }
        let work = DispatchWorkItem {
            guard !self.audio.focusMode, self.audio.isAnythingPlaying else { return }
            withAnimation(.easeInOut(duration: 0.9)) { self.audio.ambientScreensaver = true }
        }
        idleFade = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
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
        let binLabels = ["delta": "Deep", "theta": "Drift", "alpha": "Relax", "gamma": "Focus"]
        var p: [String] = []
        if audio.noiseOn { p.append(audio.noiseType.capitalized) }
        if audio.binauralOn { p.append(binLabels[audio.binauralPreset] ?? audio.binauralPreset.capitalized) }
        if audio.isPodPlaying { p.append("Podcast") }
        return p
    }

    // Bottom session control — mode-aware: Sleep timer vs Focus Pomodoro.
    @ViewBuilder private var sessionButton: some View {
        Button(action: {
            if audio.focusMode {
                if audio.pomodoro.isRunning { audio.pomodoro.stop() } else { audio.pomodoro.start() }
            } else {
                showTimerActionSheet = true
            }
        }) {
            HStack(spacing: 6) {
                if audio.focusMode {
                    Image(systemName: audio.pomodoro.isRunning ? "stop.fill" : "bolt.fill")
                    Text(audio.pomodoro.isRunning ? "\(Int(audio.pomodoro.remaining / 60))m" : "Focus session")
                } else {
                    Image(systemName: "moon.zzz")
                    Text(audio.sleepTimer.timerRemaining > 0 ? "\(Int(audio.sleepTimer.timerRemaining / 60))m left" : "Sleep timer")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(pal.dim)
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .frame(minHeight: 44)
    }

    private func statusText() -> String {
        var parts: [String] = []
        if audio.noiseOn { parts.append(audio.noiseType.capitalized) }
        if audio.binauralOn { parts.append(audio.binauralPreset.capitalized) }
        if audio.isPodPlaying { parts.append("Podcast") }
        
        let layers = parts.isEmpty ? "All paused" : parts.joined(separator: " + ")
        
        if audio.isAnythingPlaying {
            if audio.sleepTimer.timerRemaining > 0 {
                return "\(layers) · \(Int(audio.sleepTimer.timerRemaining / 60))m"
            }
            return layers
        } else {
            if let mix = audio.lastMix, (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
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
        } else if let mix = audio.lastMix,
                  (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
            audio.resumeMix(mix)
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

            if audio.focusMode {
                // Focus: cool + energizing — no sleepy stars/moon/breathing glow.
                FocusBackdrop(accent: pal.accent, reduceMotion: reduceMotion)
            } else {
                // Sleep: a realistic night sky. The moon descends its arc as the sleep
                // timer runs down, sinking into the warm horizon glow; the sky deepens
                // toward black as the night ends.
                StarfieldView(paused: audio.ambientScreensaver)
                    .ignoresSafeArea()
                MoonArc(sleepTimer: audio.sleepTimer)
                    .ignoresSafeArea()
                ShootingStarView()
                    .ignoresSafeArea()
                Color.black
                    .opacity(audio.sleepTimer.nightProgress * 0.35)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            
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

                        Text(statusText())
                            .font(.system(.callout, design: .rounded).weight(.medium))
                            .foregroundColor(pal.dim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)

                        if !activeLayers.isEmpty {
                            LayerPills(layers: activeLayers, pal: pal)
                        }

                        // Rescued from the old HeroTransport: as the fade is about to cut the
                        // night off, offer a half-asleep one-tap "+15m" instead of forcing a
                        // reopen of the timer sheet (which would start a brand-new timer).
                        if audio.sleepTimer.timerRemaining > 0, audio.sleepTimer.timerRemaining <= 120 {
                            Button(action: {
                                audio.sleepTimer.bumpTimer()
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

                Spacer()

                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Button(action: { showMix = true }) {
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

                        sessionButton
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
                .padding(.bottom, audio.hasLoadedEpisode ? 84 : 22)
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
        }
        .onAppear { scheduleIdleFade() }
        .onChange(of: audio.isAnythingPlaying) { playing in
            if playing { scheduleIdleFade() } else { wakeChrome() }
        }
        .onChange(of: audio.focusMode) { focus in
            // Never screensaver while focusing — the session readout must stay visible.
            if focus { idleFade?.cancel(); withAnimation { audio.ambientScreensaver = false } }
            else { scheduleIdleFade() }
        }
        .fullScreenCover(isPresented: $showBreathing) {
            BreathingView(isPresented: $showBreathing)
        }
        .sheet(isPresented: $showTimerActionSheet) {
            TimerSelectionSheet(audio: audio, isPresented: $showTimerActionSheet, pal: pal)
                .presentationDetents([.fraction(0.5)])
        }
        .sheet(isPresented: $showMix) {
            MixDrawer(audio: audio, pal: pal)
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

// The "Build mix" drawer — all the detailed controls (mixer, master volume, save / saved
// mixes) live here so the main screen stays calm and art-first.
struct MixDrawer: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Your mix")
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundColor(pal.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)

                MixPanel(audio: audio, pal: pal)

                HomeBottomBar(audio: audio, pal: pal)
                    .padding(.top, 4)

                if audio.isAnythingPlaying {
                    Button(action: {
                        audio.saveCurrentAsPlaylist()
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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

                if !audio.savedPlaylists.isEmpty {
                    SavedMixesList(audio: audio, pal: pal)
                }
            }
            .padding(.vertical, 22)
        }
        .background(pal.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}

/// A realistic night sky for Sleep mode. Power-law brightness (lots of faint stars, a
/// few bright ones with soft halos), varied colour temperature, and a faint Milky Way
/// band. A sparse subset twinkles slowly. The twinkle is a gentle opacity fade (not the
/// vestibular kind of motion), so it runs regardless of system Reduce Motion: a deliberate
/// dog-food choice so the sky reads alive. It still settles to static ~60s after appearing
/// and the moment the screensaver engages, for battery.
struct StarfieldView: View {
    /// Holds the field static when the screensaver engages (battery on an all-night screen).
    var paused: Bool = false

    @State private var twinkle = false
    /// Latches true ~60s after appear so the sky stops animating even if controls stay up.
    @State private var settled = false

    private struct Star: Identifiable {
        let id: Int
        let x, y, r, baseOpacity, dur, delay: Double
        let tint: Color
        let bright: Bool
        let twinkles: Bool
    }

    // Real stars aren't all white — most read cool, some warm, a few blue-white.
    private static let coolWhite = Color(red: 0.93, green: 0.95, blue: 1.0)
    private static let warmStar  = Color(red: 1.0,  green: 0.86, blue: 0.66)
    private static let blueStar  = Color(red: 0.74, green: 0.84, blue: 1.0)

    private static let stars: [Star] = build()

    // Deterministic layout (fixed seed) so the sky is stable across launches.
    private static func build() -> [Star] {
        var rng: UInt64 = 0x5EED5160_0DECAF01
        func next() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(rng % 1_000_000) / 1_000_000.0
        }
        var out: [Star] = []

        // Scattered field — cube the brightness so most stars are dim and only a handful blaze.
        for i in 0..<80 {
            let mag = pow(next(), 3.0)
            let yb = next()
            let y = (yb * yb) * 0.72                       // denser toward the top of the sky
            let horizonFade = 1.0 - (y / 0.72) * 0.5
            let tt = next()
            let tint = tt < 0.66 ? coolWhite : (tt < 0.88 ? warmStar : blueStar)
            out.append(Star(
                id: i, x: next(), y: y,
                r: 0.5 + mag * 2.4,
                baseOpacity: (0.28 + mag * 0.62) * horizonFade,
                dur: 2.6 + next() * 3.6,                   // slow, each on its own clock
                delay: next() * 4.0,
                tint: tint,
                bright: mag > 0.86,
                twinkles: next() < 0.34
            ))
        }

        // Milky Way — a denser diagonal swath of faint, small stars.
        for i in 0..<38 {
            let u = next()
            let bx = 0.10 + u * 0.82
            let by = max(0.02, 0.08 + u * 0.52 + (next() - 0.5) * 0.14)
            let mag = pow(next(), 4.0)
            out.append(Star(
                id: 1000 + i, x: bx, y: by,
                r: 0.4 + mag * 1.0,
                baseOpacity: 0.16 + mag * 0.38,
                dur: 3.0 + next() * 3.0,
                delay: next() * 4.0,
                tint: coolWhite,
                bright: false,
                twinkles: next() < 0.18
            ))
        }
        return out
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                hazeBand(geo.size)
                ForEach(Self.stars) { s in
                    star(s, size: geo.size)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            twinkle = true
            // Settle to fully static after a minute so an all-night screen isn't animating.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { settled = true }
        }
    }

    // The soft luminous band behind the Milky Way stars — adds depth without dots.
    private func hazeBand(_ size: CGSize) -> some View {
        Ellipse()
            .fill(Color.white.opacity(0.035))
            .frame(width: size.width * 1.5, height: size.height * 0.24)
            .rotationEffect(.degrees(-24))
            .position(x: size.width * 0.5, y: size.height * 0.27)
            .blur(radius: 38)
    }

    // One star. A plain function (not a ViewBuilder) so we can branch on `active`.
    private func star(_ s: Star, size: CGSize) -> some View {
        let active = s.twinkles && !paused && !settled
        return Circle()
            .fill(s.tint)
            .frame(width: s.r * 2, height: s.r * 2)
            .opacity(active ? (twinkle ? s.baseOpacity * 0.35 : s.baseOpacity) : s.baseOpacity)
            .shadow(color: s.bright ? s.tint.opacity(0.6) : Color.clear,
                    radius: s.bright ? s.r * 1.6 : 0)
            .position(x: s.x * size.width, y: s.y * size.height)
            .animation(active ? .easeInOut(duration: s.dur).repeatForever(autoreverses: true).delay(s.delay) : nil,
                       value: twinkle)
    }
}

// Tonight's real lunar phase — illuminated fraction (0 new … 1 full) and whether it's
// waxing, from days since a known new moon. Good enough for a believable moon, not an
// ephemeris.
enum MoonPhase {
    static func current(_ date: Date = Date()) -> (illumination: Double, waxing: Bool) {
        let synodic = 29.530588853
        let knownNew = Date(timeIntervalSince1970: 947182440)   // 2000-01-06 18:14 UTC
        var age = date.timeIntervalSince(knownNew) / 86400.0
        age = age.truncatingRemainder(dividingBy: synodic)
        if age < 0 { age += synodic }
        let illum = (1 - cos(2 * Double.pi * age / synodic)) / 2
        return (illum, age < synodic / 2)
    }
}

// A soft moon rendered at tonight's phase — radial-lit disc, warm halo, faint craters,
// and a terminator that carves the correct crescent → gibbous. The Sleep counterpart to
// the Focus ring's focal element.
struct MoonView: View {
    var size: CGFloat = 60
    var illumination: Double = 1.0      // 0 new … 1 full
    var waxing: Bool = true             // lit limb on the right (N. hemisphere)

    private static let litLight = Color(red: 0.99, green: 0.97, blue: 0.90)
    private static let litDark  = Color(red: 0.86, green: 0.81, blue: 0.68)
    private static let nightSide = Color(red: 0.07, green: 0.07, blue: 0.10)

    private var litFill: RadialGradient {
        RadialGradient(
            gradient: Gradient(colors: [Self.litLight, Self.litDark]),
            center: UnitPoint(x: 0.38, y: 0.34),
            startRadius: 1,
            endRadius: size * 0.78
        )
    }

    var body: some View {
        ZStack {
            // Halo dims with the phase so a thin sliver doesn't glow like a full moon.
            Circle()
                .fill(Color(red: 0.96, green: 0.92, blue: 0.80))
                .frame(width: size * 1.7, height: size * 1.7)
                .blur(radius: 22)
                .opacity(0.05 + 0.12 * illumination)

            ZStack {
                Circle()
                    .fill(litFill)
                    .overlay(
                        ZStack {
                            crater(0.30, -0.18, 0.16)
                            crater(-0.22, 0.12, 0.22)
                            crater(0.12, 0.30, 0.12)
                            crater(0.36, 0.20, 0.09)
                        }
                    )

                phaseShadow()
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        }
        .accessibilityHidden(true)
    }

    // The terminator is a vertical ellipse (the disc scaled horizontally). For a crescent
    // the ellipse is shadow that carves into the lit side; for a gibbous it's light that
    // restores the dark side. Plus the far hemisphere is always dark.
    private func phaseShadow() -> some View {
        let k = min(max(illumination, 0), 1)
        let a = (size / 2) * CGFloat(abs(1 - 2 * k))
        return ZStack {
            Rectangle()
                .fill(Self.nightSide)
                .frame(width: size / 2, height: size)
                .offset(x: waxing ? -size / 4 : size / 4)

            if k <= 0.5 {
                Ellipse().fill(Self.nightSide).frame(width: a * 2, height: size)
            } else {
                Ellipse().fill(litFill).frame(width: a * 2, height: size)
            }
        }
    }

    private func crater(_ dx: CGFloat, _ dy: CGFloat, _ rel: CGFloat) -> some View {
        Circle()
            .fill(Color(red: 0.70, green: 0.65, blue: 0.52).opacity(0.28))
            .frame(width: size * rel, height: size * rel)
            .offset(x: dx * size * 0.5, y: dy * size * 0.5)
    }
}

// Places the moon along a Bézier arc from a high resting spot down to the horizon,
// driven by how far through the sleep timer the night is. Idle (no timer) → rests high.
struct MoonArc: View {
    @ObservedObject var sleepTimer: SleepTimerService

    var body: some View {
        GeometryReader { geo in
            moon(in: geo.size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func moon(in size: CGSize) -> some View {
        let p0 = CGPoint(x: size.width * 0.18, y: size.height * 0.16)   // full night: high left
        let ctrl = CGPoint(x: size.width * 0.52, y: size.height * 0.06)  // gentle rise
        let p1 = CGPoint(x: size.width * 0.82, y: size.height * 0.66)   // night's end: horizon
        let t = CGFloat(sleepTimer.nightProgress)
        let pt = Self.quad(p0, ctrl, p1, t)
        let phase = MoonPhase.current()
        return MoonView(size: 60, illumination: phase.illumination, waxing: phase.waxing)
            .position(pt)
            // Eased glide regardless of Reduce Motion: a slow drift over the whole timer,
            // not the jarring kind of motion (the position updates either way; this just
            // smooths the per-tick steps).
            .animation(.easeInOut(duration: 1.0), value: t)
    }

    // Point on a quadratic Bézier at parameter t.
    static func quad(_ p0: CGPoint, _ c: CGPoint, _ p1: CGPoint, _ t: CGFloat) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * c.x + t * t * p1.x,
            y: mt * mt * p0.y + 2 * mt * t * c.y + t * t * p1.y
        )
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

    var body: some View {
        VStack(spacing: 10) {
            WarmMixerRow(
                icon: "waveform.path.ecg",
                title: audio.noiseType.capitalized,
                isOn: $audio.noiseOn,
                volume: $audio.noiseVolume,
                pal: pal,
                options: audio.focusMode ? ["pink", "fan", "white"] : ["brown", "rain", "ocean"],
                selection: $audio.noiseType
            )
            .glassPanel()
            
            WarmMixerRow(
                icon: "headphones",
                title: "Binaural (\(audio.binauralPreset.capitalized))",
                isOn: $audio.binauralOn,
                volume: $audio.binVolume,
                pal: pal,
                options: audio.focusMode ? ["alpha", "gamma"] : ["delta", "theta"],
                optionLabels: ["delta":"Deep","theta":"Drift","alpha":"Relax","gamma":"Focus"],
                selection: $audio.binauralPreset
            )
            .glassPanel()
            
            // Podcast is on/off + volume like the other layers — episode picking lives in the
            // Library tab and the mini-player, not an impractical inline dropdown.
            WarmMixerRow(
                icon: "mic.fill",
                title: audio.isPodPlaying ? audio.podTitle : "Podcast",
                isOn: $audio.isPodPlaying,
                volume: $audio.podVolume,
                pal: pal,
                onToggle: { audio.togglePodcast() }
            )
            .glassPanel()
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
                    .foregroundColor(audio.isMuted ? .red : pal.accent)
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
    let pal: Palette

    private func mixSummary(_ mix: SavedMix) -> String {
        var parts: [String] = []
        if mix.noiseOn { parts.append(mix.noiseType.capitalized) }
        if mix.binauralOn { parts.append(mix.binauralPreset.capitalized) }
        if mix.podcastUrl != nil { parts.append("Podcast") }
        return parts.isEmpty ? "Silent" : parts.joined(separator: " + ")
    }

    // A horizontal row of compact mix cards — tap to load, long-press to delete. Replaces
    // the old full-width list of name + Load + Delete + divider rows.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Saved mixes")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(pal.dim)
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(audio.savedPlaylists, id: \.id) { (mix: SavedMix) in
                        Button(action: { audio.resumeMix(mix) }) {
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
                            Button(role: .destructive) { audio.deleteMix(mix) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel("Load mix \(mix.name)")
                        .accessibilityHint("Long press to delete")
                    }
                }
                .padding(.horizontal, 20)
            }
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

    var body: some View {
        VStack(spacing: 24) {
            Text("Sleep Timer")
                .font(.title2.bold())
                .foregroundColor(pal.text)
            
            Text("Fade out smoothly over...")
                .foregroundColor(pal.dim)
            
            HStack(spacing: 12) {
                ForEach([15, 30, 45, 60], id: \.self) { mins in
                    Button(action: {
                        timerMinutes = Double(mins)
                        audio.sleepTimer.startSleepTimer(minutes: mins)
                        isPresented = false
                    }) {
                        Text("\(mins)m")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color(white: 0.15))
                            .foregroundColor(pal.text)
                            .cornerRadius(10)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
            }
            
            VStack(spacing: 8) {
                Text("Custom: \(Int(timerMinutes)) Minutes")
                    .font(.headline)
                    .foregroundColor(pal.text)
                
                Slider(value: $timerMinutes, in: 5...120, step: 5)
                    .tint(pal.accent)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
            
            Button(action: {
                audio.sleepTimer.startSleepTimer(minutes: Int(timerMinutes))
                isPresented = false
            }) {
                Text("Start Timer")
                    .font(.headline.bold())
                    .foregroundColor(pal.bg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding()
                    .background(pal.accent)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .padding(.top, 20)
            
            Spacer()
        }
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg.ignoresSafeArea())
    }
}
