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

    // Regression: advanceQueue must remove the episode that ACTUALLY finished (by id), not blindly
    // the head — otherwise a reordered queue drops (and, with delete-on-completion, deletes) the
    // wrong one.
    func testAdvanceRemovesFinishedByIdNotHead() {
        let qm = PodcastQueueManager()
        qm.autoPlay = false
        qm.queue = [makeEpisode("A"), makeEpisode("B"), makeEpisode("C")]

        qm.advanceQueue(finishedEpId: "B")          // B finished, but it's NOT the head
        XCTAssertFalse(qm.queue.contains { $0.id == "B" }, "the finished episode is removed")
        XCTAssertEqual(qm.queue.map(\.id), ["A", "C"], "the head (A) is untouched")
    }

    func testAdvanceWithUnknownIdRemovesNothing() {
        let qm = PodcastQueueManager()
        qm.autoPlay = false
        qm.queue = [makeEpisode("A"), makeEpisode("B")]
        qm.advanceQueue(finishedEpId: "gone")       // already removed elsewhere
        XCTAssertEqual(qm.queue.map(\.id), ["A", "B"], "no id match → drop nothing (don't delete an innocent one)")
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
        qm.loadPodcastFn = { _, id, _, _ in loadedId = id }

        qm.advanceQueue(finishedEpId: "1")
        XCTAssertEqual(qm.queue.count, 2)
        XCTAssertFalse(qm.queue.contains { $0.id == "1" })   // finished head removed
        XCTAssertNotNil(loadedId)
        XCTAssertNotEqual(loadedId, "1")
        XCTAssertEqual(qm.queue.first?.id, loadedId)         // the loaded item is promoted to head
    }

    // Bug 2 (next-track-not-at-zero): an auto-advanced next track must load as a fresh start
    // (resume == false) so it begins at 0, while a user-initiated play resumes (resume == true).
    // This locks in the load-intent flag that the position-poison fix relies on.
    func testLoadIntentFreshOnAdvanceResumeOnPlayEpisode() {
        let qm = PodcastQueueManager()
        qm.autoPlay = true
        qm.shuffleQueue = false
        qm.queue = [makeEpisode("1"), makeEpisode("2")]
        var lastResume: Bool?
        qm.loadPodcastFn = { _, _, _, resume in lastResume = resume }

        qm.advanceQueue(finishedEpId: "1")
        XCTAssertEqual(lastResume, false)   // next queued track starts at the beginning

        qm.playEpisode(makeEpisode("9"))
        XCTAssertEqual(lastResume, true)    // tapping an episode resumes where you left off
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

    // Hermetic + instant: the prune rule is now a pure function, so this no longer writes to the
    // shared StorageManager singleton or waits on a 1-second wall-clock flush (the old version did
    // both — slow and order-dependent).
    func testPositionPruneCapsAt100() {
        var positions: [String: Double] = [:]
        for i in 0..<105 { positions["\(i)"] = Double(i) }

        let pruned = PodcastPlayer.prunedPositions(positions, keeping: "42")
        XCTAssertEqual(pruned.count, 100)
        XCTAssertNotNil(pruned["42"], "the currently-playing id must always be kept")
    }

    func testPositionPruneNoOpUnderCap() {
        let positions = ["a": 1.0, "b": 2.0, "c": 3.0]
        let pruned = PodcastPlayer.prunedPositions(positions, keeping: "a", cap: 100)
        XCTAssertEqual(pruned, positions, "a map already under the cap is returned unchanged")
    }

    func testPositionPruneKeepsCurrentEvenAtBoundary() {
        var positions: [String: Double] = [:]
        for i in 0..<101 { positions["ep\(i)"] = Double(i) }
        let pruned = PodcastPlayer.prunedPositions(positions, keeping: "ep100", cap: 100)
        XCTAssertEqual(pruned.count, 100)
        XCTAssertNotNil(pruned["ep100"], "current id survives even when exactly one over the cap")
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

    // Named-timezone RFC-822 (e.g. "GMT") and ISO-8601 pubDates must parse, not fall back to
    // distantPast (which would sink real episodes to the bottom of the sorted feed).
    func testNamedTimezoneAndISO8601Dates() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss><channel><title>Dates</title>
          <item><title>Named TZ</title><guid>d-1</guid>
            <enclosure url="https://example.com/1.mp3" type="audio/mpeg"/>
            <pubDate>Mon, 02 Jun 2025 08:00:00 GMT</pubDate>
          </item>
          <item><title>ISO</title><guid>d-2</guid>
            <enclosure url="https://example.com/2.mp3" type="audio/mpeg"/>
            <pubDate>2025-06-03T09:30:00Z</pubDate>
          </item>
        </channel></rss>
        """
        let feed = try parse(xml)
        XCTAssertEqual(feed.episodes.count, 2)
        for ep in feed.episodes {
            XCTAssertNotNil(ep.pubDate, "\(ep.title) date should parse")
        }
    }

    // An audio enclosure must win over a transcript/chapters enclosure regardless of order, so a
    // non-audio enclosure can't overwrite the playable URL (it used to be last-wins).
    func testPrefersAudioEnclosureOverNonAudio() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss><channel><title>Enc</title>
          <item><title>Transcript first</title><guid>e-1</guid>
            <enclosure url="https://example.com/transcript.pdf" type="application/pdf"/>
            <enclosure url="https://example.com/audio.mp3" type="audio/mpeg"/>
          </item>
          <item><title>Transcript last</title><guid>e-2</guid>
            <enclosure url="https://example.com/audio2.mp3" type="audio/mpeg"/>
            <enclosure url="https://example.com/notes.html" type="text/html"/>
          </item>
        </channel></rss>
        """
        let feed = try parse(xml)
        let byId = Dictionary(uniqueKeysWithValues: feed.episodes.map { ($0.id, $0) })
        XCTAssertEqual(byId["e-1"]?.audioUrl, "https://example.com/audio.mp3")
        XCTAssertEqual(byId["e-2"]?.audioUrl, "https://example.com/audio2.mp3")
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

// Multi-layer noise — stacking, persistence round-trips, back-compat decode, and mode reconcile.
// Deterministic AudioEngine state (no podcast in any mix → resumeMix never hits the network).
@MainActor
final class NoiseLayeringTests: XCTestCase {

    func testAddExtraLayerRespectsCap() {
        let engine = AudioEngine()
        engine.extraLayers = []
        for _ in 0..<(AudioEngine.maxExtraLayers + 2) { engine.addExtraLayer() }
        XCTAssertEqual(engine.extraLayers.count, AudioEngine.maxExtraLayers)
    }

    func testAddExtraLayerPicksUnusedPaletteSound() {
        let engine = AudioEngine()
        engine.focusMode = false
        engine.noiseType = "brown"
        engine.extraLayers = []
        engine.addExtraLayer()
        XCTAssertNotEqual(engine.extraLayers.first?.type, "brown")  // not a duplicate of primary
        XCTAssertTrue(AudioEngine.sleepNoises.contains(engine.extraLayers.first?.type ?? ""))
    }

    func testApplyPresetRestoresExtraLayers() {
        let engine = AudioEngine()
        engine.focusMode = false
        let preset = SoundPreset(name: "Stack", mode: "sleep",
                                 noiseOn: true, noiseType: "brown", noiseVolume: 0.5,
                                 binauralOn: false, binauralPreset: "delta", binVolume: 0.3,
                                 sceneId: nil,
                                 extraLayers: [ExtraNoiseLayer(type: "rain", volume: 0.4)])
        engine.applyPreset(preset)
        XCTAssertEqual(engine.extraLayers.count, 1)
        XCTAssertEqual(engine.extraLayers.first?.type, "rain")
        XCTAssertEqual(engine.extraLayers.first?.volume ?? 0, 0.4, accuracy: 0.0001)
    }

    // A preset persisted before layering existed has no `extraLayers` key — it must decode to nil
    // and apply as "no extra layers", never crash.
    func testOldPresetWithoutLayersDecodesToNil() throws {
        let json = """
        {"id":"x","name":"Old","mode":"sleep","noiseOn":true,"noiseType":"brown",
        "noiseVolume":0.5,"binauralOn":false,"binauralPreset":"delta","binVolume":0.3}
        """
        let preset = try JSONDecoder().decode(SoundPreset.self, from: Data(json.utf8))
        XCTAssertNil(preset.extraLayers)
        let engine = AudioEngine()
        engine.applyPreset(preset)
        XCTAssertTrue(engine.extraLayers.isEmpty)
    }

    func testSaveAndResumeLastMixRoundTripsLayers() {
        let engine = AudioEngine()
        engine.focusMode = false
        engine.noiseType = "brown"; engine.noiseVolume = 0.5; engine.noiseOn = true
        engine.extraLayers = [ExtraNoiseLayer(type: "rain", volume: 0.35)]
        engine.saveLastMix()
        let mix = engine.lastMix
        XCTAssertEqual(mix?.extraLayers?.count, 1)

        engine.extraLayers = []
        engine.resumeMix(mix!)
        XCTAssertEqual(engine.extraLayers.first?.type, "rain")
        XCTAssertEqual(engine.extraLayers.first?.volume ?? 0, 0.35, accuracy: 0.0001)
    }

    // Modes share no sounds (pink excepted): switching to Focus must drop a Sleep-only extra layer.
    func testModeSwitchDropsCrossModeLayers() {
        let engine = AudioEngine()
        engine.focusMode = false
        engine.noiseType = "brown"
        engine.extraLayers = [ExtraNoiseLayer(type: "rain", volume: 0.3)]   // sleep-only sound
        engine.focusMode = true                                            // → reconcileSoundsToMode
        XCTAssertFalse(engine.extraLayers.contains { $0.type == "rain" })
        XCTAssertTrue(engine.extraLayers.allSatisfy { AudioEngine.focusNoises.contains($0.type) })
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

// Fail-safe backstop: the out-of-process net is scheduled on start, moved on bump, and torn down
// on cancel/fire; and a foreground reconcile fires the terminal stop if the app was suspended
// through a duration deadline. Spy scheduler keeps these deterministic (no UNUserNotificationCenter).
@MainActor
final class SleepTimerBackstopTests: XCTestCase {
    private final class SpyBackstop: SleepTimerBackstopScheduling {
        var scheduledAfter: [TimeInterval] = []
        var cancelCount = 0
        func schedule(after seconds: TimeInterval) { scheduledAfter.append(seconds) }
        func cancel() { cancelCount += 1 }
    }

    func testBackstopScheduledOnStart() {
        let svc = SleepTimerService()
        let spy = SpyBackstop()
        svc.backstop = spy
        svc.startSleepTimer(minutes: 30)
        XCTAssertEqual(spy.scheduledAfter.last, 1800)   // 30 min in seconds
        svc.cancelTimer()
    }

    func testBackstopCancelledOnCancel() {
        let svc = SleepTimerService()
        let spy = SpyBackstop()
        svc.backstop = spy
        svc.startSleepTimer(minutes: 30)
        let before = spy.cancelCount
        svc.cancelTimer()
        XCTAssertGreaterThan(spy.cancelCount, before)
    }

    func testBumpMovesBackstopLater() {
        let svc = SleepTimerService()
        let spy = SpyBackstop()
        svc.backstop = spy
        svc.startSleepTimer(minutes: 30)
        spy.scheduledAfter.removeAll()
        svc.bumpTimer()                                  // +15 min
        XCTAssertEqual(spy.scheduledAfter.count, 1)
        XCTAssertEqual(spy.scheduledAfter.first ?? 0, 2700, accuracy: 2)  // 1800 + 900
        svc.cancelTimer()
    }

    func testReconcileFiresOnceWhenExpired() {
        let svc = SleepTimerService()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.backstop = SpyBackstop()
        svc.startSleepTimer(minutes: 0)                  // deadline == now
        Thread.sleep(forTimeInterval: 0.01)              // ensure now >= end
        svc.reconcileIfExpired()
        XCTAssertEqual(stops, 1)
        svc.reconcileIfExpired()                         // idempotent — must not double-fire
        XCTAssertEqual(stops, 1)
    }

    func testReconcileNoOpWhileRunning() {
        let svc = SleepTimerService()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.backstop = SpyBackstop()
        svc.startSleepTimer(minutes: 30)
        svc.reconcileIfExpired()
        XCTAssertEqual(stops, 0)
        svc.cancelTimer()
    }

    func testReconcileIgnoresEndOfEpisodeTimer() {
        let svc = SleepTimerService()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.backstop = SpyBackstop()
        svc.startEndOfEpisode(remaining: 0.001)          // episode timer, not a duration timer
        Thread.sleep(forTimeInterval: 0.01)
        svc.reconcileIfExpired()                         // reconcile only covers duration timers
        XCTAssertEqual(stops, 0)
        svc.cancelTimer()
    }
}

// The "Turn off timer" control added to the timer sheet relies on cancelTimer() clearing a
// running duration timer *without* firing the terminal stop (cancelling ≠ the fade finishing).
// The sheet's show/hide condition is `timerRemaining > 0`, so that's the value pinned here.
// NoopBackstop keeps it off the real UNUserNotificationCenter.
@MainActor
final class SleepTimerCancelTests: XCTestCase {
    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }

    func testCancelClearsRunningTimer() {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()

        svc.startSleepTimer(minutes: 30)
        XCTAssertGreaterThan(svc.timerRemaining, 0)   // "Turn off timer" button is visible

        svc.cancelTimer()
        XCTAssertEqual(svc.timerRemaining, 0)         // condition flips false → button hides
        XCTAssertFalse(svc.isEndOfEpisode)
    }

    func testCancelDoesNotFireTerminalStop() {
        let svc = SleepTimerService()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.backstop = NoopBackstop()

        svc.startSleepTimer(minutes: 30)
        svc.cancelTimer()
        XCTAssertEqual(stops, 0, "cancelling must not run the stop-all that the fade end does")
    }

    func testCancelTearsDownBackstop() {
        final class SpyBackstop: SleepTimerBackstopScheduling {
            var cancelCount = 0
            func schedule(after seconds: TimeInterval) {}
            func cancel() { cancelCount += 1 }
        }
        let svc = SleepTimerService()
        let spy = SpyBackstop()
        svc.backstop = spy

        svc.startSleepTimer(minutes: 30)
        let before = spy.cancelCount
        svc.cancelTimer()
        XCTAssertGreaterThan(spy.cancelCount, before)  // out-of-process net removed on cancel
    }
}

// First-run "show me the magic" start: the very first tap should bring up a *layered* bed
// (noise + binaural) rather than a single bare noise, so the layering concept is audible.
@MainActor
final class FirstRunDefaultMixTests: XCTestCase {
    func testStartDefaultMixBringsUpLayeredBed() {
        let engine = AudioEngine()
        engine.noiseOn = false
        engine.binauralOn = false
        engine.isPodPlaying = false

        engine.startDefaultMix()
        XCTAssertTrue(engine.noiseOn, "first-run default must include a noise bed")
        XCTAssertTrue(engine.binauralOn, "first-run default must layer in binaural")
        XCTAssertTrue(engine.isAnythingPlaying)
    }
}

// Episode/Podcast identity is the id only. A custom == with a synthesized hash(into:) over all
// fields would break the Hashable contract (equal values, unequal hashes) — corrupting Set/dict use.
final class ModelIdentityTests: XCTestCase {
    func testEpisodeEqualityAndHashUseIdOnly() {
        let a = Episode(id: "x", title: "A", audioUrl: "u1", duration: 1, pubDate: nil, description: nil)
        let b = Episode(id: "x", title: "B-different", audioUrl: "u2", duration: 99, pubDate: Date(), description: "notes")
        let c = Episode(id: "y", title: "A", audioUrl: "u1", duration: 1, pubDate: nil, description: nil)

        XCTAssertEqual(a, b, "same id must be equal regardless of other fields")
        XCTAssertEqual(a.hashValue, b.hashValue, "equal values must share a hash")
        XCTAssertNotEqual(a, c)

        var set: Set<Episode> = [a]
        XCTAssertTrue(set.contains(b), "Set membership must follow ==/hash (broke with synthesized hash)")
        set.insert(b)
        XCTAssertEqual(set.count, 1, "inserting an equal value must not grow the set")
    }

    func testPodcastEqualityAndHashUseIdOnly() {
        let e1 = Episode(id: "1", title: "t", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        let p1 = Podcast(id: "p", name: "N", url: "feed", episodes: [e1])
        let p2 = Podcast(id: "p", name: "N2-diff", url: "feed2", episodes: [])

        XCTAssertEqual(p1, p2, "same id must be equal regardless of episodes")
        XCTAssertEqual(p1.hashValue, p2.hashValue)
    }
}

// OPML import hardening: only http(s) feeds, deduped, with a stable url-based id.
final class OPMLParserTests: XCTestCase {
    private func parse(_ opml: String) throws -> [OPMLFeed] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).opml")
        try Data(opml.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return OPMLParser().parse(url: url)
    }

    func testValidatesSchemeDedupesAndUsesStableId() throws {
        let opml = """
        <?xml version="1.0"?>
        <opml version="1.0"><body>
          <outline text="Show A" type="rss" xmlUrl="https://a.example/feed"/>
          <outline text="Show A dup" type="rss" xmlUrl="https://a.example/feed"/>
          <outline text="Bad scheme" type="rss" xmlUrl="javascript:alert(1)"/>
          <outline text="Local file" type="rss" xmlUrl="file:///etc/passwd"/>
          <outline text="Show B" type="rss" xmlUrl="http://b.example/feed"/>
          <outline text="Folder only"/>
        </body></opml>
        """
        let feeds = try parse(opml)
        XCTAssertEqual(feeds.map(\.url), ["https://a.example/feed", "http://b.example/feed"],
                       "http(s) only, deduped, order preserved")
        XCTAssertEqual(feeds.first?.id, "https://a.example/feed", "id must be the stable feed url")
        XCTAssertEqual(feeds.first?.name, "Show A")
    }

    // A truncated/corrupt OPML must not crash or hang — feeds parsed before the malformed
    // point are still returned (XMLParser stops there; the parse failure is logged).
    func testCorruptOPMLKeepsFeedsParsedBeforeError() throws {
        let opml = """
        <?xml version="1.0"?>
        <opml version="1.0"><body>
          <outline text="Show A" type="rss" xmlUrl="https://a.example/feed"/>
          <outline text="Broken
        """
        let feeds = try parse(opml)
        XCTAssertEqual(feeds.map(\.url), ["https://a.example/feed"],
                       "feeds before the malformed point survive a corrupt OPML")
    }

    func testMissingFileReturnsEmpty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-nonexistent.opml")
        XCTAssertEqual(OPMLParser().parse(url: url).count, 0)
    }
}

// MARK: - Ambient tail integrity (the "+15m mid-tail volume blast" fix)

/// The ambient tail must never be interrupted by a lock-screen "+15m": bumpTimer used to snap
/// the fade multiplier to 1.0 — an already-faded bed popping to full volume mid-drift-off —
/// and then freeze near-silent for the added span. The intent is now dropped while in-tail
/// (the Live Activity also hides the button via ContentState.isInTail).
final class SleepTimerTailTests: XCTestCase {
    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }

    /// Reference box for recording fade updates — the stored closure outlives the helper
    /// call, so an inout-to-pointer capture here would be undefined behavior.
    private final class FadeLog {
        var values: [Double] = []
    }

    /// Drives an end-of-episode timer to its expiry so the service hands off to the tail
    /// (externalTick runs synchronously on the calling thread — no waits needed).
    private func serviceInTail(fadeLog: FadeLog? = nil) -> SleepTimerService {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()
        svc.ambientTailFn = { 300 }
        svc.tailEligibleFn = { true }
        svc.stopPodcastFn = { }
        if let fadeLog {
            svc.updateFadeMultFn = { fadeLog.values.append($0) }
        }
        svc.startEndOfEpisode(remaining: 60)
        svc.externalTick(remaining: 0.3)   // episode over → tail handoff
        return svc
    }

    func testEpisodeEndHandsOffToTailInsteadOfStopping() {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()
        var stops = 0
        var podcastStops = 0
        svc.stopAllFn = { stops += 1 }
        svc.stopPodcastFn = { podcastStops += 1 }
        svc.ambientTailFn = { 300 }
        svc.tailEligibleFn = { true }

        svc.startEndOfEpisode(remaining: 60)
        svc.externalTick(remaining: 0.3)

        XCTAssertEqual(podcastStops, 1, "the tail silences only the podcast")
        XCTAssertEqual(stops, 0, "the terminal stop must wait for the tail to run out")
        XCTAssertEqual(svc.timerRemaining, 300, accuracy: 1.5, "deadline extended by the tail span")
        svc.cancelTimer()
    }

    func testBumpIsDroppedDuringTail() {
        let fades = FadeLog()
        let svc = serviceInTail(fadeLog: fades)
        XCTAssertTrue(svc.inTail, "handoff must publish inTail so bump surfaces can hide")
        let before = svc.timerRemaining
        fades.values.removeAll()

        svc.bumpTimer()

        XCTAssertEqual(svc.timerRemaining, before, accuracy: 0.5,
                       "+15m must not extend the tail")
        XCTAssertTrue(fades.values.isEmpty,
                      "bump-in-tail must not touch the fade — the old path snapped it to 1.0")
        svc.cancelTimer()
        XCTAssertFalse(svc.inTail, "cancel must clear the tail so bump surfaces can return")
    }

    func testBumpStillWorksBeforeTheTail() {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()
        svc.startSleepTimer(minutes: 30)
        let before = svc.timerRemaining

        svc.bumpTimer()

        XCTAssertEqual(svc.timerRemaining, before + 900, accuracy: 1.5)
        svc.cancelTimer()
    }
}

// MARK: - Pomodoro continuous ring progress

/// The Focus ring depletes off the phase end-date via `progress(at:)` (smooth) rather than the
/// 1 Hz-published `progress` (stepped). Verify the continuous form tracks elapsed time and is
/// inert when idle.
final class PomodoroProgressTests: XCTestCase {
    func testContinuousProgressTracksElapsed() {
        let p = PomodoroService()
        p.workMinutes = 10          // 600 s work phase
        p.start()
        defer { p.stop() }          // cancel the real GCD timer

        // Just started → ~0 elapsed; halfway/threequarter points track linearly.
        XCTAssertEqual(p.progress(at: Date()), 0.0, accuracy: 0.02)
        XCTAssertEqual(p.progress(at: Date().addingTimeInterval(300)), 0.5, accuracy: 0.02)
        XCTAssertEqual(p.progress(at: Date().addingTimeInterval(450)), 0.75, accuracy: 0.02)
    }

    func testContinuousProgressClampsAndIdles() {
        let p = PomodoroService()
        p.workMinutes = 10
        // Idle: no phase running → 0, and it must not read a stale phaseEnd.
        XCTAssertEqual(p.progress(at: Date().addingTimeInterval(9999)), 0.0, accuracy: 1e-9)

        p.start()
        defer { p.stop() }
        // Past the phase end → clamped to 1, never overshoots.
        XCTAssertEqual(p.progress(at: Date().addingTimeInterval(10_000)), 1.0, accuracy: 1e-9)
    }

    func testPhaseElapsedDrivesTheBoundaryRefill() {
        let p = PomodoroService()
        p.workMinutes = 10
        // Idle → 0 (no refill outside a session).
        XCTAssertEqual(p.phaseElapsed(at: Date().addingTimeInterval(5)), 0.0, accuracy: 1e-9)

        p.start()
        defer { p.stop() }
        // Anchor to a reference taken AFTER start() returns, and assert on DELTAS from it.
        // `start()` schedules a local notification + a Live Activity (both IPC) after capturing
        // phaseEnd, so `phaseElapsed(at: Date())` is really "how long start()'s tail took" — a
        // machine-load-dependent 60–80 ms here, which made the old absolute ±0.05 s assertion fail
        // intermittently. The deltas below are exact arithmetic against the same phaseEnd, so they
        // pin the real contract (the refill advances 1:1 with wall-clock) with no timing race.
        let ref = Date()
        let base = p.phaseElapsed(at: ref)
        // Arc starts empty at the boundary — small, not exactly 0 (see above); a loose bound still
        // catches a real regression (returning phaseTotal, a negative, or a wildly wrong origin).
        XCTAssertGreaterThanOrEqual(base, 0)
        XCTAssertLessThan(base, 1.0)
        XCTAssertEqual(p.phaseElapsed(at: ref.addingTimeInterval(0.5)) - base, 0.5, accuracy: 1e-6)
        XCTAssertEqual(p.phaseElapsed(at: ref.addingTimeInterval(120)) - base, 120, accuracy: 1e-6)
    }
}

// MARK: - Resume / persistence integrity

/// "Resume Last Night" must restore the exact recipe faithfully — including a muted extra layer,
/// which the four rebuild maps used to drop. Resume deliberately does NOT reconcile to the current
/// mode (see resumeMix's NOTE): a SavedMix carries no mode, so snapping would corrupt a cross-mode
/// mix. These tests use Sleep-valid inputs so "faithful" is unambiguous.
@MainActor
final class ResumeIntegrityTests: XCTestCase {
    private func lastNight(noiseType: String, layers: [ExtraNoiseLayer]) -> SavedMix {
        SavedMix(name: "Last Night", noiseOn: true, noiseVolume: 0.4, noiseType: noiseType,
                 binauralOn: false, binVolume: 0.3, binauralPreset: "delta", podVolume: 0.7,
                 podcastUrl: nil, podcastId: nil, extraLayers: layers)
    }

    func testResumePreservesMutedLayer() {
        let engine = AudioEngine()
        engine.focusMode = false
        engine.resumeMix(lastNight(noiseType: "brown",
                                   layers: [ExtraNoiseLayer(id: "L1", type: "rain", volume: 0.5, muted: true)]))
        XCTAssertEqual(engine.extraLayers.first?.type, "rain")
        XCTAssertEqual(engine.extraLayers.first?.muted, true,
                       "muted must survive the rebuild map — it used to un-mute on resume")
    }

    func testResumeRestoresSoundFaithfully() {
        // Resume is faithful: it restores the saved sound as-is and does NOT reconcile to the
        // current mode (a SavedMix carries no mode; snapping would corrupt a cross-mode mix).
        let engine = AudioEngine()
        engine.focusMode = false
        engine.resumeMix(lastNight(noiseType: "green", layers: []))   // green is a valid Sleep sound
        XCTAssertEqual(engine.noiseType, "green")
    }
}
