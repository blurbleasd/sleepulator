import SwiftUI

/// A calm night sky for Sleep mode, built to lull rather than impress: faint stars in varied
/// colour temperature over a soft Milky Way haze, the whole field drifting down very slowly
/// while a gentle collective "breath" rises and falls the brightness on a slow sleep cadence.
/// One TimelineView/Canvas loop (~30fps); freezes only when the deep night-dim veil has
/// occluded the screen. Runs regardless of system Reduce Motion. No bright focal point.
struct StarfieldView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false

    private struct Star {
        let x, y, r, baseOpacity: Double
        let tint: Color
        let bright: Bool
        let twAmp, twSpeed, twPhase: Double
    }

    private static let coolWhite = Color(red: 0.93, green: 0.95, blue: 1.0)
    private static let warmStar  = Color(red: 1.0,  green: 0.86, blue: 0.66)
    private static let blueStar  = Color(red: 0.74, green: 0.84, blue: 1.0)

    // Tuning knobs — all slow on purpose (a sleep aid, not a screensaver demo).
    private static let driftPeriod: Double = 300    // seconds to drift one screen-height down
    private static let breathPeriod: Double = 9     // seconds per breath (brightness rise + fall)
    private static let breathDepth: Double = 0.22   // how much the breath dims the field at the trough

    private static let stars: [Star] = build()

    private static func build() -> [Star] {
        var rng: UInt64 = 0x5EED5160_0DECAF01
        func n() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        func tint() -> Color { let t = n(); return t < 0.66 ? coolWhite : (t < 0.88 ? warmStar : blueStar) }
        var out: [Star] = []
        // Scattered field — cube the brightness so most stars are dim and only a few brighter.
        for _ in 0..<90 {
            let mag = pow(n(), 3.0)
            out.append(Star(x: n(), y: n(),
                            r: 0.5 + mag * 2.2,
                            baseOpacity: 0.22 + mag * 0.6,
                            tint: tint(),
                            bright: mag > 0.88,
                            twAmp: 0.25 + n() * 0.45, twSpeed: 0.5 + n() * 1.2, twPhase: n() * 6.283))
        }
        // A denser diagonal Milky Way swath of faint stars.
        for _ in 0..<40 {
            let u = n()
            let mag = pow(n(), 4.0)
            out.append(Star(x: 0.08 + u * 0.86,
                            y: 0.06 + u * 0.5 + (n() - 0.5) * 0.16,
                            r: 0.4 + mag * 0.9,
                            baseOpacity: 0.12 + mag * 0.34,
                            tint: coolWhite,
                            bright: false,
                            twAmp: 0.2 + n() * 0.3, twSpeed: 0.4 + n() * 0.8, twPhase: n() * 6.283))
        }
        return out
    }

    var body: some View {
        ZStack {
            hazeBand
            if paused {
                Canvas { ctx, size in Self.draw(ctx, size, t: 0) }      // occluded: one static frame
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    Canvas { ctx, size in Self.draw(ctx, size, t: tl.date.timeIntervalSinceReferenceDate) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    // Soft luminous band behind the Milky Way (static — drawn once, not per frame).
    private var hazeBand: some View {
        GeometryReader { geo in
            Ellipse()
                .fill(Color.white.opacity(0.03))
                .frame(width: geo.size.width * 1.5, height: geo.size.height * 0.26)
                .rotationEffect(.degrees(-22))
                .position(x: geo.size.width * 0.5, y: geo.size.height * 0.28)
                .blur(radius: 40)
        }
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, t: Double) {
        // Collective breath: a slow brightness envelope (1.0 at the top of the breath).
        let breath = 1.0 - breathDepth * (0.5 - 0.5 * cos(t * 2 * .pi / breathPeriod))
        // Field drift: everything sinks slowly, wrapping top <-> bottom.
        let drift = (t / driftPeriod).truncatingRemainder(dividingBy: 1.0)

        for s in stars {
            var yy = (s.y + drift).truncatingRemainder(dividingBy: 1.0)
            if yy < 0 { yy += 1 }
            let edge = min(1.0, min(yy, 1 - yy) / 0.06)               // fade the wrap seam
            let twinkle = 1.0 - s.twAmp * (0.5 - 0.5 * cos(t * s.twSpeed + s.twPhase))
            let op = s.baseOpacity * breath * edge * twinkle
            let x = s.x * size.width
            let y = yy * size.height
            if s.bright {
                let g = s.r * 2.4
                ctx.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2)),
                         with: .radialGradient(Gradient(colors: [s.tint.opacity(op * 0.5), .clear]),
                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: g))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: x - s.r, y: y - s.r, width: s.r * 2, height: s.r * 2)),
                     with: .color(s.tint.opacity(op)))
        }
    }
}

