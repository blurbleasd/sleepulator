import XCTest
import Combine
import SwiftUI
import UIKit
import simd
@testable import Sleepulator

/// Pins the Pomodoro→look mapping the Focus scenes share. The shaders and their thermals are
/// device-verified; `FocusStillFrameTests`, below, cover the still frame's redraw.
final class FocusDriversTests: XCTestCase {

    private let acc = 1e-9

    // MARK: idle (not running) — calm, independent of progress.

    func testIdleUsesIdleTintAndCalmDrivers() {
        for prog in [0.0, 0.5, 1.0] {
            let look = FocusDrivers.look(isRunning: false, isWork: true, progress: prog)
            XCTAssertEqual(look.op, 0.45, accuracy: acc)
            XCTAssertEqual(look.amp, 0.65, accuracy: acc)
            XCTAssertEqual(look.speed, 0.65, accuracy: acc)
            XCTAssertEqual(look.tint, FocusDrivers.idleTint, "idle must use idleTint regardless of phase/progress")
        }
    }

    func testIdleIgnoresPhase() {
        let work = FocusDrivers.look(isRunning: false, isWork: true, progress: 0.3)
        let rest = FocusDrivers.look(isRunning: false, isWork: false, progress: 0.3)
        XCTAssertEqual(work, rest)
    }

    // MARK: work — op/amp/speed all ramp with progress.

    func testWorkAtProgressZero() {
        let look = FocusDrivers.look(isRunning: true, isWork: true, progress: 0.0)
        XCTAssertEqual(look.op, 0.55, accuracy: acc)
        XCTAssertEqual(look.amp, 0.70, accuracy: acc)
        XCTAssertEqual(look.speed, 0.85, accuracy: acc)
        XCTAssertEqual(look.tint, FocusDrivers.workTint)
    }

    func testWorkAtProgressHalf() {
        let look = FocusDrivers.look(isRunning: true, isWork: true, progress: 0.5)
        XCTAssertEqual(look.op, 0.55 + 0.45 * 0.5, accuracy: acc)
        XCTAssertEqual(look.amp, 0.70 + 0.50 * 0.5, accuracy: acc)
        XCTAssertEqual(look.speed, 0.85 + 0.55 * 0.5, accuracy: acc)
    }

    func testWorkAtProgressFull() {
        let look = FocusDrivers.look(isRunning: true, isWork: true, progress: 1.0)
        XCTAssertEqual(look.op, 1.00, accuracy: acc)
        XCTAssertEqual(look.amp, 1.20, accuracy: acc)
        XCTAssertEqual(look.speed, 1.40, accuracy: acc)
    }

    func testWorkRampIsMonotonic() {
        let a = FocusDrivers.look(isRunning: true, isWork: true, progress: 0.1)
        let b = FocusDrivers.look(isRunning: true, isWork: true, progress: 0.9)
        XCTAssertGreaterThan(b.op, a.op)
        XCTAssertGreaterThan(b.amp, a.amp)
        XCTAssertGreaterThan(b.speed, a.speed)
    }

    // MARK: rest — eased, cooler, flat across progress.

    func testRestUsesRestTintAndEasedDrivers() {
        let look = FocusDrivers.look(isRunning: true, isWork: false, progress: 0.7)
        XCTAssertEqual(look.op, 0.34, accuracy: acc)
        XCTAssertEqual(look.amp, 0.55, accuracy: acc)
        XCTAssertEqual(look.speed, 0.55, accuracy: acc)
        XCTAssertEqual(look.tint, FocusDrivers.restTint)
    }

    func testRestIsFlatAcrossProgress() {
        let a = FocusDrivers.look(isRunning: true, isWork: false, progress: 0.0)
        let b = FocusDrivers.look(isRunning: true, isWork: false, progress: 1.0)
        XCTAssertEqual(a, b, "rest look must not depend on progress")
    }

    // MARK: progress clamped defensively.

