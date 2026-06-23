import SwiftUI

/// "Current" (Focus): slow cool streams drift across a deep field — momentum without flicker.
/// Pomodoro-reactive: during a work interval the current quickens and brightens as you progress;
/// during a break it eases and cools toward teal. Calm, never attention-grabbing (peripheral
/// motion that demands attention would defeat the point of Focus). Freezes when occluded.
struct CurrentView: View {
    var paused: Bool = false
    /// Read live (not observed) inside the TimelineView so phase/progress drive the look.
    let pomodoro: PomodoroService

    private struct Stream {
        let baseY: Double      // 0…1
        let freq: Double       // spatial frequency across the width
        let speed: Double      // horizontal flow speed
        let phase: Double
        let amp: Double        // 0…1 vertical amplitude (fraction of height)
        let op: Double         // base opacity
    }

    private static let workTint = Color(red: 0.36, green: 0.62, blue: 0.96)  // cool blue
    private static let restTint = Color(red: 0.30, green: 0.72, blue: 0.66)  // teal (ease)
    private static let idleTint = Color(red: 0.40, green: 0.56, blue: 0.84)

    private static let streams: [Stream] = build()

    private static func build() -> [Stream] {
        var rng: UInt64 = 0x57EADFA5_7C0DE01
        func n() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        var out: [Stream] = []
        for i in 0..<7 {
            out.append(Stream(
                baseY: 0.16 + Double(i) / 7.0 * 0.68 + (n() - 0.5) * 0.05,
                freq: 1.4 + n() * 1.6,
                speed: 0.05 + n() * 0.07,
                phase: n() * 6.283,
                amp: 0.03 + n() * 0.05,
                op: 0.18 + n() * 0.22))
        }
        return out
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.06, blue: 0.12),
                                    Color(red: 0.02, green: 0.03, blue: 0.06)],
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

        // Drive the look from the session: work builds momentum with progress; rest eases.
        let driveOp:    Double = running ? (work ? 0.55 + 0.45 * prog : 0.34) : 0.45
        let driveAmp:   Double = running ? (work ? 0.70 + 0.50 * prog : 0.55) : 0.65
        let driveSpeed: Double = running ? (work ? 0.85 + 0.55 * prog : 0.55) : 0.65
        let tint = running ? (work ? Self.workTint : Self.restTint) : Self.idleTint

        let steps = 36
        for s in Self.streams {
            var path = Path()
            for k in 0...steps {
                let fx = Double(k) / Double(steps)
                let x = fx * size.width
                let y = (s.baseY + s.amp * driveAmp * sin(fx * s.freq * 2 * .pi + t * s.speed * driveSpeed * 6 + s.phase)) * size.height
                if k == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(tint.opacity(s.op * driveOp)), lineWidth: 1.4)
        }
    }
}
