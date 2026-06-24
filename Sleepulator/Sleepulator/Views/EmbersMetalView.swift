import SwiftUI

/// "Embers" (Sleep) — the Metal edition, take two. A GPU fragment shader (`EmbersShader.metal`,
/// `emberField`) renders smoldering coals: a dark field of deep reds slowly churning on a gentle
/// differential swirl. Deliberately dark, lulling, and hypnotic — significant *but slow* motion,
/// no flames / white-hot cores / sparks (the first fire take was too stimulating for sleep).
///
/// Same `SceneContext` inputs as the other sleep scenes, sampled *live* each tick (never observed,
/// to avoid the `@Published` re-render storm CLAUDE.md warns about):
///   - `sleepTimer.nightProgress` settles the coals darker and slows the churn,
///   - `audioLevel` lifts them gently with the generative bed.
///
/// Settle (battery): when `paused` the `TimelineView` is dropped entirely — one static shader
/// pass, no redraw loop on the all-night occluded screen.
struct EmbersMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the coals settle as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the coals lift with the bed.
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
                ShaderLibrary.emberField(
                    .float(t),
                    .float2(size),
                    .float(night),
                    .float(level)
                )
            )
    }
}
