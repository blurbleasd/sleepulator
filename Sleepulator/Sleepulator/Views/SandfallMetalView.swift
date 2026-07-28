import SwiftUI

/// "Sandfall" (Focus) — the Metal edition. A GPU fragment shader (`SandfallShader.metal`,
/// `sandField`) renders a procedural hourglass: FBM-granular sand in both bulbs, the top draining
/// and the bottom mounding as the Pomodoro `progress` runs 0→1, and a turbulent falling column
/// through the neck — instead of the Canvas triangles + 14 stiff grains. A/B sibling of `SandfallView`.
///
/// `progress` + sand tint come from the SAME reads the Canvas `SandfallView` uses (level tracks the
/// Pomodoro; the fall animates off a `SceneClock`). Reduce Motion feeds rate 0 → the fall stills,
/// and `paused` (occlusion) freezes to one static frame.
struct SandfallMetalView: View {
    var paused: Bool = false
    let pomodoro: PomodoroService
    var reduceMotion: Bool = false

    private static let workSand = SIMD3<Double>(0.82, 0.85, 0.93)  // cool pale
    private static let restSand = SIMD3<Double>(0.55, 0.80, 0.74)  // teal (ease)
    private static let idleSand = SIMD3<Double>(0.66, 0.70, 0.82)

    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Unconditional TimelineView — the `paused:` variant stops driving frames on device
            // (ProMotion); see CurrentMetalView. SceneClock is @State so freeze holds its pose.
            if paused {
                field(size: size, now: nil)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
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
        // eases; idle mid), not a slow hourglass level.
        let energy = running ? (work ? 0.55 + 0.45 * prog : 0.40) : 0.50
        let sand = running ? (work ? Self.workSand : Self.restSand) : Self.idleSand

        if let now { clock.tick(now: now, rate: reduceMotion ? 0 : 1) }
        let phase = Float(clock.phase)
        return Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.sandField(
                    .float(phase),
                    .float2(size),
                    .float(Float(energy)),
                    .float3(Float(sand.x), Float(sand.y), Float(sand.z))
                )
            )
    }
}
