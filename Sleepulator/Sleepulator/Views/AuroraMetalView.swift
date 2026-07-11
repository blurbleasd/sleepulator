import SwiftUI

/// "Aurora" (Sleep) — the Metal edition. A GPU fragment shader (`AuroraShader.metal`,
/// `auroraField`) renders flowing curtains from domain-warped FBM noise, with dithering and a
/// soft filmic roll-off so the gradients don't band on OLED. It replaces the CPU `AuroraView`
/// (which composited striated gradient rectangles on a Canvas).
///
/// A thin wrapper over `ShaderBackdrop`, which owns the redraw loop, the settle, and the
/// `SceneClock` phase integration (`nightSlowdown: 0.5` → the curtains' flow eases to half
/// speed by timer end, without the rewind bug of scaling absolute time):
///   - `sleepTimer.nightProgress` winds the curtains down toward a dim violet wash,
///   - `audioLevel` lets them swell a touch with the generative bed,
///   - `tilt` parallaxes the field during the watching window.
struct AuroraMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) inside the redraw so the curtains settle as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the curtains glow as the bed swells.
    var audioLevel: (() -> Double)? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.5,
                       sleepTimer: sleepTimer, audioLevel: audioLevel, tilt: tilt) { s in
            ShaderLibrary.auroraField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(s.night),
                .float(s.audio),
                .float2(s.gyro.x, s.gyro.y)
            )
        }
    }
}