    func testProgressClampedAboveOne() {
        XCTAssertEqual(FocusDrivers.look(isRunning: true, isWork: true, progress: 5.0),
                       FocusDrivers.look(isRunning: true, isWork: true, progress: 1.0))
    }

    func testProgressClampedBelowZero() {
        XCTAssertEqual(FocusDrivers.look(isRunning: true, isWork: true, progress: -3.0),
                       FocusDrivers.look(isRunning: true, isWork: true, progress: 0.0))
    }

    // MARK: the three states are visually distinct.

    func testWorkRestIdleTintsAreDistinct() {
        XCTAssertNotEqual(FocusDrivers.workTint, FocusDrivers.restTint)
        XCTAssertNotEqual(FocusDrivers.workTint, FocusDrivers.idleTint)
        XCTAssertNotEqual(FocusDrivers.restTint, FocusDrivers.idleTint)
    }

    // MARK: fill — the POSITIONAL progress cue the Focus scenes read.
    // These matter because the whole point of `fill` is that it is the one channel the eye can
    // read absolutely. If it ever stops spanning its full 0…1 range, the scenes silently go back
    // to being decoration (the "they don't speak to focus" failure).

    func testFillIsNilWhenIdleSoNoSessionIsImplied() {
        XCTAssertNil(FocusDrivers.fill(isRunning: false, isWork: true, progress: 0.5))
        XCTAssertNil(FocusDrivers.fill(isRunning: false, isWork: false, progress: 0.0))
    }

    func testWorkFillsAcrossTheWholeRange() {
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: true, progress: 0.0)!, 0.0, accuracy: acc)
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: true, progress: 0.5)!, 0.5, accuracy: acc)
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: true, progress: 1.0)!, 1.0, accuracy: acc)
    }

    func testBreakDrainsBackSoTheDirectionReadsTheIntervalKind() {
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: false, progress: 0.0)!, 1.0, accuracy: acc)
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: false, progress: 0.25)!, 0.75, accuracy: acc)
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: false, progress: 1.0)!, 0.0, accuracy: acc)
    }

    func testFillClampsOutOfRangeProgress() {
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: true, progress: -3)!, 0.0, accuracy: acc)
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: true, progress: 9)!, 1.0, accuracy: acc)
        XCTAssertEqual(FocusDrivers.fill(isRunning: true, isWork: false, progress: 9)!, 0.0, accuracy: acc)
    }

    func testFillIsMonotonicAcrossAWorkInterval() {
        var last = -1.0
        for step in 0...20 {
            let v = FocusDrivers.fill(isRunning: true, isWork: true, progress: Double(step) / 20)!
            XCTAssertGreaterThan(v, last, "fill must rise monotonically through a work interval")
            last = v
        }
    }

}

/// Contour's reading: the light covers the interval's share of the SCREEN. The shader lights the
/// ground above the cone's height at `ContourLight.radius`, so the radius has to cover exactly
/// that share of a phone-shaped screen, edges and all.
final class ContourLightTests: XCTestCase {

    /// iPhone 17 Pro in points (402 × 874).
    private let aspect = 402.0 / 874.0

    // Value: protects=radius(share:) inverts share(radius:) across the interval; fails_when=the bisection stops converging (too few halvings, or the wrong half kept); why_new=cheap at five targets, where the pixel-count test below checks three; seam=none; no_claim=share itself (a round trip passes for any share; the pixel count checks it)
    func testTheRadiusCoversThatShareOfTheScreen() {
        for target in [0.05, 0.25, 0.5, 0.75, 0.95] {
            let r = ContourLight.radius(share: target, aspect: aspect)
            XCTAssertEqual(ContourLight.share(radius: r, aspect: aspect), target, accuracy: 0.002, "share \(target)")
        }
    }

