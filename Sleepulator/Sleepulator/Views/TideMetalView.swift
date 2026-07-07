import SwiftUI

/// "Tide" (Focus) — the Metal edition. A GPU fragment shader (`TideShader.metal`, `tideField`)
/// renders a cool water level whose height tracks the Pomodoro, with an FBM-warped waterline,
/// depth shading, a crisp surface line and specular shimmer — instead of the flat Canvas fill.
/// A/B sibling of the CPU `TideView`.
///
/// The level + tint come from the SAME mapping the Canvas `TideView` uses, so the two differ only
/// in rendering. Values are read live each tick (never observed). Ambient surface motion runs off
/// its own `SceneClock` at a constant rate (the tide's motion isn't Pomodoro-paced); Reduce Motion
/// feeds rate 0 → a still surface, and `paused` (occlusion) freezes to one static frame.
struct TideMetalView: View {
    var paused: Bool = false
    let pomodoro: PomodoroService
    var reduceMotion: Bool = false

    private static let workTint = SIMD3<Double>(0.34, 0.60, 0.95)  // cool blue
    private static let restTint = SIMD3<Double>(0.30, 0.72, 0.66)  // teal (ease)
    private static let idleTint = SIMD3<Double>(0.38, 0.54, 0.82)

    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
                field(size: size, now: paused ? nil : tl.date.timeIntervalSinceReferenceDate)
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
        // Energy-first: the Pomodoro drives INTENSITY (a work sprint builds + brightens the surge;
        // a break eases; idle sits mid), not a slow rising level.
        let energy = running ? (work ? 0.55 + 0.45 * prog : 0.40) : 0.50
        let tint = running ? (work ? Self.workTint : Self.restTint) : Self.idleTint

        if let now { clock.tick(now: now, rate: reduceMotion ? 0 : 1) }
        let phase = Float(clock.phase)
        return Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.tideField(
                    .float(phase),
                    .float2(size),
                    .float(Float(energy)),
                    .float3(Float(tint.x), Float(tint.y), Float(tint.z))
                )
            )
    }
}
