import SwiftUI

/// Pure rules for the Night sky (unit-tested): how it settles under the screensaver and over the
/// night, and when a meteor may cross.
enum NightSkyMotion {
    /// Seconds the sky takes to settle once Home's controls fade: it lands well inside the minute
    /// before the veil drops (60 s after the last touch, so ~57 s after the fade).
    static let settleIn: Double = 40
    /// Seconds it takes to lift again, in step with the controls' own 1 s rise.
    static let settleOut: Double = 1

    /// Drift speed against bedtime's: down to 40% by the night's end (as the Metal scenes'
    /// `nightSlowdown` does), and half that again while the screensaver settles.
    static func driftRate(night: Double, settle: Double) -> Double {
        (1 - 0.6 * clamp(night)) * (1 - 0.5 * clamp(settle))
    }

    /// Twinkle depth against bedtime's: `NightDamping` takes it to 35% by the night's end, and
    /// the screensaver's settle takes 60% off that.
    static func twinkleDepth(night: Double, settle: Double) -> Double {
        let damp = NightDamping.factor(nightProgress: clamp(night), bedtime: false)
        return (0.35 + 0.65 * damp) * (1 - 0.6 * clamp(settle))
    }

    /// Meteors are for someone watching: only while Home's controls show, never under the
    /// screensaver (someone drifting off), and none past 0.4 of the night (about 18 minutes into
    /// an untimed one).
    static func meteorMayFire(night: Double, screensaver: Bool) -> Bool {
        !screensaver && night < 0.4
    }

    /// A meteor's peak opacity: warm, a third of full, and fainter as the night deepens.
    static let meteorPeak: Double = 0.35

    static func meteorBrightness(night: Double) -> Double {
        meteorPeak * max(0, 1 - 1.5 * clamp(night))
    }

    /// Seconds until the next meteor: the first soon after the sky shows, the rest rare.
    static func meteorDelay(first: Bool) -> ClosedRange<Double> {
        first ? 10...22 : 90...210
    }

    /// A meteor's light along its run (0…1): it kindles over the first 15%, burns to 40%, and
    /// burns out over the rest, so it never pops on or off.
    static func meteorEnvelope(_ p: Double) -> Double {
        if p <= 0 || p >= 1 { return 0 }
        if p < 0.15 { return smooth(p / 0.15) }
        if p < 0.4 { return 1 }
        return 1 - smooth((p - 0.4) / 0.6)
    }

    private static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
    private static func smooth(_ x: Double) -> Double { let t = clamp(x); return t * t * (3 - 2 * t) }
}

/// The screensaver's settle, 0 (controls up) → 1 (settled), eased in and out. Retargeting
/// mid-ramp starts from wherever it is, so a wake during the settle never jumps.
struct SettleRamp {
    private(set) var target: Double = 0
    private var from: Double = 0
    private var start: Double = 0
    private var duration: Double = 0

    func value(at t: Double) -> Double {
        guard duration > 0 else { return target }
        let x = max(0, min(1, (t - start) / duration))
        return from + (target - from) * x * x * (3 - 2 * x)
    }

    mutating func retarget(_ newTarget: Double, at t: Double, duration: Double) {
        guard newTarget != target else { return }
        from = value(at: t)
        target = newTarget
        start = t
        self.duration = duration
    }
}

/// A calm night sky for Sleep mode, built to lull rather than impress: faint stars in pale and
/// warm whites along a soft Milky Way, the whole field sinking very slowly, a sparse few
/// twinkling. Once Home's controls fade it settles over 40 s (drift halves, the twinkle all but
/// stops), and across the night it slows further and stills (`NightSkyMotion`). One
/// TimelineView/Canvas loop (~30fps) that freezes when the scene is paused. Runs regardless of
/// system Reduce Motion. No bright focal point.
struct StarfieldView: View {
    /// Hold still: the screen is out of sight, or Moving scenes is off.
    var paused: Bool = false
    /// Home's controls have faded to the screensaver: settle.
    var screensaver: Bool = false
    /// Read live inside the redraw (never observed) for the night's slowing and stilling.
    var sleepTimer: SleepTimerService? = nil

