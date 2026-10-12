import SwiftUI

/// Pure rules for the Night sky's meteor (unit-tested): when one may cross, how bright, how soon,
/// and how its light rises and falls along its run. (The sky itself is `NightSkyMetalView`.)
enum NightSkyMotion {
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
