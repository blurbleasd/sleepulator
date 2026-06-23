import SwiftUI

/// "Sandfall" (Focus): a minimal hourglass. The sand level maps directly to the Pomodoro —
/// the top bulb drains and the bottom mound grows as `progress` runs 0→1 through the current
/// phase, with a fine stream falling through the neck while the timer runs. A tactile, numberless
/// sense of "how far into this interval am I." Cool sand for work, teal for a break. Canvas + one
/// TimelineView loop (read live, never observed); a single static frame when occluded.
struct SandfallView: View {
    var paused: Bool = false
    let pomodoro: PomodoroService

    private static let workSand = Color(red: 0.82, green: 0.85, blue: 0.93)  // cool pale
    private static let restSand = Color(red: 0.55, green: 0.80, blue: 0.74)  // teal (ease)
    private static let idleSand = Color(red: 0.66, green: 0.70, blue: 0.82)
    private static let frame    = Color(red: 0.55, green: 0.62, blue: 0.80)

    // Deterministic per-grain phases for the falling stream (stable across launches).
    private static let grains: [Double] = {
        var s: UInt64 = 0x5A4D_1A11_600D_5EED
        func n() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000 }
        return (0..<14).map { _ in n() }
    }()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.05, blue: 0.11),
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
        // Pomodoro state, read live (not observed) — same pattern as the other Focus scenes.
        let running = pomodoro.isRunning
        let prog = pomodoro.progress                         // 0→1 through the current phase
        let sand = running ? (pomodoro.phase == .work ? Self.workSand : Self.restSand) : Self.idleSand

        let W = size.width, H = size.height
        let cx = W * 0.5
        let yTop = H * 0.18, yNeck = H * 0.50, yBot = H * 0.82
        let hw = W * 0.24                                     // half-width at the bulb mouths

        // Bulb edge half-widths: hw at the mouth, ~0 at the neck.
        func topHalfW(_ y: Double) -> Double { hw * (yNeck - y) / (yNeck - yTop) }
        func botHalfW(_ y: Double) -> Double { hw * (y - yNeck) / (yBot - yNeck) }

        // Faint hourglass frame (two apex-to-apex triangles).
        var frame = Path()
        frame.move(to: CGPoint(x: cx - hw, y: yTop))
        frame.addLine(to: CGPoint(x: cx + hw, y: yTop))
        frame.addLine(to: CGPoint(x: cx, y: yNeck))
        frame.closeSubpath()
        frame.move(to: CGPoint(x: cx, y: yNeck))
        frame.addLine(to: CGPoint(x: cx + hw, y: yBot))
        frame.addLine(to: CGPoint(x: cx - hw, y: yBot))
        frame.closeSubpath()
        ctx.stroke(frame, with: .color(Self.frame.opacity(0.30)), lineWidth: 1.2)

        // Top sand: rests on the neck and drains upward as progress rises (surface lowers to neck).
        let surfaceY = yNeck - (1.0 - prog) * (yNeck - yTop)
        if surfaceY < yNeck - 0.5 {
            let hwS = topHalfW(surfaceY)
            var top = Path()
            top.move(to: CGPoint(x: cx - hwS, y: surfaceY))
            top.addLine(to: CGPoint(x: cx + hwS, y: surfaceY))
            top.addLine(to: CGPoint(x: cx, y: yNeck))
            top.closeSubpath()
            ctx.fill(top, with: .linearGradient(
                Gradient(colors: [sand.opacity(0.34), sand.opacity(0.20)]),
                startPoint: CGPoint(x: 0, y: surfaceY), endPoint: CGPoint(x: 0, y: yNeck)))
        }

        // Bottom mound: fills the lower bulb from the base up as progress rises.
        let fillY = yBot - prog * (yBot - yNeck)
        if fillY < yBot - 0.5 {
            let hwF = botHalfW(fillY)
            var bot = Path()
            bot.move(to: CGPoint(x: cx - hwF, y: fillY))
            bot.addLine(to: CGPoint(x: cx + hwF, y: fillY))
            bot.addLine(to: CGPoint(x: cx + hw, y: yBot))
            bot.addLine(to: CGPoint(x: cx - hw, y: yBot))
            bot.closeSubpath()
            ctx.fill(bot, with: .linearGradient(
                Gradient(colors: [sand.opacity(0.38), sand.opacity(0.22)]),
                startPoint: CGPoint(x: 0, y: fillY), endPoint: CGPoint(x: 0, y: yBot)))
        }

        // Falling stream: a fine column of grains through the neck while the interval is running
        // and there's still sand to fall.
        if running && prog > 0.002 && prog < 0.998 {
            let streamTop = yNeck
            let streamBot = max(fillY, yNeck + 2)
            let span = streamBot - streamTop
            for (i, ph) in Self.grains.enumerated() {
                var f = (t * 0.9 + ph).truncatingRemainder(dividingBy: 1.0)
                if f < 0 { f += 1 }
                let y = streamTop + f * span
                let jitter = sin(t * 2.0 + Double(i) * 1.7) * (W * 0.006)
                let r = 0.8 + (ph * 0.9)
                let op = (0.5 + 0.5 * sin(f * .pi)) * 0.5      // fade in/out along the fall
                ctx.fill(Path(ellipseIn: CGRect(x: cx + jitter - r, y: y - r, width: r * 2, height: r * 2)),
                         with: .color(sand.opacity(op)))
            }
        }
    }
}
