import XCTest
@testable import Sleepulator

class AudioMathTests: XCTestCase {
    
    func testBinauralPhaseDeltas() {
        let (dL, dR) = AudioMath.getBinauralPhaseDeltas(carrier: 200.0, beat: 6.0, sampleRate: 48000.0)
        XCTAssertNotEqual(dL, dR)
        XCTAssertTrue(dR > dL, "Right ear should have higher frequency increment")
    }
    
    func testCarrierAndBeat() {
        let theta = AudioMath.getCarrierAndBeat(for: "theta")
        XCTAssertEqual(theta.carrier, 200.0)
        XCTAssertEqual(theta.beat, 6.0)

        let alpha = AudioMath.getCarrierAndBeat(for: "alpha")
        XCTAssertEqual(alpha.carrier, 220.0)
        XCTAssertEqual(alpha.beat, 10.0)
    }
    
    func testFadeMultiplier() {
        // Test Fade path never writes UserDefaults (via testing the pure function logic)
        let fadeFull = AudioMath.getFadeMultiplier(timerRemaining: 1200)
        XCTAssertEqual(fadeFull, 1.0)

        let fadeHalf = AudioMath.getFadeMultiplier(timerRemaining: 300)
        // With exponential curve (300/600)^2 = 0.25
        XCTAssertEqual(fadeHalf, 0.25)

        let fadeZero = AudioMath.getFadeMultiplier(timerRemaining: 0)
        XCTAssertEqual(fadeZero, 0.0)
    }

    func testFadeFloorWhileRunning() {
        // While the timer is still running the multiplier never drops below 0.03 — the
        // keep-alive floor that stops iOS curtailing background execution before the hard stop.
        let nearEnd = AudioMath.getFadeMultiplier(timerRemaining: 1, fadeDuration: 600)
        XCTAssertEqual(nearEnd, 0.03, accuracy: 0.0001)   // (1/600)^2 ≈ 2.8e-6, floored
        // But exactly at/after zero it's a true silence (the hard stop fires there).
        XCTAssertEqual(AudioMath.getFadeMultiplier(timerRemaining: 0, fadeDuration: 600), 0.0)
        XCTAssertEqual(AudioMath.getFadeMultiplier(timerRemaining: -5, fadeDuration: 600), 0.0)
    }

    func testFadeCustomDuration() {
        // The end-of-episode timer uses a short (90 s) fade window.
        XCTAssertEqual(AudioMath.getFadeMultiplier(timerRemaining: 95, fadeDuration: 90), 1.0) // before window
        XCTAssertEqual(AudioMath.getFadeMultiplier(timerRemaining: 45, fadeDuration: 90), 0.25, accuracy: 0.0001) // (45/90)^2
    }

    // Scrubber → seek-time mapping: snaps near-start to exactly 0:00, clamps the 0…1 range, and
    // refuses a non-finite duration (the "scrub to the start doesn't reach the start" class of bug).
    func testScrubTargetSnapsToStart() {
        // Far left of the slider on a 1-hour episode: maps to 0 (exact start), not a few seconds in.
        XCTAssertEqual(AudioMath.scrubTargetSeconds(progress: 0.0, duration: 3600), 0)
        // Just inside the snap window (1.5 s < 2 s default) also lands at the true start.
        XCTAssertEqual(AudioMath.scrubTargetSeconds(progress: 1.5 / 3600, duration: 3600), 0)
    }

    func testScrubTargetNormalAndClamp() {
        XCTAssertEqual(AudioMath.scrubTargetSeconds(progress: 0.5, duration: 3600), 1800)
        // Out-of-range progress is clamped, not extrapolated past the track.
        XCTAssertEqual(AudioMath.scrubTargetSeconds(progress: 1.4, duration: 3600), 3600)
        XCTAssertEqual(AudioMath.scrubTargetSeconds(progress: -0.2, duration: 3600), 0)
    }

    func testScrubTargetRejectsUnknownDuration() {
        // progress * NaN = NaN; seeking to a NaN CMTime is silently ignored by AVPlayer, so the
        // mapper returns nil instead and the caller skips the seek.
        XCTAssertNil(AudioMath.scrubTargetSeconds(progress: 0.0, duration: .nan))
        XCTAssertNil(AudioMath.scrubTargetSeconds(progress: 0.5, duration: 0))
    }
}

/// `SceneClock` (ShaderBackdrop.swift) — the integrating animation clock behind the Metal
/// scenes' night slowdown and the Current scene's pomodoro momentum. The property under test:
/// a live rate change modulates speed WITHOUT rewinding the phase (the old
/// `absoluteTime × factor` form ran the shaders backward late in a timer run).
class SceneClockTests: XCTestCase {

