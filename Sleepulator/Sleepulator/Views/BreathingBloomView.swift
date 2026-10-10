import SwiftUI

/// A breathing bloom: a soft warm glow that slowly swells and fades on a slow breath cadence
/// (a longer exhale than inhale — the relaxing direction). Built to *entrain* — follow it and
/// your own breath slows, which is the real sleep mechanism, not just a pretty light. The most
/// directly lulling of the scenes, and the cheapest (a couple of blurred radial gradients on
/// one TimelineView loop). Freezes only when the deep night-dim veil occludes the screen.
struct BreathingBloomView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) inside the redraw so the glow dims as the night winds down —
    /// only the glow: the near-black background holds, so the fade reads as the light dying,
    /// not the scene going transparent.
    var sleepTimer: SleepTimerService? = nil
    /// Where the glow centres (global coordinates): Home passes the night ring's centre, so the
    /// bloom breathes around the ring and its ember instead of ~60 pt below them. Nil centres it
    /// on the screen (the breathing on-ramp).
    var focus: CGPoint? = nil

    // A soft candle/amber warmth on near-black. Warm = cozy + sleep-appropriate.
    var tint: Color = Color(red: 1.0, green: 0.84, blue: 0.6)

    // Breath timing — tune to a pace you find calming. Exhale longer than inhale on purpose
    // (a long exhale is what triggers the parasympathetic "wind down"). ~10s ≈ 6 breaths/min.
    static let inhale: Double = 4.0
    static let exhale: Double = 6.0
    static var period: Double { inhale + exhale }

    /// 0 = fully exhaled (small, dim) … 1 = fully inhaled (large, bright). Smooth + continuous.
    static func breath(_ t: Double) -> Double {
        let p = t.truncatingRemainder(dividingBy: period)
        if p < inhale {
            return 0.5 - 0.5 * cos(.pi * (p / inhale))            // 0 → 1
        } else {
            return 0.5 + 0.5 * cos(.pi * ((p - inhale) / exhale)) // 1 → 0
        }
    }

    /// Freeze-in-place clock: the paused static frame holds the breath pose it froze at
    /// (not `breath(0)`, which snapped to fully-exhaled on every un-occlusion).
    /// Deliberately starts at 0 — unlike the other scenes' random start, opening at
    /// `breath(0)` (fully exhaled, about to inhale) is the right entry point for entrainment.
    @State private var clock = SceneClock()

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.025, blue: 0.035).ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: paused)) { tl in
                bloom(Self.breath(ticked(tl.date)),
                      nightDim: 1 - 0.8 * (sleepTimer?.nightProgress ?? 0))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ticked(_ now: Date) -> Double {
        if !paused { clock.tick(now: now.timeIntervalSinceReferenceDate, rate: 1) }
        return clock.elapsed
    }

    /// The glow at breath value `b` — a dim wide halo + a brighter core, both swelling and
    /// fading together so the breath reads as depth, not a flat throbbing disc.
    private func bloom(_ b: Double, nightDim: Double) -> some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            let origin = geo.frame(in: .global).origin
            let center = focus.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
                ?? CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.16), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.55))
                    .frame(width: d * 1.3, height: d * 1.3)
                    .blur(radius: 50)
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.38), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.3))
                    .frame(width: d * 0.7, height: d * 0.7)
                    .blur(radius: 22)
            }
            // The breath lives mostly in the swell, not the light: brightness moves 0.45…0.75 (was
            // 0.4…0.9, a 2.25× pulse every 10 s in a partner's peripheral vision). Size still
            // carries a full, followable breath.
            .scaleEffect(0.75 + 0.25 * b)
            .opacity((0.45 + 0.30 * b) * nightDim)
            .position(center)
        }
    }
}
