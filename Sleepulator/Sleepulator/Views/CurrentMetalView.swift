import SwiftUI

/// "Current" (Focus) — the Metal edition. A GPU fragment shader (`CurrentShader.metal`,
/// `currentField`) renders cool streams flowing across a deep-indigo field from domain-warped FBM,
/// with a filmic roll-off + hash dither so the cool field doesn't band on OLED. It is the A/B
/// sibling of the CPU `CurrentView` (which stroked sine paths on a Canvas).
///
/// The look is driven by the shared `FocusDrivers` mapping — the SAME mapping the Canvas
/// `CurrentView` uses — so the two scenes can differ only in rendering, never in how they read the
/// Pomodoro. Values are sampled *live* each tick (never observed, so the per-tick redraw can't
/// trigger the `@Published` re-render storm CLAUDE.md warns about).
///
/// Flow uses its OWN `SceneClock` rather than `ShaderBackdrop`, because Current's rate is the
/// Pomodoro's `driveSpeed` (momentum), not the night-slowdown `ShaderBackdrop` integrates. Reduce
/// Motion feeds rate 0 → `flow` freezes → a static field (no advection). `paused` (occlusion)
/// freezes the schedule to one static frame at the frozen pose.
struct CurrentMetalView: View {
    var paused: Bool = false
    /// Read live (not observed) so phase/progress drive the look.
    let pomodoro: PomodoroService
    /// When true, feed the flow clock rate 0 so the field is static (Reduce Motion).
    var reduceMotion: Bool = false

    /// Integrates `driveSpeed` into a flow phase (rate, not absolute-time × speed — see
    /// `CurrentView`/`SceneClock`). Random start so the streams open at a fresh pose each appearance.
    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // `paused:` on the schedule (not an if/else swap) keeps view identity stable across the
            // freeze, and renders one static pass at the frozen SceneClock pose.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
                field(size: size, now: paused ? nil : tl.date.timeIntervalSinceReferenceDate)
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
        // Reduce Motion → rate 0 → the flow phase holds still (static field, no advection).
        let rate = reduceMotion ? 0 : look.speed
        if let now { clock.tick(now: now, rate: rate) }
        let flow = Float(clock.phase)
        return Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.currentField(
                    .float(flow),
                    .float2(size),
                    .float(Float(look.op)),
                    .float(Float(look.amp)),
                    .float3(Float(look.tint.x), Float(look.tint.y), Float(look.tint.z))
                )
            )
    }
}
