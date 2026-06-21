import SwiftUI

struct HomeView: View {
    @ObservedObject var audio: AudioEngine
    @State private var showTimerActionSheet = false
    @State private var isPlayPressed = false
    @State private var showBreathing = false
    @State private var showMix = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

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
                // Sleep: a quiet dark night sky — faint twinkling stars + a moon over the
                // now much-dimmer gradient. No bright central breathing orb.
                StarfieldView(accent: pal.accent, reduceMotion: reduceMotion)
                    .ignoresSafeArea()
                Image(systemName: "moon.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(red: 0.95, green: 0.92, blue: 0.80))
                    .rotationEffect(.degrees(-20))
                    .shadow(color: Color(red: 0.95, green: 0.92, blue: 0.80).opacity(0.25), radius: 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 50)
                    .padding(.top, 200)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
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
                    OrbButton(audio: audio, pal: pal, tap: heroTap)

                    Text(statusText())
                        .font(.system(.callout, design: .rounded).weight(.medium))
                        .foregroundColor(pal.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)

                    if !activeLayers.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(activeLayers, id: \.self) { layer in
                                Text(layer)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 5)
                                    .background(Capsule().fill(pal.accent.opacity(0.16)))
                                    .foregroundColor(pal.accent)
                            }
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

/// A subtle, slow-twinkling starfield for the upper "sky". Sits behind the content and
/// dissolves into the amber horizon glow at the bottom. Static under Reduce Motion; not
/// shown in bedtime mode (true-OLED-black is intentionally lightless overnight).
struct StarfieldView: View {
    let accent: Color
    let reduceMotion: Bool

    @State private var twinkle = false

    private struct Star: Identifiable {
        let id: Int
        let x, y, r, baseOpacity, dur, delay: Double
        let warm: Bool
    }

    // Deterministic layout (fixed seed). Horizon fade baked into baseOpacity so stars
    // dissolve toward the bottom of the sky.
    private static let stars: [Star] = {
        var rng: UInt64 = 0x5EED5160_0DECAF01
        func next() -> Double {
            rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
            return Double(rng % 1_000_000) / 1_000_000.0
        }
        return (0..<52).map { i in
            let yb = next()
            let y = (yb * yb) * 0.62                       // bias toward the top of the sky
            let horizonFade = 1.0 - (y / 0.62) * 0.45
            return Star(
                id: i,
                x: next(),
                y: y,
                r: 0.8 + next() * 1.7,
                baseOpacity: (0.45 + next() * 0.5) * horizonFade,
                dur: 1.4 + next() * 2.2,                   // each star pulses on its own clock
                delay: next() * 2.5,
                warm: next() < 0.18
            )
        }
    }()

    // CoreAnimation-driven implicit animation (runs on the render server, unlike the
    // Canvas+TimelineView approach that wasn't ticking). Each star eases between full and
    // ~30% opacity forever, desynced by per-star duration + delay → a live twinkle.
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.stars) { s in
                    Circle()
                        .fill(s.warm ? accent : Color.white)
                        .frame(width: s.r * 2, height: s.r * 2)
                        .position(x: s.x * geo.size.width, y: s.y * geo.size.height)
                        .opacity(twinkle ? s.baseOpacity * 0.3 : s.baseOpacity)
                        // Twinkle runs regardless of Reduce Motion — a gentle opacity fade isn't
                        // the vestibular kind of motion, and the static-stars complaint traced to
                        // this gate (the device very likely has Reduce Motion on).
                        .animation(.easeInOut(duration: s.dur).repeatForever(autoreverses: true).delay(s.delay),
                                   value: twinkle)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { twinkle = true }
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

struct HeaderBar: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                titleView
                Spacer()
            }
            .padding(.horizontal, 20)

            // Prominent Sleep | Focus selector — the primary frame of the whole app.
            ModeSwitcher(focusMode: $audio.focusMode, pal: pal)
                .padding(.horizontal, 20)

