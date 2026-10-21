import SwiftUI

/// "Fireflies" (Sleep): a meadow at the edge of a wood on a summer night, a GPU fragment shader
/// (`FirefliesShader.metal`, `fireflyField`). Warm points glow and fade among the trees and over
/// the grass, mist lies along the wood's foot, and tall grass stands black in front. Depth comes from
/// a far wood hazier than the near one, the grass hiding the meadow's fireflies, the nearest ones out
/// of focus in front of it, and gyro parallax by layer while the phone is held.
///
/// The night is in the structure: the fireflies start out of step, fall into step, and go out one
/// by one until a few are left pulsing together (`FireflyNight`). A thin wrapper over
/// `ShaderBackdrop`, which owns the redraw loop, the freeze and the `SceneClock`
/// (`nightSlowdown: 0.3`: the flashes, the drift and the sway ease to 70% as the night deepens):
///   - `sleepTimer.nightProgress` sets the sync and the fireflies left, and dims the sky and mist;
///   - `tilt` parallaxes the layers by depth;
///   - `occluded` keeps the still meadow following the night with Moving scenes off.
struct FirefliesMetalView: View {
    var paused: Bool = false
    var occluded: Bool = true
    /// Read live (not observed) so the meadow follows the night.
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for depth parallax.
    var tilt: (() -> SIMD2<Float>)? = nil

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ShaderBackdrop(paused: paused, nightSlowdown: 0.3,
                       sleepTimer: sleepTimer, audioLevel: nil, tilt: tilt, occluded: occluded) { s in
            let night = Double(s.night)
            let left = FireflyNight.remaining(night: night)
            return ShaderLibrary.fireflyField(
                .float(s.phase),
                .float(s.elapsed),
                .float2(s.size),
                .float(s.night),
                .float(Float(FireflyNight.sync(night: night))),
                .float3(Float(left.far), Float(left.meadow), Float(left.near)),
                .float2(s.gyro.x, s.gyro.y),
                .float(Float(displayScale))
            )
        }
    }
}

/// How the fireflies change over the night, the scene's reading of it: at bedtime each keeps its own
/// time and every layer is full; through the night they fall into step and go out, the nearest
/// first (the big out-of-focus ones are the most light), then the far ones in the trees, until a
/// few in the meadow are left pulsing together. They never all go out, so waking at 3am (an All
/// night session holds `nightProgress` at 1) still shows a few. Pure, so it's unit-tested; the
/// shader turns each share into which fireflies are lit, each fading out over a short stretch.
nonisolated enum FireflyNight {
    /// The share of each layer still flashing (0…1).
    nonisolated struct Left: Equatable {
        var far: Double
        var meadow: Double
        var near: Double
    }

    /// The share of the meadow's fireflies left at the end of the night: just its survivors, one per
    /// patch of the meadow (5-7 on a phone), fully lit, with every other firefly out. It has to sit
    /// between the survivors' fade (0…0.06) and the others' first rank (`LAST`, 0.10) in
    /// FirefliesShader.metal.
    static let meadowAtEnd = 0.08

    /// How far they've fallen into step: 0 = each on its own clock, 1 = one rhythm (a flash then
    /// rolls across the screen as a wave). Out of step through the first stretch of the night, in
    /// step well before its end.
    static func sync(night: Double) -> Double {
        smoothstep(0.12, 0.70, clamped(night))
    }

    static func remaining(night: Double) -> Left {
        let n = clamped(night)
        return Left(far: 1 - smoothstep(0.20, 0.80, n),
                    meadow: 1 - (1 - meadowAtEnd) * smoothstep(0.30, 0.95, n),
                    near: 1 - smoothstep(0.10, 0.55, n))
    }

    private static func clamped(_ night: Double) -> Double {
        night.isFinite ? min(max(night, 0), 1) : 0
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