// A rare delight: every few minutes a meteor streaks across the sky and fades. Schedules
// itself with random gaps, and runs regardless of Reduce Motion (a deliberate dog-food
// choice). The self-rescheduling loop is cancelled on disappear so it can't outlive the view.
struct ShootingStarView: View {
    @State private var progress: CGFloat = 0
    @State private var active = false
    @State private var seed = 0
    @State private var pending: DispatchWorkItem?

    var body: some View {
        GeometryReader { geo in
            streak(in: geo.size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { schedule(first: true) }
        .onDisappear { pending?.cancel(); pending = nil }
    }

    private func streak(in size: CGSize) -> some View {
        let startX = size.width * (0.12 + 0.6 * frac(seed))
        let startY = size.height * (0.06 + 0.16 * frac(seed &* 7 &+ 3))
        let len = size.width * 0.55
        let x = startX + progress * len
        let y = startY + progress * len * 0.42
        return Capsule()
            .fill(LinearGradient(
                gradient: Gradient(colors: [Color.white.opacity(0), Color.white.opacity(0.9)]),
                startPoint: .leading, endPoint: .trailing))
            .frame(width: 66, height: 2)
            .rotationEffect(.degrees(22.8))
            .position(x: x, y: y)
            .opacity(active ? 1 : 0)
    }

    private func schedule(first: Bool) {
        let delay = first ? Double.random(in: 10...22) : Double.random(in: 90...210)
        let appear = DispatchWorkItem {
            seed &+= 1
            progress = 0
            active = true
            withAnimation(.easeIn(duration: 0.9)) { progress = 1 }
            let hide = DispatchWorkItem {
                active = false
                progress = 0
                schedule(first: false)
            }
            pending = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: hide)
        }
        pending = appear
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: appear)
    }

    // Cheap deterministic 0…1 hash so each meteor starts somewhere different.
    private func frac(_ n: Int) -> CGFloat {
        let v = sin(Double(n) * 12.9898) * 43758.5453
        return CGFloat(v - v.rounded(.down))
    }
}

// Focus backdrop — a slow-rotating cool "energy" sweep over the deep-indigo gradient.
// Energizing without being distracting; static under Reduce Motion.
struct FocusBackdrop: View {
    let accent: Color
    let reduceMotion: Bool
    @State private var rotate = false

    var body: some View {
        // GeometryReader's footprint is always the proposed (screen) size — it never grows
        // to fit the oversized/blurred glow, so the ZStack can't be widened (which was
        // shoving the centered content off both edges). The glow is positioned at center.
        GeometryReader { geo in
            AngularGradient(
                gradient: Gradient(colors: [
                    accent.opacity(0.0), accent.opacity(0.30), accent.opacity(0.05),
                    accent.opacity(0.22), accent.opacity(0.0)
                ]),
                center: .center
            )
            .frame(width: 640, height: 640)
            .blur(radius: 90)
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .opacity(0.75)
            .position(x: geo.size.width / 2, y: geo.size.height / 2 - 30)
        }
        .ignoresSafeArea()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            // Runs regardless of Reduce Motion — a slow blurred glow drift is ambient, not the
            // vestibular kind of motion, and Focus should feel alive even with Reduce Motion on.
            withAnimation(.linear(duration: 36).repeatForever(autoreverses: false)) {
                rotate = true
            }
        }
    }
}

