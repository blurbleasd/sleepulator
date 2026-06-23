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
}