    private struct Star {
        let x, y, r, baseOpacity: Double
        let tint: Color
        let bright: Bool
        let twAmp, twSpeed, twPhase: Double
    }

    // Sleep's palette: pale and warm whites, with a rare faint cool star for realism. Two-thirds
    // of the field used to be a cool blue-white and an eighth plainly blue, the coolest light left
    // in the warm mode.
    private static let paleStar  = Color(red: 0.98, green: 0.95, blue: 0.90)
    private static let warmStar  = Color(red: 1.0,  green: 0.86, blue: 0.66)
    private static let coolStar  = Color(red: 0.86, green: 0.89, blue: 0.97)

    /// Seconds to drift one screen-height down at bedtime.
    private static let driftPeriod: Double = 300

    private static let stars: [Star] = build()

    private static func build() -> [Star] {
        // The field's generator draws in the same order as before, so the constellation is the
        // one people know; which stars twinkle comes from a second generator.
        var rng: UInt64 = 0x5EED5160_0DECAF01
        func n() -> Double { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return Double(rng % 1_000_000) / 1_000_000 }
        var pick: UInt64 = 0x7E1C_5EED_A11E_0003
        func m() -> Double { pick ^= pick << 13; pick ^= pick >> 7; pick ^= pick << 17; return Double(pick % 1_000_000) / 1_000_000 }
        func tint() -> Color { let t = n(); return t < 0.66 ? paleStar : (t < 0.96 ? warmStar : coolStar) }
        // About one star in six twinkles, gently and slowly; the brightest never do, so the eye
        // has nothing to catch on.
        func twinkle(_ amp: Double, bright: Bool) -> Double { !bright && m() < 0.18 ? 0.08 + amp * 0.12 : 0 }
        var out: [Star] = []
        // Scattered field: cube the brightness so most stars are dim and only a few brighter.
        for _ in 0..<90 {
            let mag = pow(n(), 3.0)
            let x = n(), y = n(), t = tint(), amp = n(), speed = n(), phase = n()
            let bright = mag > 0.88
            out.append(Star(x: x, y: y,
                            r: 0.5 + mag * 1.6,
                            baseOpacity: 0.2 + mag * 0.52,
                            tint: t,
                            bright: bright,
                            twAmp: twinkle(amp, bright: bright),
                            twSpeed: 0.3 + speed * 0.6, twPhase: phase * 6.283))
        }
        // A denser diagonal Milky Way swath of faint stars, along the line the haze follows.
        for _ in 0..<40 {
            let u = n()
            let mag = pow(n(), 4.0)
            let scatter = n(), amp = n(), speed = n(), phase = n()
            out.append(Star(x: band.from.x + u * (band.to.x - band.from.x),
                            y: band.from.y + u * (band.to.y - band.from.y) + (scatter - 0.5) * 0.16,
                            r: 0.4 + mag * 0.9,
                            baseOpacity: 0.12 + mag * 0.34,
                            tint: paleStar,
                            bright: false,
                            twAmp: twinkle(amp, bright: false),
                            twSpeed: 0.25 + speed * 0.5, twPhase: phase * 6.283))
        }
        return out
    }

    /// The Milky Way's line across the screen (unit coordinates): the swath's stars scatter about
    /// it and the haze lies along it, so the two sink together.
    private static let band = (from: CGPoint(x: 0.08, y: 0.06), to: CGPoint(x: 0.94, y: 0.56))

    private static let haze = Color(red: 1.0, green: 0.90, blue: 0.78)
    /// A soft falloff, a few levels above the ground at its heart and gone at the edge.
    private static let hazeGradient = Gradient(stops: [
        .init(color: haze.opacity(0.016), location: 0),
        .init(color: haze.opacity(0.011), location: 0.35),
        .init(color: haze.opacity(0.004), location: 0.7),
        .init(color: haze.opacity(0), location: 1),
    ])

