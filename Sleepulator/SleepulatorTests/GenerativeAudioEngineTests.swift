import XCTest
import AVFoundation
@testable import Sleepulator

/// Media-services reset recovery for the generative bed. The simulator can't force a real reset,
/// so these drive the rebuild path directly. They pin that a fresh AVAudioEngine replaces the
/// invalid one, that it runs only when the bed should, and that the configuration-change
/// observer moves to the new instance. Whether the bed is audible again after a real reset is
/// device-verified (TESTING.md §3B).
@MainActor
final class GenerativeMediaResetTests: XCTestCase {

    /// A running engine with a noise layer on, or a skip when the host has no audio output.
    private func makeRunningEngine() throws -> GenerativeAudioEngine {
        let gen = GenerativeAudioEngine()
        gen.setNoise(on: true, volume: 0.5, type: "brown")
        gen.resumeIfNeeded()
        try XCTSkipUnless(gen.isRunning, "AVAudioEngine can't start here (no audio output)")
        return gen
    }

    private func nodeIDs(_ engine: AVAudioEngine) -> Set<ObjectIdentifier> {
        Set(engine.attachedNodes.map(ObjectIdentifier.init))
    }

    /// The configuration-change handler hops to main; let it run.
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    func testResetSwapsTheEngineAndRestartsWhenTheBedIsOn() throws {
        let gen = try makeRunningEngine()
        let old = gen.currentEngine
        gen.handleMediaServicesReset(restart: true)
        XCTAssertFalse(gen.currentEngine === old, "the old engine is invalid after a reset; a new one must replace it")
        XCTAssertFalse(old.isRunning, "the old engine must be stopped before the swap")
        XCTAssertTrue(gen.isRunning, "noise is on, so the rebuilt engine must be rendering")
    }

    func testResetLeavesTheEngineStoppedWhenTheBedIsOff() throws {
        let gen = try makeRunningEngine()
        gen.handleMediaServicesReset(restart: false)
        XCTAssertFalse(gen.isRunning, "nothing should be playing, so the rebuilt engine stays idle")
        gen.resumeIfNeeded()
        XCTAssertTrue(gen.isRunning, "the rebuilt graph must still start when the bed turns on")
    }

    func testRepeatedResetsKeepRecovering() throws {
        let gen = try makeRunningEngine()
        for _ in 0..<3 {
            gen.handleMediaServicesReset(restart: true)
            XCTAssertTrue(gen.isRunning)
        }
    }

    func testConfigurationObserverFollowsTheNewEngine() throws {
        let gen = try makeRunningEngine()
        let old = gen.currentEngine
        gen.handleMediaServicesReset(restart: true)
        let new = gen.currentEngine
        let built = nodeIDs(new)

        // A late change from the swapped-out engine must not rebuild the new graph.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: old)
        drainMainQueue()
        XCTAssertEqual(nodeIDs(new), built, "a stale change from the old engine must be ignored")

        // A change on the new engine is observed: fresh nodes, still rendering.
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: new)
        drainMainQueue()
        XCTAssertNotEqual(nodeIDs(new), built, "the observer must be registered on the new engine")
        XCTAssertTrue(gen.isRunning)
    }

    func testConfigurationChangeWhilePausedRebuildsButStaysStopped() throws {
        let gen = try makeRunningEngine()
        gen.suspendEngine()
        let engine = gen.currentEngine
        let built = nodeIDs(engine)
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: engine)
        drainMainQueue()
        XCTAssertNotEqual(nodeIDs(engine), built, "the graph is still rebuilt for the new route")
        XCTAssertFalse(gen.isRunning, "a power-save pause must not be undone by a route change")
    }

    // MARK: AudioEngine wiring (AudioSessionController → AudioEngine → GenerativeAudioEngine)

    func testAudioEngineResetRebuildsAPlayingBed() throws {
        let audio = AudioEngine()
        audio.noiseOn = true
        let gen = audio.generativeEngineForTesting
        try XCTSkipUnless(gen.isRunning, "AVAudioEngine can't start here (no audio output)")
        let old = gen.currentEngine
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        drainMainQueue()   // AudioSessionController forwards on main
        XCTAssertFalse(gen.currentEngine === old, "the reset must reach the generative engine")
        XCTAssertTrue(gen.isRunning, "noise is on, so the bed must be playing again")
    }

    func testAudioEngineResetLeavesAnIdleBedStopped() throws {
        let audio = AudioEngine()
        audio.noiseOn = false
        audio.binauralOn = false
        let gen = audio.generativeEngineForTesting
        let old = gen.currentEngine
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: nil)
        drainMainQueue()
        XCTAssertFalse(gen.currentEngine === old, "the reset must reach the generative engine")
        XCTAssertFalse(gen.isRunning, "nothing is on, so the rebuilt engine must stay idle")
    }
}
