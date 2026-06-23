import SwiftUI

/// "Aurora" (Sleep): flowing curtains of light over a faint star field. Each curtain is built
/// from many soft, overlapping vertical striations whose brightness ripples with layered,
/// incommensurate waves — so it shimmers and folds organically and never visibly repeats. Three
/// curtains sit at different depths (far = higher, dimmer, softer, slower), and the whole sky
/// rises and falls on a slow ~11s breath. Softness comes from overlapping translucent gradients
/// blended additively — no per-frame blur pass (battery). Freezes when occluded.
struct AuroraView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false

    private struct Curtain {
        let yTop, yBottom: Double   // vertical band (0…1)
        let x0, x1: Double          // horizontal extent (can spill past edges)
        let bright: Double
        let soft: Double            // ray width factor — far curtains use wider, softer rays
        let flow: Double            // ripple/flow speed
        let foldFreq: Double        // how many folds across the curtain
        let phase: Double
        let drift: Double           // slow horizontal sway (fraction of width)
        let top, mid, bot: Color    // vertical color gradient (violet tips → green base)
    }

    private static let violet = Color(red: 0.55, green: 0.40, blue: 0.95)
    private static let teal   = Color(red: 0.25, green: 0.78, blue: 0.78)
    private static let green  = Color(red: 0.30, green: 0.90, blue: 0.55)
    private static let cyan   = Color(red: 0.30, green: 0.70, blue: 0.95)

    private static let curtains: [Curtain] = [
        // far — high, dim, soft, slow
        Curtain(yTop: 0.08, yBottom: 0.52, x0: -0.05, x1: 1.05, bright: 0.45, soft: 2.0,
                flow: 0.05, foldFreq: 2.2, phase: 0.0, drift: 0.05,
                top: violet, mid: cyan, bot: teal),
        // mid
        Curtain(yTop: 0.12, yBottom: 0.60, x0: 0.0, x1: 1.0, bright: 0.75, soft: 1.3,
                flow: 0.078, foldFreq: 3.1, phase: 2.1, drift: 0.06,
                top: violet, mid: teal, bot: green),
        // near — lower, brighter, crisper, faster
        Curtain(yTop: 0.18, yBottom: 0.70, x0: -0.05, x1: 0.98, bright: 1.0, soft: 0.95,
                flow: 0.10, foldFreq: 4.3, phase: 4.0, drift: 0.08,
                top: cyan, mid: teal, bot: green)
    ]

    // A faint static star field behind the curtains, for depth.
    private struct Star { let x, y, r, op: Double }
    private static let stars: [Star] = {
        var s: UInt64 = 0xA12055_5160DECA
        func n() -> Double { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return Double(s % 1_000_000) / 1_000_000 }
        return (0..<70).map { _ in Star(x: n(), y: n() * 0.85, r: 0.4 + pow(n(), 2) * 1.3, op: 0.08 + pow(n(), 2) * 0.4) }
    }()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.02, green: 0.025, blue: 0.06),
                                    Color(red: 0.01, green: 0.012, blue: 0.025)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            Canvas { ctx, size in Self.drawStars(ctx, size) }      // static depth layer
            if paused {
                Canvas { ctx, size in Self.drawAurora(ctx, size, t: 0) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    Canvas { ctx, size in Self.drawAurora(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
                }
            }
            // Faint ground haze the curtains seem to rise from.
            LinearGradient(colors: [.clear, Self.green.opacity(0.05)],
                           startPoint: .center, endPoint: .bottom)
                .blendMode(.plusLighter)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func drawStars(_ ctx: GraphicsContext, _ size: CGSize) {
        for s in stars {
            let r = s.r
            ctx.fill(Path(ellipseIn: CGRect(x: s.x * size.width - r, y: s.y * size.height - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(.white.opacity(s.op)))
        }
    }

    private static func drawAurora(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        var ctx = ctx
        ctx.blendMode = .plusLighter
        // Slow collective breath (~11s) so the whole sky gently swells and settles.
        let breath = 0.82 + 0.18 * (0.5 - 0.5 * cos(t * 2 * .pi / 11.0))

        for c in curtains {
            let sway = sin(t * c.flow * 0.7 + c.phase) * c.drift * size.width
            let bandX0 = c.x0 * size.width + sway
            let bandW = (c.x1 - c.x0) * size.width
            let spacing = max(4.0, 8.0 * c.soft)
            let rayW = spacing * 2.6                      // overlap → continuous soft curtain
            let count = max(2, Int(bandW / spacing))

            for i in 0...count {
                let fx = Double(i) / Double(count)
                let x = bandX0 + fx * bandW
                // Two incommensurate folds → an organic, non-repeating ripple of brightness.
                let f1 = 0.5 + 0.5 * sin(fx * c.foldFreq * 2 * .pi + t * c.flow * 6.0 + c.phase)
                let f2 = 0.5 + 0.5 * sin(fx * c.foldFreq * 1.73 * 2 * .pi - t * c.flow * 3.3 + c.phase * 1.4)
                let intensity = pow(f1 * 0.6 + f2 * 0.4, 2.2) * c.bright * breath
                if intensity < 0.015 { continue }

                // The curtain's top edge wavers, so the lower rim folds like cloth.
                let topY = (c.yTop + 0.04 * sin(fx * 9 + t * c.flow * 4 + c.phase)) * size.height
                let botY = c.yBottom * size.height
                let rect = CGRect(x: x - rayW / 2, y: topY, width: rayW, height: botY - topY)

                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: c.top.opacity(0.0), location: 0.0),
                        .init(color: c.top.opacity(0.45 * intensity), location: 0.18),
                        .init(color: c.mid.opacity(0.55 * intensity), location: 0.55),
                        .init(color: c.bot.opacity(0.65 * intensity), location: 0.86),
                        .init(color: c.bot.opacity(0.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: x, y: topY),
                    endPoint: CGPoint(x: x, y: botY)))
            }
        }
    }
}
