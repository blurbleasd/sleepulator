import SwiftUI

/// "Still water" (Sleep) — the Metal edition. A GPU fragment shader
/// (`StillWaterShader.metal`, `stillWaterField`) renders a low moon over a dark pond whose
/// reflected moonpath shimmers on a per-pixel FBM wave field, with faint ripples spreading from a
/// few points. It replaces the CPU `StillWaterView`, which stroked ellipse *outlines* (wireframe
/// rings).
///
/// A thin wrapper over `ShaderBackdrop`, which owns the redraw loop, the settle, and the
/// `SceneClock` phase integration (`nightSlowdown: 0.5` → the pond's drift stills to half speed
/// by timer end, without the rewind bug of scaling absolute time — which visibly *retracted*
/// the spreading ripples here):
///   - `sleepTimer.nightProgress` stills the pond and dims the moon,
///   - `audioLevel` swells the ripples a touch with the generative bed.
struct StillWaterMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the pond stills as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the ripples swell with the bed.
    var audioLevel: (() -> Double)? = nil

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.5,
                       sleepTimer: sleepTimer, audioLevel: audioLevel) { s in
            ShaderLibrary.stillWaterField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(s.night),
                .float(s.audio)
            )
        }
    }
}
