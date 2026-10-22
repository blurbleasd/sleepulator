import SwiftUI

/// "Lamplight" (Sleep): snow falling through a street lamp's light on a winter night, seen from an
/// upstairs window, a GPU fragment shader (`LamplightShader.metal`, `lampSnowField`). Outside the
/// light the snow is unseen; inside the lamp's cone every flake is lit and the cone glows faintly in
/// the snow-filled air, over a pool of light on the snow. Further lamps recede down the street into
/// the snowfall. Depth comes from a small world in metres seen through a pinhole camera: flakes
/// nearer the window bigger, softer and faster across the screen, the far lamps fading into the
/// snow, and gyro parallax by real depth while the phone is held.
///
/// The night is in the structure: at bedtime the snow falls steadily and footprints cross the pool;
/// through the night the snowfall thins and the footprints fill in (`SnowNight`). A thin wrapper over
/// `ShaderBackdrop`, which owns the redraw loop, the freeze and the `SceneClock`
/// (`nightSlowdown: 0.4`: the fall, the breeze, the flutter and the window's wander ease to 60% as
/// the night deepens):
///   - `sleepTimer.nightProgress`, eased (`EasedNight.follow`, through ShaderBackdrop's `easedNight`,
///     so the fall's pace eases with it), sets the snowfall and how settled the snow is, and dims the
///     scene (the bowl most);
///   - `tilt` moves the window, so the scene parallaxes by depth;
///   - `occluded` keeps the still street following the night with Moving scenes off, and tells the
///     eased night whether it was watched.
struct LamplightMetalView: View {
    var paused: Bool = false
    var occluded: Bool = true
    /// Read live (not observed) so the street follows the night.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    @Environment(\.displayScale) private var displayScale

    /// The night the street shows, eased toward the timer's (see `EasedNight.follow`).
    @State private var follower = EasedNightFollower()

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.4,
                       sleepTimer: sleepTimer, audioLevel: nil, tilt: tilt, occluded: occluded,
                       easedNight: follower.night) { s in
            let night = Double(s.night)
            return ShaderLibrary.lampSnowField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(Float(night)),
                .float(Float(SnowNight.snowfall(night: night))),
                .float(Float(SnowNight.settled(night: night))),
                .float2(s.gyro.x, s.gyro.y),
                .float(Float(displayScale))
            )
        }
    }
}

/// How the snow changes over the night, the scene's reading of it: at bedtime it falls steadily and
/// footprints cross the lamp's pool; through the night it thins, and what has fallen settles (the
/// footprints fill in, snow builds on the lamp), until a quarter of the snow drifts through the light
/// over unbroken snow. It never stops, so waking at 3am (an All night session holds `nightProgress`
/// at 1) still shows snow falling. A "+15m" winds it back a little, footprints too: the whole scene
/// follows the night. Pure, so it's unit-tested; the shader turns the snowfall into which
/// flakes fall, each fading out over a short stretch.
nonisolated enum SnowNight {
    /// The share of flakes still falling at the end of the night.
    static let snowfallAtEnd = 0.25

    /// The share of flakes falling (0…1).
    static func snowfall(night: Double) -> Double {
        1 - (1 - snowfallAtEnd) * smoothstep(0.10, 0.85, EasedNight.clamped(night))
    }

    /// How far the snow has settled (0…1): 0 = crisp footprints, 1 = filled in, the lamp capped.
    /// Done well before the night's end, so the 3am street is unbroken.
    static func settled(night: Double) -> Double {
        smoothstep(0.05, 0.80, EasedNight.clamped(night))
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