    // Value: protects=no light before an interval starts and the whole map lit at its end; fails_when=the ends clamp to a radius short of the corners, or a share past 1 overflows; why_new=the scene is new; seam=none
    func testTheEndsAreNoneAndAll() {
        let reach = ContourLight.reach(aspect: aspect)
        XCTAssertEqual(ContourLight.radius(share: 0, aspect: aspect), 0)
        XCTAssertEqual(ContourLight.radius(share: -1, aspect: aspect), 0)
        XCTAssertEqual(ContourLight.radius(share: 1, aspect: aspect), reach)
        XCTAssertEqual(ContourLight.radius(share: 2, aspect: aspect), reach)
        XCTAssertEqual(ContourLight.share(radius: reach, aspect: aspect), 1, accuracy: 0.001)
        // The farthest corner from a summit at (0.5, 0.4) is a bottom one.
        XCTAssertEqual(reach, ((0.5 * aspect) * (0.5 * aspect) + 0.6 * 0.6).squareRoot(), accuracy: 1e-12)
    }

    // Value: protects=the light only ever spreads through a work interval; fails_when=the bisection or the area integral isn't monotonic; why_new=the scene is new; seam=none
    func testTheRadiusGrowsWithTheShare() {
        var last = -1.0
        for step in 0...20 {
            let r = ContourLight.radius(share: Double(step) / 20, aspect: aspect)
            XCTAssertGreaterThan(r, last, "step \(step)")
            last = r
        }
    }

    // Value: protects=a zero-height first layout pass draws the idle map instead of trapping or dividing by zero; fails_when=share/radius divide by a zero aspect; why_new=the scene is new; seam=none
    func testAZeroSizedScreenGivesNoLight() {
        XCTAssertEqual(ContourLight.share(radius: 0.5, aspect: 0), 0)
        XCTAssertEqual(ContourLight.radius(share: 0.5, aspect: 0), 0)
    }

    // Value: protects=the disc at radius(share:) covers that share of the screen's points on the
    //   iPhone shapes the app runs on; fails_when=share's closed form drops or doubles a quarter,
    //   mis-clips one cut by both its side and its top, stops clipping at a screen edge, or
    //   mis-scales the summit by the aspect; why_new=the round trip above inverts whatever share
    //   computes, so a wrong share still passes it; seam=none; no_claim=the shader's noise-bent
    //   edge (±0.07 1 sd, device-checked in TESTING §V.2); a summit-centred disc only
    func testTheLitDiscCoversThatShareOfTheScreensPoints() {
        // An independent count of every point whose centre is within the radius of the summit,
        // a row at a time: in each row the lit centres are those strictly inside the half chord.
        func litShare(radius r: Double, width: Int, height: Int) -> Double {
            let h = Double(height)
            let cx = ContourLight.summit.x * Double(width) / h, cy = ContourLight.summit.y
            var lit = 0
            for y in 0..<height {
                let dy = (Double(y) + 0.5) / h - cy
                let half2 = r * r - dy * dy
                guard half2 > 0 else { continue }
                let half = half2.squareRoot()
                // Columns i whose centre (i + 0.5) / h lies in the open interval (cx - half, cx + half).
                let first = max(0, Int(((cx - half) * h - 0.5).rounded(.down)) + 1)
                let last = min(width - 1, Int(((cx + half) * h - 0.5).rounded(.up)) - 1)
                lit += max(0, last - first + 1)
            }
            return Double(lit) / Double(width * height)
        }
        // The app is portrait-only on iPhone: an iPhone 17 Pro; an SE (16:9, the one aspect unlike
        // the others: its sides sit farther from the summit, so they clip the disc last); and a
        // Pro Max (the 17 Pro's aspect on a different point grid). 0.1 is unclipped, 0.5 clipped at
        // the sides, 0.8 has the upper quarters cut by both side and top, 0.99 the lower ones too.
        for (width, height) in [(402, 874), (375, 667), (440, 956)] {
            let aspect = Double(width) / Double(height)
            for target in [0.1, 0.5, 0.8, 0.99] {
                let r = ContourLight.radius(share: target, aspect: aspect)
                XCTAssertEqual(litShare(radius: r, width: width, height: height), target, accuracy: 0.003,
                               "\(width)×\(height) at \(target)")
            }
        }
    }

