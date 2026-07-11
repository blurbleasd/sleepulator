import SwiftUI

/// The central play orb — the single focal control of the ambient-minimal home. A soft breathing
/// glow + a clean dark disc.
///
/// The glow breathes on a `SceneClock`-driven `TimelineView`. Its baseline is a slow cosine breath;
/// on top, it swells subtly with the *generative* bed by sampling `audio.audioLevel` live (never
/// observed — the closure/plain-property discipline the scenes use). Note `audioLevel` is fed only
/// by the noise/binaural render, so a podcast-only mix breathes on the cosine alone. Two wins over
/// the old `repeatForever` loop: (1) it *freezes* when the orb isn't visible (chrome faded to the
/// screensaver, or the screen occluded/backgrounded) instead of compositing a blurred 200pt layer
/// all night; (2) its motion depth rides `NightDamping`, so the orb progressively stills as the
/// sleep timer winds down. Only *scale* is modulated — opacity stays clamped at the original
/// values, never brighter (the 2am rule). Runs under Reduce Motion by design (see `NightDamping`).
struct OrbButton: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    let tap: () -> Void
    /// True when the orb isn't visibly animating — the chrome has faded to the ambient
    /// screensaver, or the screen is occluded/backgrounded. Freezes the breath loop in place.
    var paused: Bool = false

    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @State private var pressed = false
    /// Freeze-in-place breath clock (the ShaderBackdrop primitive) — holds its pose across a
    /// pause instead of snapping, and never advances while occluded.
    @State private var clock = SceneClock()

    /// Slow breath cadence, seconds — unchanged from the original pulse.
    private static let breathPeriod: Double = 4.5

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            tap()
        }) {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { tl in
                orb(now: paused ? nil : tl.date)
            }
        }
        .buttonStyle(.plain)
        // Press tightens the orb (never brightens) — spring, not a transform of the whole view.
        .scaleEffect(pressed ? 0.96 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: pressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .accessibilityLabel(audio.isAnythingPlaying ? "Pause all audio" : "Play")
    }

    @ViewBuilder
    private func orb(now: Date?) -> some View {
        let _ = now.map { clock.tick(now: $0.timeIntervalSinceReferenceDate, rate: 1) }
        // Damp the *motion* (not the base): alive while building the mix, progressively still as
        // the timer winds down, zero motion by fade-out. Read live, never observed. (`bedtimeMode`
        // is currently always false — no live setter remains — so its branch is inert today, kept
        // for parity with how the palettes still thread it.)
        let damp = NightDamping.factor(nightProgress: audio.sleepTimer.nightProgress, bedtime: bedtimeMode)
        let breath01 = 0.5 - 0.5 * cos(clock.elapsed * 2 * .pi / Self.breathPeriod)   // [0,1]
        let level = audio.audioLevel                                                   // ~[0,1] smoothed
        // Center 0.99; the breath spans the original 0.92↔1.06, plus a subtle swell with the bed.
        // As damp → 0 the motion shrinks to nothing — the orb stills as you go under (and while
        // awake past the timer it settles to the 0.99 center; once dimmed it just holds its pose).
        let scale = 0.99 + damp * (0.14 * (breath01 - 0.5) + 0.05 * level)
        ZStack {
            Circle().fill(pal.accent.opacity(0.09))
                .frame(width: 200, height: 200)
                .blur(radius: 32)
                .scaleEffect(scale)
                // Opacity is NEVER modulated by audio — a brightening orb at 2am is a nightlight.
                .opacity(audio.isAnythingPlaying ? 0.5 : 0.22)
            Circle().fill(Color(white: 0.09).opacity(0.85))
                .frame(width: 132, height: 132)
                .overlay(Circle().stroke(pal.accent.opacity(0.35), lineWidth: 1))
            Image(systemName: audio.isAnythingPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 46, weight: .medium, design: .rounded))
                .foregroundColor(pal.accent)
        }
    }
}
