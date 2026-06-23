import SwiftUI

/// "Tide" (Focus): a calm cool level whose surface gently undulates and whose height tracks the
/// Pomodoro — it rises across a work interval (a quiet, ambient progress cue) and recedes during
/// a break. A glanceable sense of "how far in am I" without a number demanding attention.
/// Freezes when occluded.
struct TideView: View {
    var paused: Bool = false
    let pomodoro: PomodoroService

    private static let workTint = Color(red: 0.34, green: 0.60, blue: 0.95)  // cool blue
    private static let restTint = Color(red: 0.30, green: 0.72, blue: 0.66)  // teal (ease)
    private static let idleTint = Color(red: 0.38, green: 0.54, blue: 0.82)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.03, green: 0.05, blue: 0.10),
                                    Color(red: 0.015, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if paused {
                Canvas { ctx, size in draw(ctx, size, t: 0) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    Canvas { ctx, size in draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let running = pomodoro.isRunning
        let work = pomodoro.phase == .work
        let prog = pomodoro.progress

        // Fill height: rises through a work interval, recedes through a break, low calm pool idle.
        let level: Double = running ? (work ? 0.08 + 0.84 * prog : max(0.08, 0.92 - 0.6 * prog)) : 0.08
        let tint = running ? (work ? Self.workTint : Self.restTint) : Self.idleTint

        let surfaceY = (1.0 - level) * size.height
        let waveAmp = size.height * 0.012
        let steps = 48

        // Two gently offset waves so the surface breathes instead of marching uniformly.
        func surface(_ fx: Double) -> Double {
            surfaceY
                + waveAmp * sin(fx * 2.2 * 2 * .pi + t * 0.5)
                + waveAmp * 0.5 * sin(fx * 1.3 * 2 * .pi - t * 0.32)
        }

        var fill = Path()
        fill.move(to: CGPoint(x: 0, y: size.height))
        fill.addLine(to: CGPoint(x: 0, y: surface(0)))
        for k in 0...steps {
            let fx = Double(k) / Double(steps)
            fill.addLine(to: CGPoint(x: fx * size.width, y: surface(fx)))
        }
        fill.addLine(to: CGPoint(x: size.width, y: size.height))
        fill.closeSubpath()

        ctx.fill(fill, with: .linearGradient(
            Gradient(colors: [tint.opacity(0.30), tint.opacity(0.05)]),
            startPoint: CGPoint(x: 0, y: surfaceY),
            endPoint: CGPoint(x: 0, y: size.height)))

        // A brighter surface line so the level reads crisply.
        var line = Path()
        for k in 0...steps {
            let fx = Double(k) / Double(steps)
            let p = CGPoint(x: fx * size.width, y: surface(fx))
            if k == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.stroke(line, with: .color(tint.opacity(0.5)), lineWidth: 1.4)
    }
}
