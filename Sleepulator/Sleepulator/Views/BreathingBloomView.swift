import SwiftUI

/// A breathing bloom: a soft warm glow that slowly swells and fades on a slow breath cadence
/// (a longer exhale than inhale — the relaxing direction). Built to *entrain* — follow it and
/// your own breath slows, which is the real sleep mechanism, not just a pretty light. The most
/// directly lulling of the scenes, and the cheapest (a couple of blurred radial gradients on
/// one TimelineView loop). Freezes only when the deep night-dim veil occludes the screen.
struct BreathingBloomView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false

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

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.025, blue: 0.035).ignoresSafeArea()
            if paused {
                bloom(Self.breath(0))
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    bloom(Self.breath(tl.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The glow at breath value `b` — a dim wide halo + a brighter core, both swelling and
    /// fading together so the breath reads as depth, not a flat throbbing disc.
    private func bloom(_ b: Double) -> some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.16), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.55))
                    .frame(width: d * 1.3, height: d * 1.3)
                    .blur(radius: 50)
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.5), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.3))
                    .frame(width: d * 0.7, height: d * 0.7)
                    .blur(radius: 22)
            }
            .scaleEffect(0.75 + 0.25 * b)
            .opacity(0.4 + 0.5 * b)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
    }
}
