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

// Pure migration map — saved mixes break if these stop mapping (NoiseType.migrate).
final class NoiseMigrationTests: XCTestCase {
    // green / white / forest / gray are now first-class sounds with their own render cases, so
    // migrate() passes them through instead of folding them away (the audio-palette change).
    func testNewColoursPassThrough() {
        XCTAssertEqual(NoiseType.migrate("green"), "green")
        XCTAssertEqual(NoiseType.migrate("white"), "white")
        XCTAssertEqual(NoiseType.migrate("forest"), "forest")
        XCTAssertEqual(NoiseType.migrate("gray"), "gray")
    }

    func testValidPassesThroughAndUnknownFallsBack() {
        XCTAssertEqual(NoiseType.migrate("brown"), "brown")
        XCTAssertEqual(NoiseType.migrate("ocean"), "ocean")
        XCTAssertEqual(NoiseType.migrate("pink"), "pink")
        XCTAssertEqual(NoiseType.migrate("totally-unknown"), "brown")
    }
}

// Feed parsing — the historically fiddly bits (CDATA show-notes, HH:MM:SS duration,
// RFC-822 dates, item/channel artwork). Runs against in-memory XML, no network.
final class PodcastParserTests: XCTestCase {
    private func parse(_ xml: String) throws -> PodcastParser.ParsedFeed {
        try PodcastParser().parse(data: Data(xml.utf8))
    }

    func testCDATADescriptionIsCaptured() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
        <channel>
          <title>Test Show</title>
          <itunes:image href="https://example.com/art.jpg"/>
          <item>
            <title>Episode One</title>
            <guid>ep-1</guid>
            <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/>
            <pubDate>Mon, 02 Jun 2025 08:00:00 +0000</pubDate>
            <itunes:duration>1:02:03</itunes:duration>
            <description><![CDATA[<p>Hello <b>world</b> show notes.</p>]]></description>
          </item>
        </channel>
        </rss>
        """
        let feed = try parse(xml)
        XCTAssertEqual(feed.title, "Test Show")
        XCTAssertEqual(feed.episodes.count, 1)
        let ep = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(ep.id, "ep-1")
        XCTAssertEqual(ep.audioUrl, "https://example.com/1.mp3")
        XCTAssertEqual(ep.duration, 3723)                 // 1h 2m 3s
        XCTAssertNotNil(ep.pubDate)
        XCTAssertEqual(ep.artworkUrl, "https://example.com/art.jpg")
        // The regression this guards: CDATA arrives via foundCDATABlock, not foundCharacters.
        XCTAssertTrue(ep.description?.contains("Hello") ?? false, "CDATA show-notes must be captured")
    }

    func testPlainTextDescriptionAndSecondsDuration() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss><channel>
          <title>Plain Show</title>
          <item>
            <title>Ep</title>
            <guid>p-1</guid>
            <enclosure url="https://example.com/p.mp3"/>
            <itunes:duration>90</itunes:duration>
            <description>Plain notes</description>
          </item>
        </channel></rss>
        """
        let feed = try parse(xml)
        let ep = try XCTUnwrap(feed.episodes.first)
        XCTAssertEqual(ep.description, "Plain notes")
        XCTAssertEqual(ep.duration, 90)
    }

    func testItemWithoutEnclosureIsSkipped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss><channel>
          <title>S</title>
          <item><title>No audio</title><guid>x</guid></item>
        </channel></rss>
        """
        let feed = try parse(xml)
        XCTAssertEqual(feed.episodes.count, 0)
    }
}

// Characterization tests (Slice A0 of ARCHITECTURE-REFACTOR-PLAN.md): pin the AudioEngine
// behaviors the decomposition must preserve, before any code moves. All deterministic and
// network-free (no podcast in any saved mix → resumeMix never calls loadPodcast).
@MainActor
final class AudioEngineBehaviorTests: XCTestCase {

    func testSaveAndResumeLastMixRoundTrip() {
        let engine = AudioEngine()
        engine.focusMode = false
        engine.noiseType = "ocean"
        engine.noiseVolume = 0.55
        engine.noiseOn = true
        engine.binauralPreset = "theta"
        engine.binVolume = 0.22
        engine.binauralOn = true

        engine.saveLastMix()
        let saved = engine.lastMix
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.noiseType, "ocean")
        XCTAssertTrue(saved?.noiseOn ?? false)
        XCTAssertTrue(saved?.binauralOn ?? false)
        XCTAssertNil(saved?.podcastUrl)              // nothing playing → resume won't hit network

        // Mutate, then resume — the snapshot should come back.
        engine.noiseOn = false
        engine.binauralOn = false
        engine.noiseType = "brown"

        engine.resumeMix(saved!)
        XCTAssertEqual(engine.noiseType, "ocean")
        XCTAssertEqual(engine.noiseVolume, 0.55, accuracy: 0.0001)
        XCTAssertTrue(engine.noiseOn)
        XCTAssertEqual(engine.binauralPreset, "theta")
        XCTAssertTrue(engine.binauralOn)
    }

    func testResumeMixKeepsNowValidNoiseType() {
        let engine = AudioEngine()
        let mix = SavedMix(name: "old", noiseOn: true, noiseVolume: 0.4, noiseType: "green",
                           binauralOn: false, binVolume: 0.3, binauralPreset: "delta",
                           podVolume: 0.7, podcastUrl: nil, podcastId: nil)
        engine.resumeMix(mix)
        XCTAssertEqual(engine.noiseType, "green")    // green is a real sound now (NoiseType.migrate)
    }

    func testModeSwitchReconcilesSoundsIntoPalette() {
        let engine = AudioEngine()
        engine.focusMode = false
        engine.noiseType = "ocean"                   // sleep-only
        engine.binauralPreset = "delta"              // sleep-only

        engine.focusMode = true                      // didSet → reconcileSoundsToMode()
        XCTAssertTrue(AudioEngine.focusNoises.contains(engine.noiseType),
                      "noise must snap into the Focus palette on mode switch")
        XCTAssertTrue(AudioEngine.focusBinaurals.contains(engine.binauralPreset),
                      "binaural must snap into the Focus palette on mode switch")
    }
}
