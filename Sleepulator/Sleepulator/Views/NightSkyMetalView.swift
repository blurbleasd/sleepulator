import SwiftUI

/// "Night sky" (Sleep): the sky from a dark field, a GPU fragment shader (`NightSkyShader.metal`,
/// `nightSkyField`). A dome of stars turns slowly about a pole near the top of the screen with the
/// Milky Way arching through it, thin cloud drifts across in front, a warm airglow sits along the
/// horizon, and a far ridge and a near treeline stand in silhouette. Depth comes from aerial
/// perspective, occlusion, the cloud's motion parallax against the turning sky, and gyro parallax
/// by layer while the phone is held.
///
/// A thin wrapper over `ShaderBackdrop`, which owns the redraw loop, the freeze and the `SceneClock`
/// (`nightSlowdown: 0.4`: the turn and the drift ease to 60% as the night deepens):
///   - `sleepTimer.nightProgress` dims the sky, the Milky Way, the glow and the cloud, and calms
///     the scintillation;
///   - `tilt` parallaxes the sky, the ridge and the trees by depth;
///   - `occluded` keeps the still sky darkening with Moving scenes off.
/// The meteor is a SwiftUI overlay (`ShootingStarView`), shown only while Home's controls are up.
struct NightSkyMetalView: View {
    var paused: Bool = false
    var occluded: Bool = true
    /// Read live (not observed) so the sky settles as the night progresses.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.4,
                       sleepTimer: sleepTimer, audioLevel: nil, tilt: tilt, occluded: occluded) { s in
            ShaderLibrary.nightSkyField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(s.night),
                .float2(s.gyro.x, s.gyro.y),
                .float(Float(displayScale))
            )
        }
    }
}
