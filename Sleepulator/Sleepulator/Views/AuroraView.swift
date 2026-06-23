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
    /// The sleep timer, read *live* (not observed) inside the redraw so the curtains wind down
    /// as the night progresses. A plain property on purpose: observing it here would re-render
    /// the whole scene every tick (the `rmsPower`/`@Published` storm CLAUDE.md warns about).
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live so the curtains glow a little brighter as the
    /// generative bed swells (e.g. the Ocean swell). Closure, not observed — same discipline.
    var audioLevel: (() -> Double)? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live to parallax the curtains by depth
    /// (near curtains shift more). `.zero` on a nightstand, so this is a watching-window bonus.
    var tilt: (() -> SIMD2<Float>)? = nil

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
                let g = tilt?() ?? .zero
                Canvas { ctx, size in Self.drawAurora(ctx, size, t: 0, night: sleepTimer?.nightProgress ?? 0, audio: audioLevel?() ?? 0, tiltX: Double(g.x), tiltY: Double(g.y)) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    // Sample nightProgress + audio + tilt fresh each tick — live reads, no observation.
                    let night = sleepTimer?.nightProgress ?? 0
                    let level = audioLevel?() ?? 0
                    let g = tilt?() ?? .zero
                    Canvas { ctx, size in Self.drawAurora(ctx, size, t: tl.date.timeIntervalSinceReferenceDate, night: night, audio: level, tiltX: Double(g.x), tiltY: Double(g.y)) }
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

    /// - Parameter night: `nightProgress` (0 at the start of a sleep timer, →1 as it expires;
    ///   0 when no timer runs). As it rises the curtains dim, calm, and read progressively more
    ///   violet — the teal/green base fades faster than the violet tips, and the faster (nearer)
    ///   curtains recede first. Flow *rate* is left untouched on purpose: scaling the absolute
    ///   `t` here would jump the phase; we reduce motion *amplitude* instead, which reads as
    ///   "settling" without artifacts.
    /// - Parameter audio: smoothed audio level (~0…1). The curtains glow a little brighter as the
    ///   generative bed swells — a slow breath, not a meter.
    /// - Parameters tiltX, tiltY: smoothed gyro tilt (~[-1, 1]). Shifts each curtain by its depth
    ///   (near curtains move more) for parallax. Both 0 on a flat nightstand → no shift.
    private static func drawAurora(_ ctx: GraphicsContext, _ size: CGSize, t: Double, night: Double = 0, audio: Double = 0, tiltX: Double = 0, tiltY: Double = 0) {
        var ctx = ctx
        ctx.blendMode = .plusLighter
        let p = min(1, max(0, night))
        let glow = 1.0 + 0.4 * min(1, max(0, audio))      // swell brightens the curtains
        let calm = (1.0 - 0.45 * p) * glow                // overall dim toward night, lifted by audio
        // Slow collective breath (~11s); its swell shrinks as the night settles.
        let breath = 0.82 + 0.18 * (1.0 - 0.4 * p) * (0.5 - 0.5 * cos(t * 2 * .pi / 11.0))

        for c in curtains {
            // Faster (nearer) curtains recede first, so the field winds down to a single slow,
            // far, violet-tipped wash.
            let recede = max(0.0, 1.0 - p * (0.5 + c.flow * 3.0))
            let sway = sin(t * c.flow * 0.7 + c.phase) * c.drift * (1.0 - 0.5 * p) * size.width
            // Depth parallax: nearer (brighter) curtains shift more with tilt.
            let parX = tiltX * c.bright * size.width * 0.05
            let parY = tiltY * c.bright * size.height * 0.02
            let bandX0 = c.x0 * size.width + sway + parX
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
                let intensity = pow(f1 * 0.6 + f2 * 0.4, 2.2) * c.bright * breath * calm * recede
                if intensity < 0.015 { continue }

                // Bias toward violet as the night deepens: fade the warm teal/green base faster
                // than the violet tip so the end state is a dim violet glow.
                let topO = 0.45 * intensity * (1.0 - 0.15 * p)
                let midO = 0.55 * intensity * (1.0 - 0.65 * p)
                let botO = 0.65 * intensity * (1.0 - 0.85 * p)

                // The curtain's top edge wavers, so the lower rim folds like cloth.
                let topY = (c.yTop + 0.04 * sin(fx * 9 + t * c.flow * 4 + c.phase)) * size.height + parY
                let botY = c.yBottom * size.height + parY
                let rect = CGRect(x: x - rayW / 2, y: topY, width: rayW, height: botY - topY)

                ctx.fill(Path(rect), with: .linearGradient(
                    Gradient(stops: [
                        .init(color: c.top.opacity(0.0), location: 0.0),
                        .init(color: c.top.opacity(topO), location: 0.18),
                        .init(color: c.mid.opacity(midO), location: 0.55),
                        .init(color: c.bot.opacity(botO), location: 0.86),
                        .init(color: c.bot.opacity(0.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: x, y: topY),
                    endPoint: CGPoint(x: x, y: botY)))
            }
        }
    }
}
