import SwiftUI

/// "Embers" (Sleep): warm motes drift up from a faint hearth glow through slow rising smoke,
/// fading in and out over long lifetimes. Depth comes from two parallax tiers — a far haze of
/// tiny, dim, slow motes behind larger, brighter near ones — plus drifting smoke wisps and a
/// vignette. A slow ~10s breath swells the whole field so it reads as actively calming, not just
/// pretty. Canvas + one TimelineView loop; a single static frame when occluded.
struct EmbersView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false
    /// The sleep timer, read *live* (not observed) inside the redraw so the fire dies down as
    /// the night progresses. Plain property on purpose — observing it here would re-render the
    /// whole scene every tick (the `rmsPower`/`@Published` storm CLAUDE.md warns about).
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed audio level (~0…1), sampled live in the redraw so the embers flare gently with
    /// the generative bed (e.g. the Fire noise crackle). Closure, not observed — same discipline.
    var audioLevel: (() -> Double)? = nil

    private struct Ember {
        let x: Double
        let drift: Double
        let driftSpeed: Double
        let driftPhase: Double
        let life: Double
        let offset: Double
        let r: Double
        let baseOpacity: Double
        let depth: Double        // 0 = far (small/dim/slow), 1 = near
        let warm: Color
    }

    private struct Smoke {
        let x: Double
        let life: Double
        let offset: Double
        let r: Double
        let op: Double
        let sway: Double
        let swaySpeed: Double
        let swayPhase: Double
    }

    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.42)
    private static let gold  = Color(red: 1.0, green: 0.84, blue: 0.55)
    private static let rust  = Color(red: 1.0, green: 0.55, blue: 0.32)

    private static let embers: [Ember] = build()
    private static let smoke: [Smoke] = buildSmoke()

    private static func build() -> [Ember] {
        var rng: UInt64 = 0xC0FFEE_15_600D01
        func n() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        func warm() -> Color { let t = n(); return t < 0.5 ? amber : (t < 0.82 ? gold : rust) }
        var out: [Ember] = []
        for _ in 0..<85 {
            let depth = pow(n(), 1.3)              // most motes sit far → layered haze
            let mag = pow(n(), 1.5)
            out.append(Ember(
                x: n(),
                drift: 0.02 + n() * 0.06,
                driftSpeed: 0.08 + n() * 0.22,
                driftPhase: n() * 6.283,
                life: (44 - depth * 18) + n() * 14,   // far rises slower (longer life)
                offset: n(),
                r: (0.5 + mag * 1.2) * (0.5 + depth * 1.4),
                baseOpacity: (0.10 + mag * 0.4) * (0.4 + depth * 0.8),
                depth: depth,
                warm: warm()))
        }
        // Back-to-front so near, brighter embers paint over the far haze.
        return out.sorted { $0.depth < $1.depth }
    }

    private static func buildSmoke() -> [Smoke] {
        var rng: UInt64 = 0x5A0CE_0DDF00D
        func n() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        return (0..<4).map { _ in
            Smoke(x: 0.15 + n() * 0.7, life: 38 + n() * 30, offset: n(),
                  r: 0.30 + n() * 0.22, op: 0.05 + n() * 0.05,
                  sway: 0.04 + n() * 0.05, swaySpeed: 0.05 + n() * 0.08, swayPhase: n() * 6.283)
        }
    }

    var body: some View {
        ZStack {
            Color(red: 0.035, green: 0.025, blue: 0.02).ignoresSafeArea()   // warm near-black
            // The hearth fades to a faint coal as the night settles (isolated 1 Hz leaf).
            if let timer = sleepTimer {
                NightFade(timer: timer, maxDim: 0.8) { hearthGlow }
            } else {
                hearthGlow
            }
            if paused {
                Canvas { ctx, size in Self.draw(ctx, size, t: 0, night: sleepTimer?.nightProgress ?? 0, audio: audioLevel?() ?? 0) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    // Sample nightProgress + audio level fresh each tick — live reads, no observation.
                    let night = sleepTimer?.nightProgress ?? 0
                    let level = audioLevel?() ?? 0
                    Canvas { ctx, size in Self.draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate, night: night, audio: level) }
                }
            }
            vignette
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var hearthGlow: some View {
        GeometryReader { geo in
            Ellipse()
                .fill(RadialGradient(colors: [Self.rust.opacity(0.20), .clear],
                                     center: .center, startRadius: 0, endRadius: geo.size.width * 0.5))
                .frame(width: geo.size.width * 1.6, height: geo.size.height * 0.55)
                .position(x: geo.size.width * 0.5, y: geo.size.height * 1.02)
                .blur(radius: 40)
        }
    }

    // A soft dark vignette frames the scene and adds the sense of depth/enclosure.
    private var vignette: some View {
        GeometryReader { geo in
            RadialGradient(colors: [.clear, .black.opacity(0.55)],
                           center: .center, startRadius: geo.size.height * 0.30,
                           endRadius: geo.size.height * 0.85)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    /// - Parameter night: `nightProgress` (0 at the start of a sleep timer, →1 as it expires;
    ///   0 when idle). As it rises the fire dies down — the field thins (high-offset motes
    ///   retire first), what remains dims, and the breath swell calms.
    /// - Parameter audio: smoothed audio level (~0…1). The embers flare gently brighter as the
    ///   generative bed gets louder — a slow breath, not a meter.
    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double, night: Double = 0, audio: Double = 0) {
        let p = min(1, max(0, night))
        let flare = 1.0 + 0.6 * min(1, max(0, audio))     // brighten with the bed
        // Slow ~10s breath swells the whole field — gentle entrainment; calmer as night settles.
        let breath = 0.85 + 0.15 * (1.0 - 0.4 * p) * (0.5 - 0.5 * cos(t * 2 * .pi / 10.0))
        let smokeDim = 1.0 - 0.6 * p

        // Drifting smoke wisps (soft warm radial gradients; softness from the gradient, no blur).
        var sctx = ctx
        sctx.blendMode = .plusLighter
        for s in smoke {
            var prog = (t / s.life + s.offset).truncatingRemainder(dividingBy: 1.0)
            if prog < 0 { prog += 1 }
            let y = (1.05 - prog * 1.1) * size.height
            let x = (s.x + sin(t * s.swaySpeed + s.swayPhase) * s.sway) * size.width
            let env = sin(prog * .pi)
            let op = s.op * env * breath * smokeDim
            if op <= 0.002 { continue }
            let rad = s.r * size.width
            sctx.fill(Path(ellipseIn: CGRect(x: x - rad, y: y - rad, width: rad * 2, height: rad * 2)),
                      with: .radialGradient(Gradient(colors: [rust.opacity(op), .clear]),
                                            center: CGPoint(x: x, y: y), startRadius: 0, endRadius: rad))
        }

        for e in embers {
            var prog = (t / e.life + e.offset).truncatingRemainder(dividingBy: 1.0)
            if prog < 0 { prog += 1 }
            let y = (1.0 - prog) * size.height
            let x = (e.x + sin(t * e.driftSpeed + e.driftPhase) * e.drift) * size.width
            let envelope = sin(prog * .pi)
            // Thin the field as the night settles: motes with a larger stable `offset` retire
            // first, so the fire fades unevenly to a few faint coals rather than dimming flat.
            let thin = max(0.0, 1.0 - p * (0.45 + 0.55 * e.offset))
            let op = e.baseOpacity * envelope * breath * thin * flare
            if op <= 0.001 { continue }
            let g = e.r * 3.0 * flare                       // glow widens slightly on a flare
            ctx.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2)),
                     with: .radialGradient(Gradient(colors: [e.warm.opacity(op * 0.5), .clear]),
                                           center: CGPoint(x: x, y: y), startRadius: 0, endRadius: g))
            ctx.fill(Path(ellipseIn: CGRect(x: x - e.r, y: y - e.r, width: e.r * 2, height: e.r * 2)),
                     with: .color(e.warm.opacity(op)))
        }
    }
}