    /// Freeze-in-place clock: the paused static frame renders the pose the sky froze at
    /// (not `t: 0`, which snapped the drift to phase zero on every un-occlusion). Plain class,
    /// not observed — mutated inside the timeline closure. Random start so each appearance opens
    /// at a fresh pose (the old launch-anchored date gave that variety by accident).
    @State private var clock = SceneClock(start: .random(in: 0...2048))
    /// The screensaver's settle, advanced on the clock's elapsed time (so it holds while paused).
    @State private var settle = SettleBox()

    /// What one frame draws from: drift on the night-slowed phase, twinkle on elapsed time.
    private struct Pose {
        let phase, elapsed, twinkle: Double
    }

    var body: some View {
        // An if/else swap, not `TimelineView(.animation(paused:))`: the `paused:` schedule
        // stops driving frames on ProMotion devices (device 2026-07-11, see ShaderBackdrop),
        // so the scene moved only on outside re-renders. The clock is @State, so the frozen
        // frame still holds the pose it froze at.
        Group {
            if paused {
                let p = pose(advancing: nil)
                Canvas { ctx, size in Self.draw(ctx, size, p) }
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    let p = pose(advancing: tl.date)
                    Canvas { ctx, size in Self.draw(ctx, size, p) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
    }

    /// The settle first (it sets the drift's rate), then the clock.
    private func pose(advancing now: Date?) -> Pose {
        let night = sleepTimer?.nightProgress ?? 0
        settle.ramp.retarget(screensaver ? 1 : 0, at: clock.elapsed,
                             duration: screensaver ? NightSkyMotion.settleIn : NightSkyMotion.settleOut)
        let s = settle.ramp.value(at: clock.elapsed)
        if let now {
            clock.tick(now: now.timeIntervalSinceReferenceDate,
                       rate: NightSkyMotion.driftRate(night: night, settle: s))
        }
        return Pose(phase: clock.phase, elapsed: clock.elapsed,
                    twinkle: NightSkyMotion.twinkleDepth(night: night, settle: s))
    }

    private static func draw(_ ctx: GraphicsContext, _ size: CGSize, _ pose: Pose) {
        // Field drift: everything sinks slowly, wrapping bottom → top.
        let drift = (pose.phase / driftPeriod).truncatingRemainder(dividingBy: 1.0)
        drawHaze(ctx, size, drift: drift)

        for s in stars {
            var yy = (s.y + drift).truncatingRemainder(dividingBy: 1.0)
            if yy < 0 { yy += 1 }
            let edge = min(1.0, min(yy, 1 - yy) / 0.06)               // fade the wrap seam
            let twinkle = 1.0 - s.twAmp * pose.twinkle * (0.5 - 0.5 * cos(pose.elapsed * s.twSpeed + s.twPhase))
            let op = s.baseOpacity * edge * twinkle
            let x = s.x * size.width
            let y = yy * size.height
            if s.bright {
                let g = s.r * 2.4
                ctx.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: g * 2, height: g * 2)),
                         with: .radialGradient(Gradient(colors: [s.tint.opacity(op * 0.4), .clear]),
                                               center: CGPoint(x: x, y: y), startRadius: 0, endRadius: g))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: x - s.r, y: y - s.r, width: s.r * 2, height: s.r * 2)),
                     with: .color(s.tint.opacity(op)))
        }
    }

    /// The Milky Way's glow: a long soft ellipse laid along the swath, sinking with it. Drawn
    /// twice, a screen apart, so the part leaving the bottom edge is already arriving at the top.
    private static func drawHaze(_ ctx: GraphicsContext, _ size: CGSize, drift: Double) {
        let a = CGPoint(x: band.from.x * size.width, y: band.from.y * size.height)
        let b = CGPoint(x: band.to.x * size.width, y: band.to.y * size.height)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let halfLength = hypot(b.x - a.x, b.y - a.y) * 0.7
        // The swath scatters ±0.08 of the height about its line; the glow reaches a little past.
        let halfWidth = 0.12 * size.height * cos(angle)
        for shift in [drift, drift - 1] {
            var c = ctx
            c.translateBy(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 + shift * size.height)
            c.rotate(by: .radians(angle))
            c.scaleBy(x: halfLength, y: halfWidth)
            c.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                   with: .radialGradient(hazeGradient, center: .zero, startRadius: 0, endRadius: 1))
        }
    }
}

