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

    // The previously-untested branch: shuffle + autoplay should drop the finished head, then
    // promote a random remaining episode to the front and load it.
    func testAdvanceShuffleAutoplayLoadsRemaining() {
        let qm = PodcastQueueManager()
        qm.autoPlay = true
        qm.shuffleQueue = true
        qm.queue = [makeEpisode("1"), makeEpisode("2"), makeEpisode("3")]
        var loadedId: String?
        qm.loadPodcastFn = { _, id, _ in loadedId = id }

        qm.advanceQueue(finishedEpId: "1")
        XCTAssertEqual(qm.queue.count, 2)
        XCTAssertFalse(qm.queue.contains { $0.id == "1" })   // finished head removed
        XCTAssertNotNil(loadedId)
        XCTAssertNotEqual(loadedId, "1")
        XCTAssertEqual(qm.queue.first?.id, loadedId)         // the loaded item is promoted to head
    }

    func testMarkFinishedThenUnfinished() {
        let qm = PodcastQueueManager()
        qm.markFinished("abc")
        XCTAssertTrue(qm.finishedEpisodes.contains("abc"))
        qm.markUnfinished("abc")
        XCTAssertFalse(qm.finishedEpisodes.contains("abc"))
        qm.markUnfinished("never-seen")     // no-op, no crash
        XCTAssertFalse(qm.finishedEpisodes.contains("never-seen"))
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

// Adaptive rewind — the longer playback was paused, the further back resume nudges.
final class AdaptiveRewindTests: XCTestCase {
    func testRewindCurve() {
        XCTAssertEqual(PodcastPlayer.adaptiveRewind(forPause: 2),    0)   // a blink: don't move
        XCTAssertEqual(PodcastPlayer.adaptiveRewind(forPause: 30),   3)   // short pause
        XCTAssertEqual(PodcastPlayer.adaptiveRewind(forPause: 300),  10)  // few minutes away
        XCTAssertEqual(PodcastPlayer.adaptiveRewind(forPause: 1800), 20)  // up to an hour
        XCTAssertEqual(PodcastPlayer.adaptiveRewind(forPause: 36000), 30) // fell asleep / next day
    }

    func testBoundariesAreMonotonic() {
        // Never rewinds *less* as the gap grows — a monotonic, non-negative curve.
        let gaps: [TimeInterval] = [0, 9, 10, 59, 60, 599, 600, 3599, 3600, 100000]
        let rewinds = gaps.map { PodcastPlayer.adaptiveRewind(forPause: $0) }
        for i in 1..<rewinds.count { XCTAssertGreaterThanOrEqual(rewinds[i], rewinds[i-1]) }
        XCTAssertTrue(rewinds.allSatisfy { $0 >= 0 })
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

    // Malformed-feed guard: a giant <description> must be capped, not accumulated unbounded.
    func testGiantDescriptionIsCapped() throws {
        let huge = String(repeating: "A", count: 500_000)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss><channel><title>S</title>
          <item><title>Ep</title><guid>g</guid>
            <enclosure url="https://example.com/a.mp3"/>
            <description>\(huge)</description>
          </item>
        </channel></rss>
        """
        let feed = try parse(xml)
        let ep = try XCTUnwrap(feed.episodes.first)
        let desc = try XCTUnwrap(ep.description)
        XCTAssertLessThanOrEqual(desc.count, 200_000, "description must be bounded")
        XCTAssertGreaterThan(desc.count, 0)
    }
}

// Durable persistence: missing files are benign, and a corrupt primary is recovered from the
// .bak sibling that every successful save mirrors.
final class StorageManagerTests: XCTestCase {
    private func uniqueName() -> String { "test_\(UUID().uuidString).json" }

    private func storageURL(_ name: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Sleepulator").appendingPathComponent(name)
    }

    func testSaveLoadRoundTrip() {
        let name = uniqueName()
        defer { StorageManager.shared.delete(filename: name) }
        StorageManager.shared.save(["a": 1, "b": 2], to: name)
        StorageManager.shared.flush()
        let loaded: [String: Int]? = StorageManager.shared.load(from: name)
        XCTAssertEqual(loaded, ["a": 1, "b": 2])
    }

    func testMissingFileIsBenign() {
        let name = uniqueName()
        let r: (value: [String: Int]?, outcome: StorageManager.LoadOutcome) =
            StorageManager.shared.loadResult(from: name)
        XCTAssertNil(r.value)
        XCTAssertEqual(r.outcome, .missing)
    }

    func testRecoversFromBackupWhenPrimaryCorrupt() throws {
        let name = uniqueName()
        defer { StorageManager.shared.delete(filename: name) }
        StorageManager.shared.save(["x": 7], to: name)
        StorageManager.shared.flush()

        // Corrupt the primary in place; the .bak sibling still holds valid bytes.
        try Data("not valid json".utf8).write(to: storageURL(name))

        let r: (value: [String: Int]?, outcome: StorageManager.LoadOutcome) =
            StorageManager.shared.loadResult(from: name)
        XCTAssertEqual(r.value, ["x": 7])
        XCTAssertEqual(r.outcome, .recovered)
    }
}

// Network retry/backoff classification + control flow (pure, no real network).
final class NetRetryTests: XCTestCase {
    private struct Boom: Error {}

    func testIsRetryableClassification() {
        XCTAssertTrue(Net.isRetryable(HTTPStatusError(statusCode: 503)))
        XCTAssertFalse(Net.isRetryable(HTTPStatusError(statusCode: 404)))
        XCTAssertTrue(Net.isRetryable(URLError(.timedOut)))
        XCTAssertTrue(Net.isRetryable(URLError(.networkConnectionLost)))
        XCTAssertFalse(Net.isRetryable(URLError(.userAuthenticationRequired)))
    }

    func testSucceedsAfterTransientFailures() async throws {
        var calls = 0
        let result = try await Net.retry(attempts: 3, baseDelay: 0.0, isRetryable: { _ in true }) { () -> Int in
            calls += 1
            if calls < 3 { throw Boom() }
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, 3)
    }

    func testStopsImmediatelyOnNonRetryable() async {
        var calls = 0
        do {
            _ = try await Net.retry(attempts: 5, baseDelay: 0.0, isRetryable: { _ in false }) { () -> Int in
                calls += 1
                throw Boom()
            }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(calls, 1)
        }
    }

    func testGivesUpAfterAttempts() async {
        var calls = 0
        do {
            _ = try await Net.retry(attempts: 3, baseDelay: 0.0, isRetryable: { _ in true }) { () -> Int in
                calls += 1
                throw Boom()
            }
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(calls, 3)
        }
    }
}

// Pure cache-eviction policy: least-recently-used first, a re-touched file survives.
final class CacheEvictionTests: XCTestCase {
    private func file(_ name: String, _ size: UInt64, _ recency: Date) -> AudioDownloader.CacheFile {
        AudioDownloader.CacheFile(url: URL(fileURLWithPath: "/tmp/\(name)"), size: size, recency: recency)
    }

    func testNoEvictionUnderLimit() {
        let now = Date()
        let files = [file("a", 100, now), file("b", 100, now)]
        XCTAssertTrue(AudioDownloader.evictionPlan(files: files, maxBytes: 1000).isEmpty)
    }

    func testEvictsLeastRecentFirstUntilUnderCap() {
        let now = Date()
        let files = [
            file("recent", 600, now),
            file("old",    600, now.addingTimeInterval(-3600)),
            file("older",  600, now.addingTimeInterval(-7200)),
        ]
        // total 1800, cap 1000 → drop older (→1200), then old (→600); recent survives.
        let plan = AudioDownloader.evictionPlan(files: files, maxBytes: 1000)
        XCTAssertEqual(plan.map { $0.lastPathComponent }, ["older", "old"])
    }

    func testRecentlyTouchedLargeFileSurvivesOverStaleSmallOne() {
        let now = Date()
        let files = [
            file("touchedBig", 1500, now),                              // downloaded long ago, re-played now
            file("staleSmall", 600, now.addingTimeInterval(-99_999)),   // old, untouched
        ]
        let plan = AudioDownloader.evictionPlan(files: files, maxBytes: 1500)
        XCTAssertEqual(plan.map { $0.lastPathComponent }, ["staleSmall"])
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

// End-of-episode sleep timer — driven by the playback clock via externalTick. Deterministic and
// synchronous (no GCD timer / audio session); Live Activity is a no-op when unauthorized in tests.
@MainActor
final class EndOfEpisodeTimerTests: XCTestCase {
    func testFiresExactlyOnceAndIgnoresBump() {
        let svc = SleepTimerService()
        var stops = 0
        svc.stopAllFn = { stops += 1 }

        svc.startEndOfEpisode(remaining: 100)
        XCTAssertTrue(svc.isEndOfEpisode)

        svc.externalTick(remaining: 95)          // before the fade window — still running
        XCTAssertEqual(stops, 0)

        svc.bumpTimer()                          // bump is a no-op for an episode timer
        XCTAssertTrue(svc.isEndOfEpisode)

        svc.externalTick(remaining: 0.2)         // crosses the terminal threshold
        XCTAssertEqual(stops, 1)
        XCTAssertFalse(svc.isEndOfEpisode)       // timer cancelled itself

        svc.externalTick(remaining: 0.1)         // late tick must not double-fire
        XCTAssertEqual(stops, 1)
    }

    func testDurationTimerIgnoresExternalTick() {
        let svc = SleepTimerService()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.startSleepTimer(minutes: 30)         // a fixed-duration timer
        svc.externalTick(remaining: 0.1)         // playback-clock ticks must be ignored here
        XCTAssertEqual(stops, 0)
        svc.cancelTimer()
    }
}
