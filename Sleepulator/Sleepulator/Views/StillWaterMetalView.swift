import SwiftUI

/// "Still water" (Sleep) — the Metal edition. A GPU fragment shader
/// (`StillWaterShader.metal`, `stillWaterField`) renders a low moon over a dark pond whose
/// reflected moonpath shimmers on a per-pixel FBM wave field, with faint ripples spreading from a
/// few points. It replaces the CPU `StillWaterView`, which stroked ellipse *outlines* (wireframe
/// rings).
///
/// Same `SceneContext` inputs as the other sleep scenes, sampled *live* each tick (never observed,
/// to avoid the `@Published` re-render storm CLAUDE.md warns about):
///   - `sleepTimer.nightProgress` stills the pond and dims the moon,
///   - `audioLevel` swells the ripples a touch with the generative bed.
///
/// Settle (battery): when `paused` the `TimelineView` is dropped entirely — one static shader
/// pass, no redraw loop on the all-night occluded screen.
struct StillWaterMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the pond stills as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the ripples swell with the bed.
    var audioLevel: (() -> Double)? = nil

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
        Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.stillWaterField(
                    .float(t),
                    .float2(size),
                    .float(night),
                    .float(level)
                )
            )
    }
}
