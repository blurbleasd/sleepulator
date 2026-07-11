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
///   - `audioLevel` drives the reflection: `reactive == false` is the shipping global brightness
///     swell; `reactive == true` (DEBUG A/B sibling) disturbs the wave field *structurally* so the
///     moonpath shimmers/breaks up with the bed instead of the whole pond lifting.
///
/// Reduce Motion adds no shader path: it forces the `reactive` uniform to 0, so those users get the
/// calm, motionless global-gain branch.
struct StillWaterMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the pond stills as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the reflection responds to the bed.
    var audioLevel: (() -> Double)? = nil
    /// Opt into the structural audio response (the DEBUG A/B variant). Off = shipping global swell.
    var reactive: Bool = false
    /// When true, force the calm branch (`reactive` uniform → 0) so no extra surface motion is added.
    var reduceMotion: Bool = false

    var body: some View {
        // Reduce Motion routes to the calm branch: it must not add the structural surface motion.
        let reactiveFlag: Float = (reactive && !reduceMotion) ? 1 : 0
        ShaderBackdrop(paused: paused, nightSlowdown: 0.5,
                       sleepTimer: sleepTimer, audioLevel: audioLevel) { s in
            ShaderLibrary.stillWaterField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(s.night),
                .float(s.audio),
                .float(reactiveFlag)
            )
        }
    }
}