    // Value: protects=with no session the shader gets the idle signal (light < 0: even lines, no edge), and a break hands the light back; fails_when=idle maps to 0 (a session at its start: dim lines, no light) or a break reads as work; why_new=FocusDrivers.fill is tested but not the -1 the shader keys idle on; seam=none; no_claim=the shader's idle branch (device, TESTING §V.2)
    func testIdleReadsAsNoSessionAndABreakHandsTheLightBack() {
        for progress in [0.0, 0.5, 1.0] {
            XCTAssertLessThan(ContourLight.light(isRunning: false, isWork: true, progress: progress), 0)
            XCTAssertLessThan(ContourLight.light(isRunning: false, isWork: false, progress: progress), 0)
        }
        XCTAssertEqual(ContourLight.light(isRunning: true, isWork: true, progress: 0.25), 0.25, accuracy: 1e-12)
        XCTAssertEqual(ContourLight.light(isRunning: true, isWork: false, progress: 0.25), 0.75, accuracy: 1e-12)
    }
}

/// `FocusStillFrame`, the Focus scenes' still frame with Moving scenes off, redraws on each of the
/// Pomodoro's publishes, and each redraw must read the Pomodoro afresh.
@MainActor
final class FocusStillFrameTests: XCTestCase {

    // Value: protects=a still frame redrawn on a Pomodoro publish draws the new reading; fails_when=content is built once in the caller (a stored Content, as in NightFade) instead of called per body; why_new=nothing tested FocusStillFrame; seam=none; no_claim=that SwiftUI redraws it on a publish, or which branch a scene takes (device TESTING.md H step 5)
    func testEachRedrawReadsThePomodoroAfresh() {
        let p = PomodoroService()
        defer { p.stop() }
        var seen: [Bool] = []
        let frame = FocusStillFrame(pomodoro: p, content: { seen.append(p.isRunning); return EmptyView() })
        _ = frame.body
        p.start()
        _ = frame.body
        XCTAssertEqual(Array(seen.suffix(2)), [false, true], "the second redraw kept the first one's reading")
    }

