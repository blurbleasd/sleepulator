import SwiftUI

/// "Embers" (Sleep) — the Metal edition, take two. A GPU fragment shader (`EmbersShader.metal`,
/// `emberField`) renders smoldering coals: a dark field of deep reds slowly churning on a gentle
/// differential swirl. Deliberately dark, lulling, and hypnotic — significant *but slow* motion,
/// no flames / white-hot cores / sparks (the first fire take was too stimulating for sleep).
///
/// A thin wrapper over `ShaderBackdrop`, which owns the redraw loop, the settle, and the
/// `SceneClock` phase integration (`nightSlowdown: 0.3` → the churn's drift eases as the night
/// deepens, without the rewind bug of scaling absolute time):
///   - `sleepTimer.nightProgress` settles the coals darker and slows the churn,
///   - `audioLevel` lifts them gently with the generative bed.
struct EmbersMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the coals settle as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the coals lift with the bed.
    var audioLevel: (() -> Double)? = nil

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.3,
                       sleepTimer: sleepTimer, audioLevel: audioLevel) { s in
            ShaderLibrary.emberField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(s.night),
                .float(s.audio)
            )
        }
    }
}