/// Holds the sky's settle across redraws. Plain class, not observed, like `SceneClock`.
final class SettleBox {
    var ramp = SettleRamp()
    // Explicitly nonisolated: the implicit MainActor-isolated deinit aborts on iOS 18.4–26.3
    // runtimes (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}
}

/// The Night sky's own ground: a warm near-black, about (4,3,2), lifting a few levels toward the
/// bottom edge like a horizon. Home's brown is the controls' room; once they fade this takes its
/// place (`NightSkyScene`), so the screensaver is a sky rather than the app's background.
struct NightSkyGround: View {
    private static let horizon = Color(red: 7 / 255, green: 5 / 255, blue: 3.5 / 255)
    private static let zenith = Color(red: 4 / 255, green: 3 / 255, blue: 2 / 255)

    var body: some View {
        GeometryReader { geo in
            RadialGradient(colors: [Self.horizon, Self.zenith],
                           center: UnitPoint(x: 0.5, y: 1.1),
                           startRadius: 0, endRadius: geo.size.height * 0.75)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// A rare delight for someone watching: every few minutes, while Home's controls show, a meteor
// kindles, streaks and burns out. Never under the screensaver, where someone is drifting off and
// a streak at the edge of vision is a wake risk, and none past 0.4 of the night
// (`NightSkyMotion.meteorMayFire`). Schedules itself with random gaps, the first soon after the
// sky first shows, and runs regardless of Reduce Motion (a deliberate dog-food choice). The
// self-rescheduling loop stops on disappear, while paused and under the screensaver, so it never
// wakes the main queue all night.
struct ShootingStarView: View {
    /// Hold still: the screen is out of sight, or Moving scenes is off. Stop scheduling.
    var paused: Bool = false
    /// Home's controls have faded to the screensaver: no new meteors.
    var screensaver: Bool = false
    /// Read live at each meteor's fire time (never observed) for the night dimming/gating.
    var sleepTimer: SleepTimerService? = nil

    private static let meteor = Color(red: 1.0, green: 0.88, blue: 0.72)
    /// Seconds a meteor takes to cross.
    private static let run: Double = 1.1

    @State private var progress: CGFloat = 0
    @State private var active = false
    @State private var seed = 0
    @State private var brightness: Double = 0
    @State private var pending: DispatchWorkItem?
    /// A meteor is crossing: a screensaver arriving now lets it burn out rather than cutting it.
    @State private var inFlight = false
    /// Tracks onAppear/onDisappear: TabView keeps non-selected tabs installed, so without this
    /// an onChange could resurrect the chain for an invisible Home tab.
    @State private var visible = false
    /// The first meteor comes soon after the sky first shows; every later one is rare. Kept
    /// across tab switches (TabView keeps state), so hopping tabs doesn't bring one every 15 s.
    @State private var hasFired = false
    /// `paused || screensaver`, mirrored for the work items: they capture a copy of this view, so
    /// its plain properties would read as they were when the item was made.
    @State private var quiet = false

    var body: some View {
        GeometryReader { geo in
            streak(in: geo.size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            visible = true
            quiet = paused || screensaver
            scheduleIfIdle()
        }
        .onDisappear {
            visible = false
            drop()
        }
        .onChange(of: paused) { _, frozen in
            quiet = frozen || screensaver
            if frozen { drop() } else { scheduleIfIdle() }
        }
        .onChange(of: screensaver) { _, on in
            quiet = paused || on
            if on {
                if !inFlight { pending?.cancel(); pending = nil }
            } else {
                scheduleIfIdle()
            }
        }
    }

    /// Out of sight: cancel what's pending and clear a meteor mid-crossing (TabView keeps state,
    /// so it would otherwise come back frozen mid-sky).
    private func drop() {
        pending?.cancel(); pending = nil
        inFlight = false; active = false; progress = 0
    }

    /// The only entry point for starting the chain. `pending == nil` guards a second orphaned
    /// chain (onAppear can refire without an intervening onDisappear on tab/scene re-mounts);
    /// `quiet` covers mounting while already paused (at a cold launch the app isn't active yet,
    /// so the chain starts on the un-pause, and still with the first meteor's short delay);
    /// `visible` keeps a hidden-but-installed tab from running meteors off-screen.
    private func scheduleIfIdle() {
        guard pending == nil, !quiet, visible else { return }
        schedule(first: !hasFired)
    }

    private func streak(in size: CGSize) -> some View {
        MeteorStreak(progress: progress,
                     start: CGPoint(x: size.width * (0.12 + 0.6 * frac(seed)),
                                    y: size.height * (0.06 + 0.16 * frac(seed &* 7 &+ 3))),
                     travel: CGVector(dx: size.width * 0.55, dy: size.width * 0.55 * 0.42),
                     color: Self.meteor,
                     peak: active ? brightness : 0)
    }

    private func schedule(first: Bool) {
        let appear = DispatchWorkItem {
            pending = nil
            guard !quiet else { return }
            // Sampled at fire time so an hours-old schedule can't fire a bedtime-bright meteor.
            let night = sleepTimer?.nightProgress ?? 0
            guard NightSkyMotion.meteorMayFire(night: night, screensaver: false) else {
                schedule(first: false)   // keep the loop alive; the sky may lighten (timer reset)
                return
            }
            hasFired = true
            brightness = NightSkyMotion.meteorBrightness(night: night)
            seed &+= 1
            progress = 0
            active = true
            inFlight = true
            withAnimation(.easeOut(duration: Self.run)) { progress = 1 }
            let hide = DispatchWorkItem {
                pending = nil
                inFlight = false
                active = false
                progress = 0
                scheduleIfIdle()
            }
            pending = hide
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.run + 0.05, execute: hide)
        }
        pending = appear
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: NightSkyMotion.meteorDelay(first: first)),
                                      execute: appear)
    }

    // Cheap deterministic 0…1 hash so each meteor starts somewhere different.
    private func frac(_ n: Int) -> CGFloat {
        let v = sin(Double(n) * 12.9898) * 43758.5453
        return CGFloat(v - v.rounded(.down))
    }
}

/// One meteor at a point in its run. Animatable, so its light follows the run frame by frame
/// (`NightSkyMotion.meteorEnvelope`) rather than switching with `active`.
private struct MeteorStreak: View, Animatable {
    var progress: CGFloat
    let start: CGPoint
    let travel: CGVector
    let color: Color
    let peak: Double

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        MeteorTrail()
            .fill(LinearGradient(colors: [color.opacity(0), color],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: 66, height: 1.6)
            .rotationEffect(.radians(atan2(travel.dy, travel.dx)))
            .position(x: start.x + progress * travel.dx, y: start.y + progress * travel.dy)
            .opacity(peak * NightSkyMotion.meteorEnvelope(Double(progress)))
    }
}

/// A meteor's trail: a needle from nothing at the tail to a round head the frame's height.
private struct MeteorTrail: Shape {
    func path(in rect: CGRect) -> Path {
        let r = rect.height / 2
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - r, y: rect.midY), radius: r,
                 startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        p.closeSubpath()
        return p
    }
}