    // Value: protects=with Moving scenes off, a Focus still frame redraws when the Pomodoro publishes; fails_when=FocusStillFrame stops observing the Pomodoro (a plain let) or keeps a stored Content; why_new=the other tests call body and the publisher by hand, never SwiftUI redrawing it; seam=none; no_claim=which branch each scene view takes (device TESTING.md H step 5)
    func testAHostedStillFrameRedrawsWhenThePomodoroPublishes() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "no window scene in the test host")
        let p = PomodoroService()
        // What each redraw read: a count alone would credit any stray redraw to the Pomodoro.
        var readings: [(running: Bool, remaining: TimeInterval)] = []
        // A drawn shape, as the scenes' frames are: with an `EmptyView` content SwiftUI never called it.
        let host = UIHostingController(rootView: FocusStillFrame(pomodoro: p, content: {
            readings.append((p.isRunning, p.remaining))
            return Rectangle().fill(.black)
        }))
        // Shown in its own window over the test host's, not made key.
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        defer { p.stop(); window.isHidden = true; window.rootViewController = nil }

        // Turns the main run loop until `done` or the budget is spent. It's spent per turn (a 20 ms
        // turn, at most 50 ms counted), not by the wall clock: the host app's first render can hold
        // main for 10 s or more, and a wall-clock budget ran out under it with the tick still queued.
        func turn(for budget: TimeInterval, until done: () -> Bool = { false }) {
            var left = budget
            while !done(), left > 0 {
                let t0 = Date()
                RunLoop.main.run(until: t0.addingTimeInterval(0.02))
                left -= min(Date().timeIntervalSince(t0), 0.05)
            }
        }
        turn(for: 2) { !readings.isEmpty }
        XCTAssertFalse(readings.isEmpty, "the frame never rendered")
        // Settle until 25 turns (about 0.5 s) pass with no draw: layout passes after the first draw
        // aren't publishes.
        var settled = readings.count, quietTurns = 0
        turn(for: 3) {
            if readings.count != settled { settled = readings.count; quietTurns = 0 } else { quietTurns += 1 }
            return quietTurns >= 25
        }
        XCTAssertGreaterThanOrEqual(quietTurns, 25, "the frame never settled")

        // Nothing published, nothing redrawn: so the redraws below are the Pomodoro's.
        let before = readings.count
        turn(for: 0.2)
        XCTAssertEqual(readings.count, before, "the frame redrew with nothing published")

        p.start()
        turn(for: 2) { readings.last?.running == true }
        XCTAssertEqual(readings.last?.running, true, "a start didn't redraw the frame with the session running")

        // The 1 Hz tick redraws it too, with the countdown lower: the reading creeps.
        let started = p.remaining
        turn(for: 3) { (readings.last?.remaining ?? started) < started }
        XCTAssertLessThan(readings.last?.remaining ?? started, started, "a tick didn't redraw the frame with the countdown")
    }

    // Value: protects=a Focus still frame moves at once on a start, break or stop; fails_when=a start, skip or stop no longer publishes objectWillChange, all FocusStillFrame observes; why_new=PomodoroProgressTests reads progress(at:), never what the service publishes, and the hosted test checks only start and tick; seam=none; no_claim=the 1 Hz tick (the hosted test), or that nothing publishes while idle
    func testThePomodoroPublishesEachChange() {
        let p = PomodoroService()
        defer { p.stop() }
        var publishes = 0
        let counting = p.objectWillChange.sink { publishes += 1 }
        defer { counting.cancel() }

        p.start()
        XCTAssertGreaterThan(publishes, 0, "a start didn't publish")

        var before = publishes
        p.skipPhase()
        XCTAssertEqual(p.phase, .rest)
        XCTAssertGreaterThan(publishes, before, "a break didn't publish")

        before = publishes
        p.stop()
        XCTAssertGreaterThan(publishes, before, "a stop didn't publish")
    }
}

/// The night `ShaderBackdrop` hands its shader, hosted in a window as the scenes are. Only the paused
/// branches (the still frame out of sight, and in sight with Moving scenes off), which draw one frame
/// with no redraw loop, so nothing here waits on frame timing.
@MainActor
final class ShaderBackdropEasedNightTests: XCTestCase {

