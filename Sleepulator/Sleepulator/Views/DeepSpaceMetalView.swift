import SwiftUI

/// "Deep space" (Sleep) — a GPU fragment shader (`DeepSpaceShader.metal`, `nebulaField`) renders a
/// slow nebula of domain-warped FBM cloud over a three-tier parallax star field, with a comet
/// sweeping every ~40s. A new generative showpiece (no CPU predecessor), so there's no A/B sibling.
///
/// Same `SceneContext` inputs as the other sleep scenes, sampled *live* each tick (never observed,
/// to avoid the `@Published` re-render storm CLAUDE.md warns about):
///   - `sleepTimer.nightProgress` dims the field and drifts the hue,
///   - `audioLevel` lifts the nebula with the generative bed,
///   - `tilt` parallaxes the nebula and the star tiers by depth.
///
/// Settle (battery): when `paused` the `TimelineView` is dropped entirely — one static shader
/// pass, no redraw loop on the all-night occluded screen.
struct DeepSpaceMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the field settles as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the nebula lifts with the bed.
    var audioLevel: (() -> Double)? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    /// Anchor elapsed time to launch so the shader's `time` stays Float-precise all night.
    @State private var t0 = Date().timeIntervalSinceReferenceDate

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            if paused {
                field(size: size, t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    field(size: size, t: tl.date.timeIntervalSinceReferenceDate - t0)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func field(size: CGSize, t: Double) -> some View {
        let night = sleepTimer?.nightProgress ?? 0
        let level = audioLevel?() ?? 0
        let g = tilt?() ?? .zero
        Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.nebulaField(
                    .float(t),
                    .float2(size),
                    .float(night),
                    .float(level),
                    .float2(g.x, g.y)
                )
            )
    }
}
