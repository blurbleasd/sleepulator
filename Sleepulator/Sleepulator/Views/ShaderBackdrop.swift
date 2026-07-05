import SwiftUI

/// An integrating animation clock for scenes whose speed is modulated live (night settle,
/// pomodoro momentum).
///
/// The bug this exists to fix: scaling an *absolute* time by a live factor —
/// `t = elapsed × f(nightProgress)` — doesn't slow the motion, it rewinds it. `elapsed` is large
/// and growing, so when `f` shrinks the product can *decrease*: partway through a timer run the
/// aurora/water/embers visibly stall and drift backward, worst exactly when the user is going
/// under. The factor must modulate the *rate*, so it's integrated here instead:
/// `phase += Δt × rate`, which is monotonic for any rate ≥ 0 and continuous when the rate moves.
///
/// Also the freeze-in-place seam: `Δt` is clamped, so after a pause (the night-dim veil, a
/// backgrounding) the scene resumes from its frozen pose instead of jumping — and the paused
/// static frame renders the *frozen* `phase`/`elapsed`, not `t: 0` (which snapped every scene
/// back to its birth pose).
///
/// A plain class, deliberately not observed (the `TiltSource` pattern): it's mutated inside a
/// `TimelineView` closure during body evaluation, and routing that through `@Published`/`@State`
/// value changes would re-invalidate the view 30×/sec — the re-render storm CLAUDE.md warns about.
final class SceneClock {
    /// Integrated, rate-modulated time — drive all *motion* terms from this.
    private(set) var phase: Double
    /// Monotonic elapsed animation time (rate-independent) — for cyclic terms that shouldn't
    /// slow (breath, twinkle, dither) and for scheduling-like shader terms (the comet cycle).
    private(set) var elapsed: Double
    private var last: TimeInterval?

    /// `start` offsets both counters so a scene doesn't open at the identical field pose every
    /// appearance (the old launch-anchored `t0` gave that variety by accident). Keep it modest —
    /// the shaders take `time` as a Float, and their own comments bound the tolerable magnitude.
    init(start: Double = 0) {
        phase = start
        elapsed = start
    }

    /// Normal frames — and hitches down to 2fps — pass through wall-clock-true; only longer
    /// gaps (pause→resume arrives as minutes or hours, never fractions of a second) clamp,
    /// which is what makes the freeze hold its pose across an occluded night. Not smaller:
    /// clamping ordinary hitches would stretch scene time under sustained load, slowing e.g.
    /// the Breathe scene's tuned ~10s entrainment cadence.
    private static let maxStep: Double = 0.5

    func tick(now: TimeInterval, rate: Double) {
        defer { last = now }
        guard let l = last, now > l else { return }
        let dt = min(now - l, Self.maxStep)
        elapsed += dt
        phase += dt * max(0, rate)
    }
}

/// The values a scene's shader closure builds its uniforms from, one bundle per frame.
struct SceneShaderInputs {
    /// Night-slowed integrated time — use for every *motion* term (drift, travel, waves).
    var phase: Float
    /// Monotonic elapsed time — use for cyclic terms (breath, twinkle, dither, comet cycle).
    var elapsed: Float
    var size: CGSize
    /// `sleepTimer.nightProgress`, 0 start → 1 timer end.
    var night: Float
    /// Smoothed audio level, ~0…1.
    var audio: Float
    /// Smoothed gyro tilt; `.zero` when the scene doesn't use motion.
    var gyro: SIMD2<Float>
    /// True when this is the paused static frame — a scene with a scheduled transient (the
    /// deep-space comet) can dodge it so the streak isn't burned on screen all night.
    var frozen: Bool
}

/// The shared host for the full-screen Metal scenes (Aurora, Embers, Still water, Deep space) —
/// they differ only in shader function, uniform list, and how hard the night slows them, so the
/// redraw loop, the settle, and the `SceneClock` integration live here once.
///
/// `SceneContext` values are sampled *live* each tick (never observed) so the per-tick redraw
/// can't trigger the `@Published` re-render storm CLAUDE.md warns about.
///
/// Settle (battery): when `paused` the timeline schedule stops — one static shader pass at the
/// frozen `SceneClock` pose, no redraw loop on the all-night occluded screen.
struct ShaderBackdrop: View {
    var paused: Bool
    /// How hard the night settles this scene: phase rate = `1 − nightSlowdown × nightProgress`.
    var nightSlowdown: Double
    var sleepTimer: SleepTimerService?
    var audioLevel: (() -> Double)?
    var tilt: (() -> SIMD2<Float>)? = nil
    /// Builds the scene's shader from this frame's inputs.
    var makeShader: (SceneShaderInputs) -> Shader

    /// Random start so the field opens at a fresh pose each appearance (see `SceneClock.init`).
    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // `paused:` on the schedule (not an if/else branch swap) keeps the view's identity
            // stable across the freeze, so un-occluding can't reset any state.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
                field(size: size, now: paused ? nil : tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func field(size: CGSize, now: TimeInterval?) -> some View {
        let night = sleepTimer?.nightProgress ?? 0
        if let now { clock.tick(now: now, rate: 1.0 - nightSlowdown * night) }
        let inputs = SceneShaderInputs(
            phase: Float(clock.phase),
            elapsed: Float(clock.elapsed),
            size: size,
            night: Float(night),
            audio: Float(audioLevel?() ?? 0),
            gyro: tilt?() ?? .zero,
            frozen: now == nil)
        return Rectangle()
            .fill(.black)
            .colorEffect(makeShader(inputs))
    }
}