    func testPhaseIntegratesAtRate() {
        let clock = SceneClock()
        clock.tick(now: 100.0, rate: 1.0)          // first tick establishes the baseline
        XCTAssertEqual(clock.phase, 0, accuracy: 1e-9)
        for i in 1...30 { clock.tick(now: 100.0 + Double(i) * 0.033, rate: 0.5) }
        XCTAssertEqual(clock.phase, 30 * 0.033 * 0.5, accuracy: 1e-6)
        XCTAssertEqual(clock.elapsed, 30 * 0.033, accuracy: 1e-6)
    }

    func testPhaseNeverRewindsWhenRateDrops() {
        // The bug this clock replaces: t × f(night) decreases when f shrinks faster than t
        // grows. Integrated phase must be monotonic for any rate ≥ 0, however the rate moves.
        let clock = SceneClock()
        var rate = 1.0
        var lastPhase = 0.0
        var now = 0.0
        for _ in 0..<200 {
            now += 0.033
            rate = max(0.0, rate - 0.01)           // night deepening: rate falls to 0
            clock.tick(now: now, rate: rate)
            XCTAssertGreaterThanOrEqual(clock.phase, lastPhase, "phase must never run backward")
            lastPhase = clock.phase
        }
        XCTAssertGreaterThan(clock.phase, 0)
    }

    func testResumeGapIsClampedToFreezeInPlace() {
        // An occluded night: no ticks for hours, then the veil lifts. The next tick must
        // advance by at most the clamp, so the scene continues from its frozen pose.
        let clock = SceneClock()
        clock.tick(now: 0, rate: 1)
        clock.tick(now: 0.033, rate: 1)
        let frozen = clock.phase
        clock.tick(now: 8 * 3600, rate: 1)          // 8 hours later
        XCTAssertLessThanOrEqual(clock.phase - frozen, 0.5 + 1e-9)
        XCTAssertLessThanOrEqual(clock.elapsed, 0.033 + 0.5 + 1e-9)
    }

    func testOrdinaryHitchesAreWallClockTrue() {
        // A 0.4s stutter must not stretch scene time (the Breathe cadence is tuned) —
        // only pause-scale gaps clamp.
        let clock = SceneClock()
        clock.tick(now: 0, rate: 1)
        clock.tick(now: 0.4, rate: 1)
        XCTAssertEqual(clock.elapsed, 0.4, accuracy: 1e-9)
    }

    func testZeroAndNegativeRateHoldPhaseButAdvanceElapsed() {
        // elapsed drives rate-independent cyclic terms (breath, twinkle, dither) — it keeps
        // moving while a zero rate holds the motion phase still. Negative rates clamp to 0.
        let clock = SceneClock()
        clock.tick(now: 0, rate: 1)
        clock.tick(now: 0.05, rate: 0)
        clock.tick(now: 0.10, rate: -5)
        XCTAssertEqual(clock.phase, 0, accuracy: 1e-9)
        XCTAssertEqual(clock.elapsed, 0.10, accuracy: 1e-6)
    }

    func testNonMonotonicNowIsIgnored() {
        let clock = SceneClock()
        clock.tick(now: 10, rate: 1)
        clock.tick(now: 11, rate: 1)
        let phase = clock.phase
        clock.tick(now: 9, rate: 1)                 // clock went backward: skip, re-baseline
        XCTAssertEqual(clock.phase, phase, accuracy: 1e-9)
        clock.tick(now: 9.033, rate: 1)
        XCTAssertEqual(clock.phase, phase + 0.033, accuracy: 1e-6)
    }
}

/// `NightDamping` — the depth multiplier that stills reactive controls (the orb breath) as the
/// sleep timer winds down.
class NightDampingTests: XCTestCase {
    func testFullyAliveWithNoTimer() {
        // nightProgress is 0 when no timer runs — full designed motion.
        XCTAssertEqual(NightDamping.factor(nightProgress: 0, bedtime: false), 1.0, accuracy: 1e-9)
    }

    func testStillsToZeroByFadeOut() {
        // Linear decay to zero motion at timer end.
        XCTAssertEqual(NightDamping.factor(nightProgress: 0.5, bedtime: false), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NightDamping.factor(nightProgress: 1.0, bedtime: false), 0.0, accuracy: 1e-9)
    }

    func testBedtimeKillsMotionImmediately() {
        // The OLED-off intent: no motion at all, regardless of timer.
        XCTAssertEqual(NightDamping.factor(nightProgress: 0, bedtime: true), 0.0, accuracy: 1e-9)
    }

    func testClampsOutOfRangeProgress() {
        XCTAssertEqual(NightDamping.factor(nightProgress: 1.5, bedtime: false), 0.0, accuracy: 1e-9)
        XCTAssertEqual(NightDamping.factor(nightProgress: -0.2, bedtime: false), 1.0, accuracy: 1e-9)
    }
}
