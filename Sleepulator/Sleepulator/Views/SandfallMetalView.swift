import SwiftUI

/// "Sandfall" (Focus) — the Metal edition. A GPU fragment shader (`SandfallShader.metal`,
/// `sandField`) renders a procedural hourglass: FBM-granular sand in both bulbs, the top draining
/// and the bottom mounding as the Pomodoro `progress` runs 0→1, and a turbulent falling column
/// through the neck — instead of the Canvas triangles + 14 stiff grains it replaced.
///
/// `progress` + sand tint come from the shared `FocusDrivers` mapping (the fill tracks the
/// Pomodoro; the fall animates off a `SceneClock`). `paused` (occlusion, or "Moving scenes" off)
/// freezes it to one static frame, whose fill still follows the session while the screen is in
/// sight (`FocusStillFrame`). System Reduce Motion doesn't (SCREENSAVER-LIBRARY-SPEC §5).
struct SandfallMetalView: View {
    var paused: Bool = false
    /// The out-of-sight part of `paused` (`SceneContext.occluded`): only then does the still frame
    /// stop following the Pomodoro.
    var occluded: Bool
    let pomodoro: PomodoroService

    private static let workSand = SIMD3<Double>(0.82, 0.85, 0.93)  // cool pale
    private static let restSand = SIMD3<Double>(0.55, 0.80, 0.74)  // teal (ease)
    // Settled sand at rest, dim: it lies in the bottom bulb, behind the Build mix / Focus session
    // row, and at the working sand's brightness it cut "Focus session" to ~3:1.
    private static let idleSand = SIMD3<Double>(0.40, 0.43, 0.54)

    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Unconditional TimelineView — the `paused:` variant stops driving frames on device
            // (ProMotion); see CurrentMetalView. SceneClock is @State so freeze holds its pose.
            if paused && !occluded {
                // Still but in sight (Moving scenes off): the pose holds, the fill follows the
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
        let running = pomodoro.isRunning
        let work = pomodoro.phase == .work
        let prog = min(max(pomodoro.progress, 0), 1)
        // Energy-first: the Pomodoro drives the downpour's INTENSITY (work builds + brightens; break
        // eases; idle settled and dim), not a slow hourglass level.
        let energy = running ? (work ? 0.55 + 0.45 * prog : 0.40) : 0.0
        // THE reading: how far the hourglass has drained. v3 made this scene a comet downpour —
        // bolder, but it threw away the one genuinely time-meaningful metaphor in the app, where
        // "how full is the bottom bulb" IS the answer. `fill` 0→1 across a work interval drains
        // the top bulb into the bottom; a break runs it back.
        // At rest an hourglass has its sand below; a session flips it. Idle used to show the top
        // bulb full and nothing falling, which read as a stalled timer.
        let fill = FocusDrivers.fill(isRunning: running, isWork: work, progress: prog) ?? 1.0
        let sand = running ? (work ? Self.workSand : Self.restSand) : Self.idleSand

        if let now {
            clock.tick(now: now, rate: 1)
            SceneDiagnostics.shared.frame(now: now)   // F3: Focus was never instrumented until now
        }
        let phase = Float(clock.phase)
        return Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.sandField(
                    .float(phase),
                    .float2(size),
                    .float(Float(fill)),
                    .float(Float(energy)),
                    .float3(Float(sand.x), Float(sand.y), Float(sand.z))
                )
            )
    }
}
