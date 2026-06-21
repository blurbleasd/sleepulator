import XCTest
@testable import Sleepulator

@MainActor
class AudioStateTests: XCTestCase {

    private func makeEpisode(_ id: String) -> Episode {
        Episode(id: id, title: "Ep \(id)", audioUrl: "http://example.com/\(id)",
                duration: 100, pubDate: Date(), description: nil, artworkUrl: nil)
    }

    // Queue logic lives in PodcastQueueManager — test it directly (no audio session / network).
    func testQueueAdvance() {
        let qm = PodcastQueueManager()
        qm.autoPlay = false                       // deterministic: advance just pops the head
        qm.queue = [makeEpisode("1"), makeEpisode("2")]

        qm.advanceQueue(finishedEpId: "1")
        XCTAssertEqual(qm.queue.count, 1)
        XCTAssertEqual(qm.queue.first?.id, "2")

        qm.advanceQueue(finishedEpId: "2")
        XCTAssertEqual(qm.queue.count, 0)
    }

    func testShuffleKeepsCurrentFirst() {
        let qm = PodcastQueueManager()
        qm.queue = [makeEpisode("1"), makeEpisode("2"), makeEpisode("3")]
        qm.shuffleRemainingQueue()
        XCTAssertEqual(qm.queue.first?.id, "1")    // now-playing item must stay put
        XCTAssertEqual(qm.queue.count, 3)
    }

    // The giant button snapshots the active layers on pause and restores them on the next press.
    func testMasterTransportSnapshotResume() {
        let engine = AudioEngine()
        engine.noiseOn = true
        engine.binauralOn = true

        engine.toggleMasterTransport()             // something on → snapshot + pause all
        XCTAssertFalse(engine.noiseOn)
        XCTAssertFalse(engine.binauralOn)

        engine.toggleMasterTransport()             // resume exactly what was on
        XCTAssertTrue(engine.noiseOn)
        XCTAssertTrue(engine.binauralOn)
    }

    func testPositionPruneCapsAt100() {
        var mockPositions: [String: Double] = [:]
        for i in 0..<105 { mockPositions["\(i)"] = Double(i) }
        StorageManager.shared.save(mockPositions, to: "positions.json")

        let player = PodcastPlayer()               // loads the 105 saved positions
        player.flushPositionsToDisk()              // should trim to <= 100

        let exp = expectation(description: "flush to disk")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)

        let saved: [String: Double]? = StorageManager.shared.load(from: "positions.json")
        XCTAssertNotNil(saved)
        XCTAssertLessThanOrEqual(saved!.count, 100)
    }
}