            if let note = audio.playbackNote {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(note)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .foregroundColor(pal.accent)
                .padding()
                .background(pal.text.opacity(0.05))
                .cornerRadius(12)
                .padding(.horizontal, 20)
            }
        }
    }

    private var titleView: some View {
        Text("SLEEPULATOR")
            .font(.system(.title3, design: .rounded).bold())
            .foregroundColor(pal.text)
            .tracking(2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
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

struct HeroTransport: View {
    @ObservedObject var audio: AudioEngine
    @Binding var isPlayPressed: Bool
    @Binding var showTimerActionSheet: Bool
    @Binding var showBreathing: Bool
    let reduceMotion: Bool
    let statusText: String
    let heroTap: () -> Void
    let pal: Palette

    // Hero scales with Dynamic Type (so the "find-it-in-the-dark" button doesn't shrink
    // relative to enlarged text), clamped so it can't overflow at the largest AX sizes.
    @ScaledMetric(relativeTo: .largeTitle) private var heroDiameter: CGFloat = 110
    @ScaledMetric(relativeTo: .largeTitle) private var heroGlyph: CGFloat = 40
    @State private var haloBreath = false

    static func fmt(_ s: TimeInterval) -> String {
        let total = max(0, Int(s))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Giant Play/Pause button
            VStack(spacing: 8) {
                Button(action: {
                    if reduceMotion {
                        heroTap()
                    } else {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
                            heroTap()
                        }
                    }
                    // Soft, not heavy — this is the settling-down action, not a game button.
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                }) {
                    ZStack {
                        // Idle "breathing" halo — a soft, slow glow that invites the first tap.
                        if !audio.isAnythingPlaying {
                            Circle()
                                .fill(pal.accent.opacity(0.10))
                                .frame(width: min(heroDiameter, 150) + 28, height: min(heroDiameter, 150) + 28)
                                .blur(radius: 14)
                                .scaleEffect(haloBreath ? 1.08 : 0.96)
                                .opacity(haloBreath ? 0.26 : 0.11)
                                .animation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true), value: haloBreath)
                                .allowsHitTesting(false)
                        }
                        Circle()
                            .fill(Color(white: 0.1).opacity(0.8))
                            .frame(width: min(heroDiameter, 150), height: min(heroDiameter, 150))
                            .shadow(color: pal.accent.opacity(0.15), radius: isPlayPressed ? 10 : 25)
                            .overlay(
                                Circle()
                                    .stroke(pal.accent.opacity(0.3), lineWidth: 1)
                            )

                        Image(systemName: audio.isAnythingPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: min(heroGlyph, 56), weight: .medium, design: .rounded))
                            .foregroundColor(pal.accent)
                    }
                }
                .scaleEffect(isPlayPressed ? 0.95 : 1.0)
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.9), value: isPlayPressed)
                .accessibilityLabel(audio.isAnythingPlaying ? "Pause all audio" : "Play")
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPlayPressed = true }
                        .onEnded { _ in isPlayPressed = false }
                )
                .onAppear { haloBreath = true }

                Text(statusText)
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundColor(pal.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 24)
            }

            // Focus mode: Pomodoro controls (no fade, no auto-stop)
            if audio.focusMode {
                if audio.pomodoro.isRunning {
                    VStack(spacing: 8) {
                        Text("\(audio.pomodoro.phase == .work ? "Focus" : "Break") · \(HeroTransport.fmt(audio.pomodoro.remaining))")
                            .font(.headline)
                            .foregroundColor(pal.accent)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Button(action: { audio.pomodoro.stop() }) {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: "stop.fill")
                                Text("Stop")
                                    .font(.headline)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                            .foregroundColor(.red.opacity(0.8))
                            .glassPanel()
                        }
                        .frame(minHeight: 44)
                    }
                } else {
                    Button(action: { audio.pomodoro.start() }) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "bolt.fill")
                            Text("Start Focus (\(audio.pomodoro.workMinutes)/\(audio.pomodoro.restMinutes))")
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundColor(pal.accent)
                        .glassPanel()
                    }
                    .frame(minHeight: 44)
                }
            }
            // Sleep Timer
            else if audio.sleepTimer.timerRemaining > 0 {
                if audio.sleepTimer.timerRemaining <= 60 {
                    Button(action: { audio.sleepTimer.bumpTimer() }) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "plus.circle.fill")
                            Text("Still Awake? (+15m)")
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(pal.bg)
                        .padding()
                        .background(pal.accent)
                        .cornerRadius(16)
                    }
                    .frame(minHeight: 44)
                } else {
                    Button(action: { audio.sleepTimer.cancelTimer() }) {
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: "moon.stars.fill")
                            Text("Cancel (\(Int(audio.sleepTimer.timerRemaining / 60))m)")
                                .font(.headline)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .foregroundColor(.red.opacity(0.8))
                        .glassPanel()
                    }
                    .frame(minHeight: 44)
                    .accessibilityLabel("Cancel sleep timer")
                    .accessibilityValue("\(Int(audio.sleepTimer.timerRemaining / 60)) minutes remaining")
                }
            } else {
                Button(action: { showTimerActionSheet = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "moon.zzz")
                        Text("Set sleep timer")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(pal.dim)
                }
                .frame(minHeight: 44)
            }

            // Breathing is a quiet Sleep-mode extra — a subtle link, not a prominent button.
            if !audio.focusMode {
                Button(action: { showBreathing = true }) {
                    HStack(spacing: 5) {
                        Image(systemName: "wind")
                        Text("Breathing exercise")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundColor(pal.dim.opacity(0.85))
                }
            }
        }
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
