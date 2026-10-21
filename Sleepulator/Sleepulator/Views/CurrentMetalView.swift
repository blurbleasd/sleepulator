import SwiftUI

/// "Current" (Focus) — the Metal edition. A GPU fragment shader (`CurrentShader.metal`,
/// `currentField`) renders cool streams flowing across a deep-indigo field from domain-warped FBM,
/// with a filmic roll-off + hash dither so the cool field doesn't band on OLED. It replaced a CPU
/// Canvas edition that stroked sine paths.
///
/// The look is driven by the shared `FocusDrivers` mapping, the one place the Focus scenes read the
/// Pomodoro. Values are sampled *live* each tick; the view never observes it, so the per-tick
/// redraw can't trigger the `@Published` re-render storm CLAUDE.md warns about. Only its isolated
/// `FocusStillFrame` child observes it, while paused and in sight, and a publish redraws just that.
///
/// Flow uses its OWN `SceneClock` rather than `ShaderBackdrop`, because Current's rate is the
/// Pomodoro's `look.speed` (momentum), not the night-slowdown `ShaderBackdrop` integrates. System
/// Reduce Motion doesn't still it (it gates parallax only; see the NOTE in `field`). `paused`
/// (occlusion, or "Moving scenes" off) freezes the schedule to one static frame at the frozen pose;
/// while the screen is in sight that frame still follows the session (`FocusStillFrame`).
struct CurrentMetalView: View {
    var paused: Bool
    /// The out-of-sight part of `paused` (`SceneContext.occluded`): only then does the still frame
    /// stop following the Pomodoro.
    var occluded: Bool
    /// Read live, not observed here, so phase/progress drive the look (`FocusStillFrame` does
    /// observe it).
    let pomodoro: PomodoroService

    /// Integrates `look.speed` into a flow phase (rate, not absolute-time × speed — see
    /// `SceneClock`). Random start so the streams open at a fresh pose each appearance.
    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Unconditional TimelineView in the else branch. The `paused:` schedule variant stops
            // driving frames on device (ProMotion): the scene only redrew on external @Published
            // churn (the Pomodoro's ~1Hz tick), so it froze when idle and lurched during a session
            // (device 2026-07-11). The SceneClock is @State on this view, so it survives the if/else
            // and the paused frame still renders the frozen pose (never a t:0 birth-pose snap).
            if paused && !occluded {
                // Still but in sight (Moving scenes off): the pose holds, the front follows the
                // session.
                FocusStillFrame(pomodoro: pomodoro) { field(size: size, now: nil) }
            } else if paused {
                field(size: size, now: nil)
            } else {
                // 60 fps, not 30. Focus scenes are fast by design (flowing streams, falling
                // comets); on a 120 Hz ProMotion panel a 30 fps cap holds each frame for four
                // refreshes, so fast features advance in visible jumps — the long-standing
                // "focus savers are choppy" report. Sleep stays at 30: its drift is slow enough
                // that the step is sub-pixel, and it runs all night on battery.
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { tl in
                    field(size: size, now: tl.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func field(size: CGSize, now: TimeInterval?) -> some View {
        let look = FocusDrivers.look(isRunning: pomodoro.isRunning,
                                     isWork: pomodoro.phase == .work,
                                     progress: pomodoro.progress)
        // NOTE: the clock rate is deliberately NOT gated on Reduce Motion. It used to be
        // (`rate: reduceMotion ? 0 : …`), which froze the scene's phase outright whenever iOS
        // Reduce Motion was on — the long-standing "Focus savers are choppy / Current is fully
        // static" report. With the phase frozen, the only thing still changing was the
        // Pomodoro-driven `energy`/look, so Tide and Sandfall stepped once per second and
        // Current (whose look barely varies) looked dead. Sleep never had this because
        // ShaderBackdrop's rate has no Reduce Motion term.
        //
        // Per SCREENSAVER-LIBRARY-SPEC §5 Reduce Motion gates PARALLAX only; the app-level
        // "Moving scenes" toggle (Settings ▸ Display) is the control for holding a scene still,
        // and it already reaches every scene through `paused`.
        // THE reading: a luminous front whose x IS the interval's progress — it crosses the field
        // exactly once per work interval and runs back across a break. -1 hides it (idle), so the
        // scene never implies a session that isn't running. Everything else here (op/amp/speed) is
        // intensity and rate, which the eye cannot read absolutely — that is why this scene used
        // to say nothing about the session.
        let front = FocusDrivers.fill(isRunning: pomodoro.isRunning,
                                      isWork: pomodoro.phase == .work,
                                      progress: pomodoro.progress) ?? -1
        let rate = look.speed
        if let now {
            clock.tick(now: now, rate: rate)
            SceneDiagnostics.shared.frame(now: now)   // F3: Focus was never instrumented until now
        }
        let flow = Float(clock.phase)
        return Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.currentField(
                    .float(flow),
                    .float2(size),
                    .float(Float(look.op)),
                    .float(Float(look.amp)),
                    .float(Float(front)),
                    .float3(Float(look.tint.x), Float(look.tint.y), Float(look.tint.z))
                )
            )
    }
}
