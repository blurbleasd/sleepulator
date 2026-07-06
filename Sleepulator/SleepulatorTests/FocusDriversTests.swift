import XCTest
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
}