    // Value: protects=the eased night reaches the shader, read with the timer's night and inSight = !occluded, and scenes without a hook keep the timer's night; fails_when=field() passes the raw timer night (the "+15m" pop comes back for Fireflies and Lamplight), passes occluded or a constant as inSight, or the nil path stops reading the timer (the other Sleep scenes stop darkening); why_new=EasedNightTests hand the follower its flag directly and nothing hosts ShaderBackdrop; seam=none; no_claim=the animated branch and the clock's rate, that the two scenes pass follower.night (TESTING §W.4/§X.4), what the shader draws
    func testShaderBackdropHandsItsShaderTheScenesEasedNight() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
                                  "no window scene in the test host")
        // Halfway through a 30-minute timer, set directly: no tick is armed, so it holds there.
        let timer = SleepTimerService()
        timer.timerTotal = 30 * 60
        timer.timerRemaining = 15 * 60
        XCTAssertEqual(timer.nightProgress, 0.5, accuracy: 1e-9)

        // Turns the main run loop until `done` or the budget is spent, per turn (as in
        // FocusStillFrameTests): the host app's first render can hold main for 10 s or more.
        func turn(for budget: TimeInterval, until done: () -> Bool) {
            var left = budget
            while !done(), left > 0 {
                let t0 = Date()
                RunLoop.main.run(until: t0.addingTimeInterval(0.02))
                left -= min(Date().timeIntervalSince(t0), 0.05)
            }
        }

        typealias Read = (night: Double, now: TimeInterval, inSight: Bool)
        /// Hosts one paused backdrop in its own window until it has built its shader, and returns what
        /// its hook was asked and the night its shader got, with the span the reads fell in.
        func render(occluded: Bool, eased: Bool) -> (reads: [Read], shader: [Float], span: ClosedRange<TimeInterval>) {
            var reads: [Read] = []
            var shader: [Float] = []
            var hook: ((Double, TimeInterval, Bool) -> Double)?
            if eased {
                // The scene's own reading, unlike the timer's, so the test can tell which one arrived.
                hook = { night, now, inSight in
                    reads.append((night, now, inSight))
                    return 0.8
                }
            }
            let view = ShaderBackdrop(paused: true, nightSlowdown: 0.4, sleepTimer: timer, audioLevel: nil,
                                      occluded: occluded, easedNight: hook) { s in
                shader.append(s.night)
                return ShaderLibrary.lampSnowField(
                    .float(s.phase), .float(s.elapsed), .float2(s.size), .float(s.night),
                    .float(1), .float(0), .float2(0, 0), .float(3))
            }
            let from = Date.timeIntervalSinceReferenceDate
            let host = UIHostingController(rootView: view)
            // Shown in its own window over the test host's, not made key.
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.isHidden = false
            host.view.layoutIfNeeded()
            turn(for: 30) { !shader.isEmpty }
            let to = Date.timeIntervalSinceReferenceDate
            window.isHidden = true
            window.rootViewController = nil
            return (reads, shader, from...to)
        }

        // Out of sight (the veil, the lock screen): the hook reads the timer's night, not in sight.
        let veiled = render(occluded: true, eased: true)
        XCTAssertFalse(veiled.shader.isEmpty, "the occluded still frame never built its shader")
        XCTAssertFalse(veiled.reads.isEmpty, "the occluded still frame never asked the scene for its night")
        for read in veiled.reads {
            XCTAssertEqual(read.night, 0.5, accuracy: 1e-9, "the hook wasn't handed the timer's night")
            XCTAssertFalse(read.inSight, "a frame out of sight was read as in sight")
            XCTAssertTrue(veiled.span.contains(read.now), "the hook wasn't handed the clock's now: \(read.now)")
        }
        for night in veiled.shader {
            XCTAssertEqual(night, 0.8, accuracy: 1e-6, "the shader got the timer's night, not the scene's")
        }

        // In sight with Moving scenes off: the same night, read as watched.
        let still = render(occluded: false, eased: true)
        XCTAssertFalse(still.shader.isEmpty, "the still frame in sight never built its shader")
        XCTAssertFalse(still.reads.isEmpty, "the still frame in sight never asked the scene for its night")
        for read in still.reads {
            XCTAssertEqual(read.night, 0.5, accuracy: 1e-9, "the hook wasn't handed the timer's night")
            XCTAssertTrue(read.inSight, "a frame in sight was read as out of sight")
            XCTAssertTrue(still.span.contains(read.now), "the hook wasn't handed the clock's now: \(read.now)")
        }
        for night in still.shader {
            XCTAssertEqual(night, 0.8, accuracy: 1e-6, "the shader got the timer's night, not the scene's")
        }

        // No hook (Night sky, Aurora, Embers, Still water, Deep space): the timer's night as it is.
        let plain = render(occluded: true, eased: false)
        XCTAssertFalse(plain.shader.isEmpty, "the backdrop without a hook never built its shader")
        for night in plain.shader {
            XCTAssertEqual(night, 0.5, accuracy: 1e-6, "a scene without a hook lost the timer's night")
        }
    }
}
