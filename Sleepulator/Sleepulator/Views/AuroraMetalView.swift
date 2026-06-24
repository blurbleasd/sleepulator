import SwiftUI

/// "Aurora" (Sleep) — the Metal edition. A GPU fragment shader (`AuroraShader.metal`,
/// `auroraField`) renders flowing curtains from domain-warped FBM noise, with dithering and a
/// soft filmic roll-off so the gradients don't band on OLED. It replaces the CPU `AuroraView`
/// (which composited striated gradient rectangles on a Canvas).
///
/// Same `SceneContext` inputs as every sleep scene, sampled *live* each tick (never observed, so
/// the per-tick redraw can't trigger the `@Published` re-render storm CLAUDE.md warns about):
///   - `sleepTimer.nightProgress` winds the curtains down toward a dim violet wash,
///   - `audioLevel` lets them swell a touch with the generative bed,
///   - `tilt` parallaxes the field during the watching window.
///
/// Settle (battery): when `paused` the `TimelineView` is dropped entirely — one static shader
/// pass, no redraw loop on the all-night occluded screen (mirrors `RainGlassDepthView`).
struct AuroraMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) inside the redraw so the curtains settle as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the curtains glow as the bed swells.
    var audioLevel: (() -> Double)? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    /// Anchor elapsed time to launch so the shader's `time` stays Float-precise all night (a raw
    /// `timeIntervalSinceReferenceDate` is ~7e8 and loses sub-frame precision as a Float).
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
                ShaderLibrary.auroraField(
                    .float(t),
                    .float2(size),
                    .float(night),
                    .float(level),
                    .float2(g.x, g.y)
                )
            )
    }
}
