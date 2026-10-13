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

    // Value: protects=the lit share of the screen equals the interval's share; fails_when=radius or share ignores the screen's edges or aspect; why_new=the scene is new; seam=none
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
}
