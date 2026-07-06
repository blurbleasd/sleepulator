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
        if let now {
            clock.tick(now: now, rate: 1.0 - nightSlowdown * night)
            SceneDiagnostics.shared.frame(now: now)          // F3: per-scene fps / thermal / battery
        }
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

/// The `.layerEffect` sibling of `ShaderBackdrop`, for **depth** scenes whose droplets / refraction
/// must *sample* the far world behind them (the lens) — which `.colorEffect` can't do (it gets only
/// the pixel it's replacing, never the neighbourhood). Same three gifts `ShaderBackdrop` hands the
/// `.colorEffect` scenes, here for lens scenes:
///   • `SceneClock` night-slowdown (`phase += Δt·rate`) — monotonic, no runs-backward, freeze holds pose,
///   • `sleepTimer.nightProgress` reactivity, sampled *live* each tick (never observed → no re-render storm),
///   • the built-in `TimelineView(paused:)` freeze — one static pass at the frozen pose, and a stable
///     view identity across the night-dim veil (an `if paused {} else { … }` swap resets state).
///
/// The far world is a caller-supplied view (gradient + bokeh + haze). This host flattens it once via
/// `drawingGroup()` so the background blur is *baked*, not a per-frame Gaussian (§6.2 battery trap),
/// then attaches the caller's lens shader as a `.layerEffect` sampling that one baked layer.
///
/// Why a second host instead of generalizing `ShaderBackdrop`: the two differ at the one place that
/// matters — `.colorEffect` (a pure pixel map) vs `.layerEffect` (samples the layer) — so two small
/// honest hosts read clearer than one type forced to be both. Built now (not pre-emptively) because a
/// *second* depth scene — the P4 ocean — is about to ask for exactly this rail.
struct DepthBackdrop<FarWorld: View>: View {
    var paused: Bool
    /// How hard the night settles this scene: phase rate = `1 − nightSlowdown × nightProgress`.
    /// 0 until a scene tunes it (P2 also adds a `night` shader uniform for the fog / defocus reaction).
    var nightSlowdown: Double
    var sleepTimer: SleepTimerService?
    /// Smoothed gyro tilt, sampled live for the far-world parallax; `.zero` when motion is off.
    var tilt: (() -> SIMD2<Float>)? = nil
    /// How far the lens reaches from a pixel — sets `.layerEffect(maxSampleOffset:)`. Must cover the
    /// shader's widest tap (the inverted-lens interior + rim bend + gyro shift).
    var maxSampleOffset: CGSize
    /// The lens shader's `[[stitchable]]` function name — for the F2 availability gate. If it isn't in
    /// the compiled metallib, the host renders the bare far world (the 2D scaffold) instead of a
    /// broken / blank effect, and `MetalShaders` logs the miss once. Fail-safe: a working shader is
    /// never gated off (see `MetalShaders`).
    var shaderName: String
    /// The far world the lens samples, drawn once and flattened by this host.
    @ViewBuilder var farWorld: (CGSize) -> FarWorld
    /// Builds the scene's lens shader from this frame's inputs.
    var makeShader: (SceneShaderInputs) -> Shader

    /// Random start so the field opens at a fresh pose each appearance (see `SceneClock.init`).
    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // `paused:` on the schedule (not an if/else branch swap) keeps the view's identity stable
            // across the freeze, and renders one static pass at the frozen `SceneClock` pose — not a
            // `t: 0` snap back to the birth pose (the bug this host was extracted to kill).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
                lensed(size: size, now: paused ? nil : tl.date.timeIntervalSinceReferenceDate)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func lensed(size: CGSize, now: TimeInterval?) -> some View {
        let night = sleepTimer?.nightProgress ?? 0
        if let now {
            clock.tick(now: now, rate: 1.0 - nightSlowdown * night)
            SceneDiagnostics.shared.frame(now: now)          // F3: per-scene fps / thermal / battery
        }
        let inputs = SceneShaderInputs(
            phase: Float(clock.phase),
            elapsed: Float(clock.elapsed),
            size: size,
            night: Float(night),
            audio: 0,
            gyro: tilt?() ?? .zero,
            frozen: now == nil)
        // Flatten the far world to one cached texture (bake the blur once, §6.2).
        let base = farWorld(size)
            .frame(width: size.width, height: size.height)
            .drawingGroup()
        return composite(base, inputs)
    }

    /// Attach the lens — unless the shader isn't in the compiled metallib (F2): then render the bare
    /// far-world scaffold rather than a broken effect or a silent black pane (logged once, fail-safe).
    @ViewBuilder
    private func composite(_ base: some View, _ inputs: SceneShaderInputs) -> some View {
        if MetalShaders.available(shaderName) {
            base.layerEffect(makeShader(inputs), maxSampleOffset: maxSampleOffset)
        } else {
            base
        }
    }
}
