import SwiftUI

/// "Still water" (Sleep): a low moon hangs over a dark pond, its light a wavering reflected
/// column on the surface, while faint concentric ripples spread and fade from a few points. Depth
/// comes from atmospheric layering — a graded sky, a brighter near foreground, ring sources at
/// different "distances," and a vignette — and the reflection shimmer gives a calm focal point.
/// A slow ~12s breath rises and falls the ripple brightness. Canvas + one TimelineView loop;
/// a single static frame when occluded.
struct StillWaterView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false

    private struct Source {
        let cx: Double
        let cy: Double
        let period: Double
        let phase: Double
        let maxR: Double
        let depth: Double   // 0 = far (dim, small), 1 = near (brighter, wider)
    }

    private static let ringsPerSource = 4
    private static let tint = Color(red: 0.66, green: 0.78, blue: 0.98)   // cool moonlit blue-white
    private static let moonY = 0.16                                       // moon height (0…1)
    private static let moonX = 0.5

    private static let sources: [Source] = [
        Source(cx: 0.30, cy: 0.46, period: 12.0, phase: 0.0,  maxR: 0.55, depth: 0.9),
        Source(cx: 0.70, cy: 0.62, period: 15.0, phase: 0.45, maxR: 0.48, depth: 0.6),
        Source(cx: 0.52, cy: 0.78, period: 18.0, phase: 0.20, maxR: 0.62, depth: 1.0),
        Source(cx: 0.42, cy: 0.34, period: 21.0, phase: 0.70, maxR: 0.34, depth: 0.3)   // far/high
    ]

    var body: some View {
        ZStack {
            // Graded night sky → darker water, with a faint band where they meet.
            LinearGradient(stops: [
                .init(color: Color(red: 0.05, green: 0.08, blue: 0.15), location: 0.0),
                .init(color: Color(red: 0.03, green: 0.05, blue: 0.10), location: 0.4),
                .init(color: Color(red: 0.015, green: 0.02, blue: 0.045), location: 0.6),
                .init(color: Color(red: 0.01, green: 0.012, blue: 0.03), location: 1.0)
            ], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            moon
            if paused {
                Canvas { ctx, size in Self.draw(ctx, size, t: 0) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    Canvas { ctx, size in Self.draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
                }
            }
            vignette
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var moon: some View {
        GeometryReader { geo in
            let d = geo.size.width * 0.16
            ZStack {
                Circle()   // halo
                    .fill(RadialGradient(colors: [Self.tint.opacity(0.18), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 1.8))
                    .frame(width: d * 4, height: d * 4)
                Circle()   // disc
                    .fill(Self.tint.opacity(0.5))
                    .frame(width: d, height: d)
                    .blur(radius: 3)
            }
            .position(x: geo.size.width * Self.moonX, y: geo.size.height * Self.moonY)
        }
    }

    private var vignette: some View {
        GeometryReader { geo in
            RadialGradient(colors: [.clear, .black.opacity(0.5)],
                           center: .center, startRadius: geo.size.height * 0.3,
                           endRadius: geo.size.height * 0.9)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        let minDim = min(size.width, size.height)
        // Slow ~12s breath on the ripple brightness.
        let breath = 0.8 + 0.2 * (0.5 - 0.5 * cos(t * 2 * .pi / 12.0))

        // Moon's reflected column: a soft vertical smear under the moon that wavers with the water.
        var rctx = ctx
        rctx.blendMode = .plusLighter
        let mx = moonX * size.width
        let reflTop = moonY * size.height + size.height * 0.06
        let band = 18
        for k in 0..<band {
            let fy = Double(k) / Double(band)
            let y = reflTop + fy * (size.height - reflTop)
            // The column widens and wavers toward the foreground; brightness falls off downward.
            let wob = sin(y * 0.05 + t * 0.9) + 0.5 * sin(y * 0.11 - t * 0.6)
            let halfW = (4.0 + fy * 26.0) + wob * 4.0
            let op = (1.0 - fy) * 0.10 * breath
            if op <= 0.002 { continue }
            let rect = CGRect(x: mx - halfW, y: y, width: halfW * 2, height: (size.height - reflTop) / Double(band) + 2)
            rctx.fill(Path(ellipseIn: rect),
                      with: .color(tint.opacity(op)))
        }

        // Concentric ripples — flatter (elliptical) so they read as lying on a receding surface.
        for s in sources {
            let center = CGPoint(x: s.cx * size.width, y: s.cy * size.height)
            let maxR = s.maxR * minDim
            for k in 0..<ringsPerSource {
                var prog = (t / s.period + s.phase + Double(k) / Double(ringsPerSource))
                    .truncatingRemainder(dividingBy: 1.0)
                if prog < 0 { prog += 1 }
                let radius = prog * maxR
                if radius < 1 { continue }
                let fadeIn = min(1.0, prog / 0.12)
                let op = (1.0 - prog) * fadeIn * (0.12 + s.depth * 0.26) * breath
                if op <= 0.002 { continue }
                let ry = radius * 0.5   // perspective squash → ellipse on the water plane
                let rect = CGRect(x: center.x - radius, y: center.y - ry,
                                  width: radius * 2, height: ry * 2)
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(tint.opacity(op)),
                           lineWidth: 0.8 + s.depth * 0.8)
            }
        }
    }
}
