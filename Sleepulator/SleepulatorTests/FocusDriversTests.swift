import XCTest
import Combine
import SwiftUI
import UIKit
import simd
@testable import Sleepulator

/// Pins the Pomodoro→look mapping shared by the Canvas `CurrentView` and the Metal
/// `CurrentMetalView`. The one part of the Focus Metal port that's verifiable off-device; the
/// shader itself and its thermals are device-verified.
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
        var draws = 0
        // A drawn shape, as the scenes' frames are: with an `EmptyView` content SwiftUI never called it.
        let host = UIHostingController(rootView: FocusStillFrame(pomodoro: p, content: { draws += 1; return Rectangle().fill(.black) }))
        // Shown in its own window over the test host's, not made key.
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        defer { p.stop(); window.isHidden = true; window.rootViewController = nil }

        // Turns the main run loop until `done`, or for `seconds`.
        func turn(for seconds: TimeInterval, until done: () -> Bool = { false }) {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        // The waits end as soon as the draw lands; the ceilings are for CI's slow simulators.
        turn(for: 2) { draws > 0 }
        XCTAssertGreaterThan(draws, 0, "the frame never rendered")
        // Settle until the draws stop for 0.5 s: layout passes after the first draw aren't publishes.
        var settled = draws, quietSince = Date()
        turn(for: 3) {
            if draws != settled { settled = draws; quietSince = Date() }
            return Date().timeIntervalSince(quietSince) >= 0.5
        }

        // Nothing published, nothing redrawn: so the redraws below are the Pomodoro's.
        var before = draws
        turn(for: 0.2)
        XCTAssertEqual(draws, before, "the frame redrew with nothing published")

        p.start()
        turn(for: 2) { draws > before }
        XCTAssertGreaterThan(draws, before, "a start didn't redraw the frame")

        // The 1 Hz tick redraws it too: the reading creeps with the countdown.
        before = draws
        turn(for: 3) { draws > before }
        XCTAssertGreaterThan(draws, before, "a tick didn't redraw the frame")
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
