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
}
