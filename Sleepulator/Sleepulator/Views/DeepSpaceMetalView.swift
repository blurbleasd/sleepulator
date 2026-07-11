import SwiftUI

/// "Deep space" (Sleep) — a GPU fragment shader (`DeepSpaceShader.metal`, `nebulaField`) renders a
/// slow nebula of domain-warped FBM cloud over a three-tier parallax star field, with a comet
/// sweeping every ~40s. A new generative showpiece (no CPU predecessor), so there's no A/B sibling.
///
/// A thin wrapper over `ShaderBackdrop`, which owns the redraw loop, the settle, and the
/// `SceneClock` phase integration (`nightSlowdown: 0.4` → the nebula's drift eases as the night
/// deepens, without the rewind bug of scaling absolute time):
///   - `sleepTimer.nightProgress` dims the field, drifts the hue, and retires the comet,
///   - `audioLevel` lifts the nebula with the generative bed,
///   - `tilt` parallaxes the nebula and the star tiers by depth.
struct DeepSpaceMetalView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the field settles as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the nebula lifts with the bed.
    var audioLevel: (() -> Double)? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    /// Keep in sync with `COMET_SEC` / `COMET_WIN` in `DeepSpaceShader.metal` — used only to
    /// dodge the comet on the frozen frame (below), so drift here costs a wasted nudge, not a bug.
    private static let cometSec: Float = 40.0
    private static let cometWin: Float = 0.16

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.4,
                       sleepTimer: sleepTimer, audioLevel: audioLevel, tilt: tilt) { s in
            // The frozen frame must never hold a mid-sweep comet (it would sit burned on the
            // occluded screen all night): if the freeze lands inside the comet window, nudge the
            // cyclic clock out of it — toward the NEAREST edge, to keep the shift small. Star
            // positions can't move (tier drift rides `phase`, untouched here); only twinkle
            // pose, the breath, and the dither shift, sub-perceptual on a static frame. Skipped
            // once the shader has night-gated the comet away (`win *= 1 − smoothstep(.35,.75,p)`)
            // — no comet, nothing to dodge.
            var t = s.elapsed
            if s.frozen && s.night < 0.75 {
                let ph = (t / Self.cometSec) - (t / Self.cometSec).rounded(.down)
                let clear = Self.cometWin + 0.02          // window plus margin
                if ph < clear {
                    if ph < clear / 2, t > Self.cometSec {
                        t -= (ph + 0.01) * Self.cometSec  // back to just before the window opens
                    } else {
                        t += (clear + 0.02 - ph) * Self.cometSec  // forward to just past it
                    }
                }
            }
            return ShaderLibrary.nebulaField(
                .float(s.phase),
                .float(t),
                .float2(s.size),
                .float(s.night),
                .float(s.audio),
                .float2(s.gyro.x, s.gyro.y)
            )
        }
    }
}
