import XCTest
import AVFoundation
import SwiftUI
import Combine
#if canImport(ActivityKit)
import ActivityKit
#endif
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

    func testEachModeKeepsItsOwnPickAcrossARoundTrip() {
        // Brown used to come back from Focus as Pink: Focus snapped it to Pink, which Sleep also has.
        let engine = AudioEngine()
        engine.focusMode = false
        engine.noiseType = "brown"
        engine.binauralPreset = "theta"
        engine.focusMode = true
        XCTAssertTrue(AudioEngine.focusNoises.contains(engine.noiseType))
        engine.noiseType = "white"
        engine.focusMode = false
        XCTAssertEqual(engine.noiseType, "brown")
        XCTAssertEqual(engine.binauralPreset, "theta")
        engine.focusMode = true
        XCTAssertEqual(engine.noiseType, "white", "Focus keeps its own pick too")
        engine.focusMode = false
        for kind in ["noise", "binaural"] {
            for focus in [false, true] { UserDefaults.standard.removeObject(forKey: AudioEngine.pickKey(kind, focus: focus)) }
        }
    }

    func testLandingPrefersTheModesOwnPickThenTheCurrentSound() {
        let focus = AudioEngine.focusNoises
        XCTAssertEqual(AudioEngine.landing(current: "pink", remembered: "white", palette: focus, fallback: "brown"), "white")
        XCTAssertEqual(AudioEngine.landing(current: "pink", remembered: nil, palette: focus, fallback: "brown"), "pink")
        XCTAssertEqual(AudioEngine.landing(current: "brown", remembered: "rain", palette: focus, fallback: "brown"), focus.first,
                       "neither belongs: the palette's first")
        XCTAssertEqual(AudioEngine.landing(current: "x", remembered: nil, palette: [], fallback: "brown"), "brown",
                       "an emptied palette never crashes the all-night path")
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

    /// A deadline that passed during a pause (the ticks stopped with the sound) is found by the
    /// first tick after Play: stopped as the morning foreground would, reconciled and ended at the
    /// deadline, so it never counts as a clean night. One reached while playing isn't.
    func testATickThatFindsTheDeadlineLongPastStopsItAsReconciled() throws {
        for (late, reconciled, tail) in [(1.0, false, false), (SleepTimerService.overdueAfter + 25, true, false),
                                         (SleepTimerService.overdueAfter + 25, true, true)] {
            let svc = SleepTimerService()
            svc.backstop = SpyBackstop()
            // A tail set and eligible (a call's end brought back the bed and the podcast): an
            // overdue deadline still stops at once, as the morning foreground's does.
            svc.ambientTailFn = { tail ? 15 * 60 : 0 }
            svc.tailEligibleFn = { tail }
            svc.stopPodcastFn = { }
            var stops: [(reconciled: Bool, endedAt: Date)] = []
            svc.onTerminalStop = { _, r, at in stops.append((r, at)) }
            svc.startSleepTimer(minutes: 1)
            // The deadline the timer stored. One taken here, after start returned, ran up to 3 s
            // late when the Live Activity request stalled, and failed the ±2 s check below.
            let deadline = try XCTUnwrap(svc.sleepTimerEnd)
            svc.handleTick(at: deadline.addingTimeInterval(late))
            XCTAssertEqual(stops.map(\.reconciled), [reconciled], "\(late) s late, tail \(tail)")
            XCTAssertFalse(svc.inTail, "an overdue deadline began the ambient tail")
            if reconciled {
                XCTAssertEqual(stops.first?.endedAt.timeIntervalSince(deadline) ?? 99, 0, accuracy: 2,
                               "the night ended at the deadline, not at the Play")
            }
            svc.handleTick(at: deadline.addingTimeInterval(late + 1))
            XCTAssertEqual(stops.count, 1)                   // once
        }
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

// Regression for the 47-test SIGABRT on the iOS 26.3 simulator. Under SWIFT_DEFAULT_ACTOR_ISOLATION
// = MainActor a class WITHOUT an explicit deinit gets an implicit main-actor-*isolated* one, and on
// the iOS 18.4–26.3 Swift runtimes that path aborts ("pointer being freed was not allocated", in
// TaskLocal::StopLookupScope — swiftlang/swift 29245e4) when it runs synchronously on the main
// thread while a task-local is bound outside any Task. XCTest binds one around every sync test, so
// every AudioEngine teardown crashed. The engine's subtree, SceneClock and StorageManager opt out
// with `nonisolated deinit {}`; this binds its own task-local so the trigger doesn't depend on
// XCTest internals. A fixed runtime (26.4+) passes regardless — run it on a 26.3 sim to exercise it.
private enum DeinitProbe {
    @TaskLocal static var value = 0
}

@MainActor
final class IsolatedDeinitRuntimeBugTests: XCTestCase {
    func testTeardownInsideSyncTaskLocalBindingDoesNotAbort() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IsolatedDeinit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        weak var weakEngine: AudioEngine?
        weak var weakClock: SceneClock?
        weak var weakStore: StorageManager?
        DeinitProbe.$value.withValue(1) {
            let engine = AudioEngine()
            let clock = SceneClock()
            let store = StorageManager(directory: dir)
            weakEngine = engine
            weakClock = clock
            weakStore = store
        }   // all released here, still inside the binding — the crashing path pre-fix
        XCTAssertNil(weakEngine, "engine must be freed inside the binding or this test proves nothing")
        XCTAssertNil(weakClock, "clock must be freed inside the binding or this test proves nothing")
        XCTAssertNil(weakStore, "store must be freed inside the binding or this test proves nothing")
    }
}

// Episode/Podcast hash on the id only. A custom == with a synthesized hash(into:) over all
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

    /// The stale-row regression: each row-visible field alone must break equality, or SwiftUI
    /// keeps showing "40 unplayed · 40" after the show page loaded 750 episodes.
    func testPodcastEqualitySeesEachRowFieldAlone() {
        let e1 = Episode(id: "1", title: "t", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        let e2 = Episode(id: "2", title: "t2", audioUrl: "u2", duration: nil, pubDate: nil, description: nil)
        let base = Podcast(id: "p", name: "N", url: "feed", episodes: [e1])
        let more = Podcast(id: "p", name: "N", url: "feed", episodes: [e2, e1])
        XCTAssertNotEqual(base, more, "the page loaded more episodes")
        XCTAssertNotEqual(base, Podcast(id: "p", name: "N", url: "feed", episodes: [e2]), "newest changed, same count")
        XCTAssertNotEqual(base, Podcast(id: "p", name: "N", url: "feed", episodes: [e1], artworkUrl: "art"), "artwork arrived")
        XCTAssertNotEqual(base, Podcast(id: "p", name: "Real Title", url: "feed", episodes: [e1]), "placeholder name replaced")
        XCTAssertEqual(base.hashValue, more.hashValue)
    }

    func testMergeFoldsAFeedIntoAStoredShow() {
        let e1 = Episode(id: "1", title: "t", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        var stub = Podcast(id: "https://feeds.example.com/a", name: "feeds.example.com", url: "https://feeds.example.com/a", episodes: [])
        stub.merge(title: "Real Show", artworkUrl: "art", episodes: [e1])
        XCTAssertEqual(stub.name, "Real Show")
        XCTAssertEqual(stub.artworkUrl, "art")
        XCTAssertEqual(stub.episodes.map(\.id), ["1"])
        // A feed that came back empty keeps the stored episodes and reports it.
        var kept = Podcast(id: "k", name: "Show", url: "https://feeds.example.com/k", episodes: [e1])
        XCTAssertFalse(kept.merge(title: "Show", artworkUrl: nil, episodes: []))
        XCTAssertEqual(kept.episodes.map(\.id), ["1"], "an empty refresh must not wipe the show")
        var named = Podcast(id: "x", name: "My Name", url: "https://feeds.example.com/x", episodes: [], artworkUrl: "mine")
        named.merge(title: "Feed Title", artworkUrl: "theirs", episodes: [])
        XCTAssertEqual(named.name, "My Name", "a real name is kept")
        XCTAssertEqual(named.artworkUrl, "mine", "existing artwork is kept")
    }

    /// Podcast hashes by id alone, but == also compares what the library row shows: SwiftUI drops
    /// a state update whose new value == the old, so id-only equality left a show's row stale
    /// after its page loaded more episodes. The Hashable contract still holds (equal ⇒ same id ⇒
    /// same hash).
    func testPodcastHashUsesIdAndEqualitySeesRowContent() {
        let e1 = Episode(id: "1", title: "t", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        let p1 = Podcast(id: "p", name: "N", url: "feed", episodes: [e1])
        let p2 = Podcast(id: "p", name: "N2-diff", url: "feed2", episodes: [])

        XCTAssertNotEqual(p1, p2, "a refreshed or renamed show must not compare equal to the stale row")
        XCTAssertEqual(p1.hashValue, p2.hashValue, "hashing stays on the id")
        XCTAssertEqual(p1, Podcast(id: "p", name: "N", url: "feed", episodes: [e1]))

        var set: Set<Podcast> = [p1]
        XCTAssertTrue(set.contains(Podcast(id: "p", name: "N", url: "feed", episodes: [e1])))
        set.insert(p1)
        XCTAssertEqual(set.count, 1)
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

    // The player's end-of-item report reaches the same hand-off as the last clock tick: the 1 Hz tick
    // only lands in the final 0.4 s on some episodes, and the report path used to hard-stop.
    func testTheEndOfItemReportAlsoStartsTheTail() {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.stopPodcastFn = { }
        svc.ambientTailFn = { 300 }
        svc.tailEligibleFn = { true }
        svc.startEndOfEpisode(remaining: 60)
        svc.episodeEnded()
        XCTAssertTrue(svc.inTail)
        XCTAssertEqual(stops, 0)
        svc.episodeEnded()   // the other path arriving second changes nothing
        XCTAssertTrue(svc.inTail)
        XCTAssertEqual(stops, 0)
        svc.cancelTimer()
    }

    func testEpisodeEndWithoutATailStopsOnce() {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()
        var stops = 0
        svc.stopAllFn = { stops += 1 }
        svc.ambientTailFn = { 0 }
        svc.startEndOfEpisode(remaining: 60)
        svc.episodeEnded()
        svc.externalTick(remaining: 0.2)
        XCTAssertEqual(stops, 1)
    }

    // Regression: AirPods out paused the podcast but kept the sounds; a stop-with-episode timer only
    // counted on the playback clock, so it never ran out and the sounds played all night.
    func testPausingTheEpisodeMovesItsTimerToTheWallClock() {
        let svc = SleepTimerService()
        svc.backstop = NoopBackstop()
        svc.startEndOfEpisode(remaining: 600)
        svc.podcastPaused()
        XCTAssertFalse(svc.isEndOfEpisode, "now a duration timer the wall clock ends")
        XCTAssertEqual(svc.timerRemaining, 600, accuracy: 1)
        svc.podcastPaused()   // already converted: nothing more
        XCTAssertFalse(svc.isEndOfEpisode)
        svc.cancelTimer()
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
        // `start()` schedules a local notification + a Live Activity (both IPC) after stamping
        // phaseShownAt, so `phaseElapsed(at: Date())` is really "how long start()'s tail took" — a
        // machine-load-dependent 60–80 ms here, which made the old absolute ±0.05 s assertion fail
        // intermittently. The deltas below are exact arithmetic against the same phaseShownAt, so they
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

// MARK: - Pomodoro boundaries passed while suspended

/// A silent Focus session's app is suspended while the phone is locked, so the first tick after
/// unlock can come long after a phase boundary. The next phase runs from the boundary itself, and
/// every boundary passed meanwhile counts. Ticks go through `handleTick(at:)` at chosen times,
/// measured from the session's own `phaseEnd`.
@MainActor
final class PomodoroMissedBoundaryTests: XCTestCase {
    private var chimes = 0
    private var phaseChanges: [(PomodoroService.Phase, Bool)] = []

    /// A running session with these lengths. They persist (`didSet`), so the saved ones come back
    /// after the test.
    private func session(work: Int = 25, rest: Int = 5, longRest: Int = 15, cycles: Int = 4) -> PomodoroService {
        let d = UserDefaults.standard
        let keys = ["pomoWork", "pomoRest", "pomoLongRest", "pomoCycles"]
        let saved = keys.map { d.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) { if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) } }
        }
        let p = PomodoroService()
        (p.workMinutes, p.restMinutes, p.longRestMinutes, p.cyclesBeforeLongBreak) = (work, rest, longRest, cycles)
        p.chimeFn = { [unowned self] in self.chimes += 1 }
        p.phaseChangedFn = { [unowned self] phase, running in self.phaseChanges.append((phase, running)) }
        p.start()
        chimes = 0
        phaseChanges = []
        return p
    }

    // Value: protects=a boundary found late starts the break at the boundary, with the time left from there; fails_when=advancePhase starts the next phase at the tick (Date()) again; why_new=the late start was only on device, nothing ticked at a chosen time; seam=handleTick(at:); no_claim=the GCD timer's suspension, the notification's timing, the Live Activity's display
    func testABoundaryPassedWhileSuspendedStartsTheBreakAtTheBoundary() throws {
        let p = session()
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)

        p.handleTick(at: workEnd.addingTimeInterval(120))   // unlocked 2 min into the break

        XCTAssertEqual(p.phase, .rest)
        XCTAssertEqual(p.completedCycles, 1)
        XCTAssertFalse(p.restIsLong)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(workEnd), 300, accuracy: 1e-6, "the break runs from the boundary")
        XCTAssertEqual(p.remaining, 180, accuracy: 1e-6)
        XCTAssertEqual(p.progress(at: workEnd.addingTimeInterval(120)), 0.4, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(phaseChanges.map { $0.0 }, [.rest])
    }

    // Value: protects=two boundaries passed while suspended land in the next work interval, its time counted from the break's end, with one chime; fails_when=the catch-up takes only one boundary (stuck in a break that's over) or chimes per boundary; why_new=nothing covered more than one boundary per tick; seam=handleTick(at:); no_claim=the notification for the second boundary (none is scheduled while suspended)
    func testTwoBoundariesPassedWhileSuspendedLandInTheNextWorkInterval() throws {
        let p = session()
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)
        let breakEnd = workEnd.addingTimeInterval(300)

        p.handleTick(at: breakEnd.addingTimeInterval(60))   // a minute into the second work interval

        XCTAssertEqual(p.phase, .work)
        XCTAssertEqual(p.completedCycles, 1, "one work interval finished; the second is under way")
        XCTAssertFalse(p.restIsLong)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(breakEnd), 1500, accuracy: 1e-6)
        XCTAssertEqual(p.remaining, 1440, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1, "one chime for the catch-up, not one per boundary")
        XCTAssertEqual(phaseChanges.count, 1)
        XCTAssertEqual(phaseChanges.first?.0, .work)
        XCTAssertEqual(phaseChanges.first?.1, true)
    }

    // Value: protects=a catch-up counts every finished work interval, so a long break falls due on the wall clock; fails_when=completedCycles or restIsLong is set once per catch-up instead of per boundary; why_new=the long-break count across a catch-up was untested; seam=handleTick(at:); no_claim=CycleDots' drawing
    func testACatchUpThroughThreeBoundariesReachesTheLongBreak() throws {
        let p = session(cycles: 2)
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)
        let secondWorkEnd = workEnd.addingTimeInterval(300 + 1500)

        p.handleTick(at: secondWorkEnd.addingTimeInterval(100))

        XCTAssertEqual(p.phase, .rest)
        XCTAssertTrue(p.restIsLong, "the second work interval earned the long break")
        XCTAssertEqual(p.completedCycles, 2)
        XCTAssertEqual(p.remaining, 900 - 100, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
    }

    // Value: protects=an on-time tick still steps one phase and the ring's refill eases in from the tick; fails_when=phaseElapsed measures from the phase's start again (a tick 0.7 s late skips the 0.5 s ease) or the loop overshoots a phase; why_new=starting phases at the boundary moved the start before the tick; seam=handleTick(at:); no_claim=FocusHero's drawing
    func testAnOnTimeTickStepsOnePhaseAndTheRefillStartsAtTheTick() throws {
        let p = session()
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)
        let tick = workEnd.addingTimeInterval(0.7)

        p.handleTick(at: tick)

        XCTAssertEqual(p.phase, .rest)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(workEnd), 300, accuracy: 1e-6)
        XCTAssertEqual(p.phaseElapsed(at: tick), 0, accuracy: 1e-9, "the ring's refill starts when the phase comes up")
        XCTAssertEqual(p.phaseElapsed(at: tick.addingTimeInterval(0.25)), 0.25, accuracy: 1e-6)
    }

    // Value: protects=a tick before the boundary only counts down; fails_when=handleTick flips on r > 0; why_new=handleTick(at:) is new; seam=handleTick(at:); no_claim=none
    func testATickBeforeTheBoundaryOnlyCountsDown() throws {
        let p = session()
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)

        p.handleTick(at: workEnd.addingTimeInterval(-30))

        XCTAssertEqual(p.phase, .work)
        XCTAssertEqual(p.completedCycles, 0)
        XCTAssertEqual(p.remaining, 30, accuracy: 1e-6)
        XCTAssertEqual(chimes, 0)
    }

    // Value: protects=End interval / Skip break start the next phase now at its full length (a skipped focus interval still counts its round), one chime each, and do nothing when idle; fails_when=skipPhase hands advancePhase the old phase's end (the skipped time lands on the next phase) or chimes twice; why_new=no test called skipPhase, and this diff rewired it; seam=none; no_claim=the button, FocusHero's refill drawing, the notification and Live Activity
    func testASkipStartsTheNextPhaseNowAtItsFullLength() throws {
        let p = session()
        defer { p.stop() }
        let before = Date()
        p.skipPhase()                                    // End interval, 25 min early
        let after = Date()

        XCTAssertEqual(p.phase, .rest)
        XCTAssertEqual(p.completedCycles, 1, "a skipped interval still counts its round")
        XCTAssertEqual(p.remaining, 300, accuracy: 1e-6, "the whole break, from the tap")
        let end = try XCTUnwrap(p.phaseEnd)
        XCTAssertGreaterThanOrEqual(end.timeIntervalSince(before), 300 - 1e-6)
        XCTAssertLessThanOrEqual(end.timeIntervalSince(after), 300 + 1e-6)
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(phaseChanges.map { $0.0 }, [.rest])

        p.skipPhase()                                    // Skip break
        XCTAssertEqual(p.phase, .work)
        XCTAssertEqual(p.remaining, 1500, accuracy: 1e-6)
        XCTAssertEqual(p.completedCycles, 1)
        XCTAssertEqual(chimes, 2)

        p.stop()
        p.skipPhase()                                    // idle: nothing to skip
        XCTAssertFalse(p.isRunning)
        XCTAssertEqual(chimes, 2)
    }

    // Value: protects=a Skip tapped after the phase already ended (before the catch-up tick) catches up instead of skipping from the stale phase; fails_when=skipPhase always starts the next phase at the tap; why_new=the review found the late start on the skip path; seam=skipPhase(at:); no_claim=when the first tick after unlock runs
    func testASkipAfterThePhaseEndedCatchesUpInstead() throws {
        let p = session()
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)

        p.skipPhase(at: workEnd.addingTimeInterval(120))   // End interval, tapped before the catch-up tick

        XCTAssertEqual(p.phase, .rest)
        XCTAssertEqual(p.completedCycles, 1)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(workEnd), 300, accuracy: 1e-6, "the break still runs from the boundary")
        XCTAssertEqual(p.remaining, 180, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
    }

    // Value: protects=a tick exactly on the boundary is past it; fails_when=handleTick's `r <= 0` becomes `< 0`; why_new=no tick landed exactly on a boundary; seam=handleTick(at:); no_claim=none beyond protects
    func testATickExactlyOnTheBoundaryIsPastIt() throws {
        let p = session()
        defer { p.stop() }
        let workEnd = try XCTUnwrap(p.phaseEnd)

        p.handleTick(at: workEnd)

        XCTAssertEqual(p.phase, .rest)
        XCTAssertEqual(p.remaining, 300, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
    }

    // Value: protects=a catch-up landing exactly on a later boundary ends in the phase after it, with one chime and none a second later; fails_when=the catch-up stops on a phase that ends at the tick (its end compared with `>=` instead of `>`); why_new=no tick landed exactly on a later boundary; seam=handleTick(at:); no_claim=none beyond protects
    func testATickExactlyOnALaterBoundaryLandsInThePhaseAfterIt() throws {
        let p = session()
        defer { p.stop() }
        let breakEnd = try XCTUnwrap(p.phaseEnd).addingTimeInterval(300)

        p.handleTick(at: breakEnd)

        XCTAssertEqual(p.phase, .work, "a break that ended at the tick is over")
        XCTAssertEqual(p.completedCycles, 1)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(breakEnd), 1500, accuracy: 1e-6)
        XCTAssertEqual(p.remaining, 1500, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
        p.handleTick(at: breakEnd.addingTimeInterval(1))
        XCTAssertEqual(chimes, 1, "no second chime a second later")
    }

    // Value: protects=a catch-up past a long break starts the next set: the long break is cleared and only focus intervals count; fails_when=the break-to-focus step stops clearing restIsLong, or counts a round for a break; why_new=no test passed a long break's end; seam=handleTick(at:); no_claim=CycleDots' drawing
    func testACatchUpPastALongBreakStartsTheNextSet() throws {
        let p = session(cycles: 2)
        defer { p.stop() }
        let longBreakEnd = try XCTUnwrap(p.phaseEnd).addingTimeInterval(300 + 1500 + 900)

        p.handleTick(at: longBreakEnd.addingTimeInterval(60))

        XCTAssertEqual(p.phase, .work)
        XCTAssertFalse(p.restIsLong, "the long break is over")
        XCTAssertEqual(p.completedCycles, 2)
        XCTAssertEqual(p.remaining, 1500 - 60, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
    }

    // Value: protects=a tick past a break's end starts focus at the break's end, counting no round; fails_when=the walk from a break starts focus at the tick, or counts the break as a round; why_new=every tick test started its walk in focus; seam=handleTick(at:); no_claim=the bed's return to full volume (AudioEngine)
    func testATickPastTheBreaksEndStartsFocusAtTheBreaksEnd() throws {
        let p = session()
        defer { p.stop() }
        p.handleTick(at: try XCTUnwrap(p.phaseEnd))                 // into the short break
        let breakEnd = try XCTUnwrap(p.phaseEnd)
        chimes = 0
        phaseChanges = []

        p.handleTick(at: breakEnd.addingTimeInterval(30))

        XCTAssertEqual(p.phase, .work)
        XCTAssertEqual(p.completedCycles, 1)
        XCTAssertFalse(p.restIsLong)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(breakEnd), 1500, accuracy: 1e-6)
        XCTAssertEqual(p.remaining, 1470, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(phaseChanges.first?.0, .work)
        XCTAssertEqual(phaseChanges.first?.1, true)
    }

    // Value: protects=a catch-up that starts in a short break counts the focus interval it passed and lands in the next break, timed from the boundaries; fails_when=the walk from a break miscounts rounds or times the landing from the tick; why_new=every catch-up test started in focus, though a lock in a break is as likely; seam=handleTick(at:); no_claim=none beyond protects
    func testACatchUpFromAShortBreakCountsTheFocusIntervalItPassed() throws {
        let p = session()
        defer { p.stop() }
        p.handleTick(at: try XCTUnwrap(p.phaseEnd))                 // into the short break
        let breakEnd = try XCTUnwrap(p.phaseEnd)
        chimes = 0
        phaseChanges = []

        p.handleTick(at: breakEnd.addingTimeInterval(1500 + 60))   // locked through the break's end and the next focus interval

        XCTAssertEqual(p.phase, .rest)
        XCTAssertEqual(p.completedCycles, 2)
        XCTAssertFalse(p.restIsLong)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(breakEnd), 1800, accuracy: 1e-6)
        XCTAssertEqual(p.remaining, 240, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(phaseChanges.map { $0.0 }, [.rest])
    }

    // Value: protects=Skip break in a long break starts focus now at full length and clears the long break, counting no round; fails_when=a skip from a long break keeps restIsLong or counts a round; why_new=no test skipped a long break; seam=skipPhase(at:); no_claim=CycleDots' drawing
    func testSkippingALongBreakStartsFocusAndClearsIt() throws {
        let p = session(cycles: 2)
        defer { p.stop() }
        p.handleTick(at: try XCTUnwrap(p.phaseEnd).addingTimeInterval(300 + 1500))   // into the long break
        XCTAssertTrue(p.restIsLong)
        let tap = try XCTUnwrap(p.phaseEnd).addingTimeInterval(-840)                // a minute into it
        chimes = 0
        phaseChanges = []

        p.skipPhase(at: tap)

        XCTAssertEqual(p.phase, .work)
        XCTAssertFalse(p.restIsLong)
        XCTAssertEqual(p.completedCycles, 2)
        XCTAssertEqual(try XCTUnwrap(p.phaseEnd).timeIntervalSince(tap), 1500, accuracy: 1e-6)
        XCTAssertEqual(p.remaining, 1500, accuracy: 1e-6)
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(phaseChanges.map { $0.0 }, [.work])
    }

    // Value: protects=a catch-up over thousands of boundaries lands exactly and publishes a fixed number of times; fails_when=the walk writes @Published per boundary again, or the round count drifts over many sets; why_new=every catch-up test crossed 4 boundaries or fewer and none watched objectWillChange; seam=handleTick(at:); no_claim=SwiftUI's render cost
    func testAClockJumpOverThousandsOfBoundariesLandsExactlyAndPublishesOnce() throws {
        let p = session()   // 25/5/15, 4 rounds: one set is 4 × 1500 + 3 × 300 + 900 = 7800 s
        defer { p.stop() }
        let sessionStart = try XCTUnwrap(p.phaseEnd).addingTimeInterval(-1500)
        var willChanges = 0
        let sub = p.objectWillChange.sink { willChanges += 1 }
        defer { sub.cancel() }

        p.handleTick(at: sessionStart.addingTimeInterval(7800 * 1000 + 60))   // ~90 days: 1,000 sets, 8,000 boundaries

        XCTAssertEqual(p.phase, .work)
        XCTAssertEqual(p.completedCycles, 4000)
        XCTAssertFalse(p.restIsLong)
        XCTAssertEqual(p.remaining, 1440, accuracy: 1e-3)
        XCTAssertEqual(chimes, 1)
        XCTAssertEqual(phaseChanges.map { $0.0 }, [.work])
        XCTAssertLessThanOrEqual(willChanges, 8, "one publish per move, not per boundary")
    }
}

// MARK: - Pomodoro Live Activity

#if canImport(ActivityKit)
/// start() opens with stop(), which ends the Live Activities that are up, and then requests the new
/// session's. Which ones a stop ends is decided as it runs: read later, in the end's task, the list
/// held the new session's activity too and ended it as soon as it went up.
@MainActor
final class PomodoroLiveActivityTests: XCTestCase {
    /// ActivityKit's stand-in: activities are ids, put up and ended at once.
    private final class FakeActivities: PomodoroActivityHosting {
        var up: [String]
        var ended: [String] = []
        private var made = 0
        init(up: [String]) { self.up = up }
        var enabled: Bool { true }
        func listed() -> [String] { up }
        func request(_ content: ActivityContent<PomodoroAttributes.ContentState>) -> String? {
            made += 1
            up.append("session-\(made)")
            return up.last
        }
        func update(_ id: String, _ content: ActivityContent<PomodoroAttributes.ContentState>) {}
        func end(_ ids: [String], _ content: ActivityContent<PomodoroAttributes.ContentState>) {
            ended += ids
            up.removeAll { ids.contains($0) }
        }
    }

    /// Value: protects=a Focus session's Live Activity stays up once start() returns, while what
    /// was up before (a previous run's orphan, the last session's) is ended; fails_when=
    /// endLiveActivity reads the activity list in a task again, or startLiveActivity ends a list it
    /// reads after its request; why_new=no test covered the Pomodoro's Live Activity;
    /// seam=PomodoroService.activities; no_claim=ActivityKit itself (LivePomodoroActivities), the
    /// Lock Screen and Dynamic Island (TESTING.md §3I step 7)
    func testStartEndsWhatWasUpAndKeepsItsOwn() {
        let fake = FakeActivities(up: ["orphan"])
        let p = PomodoroService()
        p.activities = fake
        defer { p.stop() }

        p.start()
        XCTAssertEqual(fake.ended, ["orphan"], "a previous run's activity is ended")
        XCTAssertEqual(fake.up, ["session-1"], "the new session's activity stays up")

        p.start()
        XCTAssertEqual(fake.ended, ["orphan", "session-1"], "a restart ends the last session's")
        XCTAssertEqual(fake.up, ["session-2"], "and keeps its own")
    }

    /// Value: protects=Stop still ends the session's Live Activity; fails_when=stop() stops
    /// calling endLiveActivity, or the end skips the tracked activity; why_new=the start test
    /// alone would pass if nothing were ever ended after a start; seam=PomodoroService.activities;
    /// no_claim=ActivityKit dismissing it from the Lock Screen
    func testStopEndsTheSessionsActivity() {
        let fake = FakeActivities(up: [])
        let p = PomodoroService()
        p.activities = fake

        p.start()
        p.stop()
        XCTAssertEqual(fake.ended, ["session-1"])
        XCTAssertEqual(fake.up, [])
    }
}
#endif

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

// "Podcast plays muted until force-quit." The dead-pipeline detector: the AVPlayer clock keeps
// advancing while no podcast audio reaches the limiter tap. Pure — fed heartbeat/clock samples.
@MainActor
final class RenderHeartbeatMonitorTests: XCTestCase {
    private func hb(_ pulls: UInt64, _ signal: UInt64) -> TapHeartbeat {
        TapHeartbeat(pulls: pulls, signal: signal)
    }

    func testUnfedTapIsDeadAfterFourSeconds() {
        var m = RenderHeartbeatMonitor()
        XCTAssertEqual(m.observe(hb(7, 7), clock: 100, eligible: true), .unknown)   // first sample
        XCTAssertEqual(m.observe(hb(7, 7), clock: 101, eligible: true), .unknown)
        XCTAssertEqual(m.observe(hb(7, 7), clock: 102, eligible: true), .unknown)
        XCTAssertEqual(m.observe(hb(7, 7), clock: 103, eligible: true), .unknown)   // 3 s unfed
        XCTAssertEqual(m.observe(hb(7, 7), clock: 104, eligible: true), .dead,
                       "4 s of advancing playback with the tap never fed is a dead pipeline")
    }

    func testHealthyTapNeverTrips() {
        var m = RenderHeartbeatMonitor()
        var beat = hb(0, 0)
        for t in 0..<120 {
            beat.pulls += 40; beat.signal += 40           // fed many times a second, real audio
            let v = m.observe(beat, clock: Double(t), eligible: true)
            XCTAssertNotEqual(v, .dead)
            XCTAssertNotEqual(v, .sourceSilent)
            if t > 0 { XCTAssertEqual(v, .rendering) }
        }
    }

    func testFedOnlySilenceTripsAfterTheSlowWindowNotBefore() {
        // The pipeline still calls the tap, but every buffer is digital zero.
        var m = RenderHeartbeatMonitor()
        var pulls: UInt64 = 0
        var verdicts: [RenderHeartbeatMonitor.Verdict] = []
        for t in 0...Int(RenderHeartbeatMonitor.silentSourceAfter) {
            pulls += 40
            verdicts.append(m.observe(hb(pulls, 5), clock: Double(t), eligible: true))
        }
        XCTAssertFalse(verdicts.dropLast().contains(.sourceSilent),
                       "a few silent seconds are normal programme — don't trip early")
        XCTAssertFalse(verdicts.contains(.dead), "the tap IS being fed — this is not the fast tier")
        XCTAssertEqual(verdicts.last, .sourceSilent)
    }

    func testRealAudioClearsBothCounters() {
        var m = RenderHeartbeatMonitor()
        _ = m.observe(hb(1, 1), clock: 0, eligible: true)
        _ = m.observe(hb(1, 1), clock: 3, eligible: true)             // 3 s unfed + silent…
        XCTAssertEqual(m.observe(hb(2, 2), clock: 4, eligible: true), .rendering)   // …then audio
        XCTAssertEqual(m.unfedSeconds, 0)
        XCTAssertEqual(m.silentSeconds, 0)
        XCTAssertEqual(m.observe(hb(2, 2), clock: 5, eligible: true), .unknown,
                       "the count restarts from the render, not from the old silence")
    }

    func testFedButSilentStillResetsTheFastTier() {
        var m = RenderHeartbeatMonitor()
        _ = m.observe(hb(1, 1), clock: 0, eligible: true)
        _ = m.observe(hb(1, 1), clock: 3, eligible: true)
        XCTAssertEqual(m.observe(hb(9, 1), clock: 4, eligible: true), .unknown)   // fed, no signal
        XCTAssertEqual(m.unfedSeconds, 0)
        XCTAssertEqual(m.silentSeconds, 4, accuracy: 0.0001)
    }

    func testIneligibleTicksResetTheWatch() {
        // Paused / loading / no tap / AirPlay: no heartbeat is expected, so nothing accumulates.
        var m = RenderHeartbeatMonitor()
        _ = m.observe(hb(1, 1), clock: 0, eligible: true)
        _ = m.observe(hb(1, 1), clock: 3, eligible: true)
        XCTAssertEqual(m.observe(hb(1, 1), clock: 4, eligible: false), .unknown)
        XCTAssertEqual(m.unfedSeconds, 0)
        XCTAssertEqual(m.observe(hb(1, 1), clock: 5, eligible: true), .unknown)
        XCTAssertEqual(m.observe(hb(1, 1), clock: 8, eligible: true), .unknown)   // 3 s since re-arm
    }

    func testSeeksAndAStuckClockDontCountAsPlayback() {
        var m = RenderHeartbeatMonitor()
        _ = m.observe(hb(1, 1), clock: 100, eligible: true)
        XCTAssertEqual(m.observe(hb(1, 1), clock: 40, eligible: true), .unknown)    // seek back
        XCTAssertEqual(m.observe(hb(1, 1), clock: 400, eligible: true), .unknown)   // seek forward
        XCTAssertEqual(m.observe(hb(1, 1), clock: 400, eligible: true), .unknown)   // stalled clock
        XCTAssertEqual(m.unfedSeconds, 0, "only playback-sized forward steps count")
    }

    func testNonFiniteClockIsIgnored() {
        var m = RenderHeartbeatMonitor()
        _ = m.observe(hb(1, 1), clock: 0, eligible: true)
        XCTAssertEqual(m.observe(hb(1, 1), clock: .nan, eligible: true), .unknown)
        XCTAssertEqual(m.unfedSeconds, 0)
    }
}

// The fix itself, on a real AVPlayer (simulator): once the pipeline is known dead, the next play
// must come from a NEW AVPlayer. The bug was that one AVPlayer lived for the whole process, so a
// pipeline killed by an alarm/interruption stayed silent — even for new episodes — until relaunch.
@MainActor
final class PodcastPlayerRebuildTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rebuild-\(UUID().uuidString).wav")
        try Self.quietWav(seconds: 20).write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// Start playback and return the player plus the identity of its first AVPlayer.
    private func startPlaying() async throws -> (PodcastPlayer, ObjectIdentifier) {
        let p = PodcastPlayer()
        p.play(url: fileURL.absoluteString, id: "rebuild-\(UUID().uuidString)", title: "Test", resume: false)
        let ready = await waitUntil { p.playerInstanceId != nil }
        XCTAssertTrue(ready, "AVPlayer never came up")
        return (p, try XCTUnwrap(p.playerInstanceId))
    }

    func testPlainResumeKeepsTheSameAVPlayer() async throws {
        // Guard against over-correcting: a healthy pause/resume must not rebuild.
        let (p, first) = try await startPlaying()
        p.pause()
        p.resume()
        XCTAssertFalse(p.needsRebuild)
        XCTAssertEqual(p.playerInstanceId, first)
    }

    func testHealthyPlaybackIsNeverFlaggedByTheWatchdog() async throws {
        // The false-positive guard: past the watchdog's 4 s window, a working tap must keep the
        // heartbeat alive — no rebuild, no "No podcast audio?" note.
        let (p, first) = try await startPlaying()
        var note: String?
        p.onPlaybackNote = { if let n = $0 { note = n } }
        let played = await waitUntil(12) { (p.currentPositionSeconds ?? 0) > RenderHeartbeatMonitor.deadAfter + 2 }
        XCTAssertTrue(played, "the clock must actually run past the watchdog window for this to mean anything")
        XCTAssertEqual(p.playerInstanceId, first, "a healthy player must not be rebuilt")
        XCTAssertFalse(p.needsRebuild)
        XCTAssertNil(note)
        // Both tiers' inputs are live: the tap is fed, and real programme counts as signal (the
        // slow digital-silence tier would otherwise misfire on every real episode).
        XCTAssertGreaterThan(p.renderHeartbeat.pulls, 0)
        XCTAssertGreaterThan(p.renderHeartbeat.signal, 0, "a quiet tone must register as real signal")
    }

    func testWatchdogRebuildsASilentPlayerThenStandsDown() async throws {
        // The no-alarm morning case: nothing reports a failure, the clock just runs in silence.
        // A frozen heartbeat stands in for a tap that's no longer fed.
        let (p, first) = try await startPlaying()
        var note: String?
        var pausedAfterStart = false
        var events: [String] = []
        p.onPipelineEvent = { kind, _ in events.append(kind) }   // what the night journal hears
        p.onPlaybackNote = { if let n = $0 { note = n } }
        p.onPlaybackStateChanged = { playing in if !playing { pausedAfterStart = true } }
        let frozen = p.renderHeartbeat
        p.heartbeatOverride = { frozen }

        let rebuilt = await waitUntil(12) { p.playerInstanceId != nil && p.playerInstanceId != first }
        XCTAssertTrue(rebuilt, "4 s of clock with no audio must swap in a fresh AVPlayer")

        // Still silent on the fresh player (the override stays frozen): no rebuild loop and no
        // auto-pause — flag it for the user's next pause/play and stand down.
        let stoodDown = await waitUntil(12) { p.needsRebuild }
        XCTAssertTrue(stoodDown)
        XCTAssertEqual(note, "No podcast audio? Pause and play to restart it")
        XCTAssertFalse(pausedAfterStart, "the watchdog must never pause real playback on its own")
        XCTAssertEqual(Array(events.prefix(2)), ["player rebuilt", "silent after a rebuild"])
    }

    func testRebuildResumesAtTheSameSpot() async throws {
        // A rebuild re-opens the episode — it must not restart it from 0:00.
        let (p, first) = try await startPlaying()
        p.seekTo(seconds: 8)
        let seeked = await waitUntil { (p.currentPositionSeconds ?? 0) >= 8 }
        XCTAssertTrue(seeked)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: p.currentItem)
        _ = await waitUntil { p.needsRebuild }
        p.resume()
        let rebuilt = await waitUntil { p.playerInstanceId != nil && p.playerInstanceId != first }
        XCTAssertTrue(rebuilt)
        // The new player appears before its resume-seek lands, so wait for the position.
        let restored = await waitUntil { (p.currentPositionSeconds ?? 0) >= 7.5 }
        XCTAssertTrue(restored, "rebuilt player lost the episode position (restarted from 0?)")
        XCTAssertLessThan(p.currentPositionSeconds ?? .infinity, 13)
    }

    func testFailedToPlayToEndRebuildsOnNextResume() async throws {
        let (p, first) = try await startPlaying()
        var reportedPaused = false
        p.onPlaybackStateChanged = { playing in if !playing { reportedPaused = true } }

        // What the Clock-alarm failure posts for an AVPlayer + MTAudioProcessingTap item.
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: p.currentItem)
        let flagged = await waitUntil { p.needsRebuild }
        XCTAssertTrue(flagged, "an item that failed to play to end must flag the player dead")
        XCTAssertTrue(reportedPaused, "the transport must show paused, not keep 'playing' in silence")

        p.resume()
        let rebuilt = await waitUntil { p.playerInstanceId != nil && p.playerInstanceId != first }
        XCTAssertTrue(rebuilt, "resume after a dead pipeline must play from a NEW AVPlayer")
        XCTAssertFalse(p.needsRebuild)
    }

    /// The night journal hears a pipeline death and the rebuild, each stamped when it was
    /// detected (before the hop to main), so it files them under the night they happened in.
    func testPipelineDeathAndRebuildAreReportedWithTheirTimes() async throws {
        let (p, _) = try await startPlaying()
        var events: [(kind: String, at: Date)] = []
        p.onPipelineEvent = { events.append(($0, $1)) }
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: p.currentItem)
        let afterPost = Date()                                // detectedAt is taken before the hop
        _ = await waitUntil { p.needsRebuild }
        XCTAssertEqual(events.map(\.kind), ["pipeline died (item failed)"])
        XCTAssertLessThanOrEqual(events.first?.at ?? .distantFuture, afterPost)
        p.resume()
        _ = await waitUntil { events.count == 2 }
        XCTAssertEqual(events.last?.kind, "player rebuilt")
    }

    func testFailureFromAStaleItemIsIgnored() async throws {
        let (p, first) = try await startPlaying()
        var events: [String] = []
        p.onPipelineEvent = { kind, _ in events.append(kind) }
        let stale = AVPlayerItem(url: fileURL)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: stale)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(p.needsRebuild, "only the loaded item's failure condemns the player")
        XCTAssertEqual(p.playerInstanceId, first)
        XCTAssertEqual(events, [], "a replaced item's news must not reach the night")
    }

    func testMediaServicesResetWhilePlayingRebuildsImmediately() async throws {
        let (p, first) = try await startPlaying()
        var events: [String] = []
        p.onPipelineEvent = { kind, _ in events.append(kind) }
        p.handleMediaServicesReset()
        let rebuilt = await waitUntil { p.playerInstanceId != nil && p.playerInstanceId != first }
        XCTAssertTrue(rebuilt, "a media-services reset invalidates the AVPlayer — playing → rebuild now")
        XCTAssertEqual(events.first, "pipeline died (media services reset)")
    }

    func testMediaServicesResetWhilePausedWaitsForPlay() async throws {
        let (p, first) = try await startPlaying()
        p.pause()
        p.handleMediaServicesReset()
        XCTAssertTrue(p.needsRebuild)
        XCTAssertEqual(p.playerInstanceId, first, "paused → don't start playing on our own")
        p.resume()
        let rebuilt = await waitUntil { p.playerInstanceId != nil && p.playerInstanceId != first }
        XCTAssertTrue(rebuilt)
    }

    func testNewEpisodeAfterDeathAlsoGetsAFreshPlayer() async throws {
        // Picking a different episode used to replaceCurrentItem into the same dead AVPlayer.
        let (p, first) = try await startPlaying()
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: p.currentItem)
        _ = await waitUntil { p.needsRebuild }
        p.play(url: fileURL.absoluteString, id: "other-\(UUID().uuidString)", title: "Other", resume: false)
        let rebuilt = await waitUntil { p.playerInstanceId != nil && p.playerInstanceId != first }
        XCTAssertTrue(rebuilt)
    }

    /// 16-bit mono PCM WAV, a very quiet 220 Hz tone (real samples, not digital zero).
    static func quietWav(seconds: Int, sampleRate: Int = 44_100) -> Data {
        let count = seconds * sampleRate
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let s = Int16(60 * sin(2 * Double.pi * 220 * Double(i) / Double(sampleRate)))
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var d = Data("RIFF".utf8); d += u32(UInt32(36 + pcm.count)); d += Data("WAVE".utf8)
        d += Data("fmt ".utf8); d += u32(16); d += u16(1); d += u16(1)
        d += u32(UInt32(sampleRate)); d += u32(UInt32(sampleRate * 2)); d += u16(2); d += u16(16)
        d += Data("data".utf8); d += u32(UInt32(pcm.count)); d += pcm
        return d
    }
}

/// The Home screensaver hides every control and the tab bar, so it must only ever engage over a
/// session in progress — never an idle app, never under assistive tech, never behind a sheet.
final class HomeScreensaverPolicyTests: XCTestCase {
    func testIdleHomeNeverFades() {
        // The 2026-10 audit bug: a fresh launch with nothing playing blanked to stars in 3 s.
        XCTAssertFalse(HomeScreensaverPolicy.mayFade(sessionActive: false, assistiveTechRunning: false, presenting: false))
    }

    func testFadesOverASession() {
        XCTAssertTrue(HomeScreensaverPolicy.mayFade(sessionActive: true, assistiveTechRunning: false, presenting: false))
    }

    func testNeverFadesUnderAssistiveTech() {
        // Opacity-0 controls leave the accessibility tree — VoiceOver/Switch Control would lose Home.
        XCTAssertFalse(HomeScreensaverPolicy.mayFade(sessionActive: true, assistiveTechRunning: true, presenting: false))
    }

    func testNeverFadesBehindAHomeSheet() {
        XCTAssertFalse(HomeScreensaverPolicy.mayFade(sessionActive: true, assistiveTechRunning: false, presenting: true))
    }

    func testSleepFadesFasterThanFocus() {
        XCTAssertLessThan(HomeScreensaverPolicy.idleDelay(focusMode: false, tipShowing: false),
                          HomeScreensaverPolicy.idleDelay(focusMode: true, tipShowing: false))
    }

    func testATipGetsTimeToBeReadBeforeTheFade() {
        // At 3 s the first-run card faded mid-sentence. It gets longer, in either mode, but the
        // fade still comes (Play doesn't dismiss it; a held fade would light an All-night session).
        XCTAssertGreaterThan(HomeScreensaverPolicy.idleDelay(focusMode: false, tipShowing: true),
                             HomeScreensaverPolicy.idleDelay(focusMode: true, tipShowing: false))
        XCTAssertGreaterThanOrEqual(HomeScreensaverPolicy.idleDelay(focusMode: false, tipShowing: true), 12)
        XCTAssertLessThanOrEqual(HomeScreensaverPolicy.idleDelay(focusMode: false, tipShowing: true), 20)
    }

    func testAnySourceCountsAsASession() {
        XCTAssertFalse(HomeScreensaverPolicy.sessionActive(audioPlaying: false, appleMusicOn: false, pomodoroRunning: false))
        XCTAssertTrue(HomeScreensaverPolicy.sessionActive(audioPlaying: true, appleMusicOn: false, pomodoroRunning: false))
        // Apple Music sits outside `isAnythingPlaying`, and a silent Pomodoro has no audio at all —
        // both are still a session the scene can take over.
        XCTAssertTrue(HomeScreensaverPolicy.sessionActive(audioPlaying: false, appleMusicOn: true, pomodoroRunning: false))
        XCTAssertTrue(HomeScreensaverPolicy.sessionActive(audioPlaying: false, appleMusicOn: false, pomodoroRunning: true))
    }

    func testChromeLiftRestoresWhatTheHiddenTabBarTookAway() {
        // iPhone: hiding the tab bar shrinks the bottom inset 83 → 34; the controls get 49 back.
        let shown = EdgeInsets(top: 62, leading: 0, bottom: 83, trailing: 0)
        let hidden = EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        let lift = HomeScreensaverPolicy.chromeLift(anchored: shown, live: hidden)
        XCTAssertEqual(lift.bottom, 49)
        XCTAssertEqual(lift.top, 0)
    }

    func testChromeLiftIsZeroWhileChromeShowsAndNeverNegative() {
        let shown = EdgeInsets(top: 62, leading: 0, bottom: 83, trailing: 0)
        XCTAssertEqual(HomeScreensaverPolicy.chromeLift(anchored: shown, live: shown), EdgeInsets())
        // Live inset larger than the anchor (e.g. a stale anchor after rotation): clamp, don't pull up.
        let taller = EdgeInsets(top: 80, leading: 0, bottom: 100, trailing: 0)
        XCTAssertEqual(HomeScreensaverPolicy.chromeLift(anchored: shown, live: taller), EdgeInsets())
    }
}

final class CoachmarkLayoutTests: XCTestCase {
    // OrbButton's frame is the 200pt glow; the 132pt disc sits centred in it.
    private let orb = CGRect(x: 87, y: 108, width: 200, height: 200)   // disc spans y 142…274

    func testRoomClearsTheDiscAndTheRow() {
        // The 2026-10 review bug: on an iPhone SE the card covered the lower half of the orb.
        let room = CoachmarkLayout.room(orb: orb, mixRowTop: 384)
        XCTAssertEqual(room.top, 274 + CoachmarkLayout.clearance)   // starts below the disc, not the glow
        XCTAssertEqual(room.top + room.height, 384 - CoachmarkLayout.clearance)
    }

    func testRoomClearsTheNightRingWhenAsked() {
        // The tip's copy says to drag the ring, so on Sleep it must start below the ring, not the disc.
        let room = CoachmarkLayout.room(orb: orb, mixRowTop: 420, clearRadius: 111)
        XCTAssertEqual(room.top, orb.midY + 111 + CoachmarkLayout.clearance)
        XCTAssertEqual(room.top + room.height, 420 - CoachmarkLayout.clearance)
    }

    func testRoomStartsBelowTheNightLine() {
        let room = CoachmarkLayout.room(belowY: 560, mixRowTop: 730)
        XCTAssertEqual(room.top, 560 + CoachmarkLayout.clearance)
        XCTAssertEqual(room.top + room.height, 730 - CoachmarkLayout.clearance)
        XCTAssertEqual(CoachmarkLayout.room(belowY: 760, mixRowTop: 730).height, 0)
    }

    func testRoomIsEmptyNotNegativeWhenTheRowCrowdsTheOrb() {
        // Large text on a small phone can push the row up against the disc: the card gets no
        // room (and shows nothing) instead of a negative height.
        XCTAssertEqual(CoachmarkLayout.room(orb: orb, mixRowTop: 280).height, 0)
    }
}

/// The moments one half-asleep tap could cost the night: a mode switch over a live session, a
/// timer committed over silence, the veil dropping over a quiet room.
final class SessionGuardsTests: XCTestCase {
    func testSwitchingToFocusOverASleepTimerAsksFirst() {
        let w = SessionGuards.modeSwitchWarning(toFocus: true, sleepTimerActive: true,
                                                sleepSoundsPlaying: true, pomodoroRunning: false)
        XCTAssertEqual(w?.confirm, "Switch to Focus")
        XCTAssertTrue(w?.message.contains("sleep timer") ?? false)
    }

    func testSwitchingToFocusOverPlayingSleepSoundsAsksFirst() {
        // No timer, but a stray 2am tap would still swap the bed and drop the limiter.
        let w = SessionGuards.modeSwitchWarning(toFocus: true, sleepTimerActive: false,
                                                sleepSoundsPlaying: true, pomodoroRunning: false)
        XCTAssertNotNil(w)
        XCTAssertFalse(w?.message.contains("timer") ?? true)
    }

    func testSwitchToFocusOverASilentCountdownStillAsks() {
        let w = SessionGuards.modeSwitchWarning(toFocus: true, sleepTimerActive: true,
                                                sleepSoundsPlaying: false, pomodoroRunning: false)
        XCTAssertEqual(w?.message, "Your sleep timer stops and your sounds change to the Focus set.")
    }

    func testIdleSwitchToFocusIsImmediate() {
        XCTAssertNil(SessionGuards.modeSwitchWarning(toFocus: true, sleepTimerActive: false,
                                                     sleepSoundsPlaying: false, pomodoroRunning: false))
    }

    func testSwitchingToSleepOnlyAsksOverARunningPomodoro() {
        XCTAssertNotNil(SessionGuards.modeSwitchWarning(toFocus: false, sleepTimerActive: false,
                                                        sleepSoundsPlaying: false, pomodoroRunning: true))
        XCTAssertNil(SessionGuards.modeSwitchWarning(toFocus: false, sleepTimerActive: false,
                                                     sleepSoundsPlaying: false, pomodoroRunning: false))
    }

    // Value: protects=the 3am glance: first tap shows it, a quick follow-up doesn't skip it, a tap while it shows/fades wakes, VO/Switch wake at once; fails_when=a boundary flips or the settle/assistive guard goes; why_new=veilTapped is view wiring the UI test can only sample; seam=none
    func testTheVeilGlancesFirstThenWakes() {
        let hold = SessionGuards.glanceHold, fade = SessionGuards.glanceFade
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: nil, assistiveTech: false), .glance)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: 0.3, assistiveTech: false), .ignore)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: SessionGuards.glanceSettle, assistiveTech: false), .wake)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: hold + fade - 0.1, assistiveTech: false), .wake)   // still fading
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: hold + fade, assistiveTech: false), .glance)       // gone: glance again
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: nil, assistiveTech: true), .wake)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: 0.3, assistiveTech: true), .wake)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: -120, assistiveTech: false), .glance,
                       "a clock step back must not lock the veil against taps")
    }

    func testVeilNeverDropsOverSilence() {
        XCTAssertFalse(SessionGuards.mayNightDim(autoNightDim: true, focusMode: false, playing: false, timerActive: true, onBedsideScreen: true))
        XCTAssertTrue(SessionGuards.mayNightDim(autoNightDim: true, focusMode: false, playing: true, timerActive: true, onBedsideScreen: false))
        XCTAssertFalse(SessionGuards.mayNightDim(autoNightDim: true, focusMode: true, playing: true, timerActive: true, onBedsideScreen: true))
        XCTAssertFalse(SessionGuards.mayNightDim(autoNightDim: false, focusMode: false, playing: true, timerActive: true, onBedsideScreen: true))
    }

    // Value: protects=All night veils the bedside screens (Home, Now Playing) but not daytime listening on other tabs; fails_when=the Home or timer clause is dropped or inverted; why_new=the rule gained onBedsideScreen for untimed nights; seam=none
    func testAllNightVeilsOnlyTheSleepScreen() {
        XCTAssertTrue(SessionGuards.mayNightDim(autoNightDim: true, focusMode: false, playing: true, timerActive: false, onBedsideScreen: true))
        XCTAssertFalse(SessionGuards.mayNightDim(autoNightDim: true, focusMode: false, playing: true, timerActive: false, onBedsideScreen: false))
        XCTAssertTrue(SessionGuards.mayNightDim(autoNightDim: true, focusMode: false, playing: true, timerActive: true, onBedsideScreen: false),
                      "a running timer veils every tab, as before")
    }

    func testTheFirstSessionIsTheLayeredBedHoweverTheTipWasDismissed() {
        // The first bed has its own flag: touching the ring (which retires the first-run tip)
        // used to make the first play a bare Brown.
        XCTAssertTrue(SessionGuards.begin(hasResumableMix: false, firstSessionStarted: false) == .firstBed)
        XCTAssertTrue(SessionGuards.begin(hasResumableMix: false, firstSessionStarted: true) == .transport)
        XCTAssertTrue(SessionGuards.begin(hasResumableMix: true, firstSessionStarted: false) == .resume)
        XCTAssertTrue(SessionGuards.begin(hasResumableMix: true, firstSessionStarted: true) == .resume)
    }

    func testVeilWaitsOutAPresentationInsteadOfDroppingUnderIt() {
        // The veil can't cover a sheet or dialog: dropping it then left a lit dialog on black.
        XCTAssertTrue(SessionGuards.veilTimeout(mayDim: true, presenting: false) == .drop)
        XCTAssertTrue(SessionGuards.veilTimeout(mayDim: true, presenting: true) == .wait)
        XCTAssertTrue(SessionGuards.veilTimeout(mayDim: false, presenting: false) == .stand)
        XCTAssertTrue(SessionGuards.veilTimeout(mayDim: false, presenting: true) == .stand)
    }

    func testSystemOverlaysHideOnlyInTheDark() {
        // The veil hides them in any mode it can show in; the screensaver only in Sleep.
        XCTAssertTrue(SessionGuards.hidesSystemOverlays(nightDimmed: true, screensaver: false, focusMode: false))
        XCTAssertTrue(SessionGuards.hidesSystemOverlays(nightDimmed: false, screensaver: true, focusMode: false))
        XCTAssertFalse(SessionGuards.hidesSystemOverlays(nightDimmed: false, screensaver: true, focusMode: true))
        XCTAssertFalse(SessionGuards.hidesSystemOverlays(nightDimmed: false, screensaver: false, focusMode: false))
    }

    func testTimerCommitStartsTheMixWhenNothingPlays() {
        XCTAssertEqual(SessionGuards.timerCommitTitle(playing: false, timerActive: false), "Play & start timer")
        XCTAssertEqual(SessionGuards.timerCommitTitle(playing: false, timerActive: true), "Play & start timer")
        XCTAssertEqual(SessionGuards.timerCommitTitle(playing: true, timerActive: false), "Start timer")
        XCTAssertEqual(SessionGuards.timerCommitTitle(playing: true, timerActive: true), "Restart timer")
    }
}

/// One name per sound, and timer copy that matches the real fade (the last 600 s).
final class ClarityCopyTests: XCTestCase {
    func testBinauralPresetsUseOneName() {
        XCTAssertEqual(SoundNames.binaural("delta"), "Deep")
        XCTAssertEqual(SoundNames.binaural("theta"), "Drift")
        XCTAssertEqual(SoundNames.binaural("gamma"), "Focus")
        XCTAssertEqual(SoundNames.binaural("smr"), "Smr")   // unknown: capitalized, never blank
    }

    func testTimerConsequenceMatchesTheFade() {
        XCTAssertEqual(TimerCopy.consequence(minutes: 30, tailMinutes: 0), "Fades out over the last 10 min, then stops.")
        XCTAssertEqual(TimerCopy.consequence(minutes: 5, tailMinutes: 0), "Fades out gently, then stops.")
        XCTAssertEqual(TimerCopy.consequence(minutes: 30, tailMinutes: 15),
                       "The podcast stops at 30 min. Your sounds carry on softly for 15 more.")
    }

    func testTimerCopyAtTheFadeBoundary() {
        XCTAssertEqual(TimerCopy.consequence(minutes: 10, tailMinutes: 0), "Fades out gently, then stops.")
        XCTAssertEqual(TimerCopy.consequence(minutes: 15, tailMinutes: 0), "Fades out over the last 10 min, then stops.")
    }
}

/// The Sleep player's night line: does tonight's timer cut this story off, or does it end first?
final class NightLineCopyTests: XCTestCase {
    private func line(timer: Double, eoe: Bool = false, tail: Bool = false,
                      episode: Double?, tailMinutes: Int = 0) -> String {
        NightLineCopy.line(timerRemaining: timer, endOfEpisode: eoe, inTail: tail,
                           episodeRemaining: episode, tailMinutes: tailMinutes)
    }

    func testNoTimerPlaysAllNight() {
        XCTAssertEqual(line(timer: 0, episode: 1000), "Plays all night")
    }

    func testTimerCutsTheEpisodeShort() {
        XCTAssertEqual(line(timer: 38 * 60, episode: 61 * 60),
                       "Timer ends in 38 min · 23 min before this episode does")
    }

    func testEpisodeEndsFirst() {
        XCTAssertEqual(line(timer: 52 * 60, episode: 38 * 60), "This episode ends 14 min before the timer")
    }

    func testWithinAMinuteTheyEndTogether() {
        XCTAssertEqual(line(timer: 30 * 60, episode: 30 * 60 + 40), "Timer ends with this episode · in 30 min")
    }

    func testStopWithEpisodeMentionsTheTail() {
        XCTAssertEqual(line(timer: 17 * 60, eoe: true, episode: 17 * 60), "Stops with this episode · in 17 min")
        XCTAssertEqual(line(timer: 17 * 60, eoe: true, episode: 17 * 60, tailMinutes: 30),
                       "Stops with this episode · in 17 min · sounds go on 30 min")
    }

    func testTailAndUnknownLength() {
        XCTAssertEqual(line(timer: 12 * 60, tail: true, episode: nil), "Sounds fading · 12 min left")
        XCTAssertEqual(line(timer: 38 * 60, episode: nil), "Timer ends in 38 min")
    }

    func testSpanRoundsUpAndShowsHours() {
        XCTAssertEqual(NightLineCopy.span(1), "1 min")
        XCTAssertEqual(NightLineCopy.span(61), "2 min", "a countdown never claims less than is left")
        XCTAssertEqual(NightLineCopy.span(72 * 60), "1 hr 12 min")
        XCTAssertEqual(NightLineCopy.span(120 * 60), "2 hr")
    }
}

/// The night ring: a 120-minute dial from 12 o'clock, snapping to 5, 0 = All night.
final class NightRingMathTests: XCTestCase {
    func testAngleMapsToSnappedMinutes() {
        XCTAssertEqual(NightRingMath.minutes(forAngle: 0), 0)
        XCTAssertEqual(NightRingMath.minutes(forAngle: .pi / 2), 30)          // 3 o'clock
        XCTAssertEqual(NightRingMath.minutes(forAngle: .pi), 60)              // 6 o'clock
        XCTAssertEqual(NightRingMath.minutes(forAngle: 2 * .pi * 0.01), 0)    // 1.2 min → All night
        XCTAssertEqual(NightRingMath.minutes(forAngle: 2 * .pi * 0.99), 120)
    }

    func testAngleIsClockwiseFromTwelve() {
        let c = CGPoint(x: 100, y: 100)
        XCTAssertEqual(NightRingMath.angle(of: CGPoint(x: 100, y: 0), center: c), 0, accuracy: 1e-9)
        XCTAssertEqual(NightRingMath.angle(of: CGPoint(x: 200, y: 100), center: c), .pi / 2, accuracy: 1e-9)
        XCTAssertEqual(NightRingMath.angle(of: CGPoint(x: 0, y: 100), center: c), 3 * .pi / 2, accuracy: 1e-9)
    }

    func testDragNeverWrapsAcrossTwelve() {
        XCTAssertEqual(NightRingMath.continuous(previous: 115, raw: 5), 120)
        XCTAssertEqual(NightRingMath.continuous(previous: 5, raw: 115), 0)
        XCTAssertEqual(NightRingMath.continuous(previous: 40, raw: 45), 45)
    }

    func testReleaseAtRestOnlySetsTheLength() {
        XCTAssertEqual(NightRingMath.commit(minutes: 45, playing: false, timerActive: false), .none)
        XCTAssertEqual(NightRingMath.commit(minutes: 45, playing: true, timerActive: false), .start(45))
        XCTAssertEqual(NightRingMath.commit(minutes: 45, playing: false, timerActive: true), .start(45))
        XCTAssertEqual(NightRingMath.commit(minutes: 0, playing: true, timerActive: true), .cancel)
        XCTAssertEqual(NightRingMath.commit(minutes: 0, playing: true, timerActive: false), .none)
    }

    func testRingLocksOnceTheNightIsFading() {
        // A restart inside the 600 s fade would snap a fading bed back up to full volume.
        XCTAssertTrue(NightRingMath.locked(remaining: 90, inTail: false, endOfEpisode: false))
        XCTAssertTrue(NightRingMath.locked(remaining: 500, inTail: false, endOfEpisode: false))
        XCTAssertTrue(NightRingMath.locked(remaining: 600, inTail: false, endOfEpisode: false))
        XCTAssertFalse(NightRingMath.locked(remaining: 601, inTail: false, endOfEpisode: false))
        XCTAssertTrue(NightRingMath.locked(remaining: 900, inTail: true, endOfEpisode: false))
        XCTAssertTrue(NightRingMath.locked(remaining: 300, inTail: false, endOfEpisode: true))   // EOE fades too
        XCTAssertFalse(NightRingMath.locked(remaining: 0, inTail: false, endOfEpisode: false))
    }

    func testVoiceOverStepsStayOnTheDial() {
        XCTAssertEqual(NightRingMath.adjusted(0, up: true), 5)
        XCTAssertEqual(NightRingMath.adjusted(5, up: false), 0)
        XCTAssertEqual(NightRingMath.adjusted(0, up: false), 0)
        XCTAssertEqual(NightRingMath.adjusted(120, up: true), 120)
        XCTAssertEqual(NightRingMath.adjusted(115, up: true), 120)
    }

    func testVoiceOverStepsSnapToTheGrid() {
        XCTAssertEqual(NightRingMath.adjusted(43, up: true), 45)    // not 48
        XCTAssertEqual(NightRingMath.adjusted(43, up: false), 40)
        XCTAssertEqual(NightRingMath.adjusted(45, up: false), 40)
    }

    func testVoiceOverIncrementNeverShortensALongNight() {
        // An end-of-episode timer with 150 min left: "up" used to clamp it to 120.
        XCTAssertEqual(NightRingMath.adjusted(150, up: true), 150)
        XCTAssertEqual(NightRingMath.adjusted(150, up: false), 145)
    }

    func testStoredLengthStaysOnTheDialAndSane() {
        XCTAssertEqual(NightRingMath.storable(145), 120)
        XCTAssertEqual(NightRingMath.storable(-5), 0)
        XCTAssertEqual(NightRingMath.sanitized(1e300), 120)       // a hand-edited backup can't trap Int()
        XCTAssertEqual(NightRingMath.sanitized(.infinity), 0)
        XCTAssertEqual(NightRingMath.sanitized(.nan), 0)
        XCTAssertEqual(NightRingMath.sanitized(45), 45)
    }

    func testFractionPinsPastTheDial() {
        XCTAssertEqual(NightRingMath.fraction(forMinutes: 60), 0.5, accuracy: 1e-9)
        XCTAssertEqual(NightRingMath.fraction(forMinutes: 180), 1)
        XCTAssertEqual(NightRingMath.fraction(forMinutes: -3), 0)
    }

    func testAngleWrapsBothWays() {
        XCTAssertEqual(NightRingMath.minutes(forAngle: -.pi / 2), 90)
        XCTAssertEqual(NightRingMath.minutes(forAngle: 2 * .pi + .pi / 2), 30)
        XCTAssertEqual(NightRingMath.spoken(minutes: 0), "All night")
        XCTAssertEqual(NightRingMath.spoken(minutes: 45), "45 minutes")
    }

    func testOvershootPastEitherEndStaysPinned() {
        // Counter-clockwise past All night used to jump to 85; clockwise past 120 to 35.
        XCTAssertEqual(NightRingMath.continuous(previous: 0, raw: 85), 0)
        XCTAssertEqual(NightRingMath.continuous(previous: 120, raw: 35), 120)
        // …and comes back once the finger returns to the near half of the dial.
        XCTAssertEqual(NightRingMath.continuous(previous: 0, raw: 20), 20)
        XCTAssertEqual(NightRingMath.continuous(previous: 120, raw: 100), 100)
    }

    func testPlayHonoursTheRing() {
        XCTAssertEqual(SessionGuards.timerOnPlay(focusMode: false, lengthMinutes: 45, timerActive: false), 45)
        XCTAssertNil(SessionGuards.timerOnPlay(focusMode: false, lengthMinutes: 0, timerActive: false))    // All night
        XCTAssertNil(SessionGuards.timerOnPlay(focusMode: false, lengthMinutes: 45, timerActive: true))    // resume keeps it
        XCTAssertNil(SessionGuards.timerOnPlay(focusMode: true, lengthMinutes: 45, timerActive: false))    // Focus has the Pomodoro
    }

    func testPlayTimesOnlyFromFiveMinutes() {
        XCTAssertNil(SessionGuards.timerOnPlay(focusMode: false, lengthMinutes: 4.9, timerActive: false))
        XCTAssertEqual(SessionGuards.timerOnPlay(focusMode: false, lengthMinutes: 5, timerActive: false), 5)
        XCTAssertEqual(SessionGuards.timerOnPlay(focusMode: false, lengthMinutes: 1e300, timerActive: false), 120)
    }

    func testNightLineIsSpokenInMinutes() {
        XCTAssertEqual(NightLine.spoken("45m"), "45 minutes")
        XCTAssertEqual(NightLine.spoken("38m left"), "38 minutes left")
        XCTAssertEqual(NightLine.spoken("All night"), "All night")
        XCTAssertEqual(NightLine.spoken("Ends with the episode"), "Ends with the episode")
    }

    func testNightLineSaysTheNightPlainly() {
        XCTAssertEqual(NightLine.timerText(remaining: 0, inTail: false, endOfEpisode: false, playing: false, lengthMinutes: 45), "45m")
        XCTAssertEqual(NightLine.timerText(remaining: 0, inTail: false, endOfEpisode: false, playing: false, lengthMinutes: 0), "All night")
        XCTAssertEqual(NightLine.timerText(remaining: 0, inTail: false, endOfEpisode: false, playing: true, lengthMinutes: 45), "All night")
        XCTAssertEqual(NightLine.timerText(remaining: 61, inTail: false, endOfEpisode: false, playing: true, lengthMinutes: 45), "2m left")
        XCTAssertEqual(NightLine.timerText(remaining: 600, inTail: false, endOfEpisode: true, playing: true, lengthMinutes: 0), "Ends with the episode")
        XCTAssertEqual(NightLine.timerText(remaining: 600, inTail: true, endOfEpisode: false, playing: true, lengthMinutes: 0), "Sounds easing out")
    }
}

/// Screens keep exactly the room the floating mini-player covers.
final class MiniPlayerClearanceTests: XCTestCase {
    func testClearsTheBarPlusAGap() {
        // Safe bottom at 792, bar top at 695 → 97 covered + 12 gap.
        XCTAssertEqual(MiniPlayerClearanceMath.clearance(safeBottom: 792, miniTop: 695), 109)
    }

    func testNoBarNoRoom() {
        XCTAssertEqual(MiniPlayerClearanceMath.clearance(safeBottom: 792, miniTop: nil), 0)
        XCTAssertEqual(MiniPlayerClearanceMath.clearance(safeBottom: 0, miniTop: 695), 0)   // not measured yet
    }

    func testBarBelowTheEdgeNeedsNothingExtra() {
        XCTAssertEqual(MiniPlayerClearanceMath.clearance(safeBottom: 600, miniTop: 700), 0)
    }
}


/// What the mode-switch confirm promises ("your sleep timer stops", "your focus session ends") is
/// done by AudioEngine.focusMode's didSet — and the palettes off Home read the key it writes.
@MainActor
final class ModeSwitchConsequenceTests: XCTestCase {
    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }

    func testSwitchingToFocusCancelsTheSleepTimer() {
        let e = AudioEngine(); e.focusMode = false
        e.sleepTimer.backstop = NoopBackstop()
        e.sleepTimer.startSleepTimer(minutes: 45)
        XCTAssertGreaterThan(e.sleepTimer.timerRemaining, 0)
        e.focusMode = true
        XCTAssertEqual(e.sleepTimer.timerRemaining, 0)
        e.focusMode = false
    }

    func testSwitchingToSleepStopsThePomodoro() {
        let e = AudioEngine(); e.focusMode = true
        e.pomodoro.start()
        XCTAssertTrue(e.pomodoro.isRunning)
        e.focusMode = false
        XCTAssertFalse(e.pomodoro.isRunning)
    }

    func testFocusModeIsPersistedUnderTheKeyThePalettesRead() {
        let e = AudioEngine()
        e.focusMode = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "focusMode"))
        XCTAssertFalse(Palette(focusMode: true).warm)
        e.focusMode = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "focusMode"))
        XCTAssertTrue(Palette(focusMode: false).warm)
    }
}

/// Default preset names use the mixer's words ("Deep", not "Delta").
@MainActor
final class PresetNamingTests: XCTestCase {
    func testDefaultPresetNameUsesTheMixerVocabulary() {
        let e = AudioEngine(); e.focusMode = false; e.extraLayers = []
        e.noiseType = "brown"; e.binauralPreset = "delta"
        e.noiseOn = true; e.binauralOn = true
        defer { e.noiseOn = false; e.binauralOn = false; e.extraLayers = [] }
        XCTAssertEqual(e.defaultPresetName(), "Brown + Deep")
        e.extraLayers = [ExtraNoiseLayer(id: "x", type: "rain", volume: 0.5, muted: nil)]
        XCTAssertEqual(e.defaultPresetName(), "Brown + Rain + Deep")
        e.noiseOn = false
        XCTAssertEqual(e.defaultPresetName(), "Deep")
        e.binauralOn = false
        XCTAssertEqual(e.defaultPresetName(), "My Mix")
    }

    func testFocusPresetNamesMatchTheChips() {
        let e = AudioEngine(); e.focusMode = true; e.extraLayers = []
        e.noiseType = "white"; e.binauralPreset = "beta"
        e.noiseOn = true; e.binauralOn = true
        defer { e.noiseOn = false; e.binauralOn = false; e.focusMode = false }
        XCTAssertEqual(e.defaultPresetName(), "White + Concentrate")
    }
}

/// Opening Build mix at rest shows what Play would resume.
@MainActor
final class StageForEditingTests: XCTestCase {
    private func mix(_ noise: String, _ bin: String) -> SavedMix {
        SavedMix(name: "Last Night", noiseOn: true, noiseVolume: 0.61, noiseType: noise,
                 binauralOn: true, binVolume: 0.27, binauralPreset: bin,
                 podVolume: 0.7, podcastUrl: nil, podcastId: nil)
    }

    func testStagesInPalettePicksAtRestWithoutPlaying() {
        let e = AudioEngine(); e.focusMode = false
        e.noiseOn = false; e.binauralOn = false
        e.noiseType = "green"; e.binauralPreset = "delta"
        e.stageForEditing(mix("brown", "theta"))
        XCTAssertEqual(e.noiseType, "brown"); XCTAssertEqual(e.noiseVolume, 0.61, accuracy: 1e-9)
        XCTAssertEqual(e.binauralPreset, "theta"); XCTAssertEqual(e.binVolume, 0.27, accuracy: 1e-9)
        XCTAssertFalse(e.isAnythingPlaying)                       // never turns anything on
    }

    func testNeverTouchesALiveMix() {
        let e = AudioEngine(); e.focusMode = false
        e.noiseType = "rain"; e.noiseOn = true
        defer { e.noiseOn = false }
        e.stageForEditing(mix("brown", "theta"))
        XCTAssertEqual(e.noiseType, "rain")
    }

    func testCrossModePicksStayPut() {
        let e = AudioEngine(); e.focusMode = true
        e.noiseOn = false; e.binauralOn = false
        let (n, b) = (e.noiseType, e.binauralPreset)
        e.stageForEditing(mix("ocean", "delta"))                  // Sleep-only picks
        XCTAssertEqual(e.noiseType, n); XCTAssertEqual(e.binauralPreset, b)
        e.focusMode = false
    }

    private func layer(_ id: String, _ type: String, _ volume: Double, muted: Bool? = nil) -> ExtraNoiseLayer {
        ExtraNoiseLayer(id: id, type: type, volume: volume, muted: muted)
    }

    func testStagesTheSnapshotsExtraLayers() {
        // A Sleep → Focus → Sleep round trip dropped the rain layer from the mixer; Resume would
        // still bring it back, so Build mix must show it.
        let e = AudioEngine(); e.focusMode = false
        e.noiseOn = false; e.binauralOn = false; e.extraLayers = []
        defer { e.extraLayers = [] }
        var m = mix("brown", "theta")
        m.extraLayers = [layer("a", "rain", 0.42), layer("b", "ocean", 0.2, muted: true)]
        e.stageForEditing(m)
        XCTAssertEqual(e.extraLayers, m.extraLayers)              // ids, levels, mute all kept
        XCTAssertFalse(e.isAnythingPlaying)
    }

    func testSnapshotWithoutLayersClearsStaleOnes() {
        // Play resumes with no extra layers, so the idle mixer shouldn't show any.
        let e = AudioEngine(); e.focusMode = false
        e.noiseOn = false; e.binauralOn = false
        e.extraLayers = [layer("old", "forest", 0.5)]
        defer { e.extraLayers = [] }
        e.stageForEditing(mix("brown", "theta"))
        XCTAssertEqual(e.extraLayers, [])
    }

    func testStagedLayersAreCappedLikeResume() {
        let e = AudioEngine(); e.focusMode = false
        e.noiseOn = false; e.binauralOn = false; e.extraLayers = []
        defer { e.extraLayers = [] }
        var m = mix("brown", "theta")
        m.extraLayers = [layer("a", "rain", 0.3), layer("b", "ocean", 0.3), layer("c", "forest", 0.3)]
        e.stageForEditing(m)
        XCTAssertEqual(e.extraLayers.map(\.id), Array(["a", "b", "c"].prefix(AudioEngine.maxExtraLayers)))
    }

    func testCrossModeLayersStayPut() {
        let e = AudioEngine(); e.focusMode = true
        e.noiseOn = false; e.binauralOn = false
        let focusLayers = [layer("f", "fan", 0.35)]
        e.extraLayers = focusLayers
        defer { e.extraLayers = []; e.focusMode = false }
        var sleepOnly = mix("ocean", "delta")
        sleepOnly.extraLayers = [layer("r", "rain", 0.5)]
        e.stageForEditing(sleepOnly)
        XCTAssertEqual(e.extraLayers, focusLayers)
        // Pink is in both palettes, so it stages, but its Sleep-only layer keeps the stack out.
        var pinkLed = mix("pink", "delta")
        pinkLed.extraLayers = [layer("r", "rain", 0.5)]
        e.stageForEditing(pinkLed)
        XCTAssertEqual(e.noiseType, "pink")
        XCTAssertEqual(e.extraLayers, focusLayers)
    }

    func testLiveLayersAreNeverStaged() {
        let e = AudioEngine(); e.focusMode = false
        e.noiseType = "brown"; e.extraLayers = [layer("live", "rain", 0.5)]
        e.noiseOn = true
        defer { e.noiseOn = false; e.extraLayers = [] }
        e.stageForEditing(mix("brown", "theta"))
        XCTAssertEqual(e.extraLayers.map(\.id), ["live"])
    }
}

/// Every way of starting a Sleep session from rest honours the night ring (it used to be the orb
/// only): the engine starts the timer on the idle → playing edge.
@MainActor
final class NightTimerSessionStartTests: XCTestCase {
    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }

    private func engine(length: Double, focus: Bool = false) -> AudioEngine {
        let e = AudioEngine()
        e.sleepTimer.backstop = NoopBackstop()
        e.nightLengthProvider = { length }
        e.focusMode = focus
        return e
    }

    private func tearDownEngine(_ e: AudioEngine) {
        e.noiseOn = false; e.binauralOn = false; e.isPodPlaying = false
        e.sleepTimer.cancelTimer()
        e.focusMode = false
    }

    func testASleepSessionFromRestStartsTheNightTimer() {
        let e = engine(length: 30)
        defer { tearDownEngine(e) }
        e.noiseOn = true                                       // a mixer switch, not the orb
        XCTAssertEqual(e.sleepTimer.timerRemaining, 30 * 60, accuracy: 2)
    }

    func testAPodcastStartCountsToo() {
        let e = engine(length: 20)
        defer { tearDownEngine(e) }
        e.isPodPlaying = true                                  // lock screen / AirPods / Podcasts tab
        XCTAssertEqual(e.sleepTimer.timerRemaining, 20 * 60, accuracy: 2)
    }

    func testFocusNeverTimesAndAllNightStartsNothing() {
        let f = engine(length: 30, focus: true)
        defer { tearDownEngine(f) }
        var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        f.sleepTimer.now = { now }
        f.noiseOn = true
        XCTAssertEqual(f.sleepTimer.timerRemaining, 0)
        // Value: protects=a Focus session never settles a night (the Focus orb reads nightProgress and would still to nothing); fails_when=beginSleepNight drops its !focusMode guard; why_new=only the switch into Focus was tested, not a Focus start from rest; seam=none
        now += 60 * 60
        XCTAssertEqual(f.sleepTimer.nightProgress, 0)

        let a = engine(length: 0)
        defer { tearDownEngine(a) }
        a.noiseOn = true
        XCTAssertEqual(a.sleepTimer.timerRemaining, 0)
    }

    func testAddingALayerMidSessionDoesNotRestartTheNight() {
        var length = 30.0
        let e = engine(length: 30)
        e.nightLengthProvider = { length }
        defer { tearDownEngine(e) }
        e.noiseOn = true
        length = 60
        e.binauralOn = true                                    // already playing: not a new session
        XCTAssertEqual(e.sleepTimer.timerRemaining, 30 * 60, accuracy: 2)
    }

    func testResumingAfterAPauseKeepsTheRunningCountdown() {
        var length = 30.0
        let e = engine(length: 30)
        e.nightLengthProvider = { length }
        defer { tearDownEngine(e) }
        e.noiseOn = true
        e.noiseOn = false                                      // paused (the countdown keeps going)
        length = 60
        e.noiseOn = true                                       // resume, or a podcast stall ending
        XCTAssertEqual(e.sleepTimer.timerRemaining, 30 * 60, accuracy: 2)
    }
}

/// The untimed ("All night") night: it settles on the clock, a short pause keeps it, a long one
/// ends it. Before, All night (the default) had nightProgress 0 all night, so no scene darkened.
final class UntimedNightTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testItSettlesAcrossFortyFiveMinutes() {
        XCTAssertEqual(UntimedNight.progress(start: nil, stoppedAt: nil, now: t0), 0)
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: nil, now: t0), 0)
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: nil, now: t0 + 22.5 * 60), 0.5, accuracy: 1e-9)
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: nil, now: t0 + 6 * 3600), 1)
    }

    func testAShortPauseKeepsTheNightAndALongOneEndsIt() {
        let stop = t0 + 3600
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: stop, now: stop + 60), 1)
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: stop, now: stop + 31 * 60), 0)
        XCTAssertEqual(UntimedNight.start(previous: t0, stoppedAt: stop, now: stop + 5 * 60), t0)
        XCTAssertEqual(UntimedNight.start(previous: t0, stoppedAt: stop, now: stop + 31 * 60), stop + 31 * 60)
        XCTAssertEqual(UntimedNight.start(previous: nil, stoppedAt: nil, now: stop), stop)

        // Value: protects=start and progress agree on the resumeWindow edge (night over ⇔ a new one starts); fails_when=one comparison flips (< vs <=), so the scene reads 0 but resumes at 1 (or the reverse); why_new=existing cases sit at 5 and 31 min, never the edge; seam=none
        let w = UntimedNight.resumeWindow
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: stop, now: stop + w - 1), 1)
        XCTAssertEqual(UntimedNight.start(previous: t0, stoppedAt: stop, now: stop + w - 1), t0)
        XCTAssertEqual(UntimedNight.progress(start: t0, stoppedAt: stop, now: stop + w), 0)
        XCTAssertEqual(UntimedNight.start(previous: t0, stoppedAt: stop, now: stop + w), stop + w)
        // A night that never stopped carries on, however long it has run.
        XCTAssertEqual(UntimedNight.start(previous: t0, stoppedAt: nil, now: t0 + 6 * 3600), t0)
    }

    func testATimerStillOwnsTheNightWhileItRuns() {
        let timer = SleepTimerService()
        timer.backstop = NoopBackstop()
        var now = t0
        timer.now = { now }
        timer.noteSleepSessionStarted()
        timer.startSleepTimer(minutes: 30)                        // from bedtime (base 0)
        timer.timerRemaining = 15 * 60                            // halfway through the timer
        now = t0 + 45 * 60                                        // the clock alone would say 1
        XCTAssertEqual(timer.nightProgress, 0.5, accuracy: 1e-9)  // the timer's own curve
        timer.cancelTimer()
        // Value: protects=cancelling a timer mid-night (ring → All night) hands back the settled untimed night, not bedtime brightness; fails_when=cancelTimer ends the untimed night or nightProgress returns 0 with no timer; why_new=the test cancelled but never read nightProgress after; seam=none
        XCTAssertEqual(timer.nightProgress, 1, accuracy: 1e-9)    // the clock's night again
    }

    // Value: protects=starting a timer mid-night continues from the night reached (no 2am snap-back to bedtime); fails_when=timedBase is dropped and the timer's curve restarts at 0; why_new=only a timer from rest was tested; seam=none
    func testATimerStartedMidNightNeverBrightensTheScene() {
        let timer = SleepTimerService()
        timer.backstop = NoopBackstop()
        var now = t0
        timer.now = { now }
        defer { timer.cancelTimer() }
        timer.noteSleepSessionStarted()
        now = t0 + 36 * 60                                        // an untimed night 80% settled
        XCTAssertEqual(timer.nightProgress, 0.8, accuracy: 1e-6)
        timer.startSleepTimer(minutes: 30)                        // drag the ring at 2am
        XCTAssertEqual(timer.nightProgress, 0.8, accuracy: 0.01, "the timer settles on from 0.8, not from 0")
        timer.timerRemaining = 15 * 60                            // halfway: settles on toward 1
        XCTAssertEqual(timer.nightProgress, 0.9, accuracy: 1e-6)
        timer.timerRemaining = 0
        XCTAssertEqual(timer.nightProgress, 1, accuracy: 1e-9)
        timer.startSleepTimer(minutes: 45)                        // a restart keeps the night too
        XCTAssertEqual(timer.nightProgress, 1, accuracy: 1e-6)
        timer.cancelTimer()
        timer.startEndOfEpisode(remaining: 20 * 60)               // and so does an episode timer
        XCTAssertEqual(timer.nightProgress, 1, accuracy: 1e-6)
    }

    // Value: protects=cancelling a short timer mid-night (ring → All night) keeps the night it reached; fails_when=cancelTimer drops back to the untimed clock from the session start; why_new=only a cancel after a fully settled night was tested; seam=none
    func testCancellingATimerMidNightKeepsTheNightReached() {
        let timer = SleepTimerService()
        timer.backstop = NoopBackstop()
        var now = t0
        timer.now = { now }
        defer { timer.cancelTimer() }
        timer.noteSleepSessionStarted()
        now = t0 + 9 * 60                                         // 0.2 into an untimed night
        timer.startSleepTimer(minutes: 15)
        timer.timerRemaining = 5 * 60                             // 10 of its 15 minutes gone
        now = t0 + 19 * 60
        let reached = timer.nightProgress                         // 0.2 + 0.8 × 2/3 ≈ 0.73
        XCTAssertEqual(reached, 0.2 + 0.8 * 2.0 / 3.0, accuracy: 1e-6)
        timer.cancelTimer()                                       // ring → All night
        XCTAssertEqual(timer.nightProgress, reached, accuracy: 1e-6, "not the clock's 19/45 ≈ 0.42")
    }

    // Value: protects=the ambient tail carries the night straight on instead of dropping it as the podcast stops; fails_when=beginTail grows the total without re-basing; why_new=no test read nightProgress across the tail handoff; seam=none
    func testTheAmbientTailNeverBrightensTheNight() {
        let timer = SleepTimerService()
        timer.backstop = NoopBackstop()
        timer.ambientTailFn = { 15 * 60 }
        timer.tailEligibleFn = { true }
        timer.stopPodcastFn = {}
        defer { timer.cancelTimer() }
        timer.startSleepTimer(minutes: 0)                         // the deadline is now…
        timer.timerTotal = 30 * 60                                // …of a 30-min night
        Thread.sleep(forTimeInterval: 0.01)
        // Fade complete → the tail. The tick's main-queue half, called directly: a fixed run-loop
        // pump for backgroundTick's hop to main wasn't always long enough on CI's slow simulators.
        timer.handleTick(at: Date())
        XCTAssertTrue(timer.inTail)
        XCTAssertEqual(timer.nightProgress, 1, accuracy: 1e-6, "the scene held, not dropped by tail / (total + tail)")
    }

    // Value: protects=a settled night's end expires (resumeWindow), and a timer over silence settles nothing; fails_when=the end isn't recorded, or a timer over silence settles a night; why_new=the stop edge used to be the only thing bounding it; seam=none
    func testASettledEndExpiresAndSilenceSettlesNothing() {
        for path in ["tick", "reconcile"] {
            let e = AudioEngine()
            e.sleepTimer.backstop = NoopBackstop()
            e.nightLengthProvider = { 0 }
            e.focusMode = false
            var now = t0
            e.sleepTimer.now = { now }
            defer { e.noiseOn = false; e.sleepTimer.cancelTimer(); e.focusMode = false }
            e.noiseOn = true
            e.sleepTimer.startSleepTimer(minutes: 0)              // the deadline is now…
            e.sleepTimer.timerTotal = 30 * 60                     // …of a 30-min night
            Thread.sleep(forTimeInterval: 0.01)
            now = t0 + 30 * 60
            if path == "tick" {
                // The duration timer's fade-complete stop: the tick's main-queue half, called
                // directly (a fixed pump for backgroundTick's hop lost the race on a slow CI sim).
                e.sleepTimer.handleTick(at: Date())
            } else {
                e.sleepTimer.reconcileIfExpired()                 // a deadline passed while suspended
            }
            XCTAssertFalse(e.isAnythingPlaying, path)
            XCTAssertEqual(e.sleepTimer.nightProgress, 1, accuracy: 1e-9, path)
            now += UntimedNight.resumeWindow + 60
            XCTAssertEqual(e.sleepTimer.nightProgress, 0, "\(path): the night is over")
        }

        let quiet = SleepTimerService()                           // a timer set over silence (Siri)
        quiet.backstop = NoopBackstop()
        var now = t0
        quiet.now = { now }
        quiet.startSleepTimer(minutes: 0)
        Thread.sleep(forTimeInterval: 0.01)
        quiet.reconcileIfExpired()
        XCTAssertEqual(quiet.nightProgress, 0, accuracy: 1e-9, "a timer over silence settles nothing")
        now += 6 * 3600                                           // the next evening
        quiet.noteSleepSessionStarted()
        XCTAssertEqual(quiet.nightProgress, 0, accuracy: 1e-9, "bedtime, not last night's settled state")
    }

    // Value: protects=a timed night that ends on its own stays settled through the silence; fails_when=the terminal stop's cancel stops carrying the reached night and stopAll's reset lifts the scene; why_new=nothing read nightProgress after a terminal stop; seam=none
    func testATimedNightsEndLeavesTheSceneSettled() {
        let e = AudioEngine()
        e.sleepTimer.backstop = NoopBackstop()
        e.nightLengthProvider = { 0 }
        e.focusMode = false
        var now = t0
        e.sleepTimer.now = { now }
        defer { e.noiseOn = false; e.sleepTimer.cancelTimer(); e.focusMode = false }
        e.noiseOn = true
        e.sleepTimer.startEndOfEpisode(remaining: 30 * 60)        // a 30-min "stop with the episode" night
        now = t0 + 30 * 60
        e.sleepTimer.episodeEnded()                               // its terminal stop (no tail: no podcast bed)
        XCTAssertFalse(e.isAnythingPlaying)
        XCTAssertEqual(e.sleepTimer.nightProgress, 1, accuracy: 1e-9, "the settled night must not lift as it ends")
        now = t0 + 30 * 60 + 31 * 60                              // silent past the resume window
        XCTAssertEqual(e.sleepTimer.nightProgress, 0, "that night is over; the next opens at bedtime")
    }

    // Value: protects=switching Focus→Sleep with sound playing starts the night (settle + ring timer); fails_when=the mode switch stops calling beginSleepNight; why_new=only starts from rest were covered; seam=none
    func testSwitchingIntoSleepWhilePlayingStartsTheNight() {
        let e = AudioEngine()
        e.sleepTimer.backstop = NoopBackstop()
        e.nightLengthProvider = { 30 }
        e.focusMode = true
        var now = t0
        e.sleepTimer.now = { now }
        defer { e.noiseOn = false; e.sleepTimer.cancelTimer(); e.focusMode = false }
        e.noiseOn = true                                          // playing in Focus: no night, no timer
        XCTAssertEqual(e.sleepTimer.timerRemaining, 0)
        e.focusMode = false                                       // into Sleep, sound still going
        XCTAssertTrue(e.isAnythingPlaying)
        XCTAssertEqual(e.sleepTimer.timerRemaining, 30 * 60, accuracy: 2, "the ring's night starts as with Play")
        e.sleepTimer.cancelTimer()                                // ring → All night
        now = t0 + 45 * 60
        XCTAssertEqual(e.sleepTimer.nightProgress, 1, accuracy: 1e-6, "and the untimed night settles on the clock")
    }

    // Value: protects=switching into Sleep at rest or re-assigning the same mode starts no night or countdown; fails_when=the switched/isAnythingPlaying guards go; why_new=only the playing switch was tested; seam=none
    func testSwitchingIntoSleepAtRestOrToTheSameModeStartsNothing() {
        let e = AudioEngine()
        e.sleepTimer.backstop = NoopBackstop()
        e.nightLengthProvider = { 30 }
        e.focusMode = true
        var now = t0
        e.sleepTimer.now = { now }
        defer { e.noiseOn = false; e.sleepTimer.cancelTimer(); e.focusMode = false }
        e.focusMode = false                                       // into Sleep, nothing playing
        XCTAssertEqual(e.sleepTimer.timerRemaining, 0, "no countdown over silence")
        now += 45 * 60
        XCTAssertEqual(e.sleepTimer.nightProgress, 0, "no night without sound")
        e.nightLengthProvider = { 0 }
        e.noiseOn = true                                          // an All night session
        e.nightLengthProvider = { 30 }
        e.focusMode = false                                       // same mode re-assigned (a restore)
        XCTAssertEqual(e.sleepTimer.timerRemaining, 0, "not a switch: no night start")
    }

    func testAllNightOnTheEngineSettlesAndFocusEndsIt() {
        let e = AudioEngine()
        e.sleepTimer.backstop = NoopBackstop()
        e.nightLengthProvider = { 0 }                             // All night
        e.focusMode = false
        var now = t0
        e.sleepTimer.now = { now }
        defer { e.noiseOn = false; e.sleepTimer.cancelTimer(); e.focusMode = false }

        e.noiseOn = true
        now = t0 + 22.5 * 60
        XCTAssertEqual(e.sleepTimer.nightProgress, 0.5, accuracy: 1e-6)
        e.noiseOn = false                                         // headphones out
        now = t0 + 25 * 60
        e.noiseOn = true                                          // back in: the same night
        XCTAssertEqual(e.sleepTimer.nightProgress, 25.0 / 45.0, accuracy: 1e-6)

        e.focusMode = true
        XCTAssertEqual(e.sleepTimer.nightProgress, 0)
    }

    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }
}

/// Which Home tip shows: the first-run card for new users, the "timer moved" note once for people
/// who used the app before the night ring, nothing in Focus.
final class CoachmarkContentTests: XCTestCase {
    func testNewUsersGetTheFirstRunCardOnly() {
        XCTAssertEqual(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: false, hasSeenNightRingTip: false), .firstRun)
        // Retiring it retires the note too (HomeView.retireFirstRunTip sets both).
        XCTAssertNil(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: true, hasSeenNightRingTip: true))
    }

    func testUpgradersSeeTheNightRingNoteOnce() {
        XCTAssertEqual(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: true, hasSeenNightRingTip: false), .nightRing)
        XCTAssertFalse(CoachmarkContent.nightRing.pointsDown)       // it's about the ring above, not Build mix
    }

    func testTheFirstRunCardSaysOneThingAtEitherSize() {
        // The brief card (most phones) shows the title over `briefMessage`: both are about the
        // orb and its ring. Layering is the mixer's own first-open hint now.
        let card = CoachmarkContent.firstRun
        XCTAssertTrue(card.title.contains("orb"))
        XCTAssertTrue(card.briefMessage.contains("ring"))
        XCTAssertFalse(card.title.localizedCaseInsensitiveContains("layer"))
        XCTAssertTrue(card.message.contains("Build mix"), "the full card still points at Build mix")
    }

    func testNoTipsInFocus() {
        XCTAssertNil(CoachmarkContent.current(focusMode: true, hasCompletedFirstRun: false, hasSeenNightRingTip: false))
        XCTAssertNil(CoachmarkContent.current(focusMode: true, hasCompletedFirstRun: true, hasSeenNightRingTip: false))
    }
}

/// The player's one source of truth: the loaded episode leads, Up Next is everything else, and the
/// two never disagree, wherever (or whether) the loaded episode sits in the queue.
final class NowPlayingStateTests: XCTestCase {
    private func ep(_ id: String, duration: TimeInterval? = 100) -> Episode {
        Episode(id: id, title: "Ep \(id)", audioUrl: "http://example.com/\(id)", duration: duration)
    }

    func testNothingLoadedLeadsWithTheHead() {
        let s = NowPlayingState(loaded: nil, queue: [ep("A"), ep("B"), ep("C")])
        XCTAssertEqual(s.hero?.id, "A")
        XCTAssertFalse(s.isLoaded)
        XCTAssertEqual(s.upNext.map(\.id), ["B", "C"])
    }

    func testLoadedEpisodeLeadsEvenWhenTheQueueMovedOn() {
        // A failure (Auto-Play off) or the sleep-aware hold drops the loaded episode from the
        // queue. The sheet used to show the head's art over the loaded title and hide the head.
        let s = NowPlayingState(loaded: ep("X"), queue: [ep("A"), ep("B")])
        XCTAssertEqual(s.hero?.id, "X")
        XCTAssertTrue(s.isLoaded)
        XCTAssertEqual(s.upNext.map(\.id), ["A", "B"], "the cued head stays visible")
    }

    func testLoadedEpisodeMidQueueIsLeftOutOfUpNext() {
        let s = NowPlayingState(loaded: ep("B"), queue: [ep("A"), ep("B"), ep("C")])
        XCTAssertEqual(s.upNext.map(\.id), ["A", "C"])
    }

    func testEmptyQueueAndNothingLoaded() {
        let s = NowPlayingState(loaded: nil, queue: [])
        XCTAssertNil(s.hero)
        XCTAssertTrue(s.upNext.isEmpty)
    }

    func testPhase() {
        func p(loaded: Bool = true, failed: Bool = false, loading: Bool = false, playing: Bool,
               elapsed: Double, duration: Double) -> NowPlayingState.Phase {
            NowPlayingState.phase(isLoaded: loaded, failed: failed, loading: loading, isPlaying: playing,
                                  elapsed: elapsed, duration: duration)
        }
        XCTAssertEqual(p(loaded: false, playing: false, elapsed: 0, duration: 1), .ready)
        XCTAssertEqual(p(loading: true, playing: false, elapsed: 0, duration: 0), .loading)
        XCTAssertEqual(p(playing: true, elapsed: 0, duration: 0), .loading, "playing, first report not in yet")
        XCTAssertEqual(p(failed: true, loading: true, playing: false, elapsed: 30, duration: 100), .failed)
        XCTAssertEqual(p(playing: true, elapsed: 12, duration: 0), .live)
        XCTAssertEqual(p(playing: true, elapsed: 12, duration: 100), .playing)
        XCTAssertEqual(p(playing: false, elapsed: 12, duration: 100), .paused)
        XCTAssertEqual(p(playing: false, elapsed: 99.5, duration: 100), .finished)
    }

    // Regression: a pause before the player's first position report (a call, AirPods out) used to
    // leave .loading, a disabled spinner, with no way to press Play in either player.
    func testPausedBeforeTheFirstReportIsPausedNotLoading() {
        XCTAssertEqual(NowPlayingState.phase(isLoaded: true, failed: false, loading: false, isPlaying: false,
                                             elapsed: 0, duration: 0), .paused)
        XCTAssertEqual(NowPlayingState.phase(isLoaded: true, failed: false, loading: false, isPlaying: false,
                                             elapsed: 40, duration: 0), .paused, "a paused live stream reads paused")
    }

    func testSkipsNeedAPositionNotALength() {
        XCTAssertTrue(NowPlayingState.canSkip(.live), "a live stream keeps back/forward 15")
        XCTAssertTrue(NowPlayingState.canSkip(.paused))
        XCTAssertFalse(NowPlayingState.canSkip(.loading))
        XCTAssertFalse(NowPlayingState.canSkip(.failed))
        XCTAssertFalse(NowPlayingState.canSkip(.ready))
    }

    func testSeekingNeedsAPositionAndALength() {
        XCTAssertTrue(NowPlayingState.canSeek(.paused, duration: 100))
        XCTAssertFalse(NowPlayingState.canSeek(.paused, duration: 0))
        XCTAssertFalse(NowPlayingState.canSeek(.loading, duration: 100))
        XCTAssertFalse(NowPlayingState.canSeek(.failed, duration: 100))
        XCTAssertFalse(NowPlayingState.canSeek(.live, duration: 0))
    }

    // Values from a restored backup or a bad feed used to trap the Int conversion and crash the
    // player on open.
    func testAbsurdValuesFormatWithoutCrashing() {
        XCTAssertFalse(PlayerClock.string(1e300).isEmpty)
        XCTAssertFalse(PlayerClock.short(1e300).isEmpty)
        XCTAssertFalse(PlayerClock.spoken(1e300).isEmpty)
        XCTAssertFalse(PlayerClock.speedLabel(1e300).isEmpty)
        XCTAssertEqual(PlayerClock.speedLabel(.nan), "1\u{00D7}")
        XCTAssertFalse(NightLineCopy.span(1e300).isEmpty)
    }

    func testClockShowsHoursPastAnHour() {
        XCTAssertEqual(PlayerClock.string(0), "0:00")
        XCTAssertEqual(PlayerClock.string(245), "4:05")
        XCTAssertEqual(PlayerClock.string(4607), "1:16:47", "not -76:47")
        XCTAssertEqual(PlayerClock.string(-3), "0:00")
        XCTAssertEqual(PlayerClock.string(.nan), "0:00")
    }

    func testShortLengthsAndSpeeds() {
        XCTAssertEqual(PlayerClock.short(66 * 60 + 41), "1 hr 7 min")
        XCTAssertEqual(PlayerClock.short(45 * 60), "45 min")
        XCTAssertEqual(PlayerClock.short(120 * 60), "2 hr")
        XCTAssertEqual(PlayerClock.short(10), "1 min", "never \"0 min\"")
        XCTAssertEqual(PlayerClock.speedLabel(1.0), "1\u{00D7}")
        XCTAssertEqual(PlayerClock.speedLabel(1.2), "1.2\u{00D7}")
    }

    func testSpokenTimeUsesWords() {
        XCTAssertFalse(PlayerClock.spoken(4607).contains(":"))
        XCTAssertFalse(PlayerClock.spoken(0).isEmpty)
    }
}

/// Next, retry and queue edits from the player. A skip is not a finish.
@MainActor
final class PlayerQueueActionTests: XCTestCase {
    // A local URL that doesn't exist: an engine-level load never touches the network, and the
    // assertions run before any of the player's main-queue callbacks can.
    private func ep(_ id: String) -> Episode {
        Episode(id: id, title: "Ep \(id)", audioUrl: "file:///nonexistent/sleepulator-test-\(id).mp3", duration: 100)
    }

    func testSkipPlaysTheNextEvenWithAutoPlayOff() {
        let qm = PodcastQueueManager()
        qm.autoPlay = false                   // Next used to pause and silently drop the episode
        qm.shuffleQueue = false
        qm.queue = [ep("1"), ep("2"), ep("3")]
        var loaded: (id: String, resume: Bool)?
        qm.loadPodcastFn = { _, id, _, resume in loaded = (id, resume) }
        var paused = false
        qm.pausePodcastFn = { paused = true }

        XCTAssertTrue(qm.skipToNext(currentId: "1"))
        XCTAssertEqual(loaded?.id, "2")
        XCTAssertEqual(loaded?.resume, true, "a tap on Next resumes where you left that episode")
        XCTAssertFalse(paused)
        XCTAssertEqual(qm.queue.map(\.id), ["2", "3"])
    }

    func testSkipNeverMarksPlayed() {
        let qm = PodcastQueueManager()
        qm.shuffleQueue = false
        qm.markUnfinished("1")
        qm.queue = [ep("1"), ep("2")]
        qm.loadPodcastFn = { _, _, _, _ in }
        qm.skipToNext(currentId: "1")
        XCTAssertFalse(qm.finishedEpisodes.contains("1"))
    }

    func testSkipFromAnEpisodeNoLongerQueuedPlaysTheHead() {
        let qm = PodcastQueueManager()
        qm.shuffleQueue = false
        qm.queue = [ep("A"), ep("B")]
        var loadedId: String?
        qm.loadPodcastFn = { _, id, _, _ in loadedId = id }
        qm.skipToNext(currentId: "gone")      // the loaded episode failed and left the queue
        XCTAssertEqual(loadedId, "A")
        XCTAssertEqual(qm.queue.map(\.id), ["A", "B"])
    }

    func testSkipWithNothingAfterChangesNothing() {
        let qm = PodcastQueueManager()
        qm.queue = [ep("1")]
        var loads = 0
        qm.loadPodcastFn = { _, _, _, _ in loads += 1 }
        XCTAssertFalse(qm.skipToNext(currentId: "1"))
        XCTAssertEqual(loads, 0)
        XCTAssertEqual(qm.queue.map(\.id), ["1"])
    }

    func testMoveInUpNextSkipsThePlayingEpisode() {
        let qm = PodcastQueueManager()
        // B is loaded and sits mid-queue; Up Next reads A, C, D.
        qm.queue = [ep("A"), ep("B"), ep("C"), ep("D")]
        qm.moveInUpNext(ep("C"), by: -1, nowPlayingId: "B")
        XCTAssertEqual(qm.queue.map(\.id), ["C", "B", "A", "D"], "C and A trade places; B stays put")
        qm.moveInUpNext(ep("C"), by: -1, nowPlayingId: "B")
        XCTAssertEqual(qm.queue.map(\.id), ["C", "B", "A", "D"], "already first in Up Next")
    }

    func testMoveInUpNextWhenTheLoadedEpisodeLeftTheQueue() {
        let qm = PodcastQueueManager()
        qm.queue = [ep("A"), ep("B")]          // the old moveDown couldn't move the head
        qm.moveInUpNext(ep("A"), by: 1, nowPlayingId: "gone")
        XCTAssertEqual(qm.queue.map(\.id), ["B", "A"])
    }

    func testMoveInUpNextWithNothingLoadedPinsTheHead() {
        let qm = PodcastQueueManager()
        qm.queue = [ep("A"), ep("B"), ep("C")]
        qm.moveInUpNext(ep("B"), by: -1, nowPlayingId: nil)
        XCTAssertEqual(qm.queue.map(\.id), ["A", "B", "C"], "the head is what plays next; it isn't in Up Next")
        qm.moveInUpNext(ep("C"), by: -1, nowPlayingId: nil)
        XCTAssertEqual(qm.queue.map(\.id), ["A", "C", "B"])
    }

    func testRemoveThenUndoPutsItBackInPlace() {
        let qm = PodcastQueueManager()
        qm.queue = [ep("A"), ep("B"), ep("C")]
        let at = qm.remove(ep("B"))
        XCTAssertEqual(at, 1)
        XCTAssertEqual(qm.queue.map(\.id), ["A", "C"])
        qm.restore(ep("B"), at: at!)
        XCTAssertEqual(qm.queue.map(\.id), ["A", "B", "C"])
        qm.restore(ep("B"), at: 0)                     // already back: no duplicate
        XCTAssertEqual(qm.queue.map(\.id), ["A", "B", "C"])
    }

    func testUndoAfterTheQueueShrankClampsTheIndex() {
        let qm = PodcastQueueManager()
        qm.queue = [ep("A"), ep("B"), ep("C")]
        let at = qm.remove(ep("C"))!                  // was at 2
        qm.remove(ep("B"))
        qm.restore(ep("C"), at: at)
        XCTAssertEqual(qm.queue.map(\.id), ["A", "C"])
        XCTAssertNil(qm.remove(ep("Z")), "not queued")
    }

    func testShuffleUpNextMovesTheHeadWhenTheLoadedEpisodeLeftTheQueue() {
        let qm = PodcastQueueManager()
        let eps = (1...8).map { ep("\($0)") }
        var headMoved = false
        for _ in 0..<20 where !headMoved {
            qm.queue = eps
            qm.shuffleRemainingQueue(nowPlayingId: "gone")   // the loaded episode failed and left
            headMoved = qm.queue.first?.id != "1"
        }
        XCTAssertTrue(headMoved, "Up Next's first row (what Next plays) must be shuffleable")
        XCTAssertEqual(Set(qm.queue.map(\.id)), Set(eps.map(\.id)))
    }

    func testShuffleUpNextKeepsTheLoadedEpisodeInPlace() {
        let qm = PodcastQueueManager()
        let eps = (1...6).map { ep("\($0)") }
        qm.queue = eps
        qm.shuffleRemainingQueue(nowPlayingId: "3")
        XCTAssertEqual(qm.queue[2].id, "3")
        XCTAssertEqual(Set(qm.queue.map(\.id)), Set(eps.map(\.id)))
    }

    func testShuffledSkipPromotesARemainingEpisode() {
        let qm = PodcastQueueManager()
        qm.shuffleQueue = true
        defer { qm.shuffleQueue = false }
        qm.queue = [ep("1"), ep("2"), ep("3")]
        var loadedId: String?
        qm.loadPodcastFn = { _, id, _, _ in loadedId = id }
        XCTAssertTrue(qm.skipToNext(currentId: "1"))
        XCTAssertNotNil(loadedId)
        XCTAssertNotEqual(loadedId, "1")
        XCTAssertEqual(qm.queue.first?.id, loadedId)
        XCTAssertEqual(Set(qm.queue.map(\.id)), ["2", "3"])
    }

    func testSkipFromAMidQueueEpisodePlaysUpNextsFirst() {
        let qm = PodcastQueueManager()
        qm.shuffleQueue = false
        qm.queue = [ep("A"), ep("X"), ep("C")]
        var loadedId: String?
        qm.loadPodcastFn = { _, id, _, _ in loadedId = id }
        qm.skipToNext(currentId: "X")
        XCTAssertEqual(loadedId, "A")
        XCTAssertEqual(qm.queue.map(\.id), ["A", "C"])
    }

    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }

    /// An engine whose loads can't start a night: the tests below drive real loads (to a file URL
    /// that doesn't exist), and CLAUDE.md requires session-starting tests to pin the night length.
    /// No real timer backstop notification either.
    private func quietEngine() -> AudioEngine {
        let engine = AudioEngine()
        engine.nightLengthProvider = { 0 }
        engine.sleepTimer.backstop = NoopBackstop()
        return engine
    }

    /// Run with Auto-Play set, then put the user's setting back (it persists to UserDefaults).
    private func withAutoPlay(_ on: Bool, _ engine: AudioEngine, _ body: () -> Void) {
        let saved = engine.queueManager.autoPlay
        engine.queueManager.autoPlay = on
        defer { engine.queueManager.autoPlay = saved; engine.stopAll() }
        body()
    }

    func testRetryPutsTheFailedEpisodeBackAndClearsTheFailure() {
        let engine = quietEngine()
        withAutoPlay(false, engine) {
            engine.queueManager.queue = [ep("1"), ep("2")]
            engine.queueManager.playEpisode(ep("1"))
            XCTAssertEqual(engine.loadedEpisode?.id, "1")
            XCTAssertTrue(engine.episodeLoading)
            // What a failure does: the player reports it, then the episode ends as a failure.
            engine.handlePodcastFailure(episodeId: "1")
            engine.episodeDidEnd("1", didFinish: false)
            XCTAssertTrue(engine.podcastFailed)
            XCTAssertFalse(engine.episodeLoading)
            XCTAssertEqual(engine.playbackNote, NowPlayingState.failedCopy)
            XCTAssertEqual(engine.loadedEpisode?.id, "1", "the player is still on it")
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["1", "2"], "a failure keeps it queued")
            XCTAssertFalse(engine.finishedEpisodes.contains("1"), "a failure is not a listen")

            engine.retryLoadedEpisode()
            XCTAssertFalse(engine.podcastFailed, "Try again must leave the failed state")
            XCTAssertNil(engine.playbackNote)
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["1", "2"])
            XCTAssertEqual(engine.loadedEpisode?.id, "1")
        }
    }

    // A failure arrives through the main queue; one from an item that's since been replaced must
    // not paint "Try again" over the episode now loading.
    func testAFailureFromAReplacedEpisodeIsIgnored() {
        let engine = quietEngine()
        withAutoPlay(false, engine) {
            engine.queueManager.queue = [ep("1"), ep("2")]
            engine.queueManager.playEpisode(ep("2"))
            engine.nightJournal.sessionStarted()             // a night is open
            engine.handlePodcastFailure(episodeId: "1")
            XCTAssertFalse(engine.podcastFailed)
            XCTAssertEqual(engine.nightJournal.open?.taints, [], "a replaced episode's failure spoiled the night")
        }
    }

    func testAFailureWithAutoPlayOnMovesStraightOn() {
        let engine = quietEngine()
        withAutoPlay(true, engine) {
            engine.queueManager.shuffleQueue = false
            engine.queueManager.queue = [ep("1"), ep("2"), ep("3")]
            engine.queueManager.playEpisode(ep("1"))
            engine.handlePodcastFailure(episodeId: "1")
            engine.episodeDidEnd("1", didFinish: false)
            XCTAssertEqual(engine.loadedEpisode?.id, "2")
            XCTAssertFalse(engine.podcastFailed, "the next load clears it")
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["2", "1", "3"],
                           "the failed one stays queued, right behind the one now playing")
            XCTAssertFalse(engine.finishedEpisodes.contains("1"))
        }
    }

    // Next from a failed episode (Auto-Play off) plays the real next, not the one after it.
    func testNextAfterAFailurePlaysTheCuedHead() {
        let engine = quietEngine()
        withAutoPlay(false, engine) {
            engine.queueManager.shuffleQueue = false
            engine.queueManager.queue = [ep("1"), ep("2"), ep("3")]
            engine.queueManager.playEpisode(ep("1"))
            engine.handlePodcastFailure(episodeId: "1")
            engine.episodeDidEnd("1", didFinish: false)
            engine.skipToNextEpisode()
            XCTAssertEqual(engine.loadedEpisode?.id, "2")
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["2", "3"])
        }
    }

    // The phone goes offline at bedtime: every load fails within a second or two. Auto-Play used
    // to advance as if each one had finished, dropping it from the queue, so the whole queue was
    // gone by morning. Now it gives up after a few and the queue reads as it did.
    func testAnOfflineNightKeepsTheQueue() {
        let engine = quietEngine()
        withAutoPlay(true, engine) {
            engine.queueManager.shuffleQueue = false
            engine.queueManager.queue = (1...5).map { ep("\($0)") }
            engine.queueManager.playEpisode(ep("1"))
            var failures = 0
            while let id = engine.loadedEpisode?.id, failures < 10 {
                engine.handlePodcastFailure(episodeId: id)
                engine.episodeDidEnd(id, didFinish: false)
                failures += 1
                if engine.loadedEpisode?.id == id { break }   // nothing new loaded: Auto-Play stopped
            }
            XCTAssertEqual(failures, PodcastQueueManager.failureLimit, "Auto-Play gives up, not drains")
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["1", "2", "3", "4", "5"])
            XCTAssertTrue(engine.finishedEpisodes.isDisjoint(with: ["1", "2", "3"]), "a failure is not a listen")
            XCTAssertTrue(engine.podcastFailed, "the player says so and offers Try again")
        }
    }

    // A failure in the sleep-aware hold (or the ambient tail) plays nothing next, and keeps the
    // episode: it used to be dropped like a finished one.
    func testAFailureDuringTheHoldKeepsTheEpisodeAndPlaysNothing() {
        let engine = quietEngine()
        let savedHold = UserDefaults.standard.object(forKey: "holdQueueDuringSleepTimer")
        UserDefaults.standard.set(true, forKey: "holdQueueDuringSleepTimer")
        defer { UserDefaults.standard.set(savedHold, forKey: "holdQueueDuringSleepTimer") }
        withAutoPlay(true, engine) {
            engine.queueManager.shuffleQueue = false
            engine.queueManager.queue = [ep("1"), ep("2")]
            engine.queueManager.playEpisode(ep("1"))
            engine.sleepTimer.startSleepTimer(minutes: 30)
            defer { engine.sleepTimer.cancelTimer() }
            engine.episodeDidEnd("1", didFinish: false)
            XCTAssertEqual(engine.loadedEpisode?.id, "1", "nothing else starts while you sleep")
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["1", "2"])
        }
    }

    // A failure reaches the engine through the main queue. One from an episode a newer pick has
    // already replaced must leave that pick alone: with Auto-Play off its stop would hold the new
    // load paused, and it would shuffle the queue under it.
    func testAStaleFailureReportLeavesTheNewPickAlone() {
        let engine = quietEngine()
        withAutoPlay(false, engine) {
            engine.queueManager.queue = [ep("1"), ep("2")]
            engine.queueManager.playEpisode(ep("1"))
            engine.queueManager.playEpisode(ep("2"))
            engine.episodeDidEnd("1", didFinish: false)
            XCTAssertTrue(engine.podcastIsPlayingOrStarting, "the pick still starts")
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["2", "1"])
        }
    }

    func testNextIsIgnoredWhileAnEpisodeLoads() {
        let engine = quietEngine()
        withAutoPlay(false, engine) {
            engine.queueManager.shuffleQueue = false
            engine.queueManager.queue = [ep("1"), ep("2")]
            engine.queueManager.playEpisode(ep("1"))
            XCTAssertTrue(engine.episodeLoading)
            engine.skipToNextEpisode()   // a double tap: the first already started this load
            XCTAssertEqual(engine.queueManager.queue.map(\.id), ["1", "2"], "nothing dropped unheard")
        }
    }

    // Resume Last Night after its episode left the queue: the cold-launch podTitle is the queue
    // head's, and the player showed that name over the resumed audio.
    func testLoadingAnUnqueuedEpisodeDoesNotBorrowTheHeadsTitle() {
        let engine = quietEngine()
        defer { engine.stopAll() }
        engine.queueManager.queue = [ep("A")]
        engine.podTitle = "Ep A"
        engine.loadPodcast("file:///nonexistent/sleepulator-test-X.mp3", id: "X",
                           fallbackTitle: "Last night\u{2019}s episode")
        XCTAssertEqual(engine.loadedEpisode?.id, "X")
        XCTAssertEqual(engine.loadedEpisode?.title, "Last night\u{2019}s episode")
        XCTAssertEqual(engine.podTitle, "Last night\u{2019}s episode", "the lock screen agrees")
    }

    // Only a user's pick lifts the ambient tail. An automatic load (auto-advance) during the tail
    // must leave the night's fade and timer alone.
    func testOnlyAUserPickCancelsTheAmbientTail() {
        let engine = quietEngine()
        defer { engine.stopAll() }
        func intoTail() {
            engine.sleepTimer.ambientTailFn = { 300 }
            engine.sleepTimer.tailEligibleFn = { true }
            engine.sleepTimer.startEndOfEpisode(remaining: 60)
            engine.sleepTimer.externalTick(remaining: 0.3)
            XCTAssertTrue(engine.sleepTimer.inTail)
        }
        intoTail()
        engine.queueManager.queue = [ep("2"), ep("3")]
        engine.queueManager.loadPodcastFn?(ep("2").audioUrl, "2", "Ep 2", false)   // auto-advance
        XCTAssertTrue(engine.sleepTimer.inTail, "an automatic load keeps the night")
        engine.queueManager.skipToNext(currentId: "2")                              // a tap on Next
        XCTAssertFalse(engine.sleepTimer.inTail, "picking an episode means awake")
        XCTAssertEqual(engine.sleepTimer.timerRemaining, 0)
    }

    // Try again on Resume Last Night's stand-in reloads it without writing a title-only
    // placeholder into the queue.
    func testRetryingAStandInDoesNotQueueIt() {
        let engine = quietEngine()
        defer { engine.stopAll() }
        engine.queueManager.queue = [ep("A")]
        engine.loadPodcast("file:///nonexistent/sleepulator-test-X.mp3", id: "X", fallbackTitle: "Last night")
        engine.handlePodcastFailure(episodeId: "X")
        engine.retryLoadedEpisode()
        XCTAssertEqual(engine.queueManager.queue.map(\.id), ["A"])
        XCTAssertEqual(engine.loadedEpisode?.id, "X")
        XCTAssertFalse(engine.podcastFailed)
    }

    // The end-of-episode timer ticks off the playback clock; started on a paused episode it would
    // replace the night's timer with one that never runs out.
    func testStopAfterThisEpisodeNeedsTheEpisodePlaying() {
        let engine = quietEngine()
        defer { engine.stopAll() }
        engine.sleepTimer.startSleepTimer(minutes: 45)
        engine.startEndOfEpisodeTimer()   // nothing playing
        XCTAssertFalse(engine.sleepTimer.isEndOfEpisode)
        XCTAssertGreaterThan(engine.sleepTimer.timerRemaining, 0, "the night's timer stands")
        engine.sleepTimer.cancelTimer()
    }
}

/// The veil's timeout over a presented sheet: wait (mid-task), except an idle Now Playing sheet,
/// the brightest surface at night, which closes so the veil can drop.
final class VeilTimeoutNowPlayingTests: XCTestCase {
    func testAnIdleNowPlayingSheetClosesSoTheVeilCanDrop() {
        XCTAssertEqual(SessionGuards.veilTimeout(mayDim: true, presenting: true, nowPlayingUp: true), .closeNowPlaying)
        XCTAssertEqual(SessionGuards.veilTimeout(mayDim: true, presenting: true, nowPlayingUp: false), .wait,
                       "any other sheet or dialog keeps the veil waiting")
        XCTAssertEqual(SessionGuards.veilTimeout(mayDim: true, presenting: true, nowPlayingUp: true,
                                                 assistiveTech: true), .stand,
                       "VoiceOver / Switch Control reach the sheet without touches")
        XCTAssertEqual(SessionGuards.veilTimeout(mayDim: true, presenting: false, assistiveTech: true), .stand,
                       "and navigate without them, so the veil never drops mid-navigation")
        XCTAssertEqual(SessionGuards.veilTimeout(mayDim: false, presenting: true, nowPlayingUp: true), .stand)
        XCTAssertEqual(SessionGuards.veilTimeout(mayDim: true, presenting: false, nowPlayingUp: false), .drop)
    }
}

final class VeilDelayTests: XCTestCase {
    func testTheVeilWaitsTheMinuteUnlessADebugLaunchShortensIt() {
        XCTAssertEqual(SessionGuards.veilDelay(override: 0), 60, "no override: the real minute")
        // The tests run a Debug build, where the argument-domain override applies, held to 5…60 s.
        XCTAssertEqual(SessionGuards.veilDelay(override: 15), 15)
        XCTAssertEqual(SessionGuards.veilDelay(override: 1), 5, "never a veil that drops mid-touch")
        XCTAssertEqual(SessionGuards.veilDelay(override: 600), 60, "never longer than the minute")
    }

    // Value: protects=the glance's real 6 s + 2 s, and a Debug launch's longer hold reaching both the glance and the wake rule; fails_when=glanceHold/glanceFade change, the override's clamp goes, or veilTap ignores the hold it's given; why_new=NightVeilUITests now holds the glance 40 s (-veilGlanceSeconds), so it no longer samples the real window; seam=glanceHold(override:); no_claim=ContentView passing the same hold to the glance's fade and to veilTap (view wiring; NightVeilUITests' wake 9+ s after the glance covers it)
    func testTheGlanceHoldsSixSecondsUnlessADebugLaunchLengthensIt() {
        XCTAssertEqual(SessionGuards.glanceHold, 6, "the glance shows 6 s")
        XCTAssertEqual(SessionGuards.glanceFade, 2, "then fades over 2 s")
        XCTAssertEqual(SessionGuards.glanceHold(override: 0), 6, "no override: the real hold")
        // The tests run a Debug build, where the argument-domain override applies, held to 6…60 s.
        XCTAssertEqual(SessionGuards.glanceHold(override: 40), 40)
        XCTAssertEqual(SessionGuards.glanceHold(override: 1), 6, "never shorter than the real glance")
        XCTAssertEqual(SessionGuards.glanceHold(override: 600), 60)
        // The wake rule follows the hold it's given: 9 s after the glance wakes under a 40 s hold,
        // and is a fresh glance under the real one.
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: 9, assistiveTech: false, hold: 40), .wake)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: 9, assistiveTech: false), .glance)
        XCTAssertEqual(SessionGuards.veilTap(sinceGlance: 42, assistiveTech: false, hold: 40), .glance)
    }
}

final class NightEmberMathTests: XCTestCase {
    func testTheEmberWandersWithinItsRadiusAndNeverJumps() {
        // Burn-in: it must keep moving over the hours, but only ever imperceptibly.
        var previous = NightEmberMath.drift(at: 0)
        var farthest: CGFloat = 0
        for second in stride(from: 1.0, through: 8 * 3600, by: 7) {
            let d = NightEmberMath.drift(at: second)
            XCTAssertLessThanOrEqual(abs(d.width), NightEmberMath.driftRadius + 0.0001)
            XCTAssertLessThanOrEqual(abs(d.height), NightEmberMath.driftRadius + 0.0001)
            XCTAssertLessThan(hypot(d.width - previous.width, d.height - previous.height), 1,
                              "7 s of drift must stay under a point")
            farthest = max(farthest, hypot(d.width, d.height))
            previous = d
        }
        XCTAssertGreaterThan(farthest, NightEmberMath.driftRadius * 0.9, "it must actually move")
    }
}

/// The Night sky meteor's pure rules (`NightSkyMotion`): only for someone watching, faint, rare
/// after the first, and never popping on or off.
final class NightSkyMotionTests: XCTestCase {
    func testMeteorsAreOnlyForSomeoneWatching() {
        XCTAssertTrue(NightSkyMotion.meteorMayFire(night: 0, screensaver: false))
        XCTAssertFalse(NightSkyMotion.meteorMayFire(night: 0, screensaver: true),
                       "under the screensaver someone is drifting off")
        XCTAssertFalse(NightSkyMotion.meteorMayFire(night: 0.4, screensaver: false), "none past 0.4 of the night")
        XCTAssertLessThanOrEqual(NightSkyMotion.meteorBrightness(night: 0), 0.35)
        XCTAssertLessThan(NightSkyMotion.meteorBrightness(night: 0.3), NightSkyMotion.meteorBrightness(night: 0))
        XCTAssertLessThan(NightSkyMotion.meteorDelay(first: true).upperBound,
                          NightSkyMotion.meteorDelay(first: false).lowerBound,
                          "the first meteor comes soon; the rest are rare")
    }

    func testAMeteorNeverPopsOnOrOff() {
        // Its light is 0 at both ends of its run and rises and falls with no step between.
        XCTAssertEqual(NightSkyMotion.meteorEnvelope(0), 0)
        XCTAssertEqual(NightSkyMotion.meteorEnvelope(1), 0)
        XCTAssertEqual(NightSkyMotion.meteorEnvelope(0.3), 1)
        var previous = 0.0
        for step in 1...1000 {
            let e = NightSkyMotion.meteorEnvelope(Double(step) / 1000)
            XCTAssertLessThan(abs(e - previous), 0.02, "a jump at \(step)/1000")
            previous = e
        }
    }
}

/// Pure text rules behind the podcast screens (`PodcastText`): show-notes cleanup, counts, and
/// placeholder show names.
final class PodcastTextTests: XCTestCase {

    func testShowNotesStripTagsAndKeepParagraphs() {
        let html = "<p>A sleepy stroll down <strong>memory</strong> lane.</p><p>Get <a href=\"https://x.com/a\">SleepPhones</a> &amp; more.</p>"
        XCTAssertEqual(PodcastText.plainShowNotes(html),
                       "A sleepy stroll down memory lane.\n\nGet SleepPhones & more.")
    }

    func testShowNotesLineBreaksListsAndEntities() {
        let html = "Line one<br/>Line two<ul><li>First</li><li>Second</li></ul>It&#8217;s &#x2014; &rsquo;quiet&lsquo; &nbsp;now"
        XCTAssertEqual(PodcastText.plainShowNotes(html),
                       "Line one\nLine two\n\n• First\n• Second\n\nIt\u{2019}s \u{2014} \u{2019}quiet\u{2018} now")
    }

    func testShowNotesDropScriptAndComments() {
        let html = "<p>Kept</p><script>var x = '<p>no</p>';</script><!-- hidden --><style>p{}</style><p>Also kept</p>"
        XCTAssertEqual(PodcastText.plainShowNotes(html), "Kept\n\nAlso kept")
    }

    func testShowNotesDoubleEncodedMarkup() {
        // The XML layer already decoded one level; the feed encoded the HTML twice.
        XCTAssertEqual(PodcastText.plainShowNotes("&lt;p&gt;Hello &amp;amp; goodnight&lt;/p&gt;"),
                       "Hello & goodnight")
    }

    func testShowNotesLeavePlainTextAndStrayAnglesAlone() {
        let plain = "Episode 3: a < b > c, and <3 for listeners.\nSecond line."
        XCTAssertEqual(PodcastText.plainShowNotes(plain), plain)
        // Idempotent on its own output, so re-cleaning cached episodes is safe.
        let once = PodcastText.plainShowNotes("<p>One</p><p>Two &amp; three</p>")
        XCTAssertEqual(PodcastText.plainShowNotes(once), once)
    }

    func testShowNotesCapAtAWordBoundary() {
        let long = Array(repeating: "word", count: 2_000).joined(separator: " ")
        let capped = PodcastText.plainShowNotes(long, limit: 100)
        XCTAssertLessThanOrEqual(capped.count, 101)
        XCTAssertTrue(capped.hasSuffix("word\u{2026}"), "cuts between words, then an ellipsis")
    }

    func testWithPlainShowNotesNilsEmptyNotes() {
        let eps = [
            Episode(id: "1", title: "A", audioUrl: "u", duration: nil, pubDate: nil, description: "<p>Hi</p>"),
            Episode(id: "2", title: "B", audioUrl: "u", duration: nil, pubDate: nil, description: "<p> </p>"),
            Episode(id: "3", title: "C", audioUrl: "u", duration: nil, pubDate: nil, description: nil),
        ]
        let cleaned = PodcastText.withPlainShowNotes(eps)
        XCTAssertEqual(cleaned.map(\.description), ["Hi", nil, nil])
    }

    func testCountsAndSubtitles() {
        XCTAssertEqual(PodcastText.episodeCount(1), "1 episode")
        XCTAssertEqual(PodcastText.episodeCount(750), "750 episodes")
        XCTAssertEqual(PodcastText.showCount(1), "1 show")
        XCTAssertEqual(PodcastText.showCount(0), "0 shows")
        XCTAssertEqual(PodcastText.librarySubtitle(total: 0, unplayed: 0), "Tap to load episodes")
        XCTAssertEqual(PodcastText.librarySubtitle(total: 40, unplayed: 40), "40 episodes")
        XCTAssertEqual(PodcastText.librarySubtitle(total: 40, unplayed: 3), "3 unplayed of 40")
        XCTAssertEqual(PodcastText.librarySubtitle(total: 1, unplayed: 0), "All caught up · 1 episode")
    }

    func testDurations() {
        XCTAssertNil(PodcastText.duration(nil))
        XCTAssertNil(PodcastText.duration(0))
        XCTAssertEqual(PodcastText.duration(30), "<1 min")
        XCTAssertEqual(PodcastText.duration(42 * 60), "42 min")
        XCTAssertEqual(PodcastText.duration(3600), "1 hr")
        XCTAssertEqual(PodcastText.duration(3723), "1 hr 2 min")
    }

    func testPlaceholderNames() {
        let feed = "https://feeds.simplecast.com/Sl5CSM3S"
        XCTAssertTrue(PodcastText.isPlaceholderName("", feedURL: feed))
        XCTAssertTrue(PodcastText.isPlaceholderName("Podcast", feedURL: feed))
        XCTAssertTrue(PodcastText.isPlaceholderName("feeds.simplecast.com", feedURL: feed))
        XCTAssertTrue(PodcastText.isPlaceholderName("example.com", feedURL: "https://www.example.com/rss"))
        XCTAssertFalse(PodcastText.isPlaceholderName("The Daily", feedURL: feed))
        // A real title that happens to contain ".com" stays (the old rule renamed these).
        XCTAssertFalse(PodcastText.isPlaceholderName("Sleep.com Stories", feedURL: feed))
    }
}

/// The Tonight shelf and the show page's Resume button (`TonightShelf`), plus the night cue copy.
final class TonightShelfTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private func ep(_ id: String, daysAgo: Double? = nil, duration: TimeInterval? = 3_600) -> Episode {
        Episode(id: id, title: "Ep \(id)", audioUrl: "https://e.example/\(id).mp3", duration: duration,
                pubDate: daysAgo.map { Date(timeIntervalSince1970: 1_800_000_000 - $0 * day) }, description: nil)
    }
    private func show(_ eps: [Episode]) -> Podcast {
        Podcast(id: "feed", name: "Sleep Show", url: "feed", episodes: eps)
    }

    func testEmptyWithoutAKnownSnapshotEpisode() {
        let lib = [show([ep("a", daysAgo: 1)])]
        XCTAssertTrue(TonightShelf.plan(library: lib, lastEpisodeId: nil, lastPosition: nil, savedPositions: [:], finished: []).isEmpty)
        XCTAssertTrue(TonightShelf.plan(library: lib, lastEpisodeId: "gone", lastPosition: 500, savedPositions: [:], finished: []).isEmpty)
    }

    /// The saved-positions map is written on every pause; the Last Night snapshot only on
    /// pause-all / stop / backgrounding, so after a podcast-only pause it's stale and must lose.
    func testResumePrefersTheSavedPositionOverAStaleSnapshot() throws {
        let lib = [show([ep("new", daysAgo: 1), ep("b", daysAgo: 3)])]
        let plan = TonightShelf.plan(library: lib, lastEpisodeId: "b", lastPosition: 1_200, savedPositions: ["b": 2_400], finished: [])
        let resume = try XCTUnwrap(plan.resume)
        XCTAssertEqual(resume.episode.id, "b")
        XCTAssertEqual(resume.position, 2_400)
        XCTAssertEqual(resume.remaining, 1_200)
        XCTAssertEqual(plan.next?.episode.id, "new", "next is the newest unplayed, not the resumed one")
        // Nothing saved for it yet: the snapshot is the fallback.
        XCTAssertEqual(TonightShelf.plan(library: lib, lastEpisodeId: "b", lastPosition: 1_200, savedPositions: [:], finished: []).resume?.position, 1_200)
    }

    func testANearlyFinishedSnapshotIsNeitherResumedNorNext() {
        let lib = [show([ep("new", daysAgo: 1), ep("b", daysAgo: 3)])]
        let plan = TonightShelf.plan(library: lib, lastEpisodeId: "b", lastPosition: 3_590, savedPositions: [:], finished: [])
        XCTAssertNil(plan.resume, "10 s left isn't worth resuming")
        XCTAssertEqual(plan.next?.episode.id, "new")
        // The show page agrees.
        XCTAssertNil(TonightShelf.showResumeTarget(podcast: lib[0], lastEpisodeId: "b", lastPosition: 3_590,
                                                   savedPositions: [:], finished: []))
        // A spent snapshot in a one-episode show leaves nothing to offer.
        XCTAssertTrue(TonightShelf.plan(library: [show([ep("b", daysAgo: 3)])], lastEpisodeId: "b", lastPosition: 3_590,
                                        savedPositions: [:], finished: []).isEmpty)
    }

    func testResumeAloneWhenNothingElseIsUnplayedAndTheThirtySecondEdge() {
        let lib = [show([ep("only", daysAgo: 2)])]
        let plan = TonightShelf.plan(library: lib, lastEpisodeId: "only", lastPosition: 30, savedPositions: [:], finished: [])
        XCTAssertEqual(plan.resume?.position, 30, "30 s is under way")
        XCTAssertNil(plan.next)
        XCTAssertFalse(plan.isEmpty)
    }

    func testShowResumeTargetFallsThroughPastLastNight() {
        let p = show([ep("new", daysAgo: 1), ep("mid", daysAgo: 4), ep("old", daysAgo: 8)])
        XCTAssertEqual(TonightShelf.showResumeTarget(podcast: p, lastEpisodeId: "old", lastPosition: 600,
                                                     savedPositions: ["mid": 900], finished: ["old"])?.episode.id, "mid",
                       "last night's episode is finished")
        XCTAssertEqual(TonightShelf.showResumeTarget(podcast: p, lastEpisodeId: "old", lastPosition: 10,
                                                     savedPositions: ["mid": 900], finished: [])?.episode.id, "mid",
                       "last night's episode barely started")
    }

    func testBackUpLabelsFollowTheInterval() {
        XCTAssertEqual(TonightShelf.backUpLabel, "Back \(Int(TonightShelf.backUpInterval / 60)) min")
        XCTAssertEqual(TonightShelf.backUpPosition(from: TonightShelf.backUpInterval + 1), 1)
    }

    func testABarelyStartedEpisodeIsOfferedAsNext() {
        let lib = [show([ep("new", daysAgo: 1), ep("cued", daysAgo: 2)])]
        let plan = TonightShelf.plan(library: lib, lastEpisodeId: "cued", lastPosition: 10, savedPositions: [:], finished: [])
        XCTAssertNil(plan.resume)
        XCTAssertEqual(plan.next?.episode.id, "cued", "cued overnight, never listened to")
    }

    func testAFinishedSnapshotEpisodeLeavesOnlyNext() {
        let lib = [show([ep("new", daysAgo: 1), ep("done", daysAgo: 2), ep("old", daysAgo: 9)])]
        let plan = TonightShelf.plan(library: lib, lastEpisodeId: "done", lastPosition: 3_500, savedPositions: [:], finished: ["done", "new"])
        XCTAssertNil(plan.resume)
        XCTAssertEqual(plan.next?.episode.id, "old")
    }

    func testLatestUnplayedSortsByDateWithUndatedLast() {
        let p = show([ep("undated", daysAgo: nil), ep("older", daysAgo: 5), ep("newest", daysAgo: 1)])
        XCTAssertEqual(TonightShelf.latestUnplayed(in: p, finished: [], excluding: nil)?.id, "newest")
        XCTAssertEqual(TonightShelf.latestUnplayed(in: p, finished: ["newest"], excluding: "older")?.id, "undated")
        XCTAssertNil(TonightShelf.latestUnplayed(in: show([ep("x")]), finished: ["x"], excluding: nil))
    }

    func testBackUpAndRemaining() {
        XCTAssertEqual(TonightShelf.backUpPosition(from: 1_000), 700)
        XCTAssertEqual(TonightShelf.backUpPosition(from: 120), 0)
        XCTAssertNil(TonightShelf.remaining(duration: nil, position: 10))
        XCTAssertEqual(TonightShelf.remaining(duration: 100, position: 140), 0)
    }

    func testShowResumeTarget() {
        let p = show([ep("new", daysAgo: 1), ep("mid", daysAgo: 4), ep("almost", daysAgo: 2), ep("old", daysAgo: 8)])
        // Last night's episode from this show wins.
        XCTAssertEqual(TonightShelf.showResumeTarget(podcast: p, lastEpisodeId: "old", lastPosition: 600,
                                                     savedPositions: ["mid": 900], finished: [])?.episode.id, "old")
        // Otherwise the newest in-progress episode, ignoring one within 30 s of its end.
        let target = TonightShelf.showResumeTarget(podcast: p, lastEpisodeId: "elsewhere", lastPosition: 600,
                                                   savedPositions: ["mid": 900, "almost": 3_590, "old": 300], finished: [])
        XCTAssertEqual(target?.episode.id, "mid")
        XCTAssertEqual(target?.position, 900)
        XCTAssertNil(TonightShelf.showResumeTarget(podcast: p, lastEpisodeId: nil, lastPosition: nil,
                                                   savedPositions: ["new": 10], finished: []))
    }

    func testTimeLeftAndNightCue() {
        XCTAssertEqual(PodcastText.timeLeft(23 * 60), "23 min left")
        XCTAssertEqual(PodcastText.timeLeft(3_900), "1 hr 5 min left")
        XCTAssertEqual(PodcastText.timeLeft(20), "<1 min left")
        XCTAssertNil(PodcastText.timeLeft(nil))
        XCTAssertEqual(PodcastText.nightLabel(minutes: 45), "45-min")
        XCTAssertEqual(PodcastText.nightLabel(minutes: 120), "2-hour")
        XCTAssertEqual(PodcastText.nightLabel(minutes: 90), "1 hr 30 min")

        XCTAssertNil(PodcastText.nightCue(remaining: 5_000, nightMinutes: 45, focusMode: true), "Focus has no night")
        XCTAssertNil(PodcastText.nightCue(remaining: 5_000, nightMinutes: 0, focusMode: false), "All night never runs past")
        XCTAssertNil(PodcastText.nightCue(remaining: 45 * 60 + 50, nightMinutes: 45, focusMode: false), "a minute of grace")
        XCTAssertEqual(PodcastText.nightCue(remaining: 84 * 60, nightMinutes: 45, focusMode: false), "Runs past your 45-min night")
        XCTAssertEqual(PodcastText.nightCue(remaining: 3 * 3_600, nightMinutes: 90, focusMode: false), "Runs past your 1 hr 30 min night")
        XCTAssertEqual(PodcastText.nightCue(remaining: 3 * 3_600, nightMinutes: 120, focusMode: false), "Runs past your 2-hour night")
    }
}

final class ShowNotesPreviewTests: XCTestCase {
    func testPreviewKeepsWholeOpeningParagraphs() {
        let notes = "A sleepy stroll down memory lane.\n\nThis is a special release from the vault.\n\n" + String(repeating: "Sponsor read. ", count: 40)
        let preview = PodcastText.notesPreview(notes)
        XCTAssertEqual(preview, "A sleepy stroll down memory lane.\n\nThis is a special release from the vault.")
        XCTAssertNotEqual(preview, notes, "something was held back, so the row offers More")
    }

    func testShortNotesNeedNoMore() {
        XCTAssertEqual(PodcastText.notesPreview("Short notes."), "Short notes.")
    }

    func testOneLongParagraphIsCutAtAWord() {
        let long = Array(repeating: "word", count: 300).joined(separator: " ")
        let preview = PodcastText.notesPreview(long)
        XCTAssertTrue(preview.hasSuffix("word\u{2026}"))
        XCTAssertLessThan(preview.count, long.count)
    }
}


final class ShowNotesEdgeTests: XCTestCase {
    /// Stored notes are already plain and can quote angle brackets; showing them must not strip
    /// them as tags (EpisodeRowView goes through displayShowNotes).
    func testDisplayKeepsQuotedAngleBracketsInStoredNotes() {
        let stored = PodcastText.plainShowNotes("<p>Write to &lt;hello@show.example&gt; or press &lt;Enter&gt;.</p>")
        XCTAssertEqual(stored, "Write to <hello@show.example> or press <Enter>.")
        XCTAssertEqual(PodcastText.displayShowNotes(stored), stored)
        // Notes cached before the parser cleaned them still get cleaned for display.
        XCTAssertEqual(PodcastText.displayShowNotes("<p>Old <b>cached</b> notes</p>"), "Old cached notes")
    }

    func testCapPrefersAParagraphThenHardCutsUnspacedText() {
        let a = String(repeating: "a", count: 60)
        let notes = a + "\n\n" + Array(repeating: "b", count: 100).joined(separator: " ")
        XCTAssertEqual(PodcastText.plainShowNotes(notes, limit: 100), a + "\u{2026}")
        let cjk = String(repeating: "夜", count: 200)
        XCTAssertEqual(PodcastText.plainShowNotes(cjk, limit: 50), String(repeating: "夜", count: 50) + "\u{2026}")
    }

    /// A malformed <itunes:duration> ("inf", "1e30") must not trap the row or the shelf.
    func testDurationRejectsNonFiniteAndAbsurdLengths() {
        XCTAssertNil(PodcastText.duration(.infinity))
        XCTAssertNil(PodcastText.duration(.nan))
        XCTAssertNil(PodcastText.duration(1e30))
        XCTAssertNil(PodcastText.timeLeft(.infinity))
        XCTAssertEqual(PodcastText.duration(PodcastText.longestDuration), "720 hr")
    }

    func testPlaceholderCoversOPMLLinkNamesAndTheFallbackName() throws {
        let feed = "https://feeds.simplecast.com/Sl5CSM3S"
        XCTAssertTrue(PodcastText.isPlaceholderName(feed, feedURL: feed), "OPML names an untitled outline after its link")
        XCTAssertTrue(PodcastText.isPlaceholderName("https://elsewhere.example/rss", feedURL: feed))
        let url = try XCTUnwrap(URL(string: "https://www.example.com/rss"))
        XCTAssertEqual(PodcastText.fallbackName(for: url), "example.com")
        XCTAssertTrue(PodcastText.isPlaceholderName(PodcastText.fallbackName(for: url), feedURL: url.absoluteString))
    }

    /// Decoded text that quotes angle brackets isn't markup, even when it starts like a tag name.
    func testQuotedAnglesThatLookLikeTagNamesSurvive() {
        let stored = PodcastText.plainShowNotes("<p>Say &lt;pause&gt; or write &lt;podcast@show.example&gt;</p>")
        XCTAssertEqual(stored, "Say <pause> or write <podcast@show.example>")
        XCTAssertEqual(PodcastText.displayShowNotes(stored), stored)
    }

    /// Stray "<" with no closing ">" used to rescan the rest of the text each time (quadratic).
    func testStrayAngleBracketsAndHugeNotesStayCheap() {
        let start = Date()
        let strays = String(repeating: "< ", count: 50_000)
        XCTAssertFalse(PodcastText.plainShowNotes(strays).isEmpty)
        let huge = String(repeating: "<p>Sponsor read.</p>", count: 20_000)
        XCTAssertLessThanOrEqual(PodcastText.plainShowNotes(huge).count, PodcastText.showNotesLimit + 1)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5, "linear, not quadratic")
    }

    func testOfflineErrors() {
        XCTAssertTrue(PodcastText.isOffline(URLError(.notConnectedToInternet)))
        XCTAssertFalse(PodcastText.isOffline(URLError(.timedOut)))
        XCTAssertFalse(PodcastText.isOffline(CocoaError(.fileNoSuchFile)))
    }

    /// The step parseFeed runs after parsing: what gets stored is plain, capped text.
    @MainActor
    func testFinalizedFeedHasPlainShowNotes() async throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rss><channel><title>T</title>
          <item><guid>1</guid><enclosure url="https://e.example/1.mp3" type="audio/mpeg"/>
            <description><![CDATA[<p>Hello <a href="https://x.example">there</a> &amp; welcome</p>]]></description></item>
          <item><guid>2</guid><enclosure url="https://e.example/2.mp3" type="audio/mpeg"/>
            <description><![CDATA[<p>\(String(repeating: "word ", count: 1_000))</p>]]></description></item>
        </channel></rss>
        """
        let parsed = try PodcastParser().parse(data: Data(xml.utf8))
        let feed = await PodcastParser.finalize(parsed)
        XCTAssertEqual(feed.episodes.first?.description, "Hello there & welcome")
        XCTAssertLessThanOrEqual(feed.episodes.last?.description?.count ?? .max, PodcastText.showNotesLimit + 1)
    }
}

@MainActor
final class QueueMoveToHeadTests: XCTestCase {
    private func ep(_ id: String) -> Episode {
        Episode(id: id, title: id.uppercased(), audioUrl: "", duration: 100, pubDate: nil, description: nil)
    }

    /// The Podcasts tab's resume path re-heads the queue in one write (one persist, one publish).
    func testMoveToHeadIsOneWriteAndNoWriteWhenAlreadyFirst() {
        let qm = PodcastQueueManager()
        qm.queue = [ep("a"), ep("b"), ep("c")]
        var writes = 0
        let sub = qm.$queue.dropFirst().sink { _ in writes += 1 }
        qm.moveToHead(ep("c"))
        XCTAssertEqual(qm.queue.map(\.id), ["c", "a", "b"])
        XCTAssertEqual(writes, 1)
        qm.moveToHead(ep("c"))
        XCTAssertEqual(writes, 1, "already the head: nothing to write")
        qm.moveToHead(ep("d"))
        XCTAssertEqual(qm.queue.map(\.id), ["d", "c", "a", "b"])
        sub.cancel()
    }
}

/// Auto-Play after a failure: the failed episode stays queued, and a run of failures (the phone
/// offline) stops after `failureLimit` instead of walking, and emptying, the whole queue.
@MainActor
final class PodcastFailureStreakTests: XCTestCase {
    private var qm: PodcastQueueManager!
    private var saved: (autoPlay: Bool, shuffle: Bool)!
    private var loads: [(id: String, resume: Bool)] = []
    private var pauses = 0

    override func setUp() {
        qm = PodcastQueueManager()
        saved = (qm.autoPlay, qm.shuffleQueue)
        qm.autoPlay = true
        qm.shuffleQueue = false
        loads = []
        pauses = 0
        qm.loadPodcastFn = { [unowned self] _, id, _, resume in self.loads.append((id, resume)) }
        qm.pausePodcastFn = { [unowned self] in self.pauses += 1 }
        qm.queue = (1...5).map(ep)
    }

    override func tearDown() {
        qm.autoPlay = saved.autoPlay
        qm.shuffleQueue = saved.shuffle
        qm = nil
    }

    private func ep(_ n: Int) -> Episode {
        Episode(id: "\(n)", title: "Ep \(n)", audioUrl: "file:///nonexistent/streak-\(n).mp3", duration: 100)
    }

    private var ids: [String] { qm.queue.map(\.id) }

    func testFailuresMoveOnThenStopWithTheQueueAsItWas() {
        XCTAssertTrue(qm.advancePastFailure(failedEpId: "1"))
        XCTAssertEqual(loads.last?.id, "2")
        XCTAssertEqual(loads.last?.resume, false, "from the start, like any auto-advance")
        XCTAssertEqual(ids, ["2", "1", "3", "4", "5"], "now playing at the head, the failed one behind it")

        XCTAssertTrue(qm.advancePastFailure(failedEpId: "2"))
        XCTAssertEqual(loads.last?.id, "3", "never back to one that already failed in this run")
        XCTAssertEqual(ids, ["3", "1", "2", "4", "5"])

        XCTAssertFalse(qm.advancePastFailure(failedEpId: "3"))
        XCTAssertEqual(loads.count, 2, "stopped at the limit")
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(ids, ["1", "2", "3", "4", "5"], "the morning queue reads as it did at bedtime")
        XCTAssertTrue(qm.finishedEpisodes.isDisjoint(with: ["1", "2", "3"]))
    }

    func testAFinishStartsTheCountOver() {
        qm.advancePastFailure(failedEpId: "1")             // → 2
        qm.advancePastFailure(failedEpId: "2")             // → 3
        qm.advanceQueue(finishedEpId: "3")                 // 3 plays to its end: loads work
        XCTAssertEqual(loads.last?.id, "1", "the failed ones get another go")
        XCTAssertTrue(qm.advancePastFailure(failedEpId: "1"), "a fresh run, not the third in a row")
        XCTAssertEqual(loads.last?.id, "2")
    }

    func testAPersonsPickStartsTheCountOver() {
        qm.advancePastFailure(failedEpId: "1")
        qm.advancePastFailure(failedEpId: "2")
        qm.playEpisode(ep(4))
        XCTAssertTrue(qm.advancePastFailure(failedEpId: "4"))
    }

    func testWithAutoPlayOffAFailureStopsAndKeepsTheEpisode() {
        qm.autoPlay = false
        XCTAssertFalse(qm.advancePastFailure(failedEpId: "1"))
        XCTAssertTrue(loads.isEmpty)
        XCTAssertEqual(pauses, 1)
        XCTAssertEqual(ids, ["1", "2", "3", "4", "5"])
    }

    func testNothingStartsWhenTheNightSaysStop() {
        // The ambient tail and the sleep-aware hold pass `mayContinue: false`.
        XCTAssertFalse(qm.advancePastFailure(failedEpId: "1", mayContinue: false))
        XCTAssertTrue(loads.isEmpty)
        XCTAssertEqual(ids, ["1", "2", "3", "4", "5"])
    }

    func testTheOnlyEpisodeFailingStops() {
        qm.queue = [ep(1)]
        XCTAssertFalse(qm.advancePastFailure(failedEpId: "1"))
        XCTAssertTrue(loads.isEmpty)
        XCTAssertEqual(ids, ["1"])
    }

    func testShuffleNeverPicksOneThatFailedThisRun() {
        qm.shuffleQueue = true
        for _ in 0..<20 {
            qm.resetFailureStreak()
            qm.queue = (1...6).map(ep)
            loads = []
            XCTAssertTrue(qm.advancePastFailure(failedEpId: "1"))
            let second = try! XCTUnwrap(loads.last?.id)
            XCTAssertNotEqual(second, "1")
            XCTAssertTrue(qm.advancePastFailure(failedEpId: second))
            XCTAssertFalse(["1", second].contains(loads.last!.id))
            XCTAssertEqual(Set(ids), Set((1...6).map { "\($0)" }), "nothing dropped")
        }
    }
}

/// A pause, a stop or a call while an episode is still loading must stick. The load awaits the
/// limiter tap (up to 1.5 s) and the resume-seek, then used to play regardless, undoing the pause.
/// Real AVPlayer (simulator), like `PodcastPlayerRebuildTests`.
@MainActor
final class PodcastLoadHoldTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hold-\(UUID().uuidString).wav")
        try PodcastPlayerRebuildTests.quietWav(seconds: 20).write(to: fileURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func settle(_ seconds: Double = 1.5) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testAPauseDuringALoadHoldsTheEpisodePaused() async {
        let p = PodcastPlayer()
        defer { p.stop() }
        var reports: [Bool] = []
        p.onPlaybackStateChanged = { reports.append($0) }
        let id = "hold-\(UUID().uuidString)"
        p.play(url: fileURL.absoluteString, id: id, title: "Held", resume: false)
        XCTAssertTrue(p.isStartingPlayback)
        p.pause()                                     // the lock screen, inside the load window
        XCTAssertFalse(p.isStartingPlayback)

        let landed = await waitUntil { p.hasPlayer && !p.isLoadingItem }
        XCTAssertTrue(landed, "the load still lands")
        await settle()
        XCTAssertEqual(reports, [false], "it must not report playing after the pause")
        XCTAssertLessThan(p.currentPositionSeconds ?? 0, 0.3, "the clock must not run")
        XCTAssertEqual(p.currentEpisodeId, id, "the new episode is loaded, paused")

        p.resume()                                    // and a later play starts it
        let playing = await waitUntil { (p.currentPositionSeconds ?? 0) > 0.5 }
        XCTAssertTrue(playing)
        XCTAssertEqual(reports.last, true)
    }

    func testTheTimersStopDuringAnAutoAdvanceIsNotUndone() async {
        let p = PodcastPlayer()
        defer { p.stop() }
        p.play(url: fileURL.absoluteString, id: "a-\(UUID().uuidString)", title: "A", resume: false)
        let first = await waitUntil { (p.currentPositionSeconds ?? 0) > 0.3 }
        XCTAssertTrue(first, "the first episode never played")

        var reports: [Bool] = []
        p.onPlaybackStateChanged = { reports.append($0) }
        let next = "b-\(UUID().uuidString)"
        p.play(url: fileURL.absoluteString, id: next, title: "B", resume: false)   // the queue moves on
        p.stop()                                      // ...and the sleep timer's terminal stop lands
        let landed = await waitUntil { !p.isLoadingItem }
        XCTAssertTrue(landed)
        await settle()
        XCTAssertEqual(reports, [false], "the next episode must not start after everything stopped")
        XCTAssertEqual(p.currentEpisodeId, next)
        XCTAssertLessThan(p.currentPositionSeconds ?? 0, 0.3)
    }

    func testAPlayDuringALoadAfterAPauseStillStartsIt() async {
        // Guard against over-correcting: pause then play inside the window plays the NEW episode.
        let p = PodcastPlayer()
        defer { p.stop() }
        var reports: [Bool] = []
        p.onPlaybackStateChanged = { reports.append($0) }
        p.play(url: fileURL.absoluteString, id: "r-\(UUID().uuidString)", title: "R", resume: false)
        p.pause()
        XCTAssertTrue(p.resume(), "a play mid-load is handled, not refused")
        XCTAssertTrue(p.isStartingPlayback)
        let playing = await waitUntil { (p.currentPositionSeconds ?? 0) > 0.5 }
        XCTAssertTrue(playing)
        XCTAssertEqual(reports.last, true)
    }

    func testAnAirPodsToggleDuringALoadPauses() async {
        // Mid-load there's no playing AVPlayer to read, so a toggle used to do nothing (or resume).
        let p = PodcastPlayer()
        defer { p.stop() }
        var reports: [Bool] = []
        p.onPlaybackStateChanged = { reports.append($0) }
        p.play(url: fileURL.absoluteString, id: "t-\(UUID().uuidString)", title: "T", resume: false)
        XCTAssertFalse(p.toggle(), "a toggle over a starting load means pause")
        _ = await waitUntil { p.hasPlayer && !p.isLoadingItem }
        await settle()
        XCTAssertEqual(reports, [false])
        XCTAssertLessThan(p.currentPositionSeconds ?? 0, 0.3)
    }

    // MARK: Through the engine

    private final class NoopBackstop: SleepTimerBackstopScheduling {
        func schedule(after seconds: TimeInterval) {}
        func cancel() {}
    }

    private func sleepEngine(nightMinutes: Double) -> AudioEngine {
        let e = AudioEngine()
        e.sleepTimer.backstop = NoopBackstop()
        e.nightLengthProvider = { nightMinutes }
        e.focusMode = false
        return e
    }

    private func interruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) -> Notification {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended {
            info[AVAudioSessionInterruptionOptionKey] =
                (shouldResume ? AVAudioSession.InterruptionOptions.shouldResume : []).rawValue
        }
        return Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }

    func testPlayOnAFirstLoadPausedMidwayResumesThatLoad() {
        // No AVPlayer exists until a first load lands, so Play used to start the queue's head
        // instead (Resume Last Night's episode swapped for another one).
        let e = sleepEngine(nightMinutes: 0)
        defer { e.stopAll() }
        e.queueManager.queue = [Episode(id: "head-\(UUID().uuidString)", title: "Head",
                                        audioUrl: fileURL.absoluteString, duration: 20)]
        let id = "last-night-\(UUID().uuidString)"
        e.loadPodcast(fileURL.absoluteString, id: id, fallbackTitle: "Last night")
        e.pauseAll()
        XCTAssertFalse(e.podcastIsPlayingOrStarting)
        e.togglePodcast()                              // the Play the paused load shows
        XCTAssertTrue(e.podcastIsPlayingOrStarting)
        XCTAssertEqual(e.loadedEpisode?.id, id, "the same episode, not the queue head")
    }

    func testTheTerminalStopDuringALoadArmsNoFreshNight() async {
        // The reported symptom: the next episode started after "everything stopped", and that
        // idle → playing edge armed a brand-new night timer over it.
        let e = sleepEngine(nightMinutes: 45)
        defer { e.stopAll(); e.sleepTimer.cancelTimer() }
        e.loadPodcast(fileURL.absoluteString, id: "stop-\(UUID().uuidString)", resume: false)
        XCTAssertTrue(e.podcastIsPlayingOrStarting)
        e.stopAll()
        XCTAssertFalse(e.podcastIsPlayingOrStarting)
        let landed = await waitUntil { e.hasLoadedEpisode }
        XCTAssertTrue(landed)
        await settle()
        XCTAssertFalse(e.isPodPlaying, "stopped means stopped")
        XCTAssertEqual(e.sleepTimer.timerRemaining, 0, "no night timer armed over a stopped app")
    }

    func testACallDuringALoadHoldsItAndItsEndBringsItBack() async {
        let e = sleepEngine(nightMinutes: 0)
        defer { e.stopAll() }
        e.loadPodcast(fileURL.absoluteString, id: "call-\(UUID().uuidString)", resume: false)
        XCTAssertFalse(e.isPodPlaying, "mid-load: not reported playing yet")
        e.handleInterruption(note: interruption(.began))
        XCTAssertFalse(e.podcastIsPlayingOrStarting, "the call pauses the load in flight")
        _ = await waitUntil { e.hasLoadedEpisode }
        await settle()
        XCTAssertFalse(e.isPodPlaying, "the episode must not start under the call")

        e.handleInterruption(note: interruption(.ended, shouldResume: true))
        let resumed = await waitUntil { e.isPodPlaying }
        XCTAssertTrue(resumed, "the call's end brings back what was starting")
    }

    // Value: protects=headphones out during a load holds it; fails_when=the route handler checks isPodPlaying only; why_new=only the call path was tested; seam=none
    func testHeadphonesOutDuringALoadKeepsItOffTheSpeaker() async {
        // AirPods out right after tapping an episode: it must not start on the speaker and wake the room.
        let e = sleepEngine(nightMinutes: 0)
        defer { e.stopAll() }
        e.loadPodcast(fileURL.absoluteString, id: "route-\(UUID().uuidString)", resume: false)
        XCTAssertTrue(e.podcastIsPlayingOrStarting)
        // Through the real observer (AudioSessionController hops it to main).
        NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil, userInfo: [
            AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
        _ = await waitUntil { e.hasLoadedEpisode }
        await settle()
        XCTAssertFalse(e.isPodPlaying, "the episode must not start on the speaker")
        XCTAssertFalse(e.podcastIsPlayingOrStarting)
    }
}

/// An episode's end is filed under the episode its ITEM was loaded for. `.AVPlayerItemDidPlayToEndTime`
/// can be posted off the main thread, so a Next tapped right at the natural end could swap the new
/// episode in first, and the late end then marked the NEW episode played, erased its position and
/// (with delete-on-completion) deleted its download.
@MainActor
final class PodcastItemEndTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDownWithError() throws {
        urls.forEach { try? FileManager.default.removeItem(at: $0) }
        urls = []
    }

    private func wav(seconds: Int) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("end-\(UUID().uuidString).wav")
        try PodcastPlayerRebuildTests.quietWav(seconds: seconds).write(to: url)
        urls.append(url)
        return url.absoluteString
    }

    private func waitUntil(_ timeout: TimeInterval = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func testALateEndFromTheReplacedItemLeavesTheNewEpisodeAlone() throws {
        let p = PodcastPlayer()
        defer { p.stop() }
        var advances: [(id: String?, finished: Bool)] = []
        p.onQueueAdvance = { advances.append(($0, $1)) }
        let newId = "next-\(UUID().uuidString)"
        p.setPositions(p.savedPositions.merging([newId: 120]) { $1 })   // where B was left

        p.play(url: try wav(seconds: 20), id: "old-\(UUID().uuidString)", title: "A", resume: false)
        let oldItem = try XCTUnwrap(p.currentItem)
        p.play(url: try wav(seconds: 20), id: newId, title: "B")         // Next, at A's very end
        // A's end, arriving after the swap.
        p.itemDidFinishPlaying(Notification(name: .AVPlayerItemDidPlayToEndTime, object: oldItem))

        XCTAssertTrue(advances.isEmpty, "a replaced item's end must not move the queue")
        XCTAssertEqual(p.savedPositions[newId], 120, "the new episode's place survives")
        XCTAssertFalse(p.didPlayToEnd, "the new episode isn't spent")
    }

    func testALateStallFromTheReplacedItemIsIgnored() async throws {
        let p = PodcastPlayer()
        defer { p.stop() }
        var notes: [String] = []
        p.onPlaybackNote = { if let n = $0 { notes.append(n) } }
        p.play(url: try wav(seconds: 20), id: "old-\(UUID().uuidString)", title: "A", resume: false)
        let oldItem = try XCTUnwrap(p.currentItem)
        p.play(url: try wav(seconds: 20), id: "new-\(UUID().uuidString)", title: "B", resume: false)
        p.itemStalled(Notification(name: .AVPlayerItemPlaybackStalled, object: oldItem))
        try? await Task.sleep(nanoseconds: 200_000_000)               // past its hop to main
        XCTAssertFalse(notes.contains("Buffering…"), "no stall watch against the episode now loading")

        p.itemStalled(Notification(name: .AVPlayerItemPlaybackStalled, object: p.currentItem))
        let watched = await waitUntil(2) { notes.contains("Buffering…") }
        XCTAssertTrue(watched, "the loaded item's own stall still counts")
    }

    func testARealEndAdvancesUnderItsOwnEpisode() async throws {
        // End to end on a real item: the observer (now taking the notification) still fires, and
        // the end is filed under the episode that played.
        let p = PodcastPlayer()
        defer { p.stop() }
        var advances: [(id: String?, finished: Bool)] = []
        p.onQueueAdvance = { advances.append(($0, $1)) }
        let id = "short-\(UUID().uuidString)"
        p.play(url: try wav(seconds: 1), id: id, title: "Short", resume: false)
        let ended = await waitUntil(10) { !advances.isEmpty }
        XCTAssertTrue(ended, "a one-second episode must reach its end")
        XCTAssertEqual(advances.first?.id, id)
        XCTAssertEqual(advances.first?.finished, true)
        XCTAssertTrue(p.didPlayToEnd)
        XCTAssertNil(p.savedPositions[id], "a finished episode keeps no resume point")
    }
}

// MARK: - Settings' pure rules

final class SettingsRulesTests: XCTestCase {

    func testLimiterChoiceReadsTheStoredFlags() {
        XCTAssertEqual(LimiterChoice.from(nightLimiter: false, byMode: false), .off)
        XCTAssertEqual(LimiterChoice.from(nightLimiter: true, byMode: false), .always)
        // Following the mode wins whatever the mode last set the limiter to.
        XCTAssertEqual(LimiterChoice.from(nightLimiter: true, byMode: true), .whileSleeping)
        XCTAssertEqual(LimiterChoice.from(nightLimiter: false, byMode: true), .whileSleeping)
    }

    func testLimiterChoiceRoundTripsThroughItsFlags() {
        for choice in LimiterChoice.allCases {
            let flags = choice.flags
            // While sleeping leaves the limiter to the mode; either mode's value reads back the same.
            for modeSet in [true, false] {
                let stored = flags.nightLimiter ?? modeSet
                XCTAssertEqual(LimiterChoice.from(nightLimiter: stored, byMode: flags.byMode), choice)
            }
        }
    }

    func testMinutesAreSingularForOne() {
        XCTAssertEqual(SettingsCopy.minutes(1), "1 minute")
        XCTAssertEqual(SettingsCopy.minutes(5), "5 minutes")
    }

    func testEachModeLeadsWithItsOwnSettings() {
        XCTAssertEqual(SettingsOrder.shown(focus: false).first, .sleep)
        XCTAssertEqual(SettingsOrder.shown(focus: true).first, .focus)
        XCTAssertFalse(SettingsOrder.shown(focus: false).contains(.focus), "the Pomodoro is folded in Sleep")
        XCTAssertFalse(SettingsOrder.shown(focus: true).contains(.nightPodcasts), "the night is folded in Focus")
    }

    func testEverySectionAppearsExactlyOnceInEachMode() {
        for focus in [false, true] {
            let all = SettingsOrder.shown(focus: focus) + SettingsOrder.folded(focus: focus)
            XCTAssertEqual(all.count, SettingsSection.allCases.count)
            XCTAssertEqual(Set(all), Set(SettingsSection.allCases))
        }
    }

    func testSleepKeepsItsPodcastSectionsTogether() throws {
        let order = SettingsOrder.shown(focus: false)
        let night = try XCTUnwrap(order.firstIndex(of: .nightPodcasts))
        XCTAssertEqual(order[night + 1], .podcasts)
    }

    func testStereoWidthShowsTheNearestStop() {
        XCTAssertEqual(StereoWidth.nearest(1.0), .natural, "the default reads Natural, not 66%")
        XCTAssertEqual(StereoWidth.nearest(0.8), .natural)
        XCTAssertEqual(StereoWidth.nearest(0.2), .mono)
        XCTAssertEqual(StereoWidth.nearest(0.3), .narrow)
        XCTAssertEqual(StereoWidth.nearest(1.3), .wide)
        XCTAssertEqual(StereoWidth.nearest(9), .wide)
    }

    func testEveryStereoStopSoundsDifferentForEveryNoise() {
        // The engine's width: min(base * width, 1), base 0.85 for Pink and Rain, 0.6 otherwise.
        for base in [0.85, 0.6] {
            let widths = StereoWidth.allCases.map { min(base * $0.rawValue, 1) }
            XCTAssertEqual(Set(widths).count, StereoWidth.allCases.count, "base \(base)")
        }
    }

    func testBeatsNoteFollowsTheRouting() {
        XCTAssertTrue(SettingsCopy.beatsNote("headphones").contains("Needs headphones"))
        XCTAssertTrue(SettingsCopy.beatsNote("speaker").contains("speaker"))
        // The default note also says "speaker", so the check above can't tell them apart.
        XCTAssertNotEqual(SettingsCopy.beatsNote("speaker"), SettingsCopy.beatsNote("auto"))
        XCTAssertEqual(SettingsCopy.beatsNote("auto"), SettingsCopy.beatsNote("anything else"))
    }

    // Value: protects=with Auto-Play off the hold switch says why it's off in its value, not only its hint; fails_when=holdSpokenValue returns nil while the switch is disabled, or drops its state; why_new=with hints off VoiceOver gave a dimmed switch and no reason; seam=none; no_claim=that VoiceOver reads it (TESTING.md §S5)
    func testTheHoldSaysWhyItsOffInItsValue() {
        XCTAssertNil(SettingsCopy.holdSpokenValue(isOn: true, autoPlay: true), "enabled, the switch says On or Off itself")
        XCTAssertEqual(SettingsCopy.holdSpokenValue(isOn: false, autoPlay: false),
                       "Off. Only applies when the next episode plays automatically.")
        XCTAssertEqual(SettingsCopy.holdSpokenValue(isOn: true, autoPlay: false),
                       "On. Only applies when the next episode plays automatically.")
        XCTAssertNotEqual(SettingsCopy.holdNote(autoPlay: true), SettingsCopy.holdNote(autoPlay: false))
    }

    func testSofteningNeverSaysOffAboveTheFloor() {
        XCTAssertEqual(SettingsCopy.softening(SettingsCopy.eqFloor), "Light")
        XCTAssertEqual(SettingsCopy.softening(0), "Off", "the old slider's zero: the EQ does nothing there")
        XCTAssertEqual(SettingsCopy.softening(1.0), "Medium")
        XCTAssertEqual(SettingsCopy.softening(2.0), "Strong")
    }
}

// MARK: - A restore's engine reload

@MainActor
final class RestoreReloadTests: XCTestCase {

    /// A temp-dir store, removed after the test (as `PersistenceTests.freshStorage`): for a test
    /// that reads a file back, since every engine, store and player the earlier tests made writes
    /// the shared files from its own queue, and `StorageManager.flush()` doesn't drain those.
    private func freshStorage() -> StorageManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.sleepulator.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return StorageManager(directory: dir)
    }

    // Value: protects=a restore's reload applies the Pomodoro lengths and never cancels a running sleep timer; fails_when=reloadAfterRestore drops reloadLengths, or focusMode's didSet starts cancelling on a same-value assignment; why_new=no test called reloadAfterRestore; seam=none; no_claim=the stores' disk reloads
    func testARestoreReloadAppliesPomodoroLengthsAndKeepsTheNightsTimer() {
        let d = UserDefaults.standard
        let keys = ["pomoWork", "pomoRest", "pomoLongRest", "pomoCycles"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) } } }
        let engine = AudioEngine()
        engine.focusMode = false
        engine.sleepTimer.startSleepTimer(minutes: 45)
        defer { engine.sleepTimer.cancelTimer() }
        for (key, value) in zip(keys, [50, 7, 20, 6]) { d.set(value, forKey: key) }
        engine.reloadAfterRestore()
        XCTAssertEqual(engine.pomodoro.workMinutes, 50, "the next session runs the restored length")
        XCTAssertEqual(engine.pomodoro.restMinutes, 7)
        XCTAssertEqual(engine.pomodoro.longRestMinutes, 20)
        XCTAssertEqual(engine.pomodoro.cyclesBeforeLongBreak, 6)
        XCTAssertGreaterThan(engine.sleepTimer.timerRemaining, 0, "a restore never cancels a running sleep timer")
    }

    // Value: protects=flushPendingWrites lands the engine's deferred mixes.json write before it returns; fails_when=AudioEngine.flushPendingWrites stops calling mixStore.flushPendingWrites; why_new=a restore didn't flush the engine's queues, so a queued write could land on top of it; seam=a temp-dir store (AudioEngine(storage:)); no_claim=the queue and volume barriers and the engine's shared-store flush (MixStore flushes its own store); places: the next test
    func testFlushPendingWritesLandsTheDeferredMixesWrite() throws {
        // Its own store, not the shared mixes.json: another test's engine or MixStore could land
        // a write there between this flush and the read.
        let storage = freshStorage()
        let engine = AudioEngine(storage: storage)
        let name = "Flush test \(UUID().uuidString)"
        engine.savePreset(named: name)                     // written 0.5 s later, unless flushed
        engine.flushPendingWrites()
        let presets: [SoundPreset] = try XCTUnwrap(storage.load(from: "mixes.json"))
        XCTAssertTrue(presets.contains { $0.name == name }, "the deferred write landed before flushPendingWrites returned")
    }

    // Value: protects=a queue.json today's types can't decode survives the reload after a restore or Undo, as at launch; fails_when=reloadFromDisk assigns [] through the persisting didSet; why_new=the reload saved [] over the queue an Undo had just put back; seam=a temp-dir store (PodcastQueueManager(storage:)); no_claim=LibraryView's matching reload (view state)
    func testAQueueReloadLeavesAnUndecodableQueueOnDisk() throws {
        // Its own store, not the shared queue.json: every PodcastQueueManager the earlier tests
        // made writes there from its own queue, and on CI QueueMoveToHeadTests' last write
        // ([d, c, a, b], 209 bytes) landed inside this test, after the drift.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("test.sleepulator.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let drift = Data(#"[{"fromAnOlderBuild":true}]"#.utf8)
        try storage.writeRawNow(drift, to: "queue.json")
        let manager = PodcastQueueManager(storage: storage)
        manager.reloadFromDisk()
        manager.flushPendingWrites()
        storage.flush()
        XCTAssertEqual(manager.queue, [])
        XCTAssertEqual(storage.rawData(for: "queue.json"), drift, "left on disk, not saved over with []")

        // Value: protects=after that, the next queue edit still saves, and a readable queue is loaded on reload; fails_when=persistsQueue isn't turned back on, or the decodable branch stops assigning; why_new=the test stopped at the reload; seam=none; no_claim=which mutators
        let ep = Episode(id: "e", title: "E", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        manager.queue.append(ep)
        manager.flushPendingWrites()
        storage.flush()
        XCTAssertEqual(storage.load(from: "queue.json") as [Episode]?, [ep], "the next edit is saved")
        let other = Episode(id: "f", title: "F", audioUrl: "v", duration: nil, pubDate: nil, description: nil)
        try storage.writeRawNow(JSONEncoder().encode([other]), to: "queue.json")
        manager.reloadFromDisk()
        XCTAssertEqual(manager.queue, [other], "a readable queue is loaded")
    }

    // Value: protects=the played list is held to a backup's byte limits at runtime too; fails_when=markFinished trims by count only, or records an id over the item limit; why_new=a thousand 16 KB ids came to 16 MB in the plist; seam=none; no_claim=the 1,000-item cap (unchanged)
    func testThePlayedListIsHeldToTheBackupLimitsAtRuntime() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "finishedEpisodes")
        let manager = PodcastQueueManager()
        defer {
            manager.flushPendingWrites()
            if let saved { defaults.set(saved, forKey: "finishedEpisodes") } else { defaults.removeObject(forKey: "finishedEpisodes") }
        }
        let ids = (0..<70).map { String(format: "%03d", $0) + String(repeating: "x", count: Backup.maxListItemBytes - 3) }
        ids.forEach(manager.markFinished)
        let stored = manager.finishedEpisodes
        XCTAssertLessThanOrEqual(stored.reduce(0) { $0 + $1.utf8.count }, Backup.maxListBytes)
        XCTAssertTrue(stored.contains(ids.last!), "the newest is kept")
        XCTAssertFalse(stored.contains(ids.first!), "the oldest went to make room")
        manager.markFinished(String(repeating: "y", count: Backup.maxListItemBytes + 1))
        XCTAssertEqual(manager.finishedEpisodes, stored, "an id over the item limit isn't recorded")
    }

    // Value: protects=flushPositionsNow writes the player's in-memory saved places to positions.json before it returns; fails_when=flushPositionsNow skips the in-memory map (e.g. reduced to a queue barrier) or returns before the store writes it; why_new=this suite covered only mixes.json, and places held in memory reach disk only every ~30 s or on a pause; seam=a temp-dir store (PodcastPlayer(storage:)); no_claim=that AudioEngine.flushPendingWrites calls it (podPlayer is private to AudioEngine)
    func testFlushPositionsNowWritesThePlacesHeldInMemory() throws {
        // Its own store, as above: every engine the earlier tests made has a player writing the
        // shared positions.json from its own queue, and again in its deinit.
        let storage = freshStorage()
        let player = PodcastPlayer(storage: storage)
        let key = "flush-test-\(UUID().uuidString)"
        player.setPositions([key: 42])                     // held in memory, as between the 30 s flushes
        player.flushPositionsNow()                         // no store flush here: it must have landed
        let places: [String: Double] = try XCTUnwrap(storage.load(from: "positions.json"))
        XCTAssertEqual(places[key], 42, "the place held in memory was on disk when flushPositionsNow returned")
    }
}


// MARK: - The night journal (docs/designs/APP-STORE-LAUNCH-1.0.md, NT-1, EV-1)

/// The pure rules: when a closed night counts as clean, and what the trail may never contain.
final class NightRulesTests: XCTestCase {
    private func night(_ by: NightEndReason?, live: TimeInterval = 0, taints: [String] = [],
                       reconciled: Bool = false) -> NightSummary {
        var s = NightSummary(id: "n", start: Date(timeIntervalSince1970: 0), lastEventAt: Date(timeIntervalSince1970: 0))
        s.end = by == nil ? nil : Date(timeIntervalSince1970: 100)
        s.endedBy = by
        s.live = live
        s.taints = taints
        s.reconciled = reconciled
        return s
    }

    func testTimerEndWhilePlayingIsClean() {
        XCTAssertTrue(NightRules.isClean(night(.timer, live: 60)))
        XCTAssertTrue(NightRules.isClean(night(.episodeEnd, live: 60)))
    }

    func testATimedNightBelowAMinuteOfLiveAudioIsNotClean() {
        let below = NightRules.timedNightMinimumLive - 1
        XCTAssertFalse(NightRules.isClean(night(.timer, live: below)))
        XCTAssertFalse(NightRules.isClean(night(.episodeEnd, live: below)))
    }

    func testReconciledDeadlineIsNotClean() {
        XCTAssertFalse(NightRules.isClean(night(.timer, live: 20 * 60, reconciled: true)))
    }

    /// The asks count nights, not sessions: at most one clean night per noon-to-noon span, by
    /// when it started. A nap, then the night, then a 1am start the next night: two.
    func testCleanNightsCountOncePerNight() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day = Date(timeIntervalSince1970: TimeInterval(1_800_000_000 / 86_400 * 86_400))   // a UTC midnight
        func v(_ hours: Double, clean: Bool = true) -> NightVerdict {
            let start = day.addingTimeInterval(hours * 3600)
            return NightVerdict(id: "\(hours)", start: start, end: start + 1800, live: 1800, clean: clean,
                                endedBy: .timer, taints: [])
        }
        let verdicts = [v(15), v(16), v(23),          // two naps and the night: one
                        v(25),                        // 1am the next day: still that night
                        v(24 + 23),                   // the next night
                        v(48 + 23, clean: false)]     // not clean: not counted
        XCTAssertEqual(NightRules.cleanNightCount(verdicts, calendar: utc), 2)
        XCTAssertEqual(NightRules.cleanNightCount([], calendar: utc), 0)
    }

    /// Noon is the wall clock's, so a daylight-saving day doesn't move it: in New York on
    /// 2026-03-08 (clocks forward), a 12:30 nap is the next night's, not the one before.
    func testTheNightBoundaryIsWallClockNoonAcrossDaylightSaving() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        let starts = [DateComponents(year: 2026, month: 3, day: 7, hour: 23),
                      DateComponents(year: 2026, month: 3, day: 8, hour: 12, minute: 30)].map { ny.date(from: $0)! }
        let verdicts = starts.map { NightVerdict(id: "\($0)", start: $0, end: $0 + 3600, live: 3600, clean: true,
                                                 endedBy: .timer, taints: []) }
        XCTAssertEqual(NightRules.cleanNightCount(verdicts, calendar: ny), 2)
    }

    func testAllNightNeedsThreeHoursOfLiveAudio() {
        XCTAssertFalse(NightRules.isClean(night(.person, live: NightRules.allNightThreshold - 1)))
        XCTAssertTrue(NightRules.isClean(night(.person, live: NightRules.allNightThreshold)))
        XCTAssertTrue(NightRules.isClean(night(.focusSwitch, live: NightRules.allNightThreshold)))
    }

    func testDiedOpenOrTaintedIsNeverClean() {
        XCTAssertFalse(NightRules.isClean(night(.died, live: 8 * 3600)))
        XCTAssertFalse(NightRules.isClean(night(nil, live: 8 * 3600)))
        XCTAssertFalse(NightRules.isClean(night(.timer, live: 60, taints: ["player rebuilt"])))
        XCTAssertFalse(NightRules.isClean(night(.person, live: 8 * 3600, taints: ["podcast failed"])))
    }

    func testScrubRemovesLinks() {
        let s = NightRules.scrub("failed https://feeds.example.com/p?token=secret and http://x.y/z ok")
        XCTAssertFalse(s.contains("://"))
        XCTAssertFalse(s.contains("secret"))
        XCTAssertEqual(NightRules.scrub("player rebuilt"), "player rebuilt")
    }
}

/// The journal against a temp folder, with an injected clock.
@MainActor
final class NightJournalTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nj-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func journal() -> NightJournal {
        NightJournal(directory: dir, storage: StorageManager(directory: dir), observeTermination: false,
                     now: { [unowned self] in self.clock })
    }

    /// Advance the clock in 1 s ticks, as the render and player clocks would.
    private func play(_ j: NightJournal, seconds: Int) {
        for _ in 0..<seconds { clock += 1; j.liveTick() }
    }

    private func fileText(_ j: NightJournal) -> String {
        j.drain()
        return j.nightFiles().compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
    }

    func testThreeHoursThenALongPauseIsACleanNightEndedByThePerson() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: Int(NightRules.allNightThreshold) + 5)
        j.sessionStopped()
        let pausedAt = clock
        clock += UntimedNight.resumeWindow + 1
        j.sessionStarted()                                    // next evening: a new night
        XCTAssertEqual(j.verdicts.count, 1)
        XCTAssertEqual(j.verdicts.first?.endedBy, .person)
        XCTAssertEqual(j.verdicts.first?.end, pausedAt)
        XCTAssertEqual(j.verdicts.first?.clean, true)
        XCTAssertNotNil(j.open)
    }

    func testAShortPauseKeepsTheNight() {
        let j = journal()
        j.sessionStarted()
        let id = j.open?.id
        play(j, seconds: 60)
        j.sessionStopped()
        clock += UntimedNight.resumeWindow - 1
        j.sessionStarted()
        XCTAssertEqual(j.open?.id, id)
        XCTAssertNil(j.open?.pausedAt)
        XCTAssertTrue(j.verdicts.isEmpty)
    }

    func testTicksFurtherApartThanTheGapDontCount() {
        let j = journal()
        j.sessionStarted()
        j.liveTick()                                          // first tick sets the base
        clock += NightRules.maxTickGap + 1
        j.liveTick()
        XCTAssertEqual(j.open?.live ?? -1, 0, accuracy: 0.001)
        clock += 1
        j.liveTick()
        XCTAssertEqual(j.open?.live ?? -1, 1, accuracy: 0.001)
    }

    func testTimerStopWhilePlayingIsCleanAndThePauseAfterIsIgnored() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 30 * 60)
        j.timerStopped(episode: false, reconciled: false, endedAt: clock)
        j.sessionStopped()                                    // stopAll's own pause, after
        XCTAssertNil(j.open)
        XCTAssertEqual(j.verdicts.map(\.endedBy), [.timer])
        XCTAssertEqual(j.verdicts.first?.clean, true)
    }

    func testAReconciledDeadlineIsNotClean() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 20 * 60)
        j.timerStopped(episode: false, reconciled: true, endedAt: clock)
        XCTAssertEqual(j.verdicts.first?.clean, false)
    }

    func testATimerStopOverAPauseEndsTheNightWhereItPaused() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 60)
        j.sessionStopped()
        let pausedAt = clock
        clock += 600
        j.timerStopped(episode: false, reconciled: false, endedAt: clock)
        XCTAssertEqual(j.verdicts.first?.endedBy, .person)
        XCTAssertEqual(j.verdicts.first?.end, pausedAt)
        XCTAssertEqual(j.verdicts.first?.clean, false)        // a minute, not three hours
    }

    func testATaintDuringTheNightSpoilsIt() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)                                 // past the minute: only the taint decides
        j.taint("player rebuilt", at: clock)
        j.timerStopped(episode: false, reconciled: false, endedAt: clock)
        XCTAssertEqual(j.verdicts.first?.clean, false)
        XCTAssertEqual(j.verdicts.first?.taints, ["player rebuilt"])
    }

    /// EV-1: news that lands after its night closed (and the next opened) is filed by when it
    /// happened, in both orders.
    func testALateTaintIsFiledUnderTheNightItHappenedIn() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)                                 // past the timed night's minute
        let happened = clock                                  // the failure, detected here
        clock += 1
        j.timerStopped(episode: false, reconciled: false, endedAt: clock)
        XCTAssertEqual(j.verdicts.first?.clean, true)
        clock += 3600
        j.sessionStarted()                                    // the next night opens
        let next = j.open?.id
        j.taint("pipeline died (item failed)", at: happened)  // the hop lands now
        XCTAssertEqual(j.verdicts.first?.clean, false)
        XCTAssertEqual(j.open?.id, next)
        XCTAssertEqual(j.open?.taints, [])
    }

    func testALateTaintBeforeTheNextNightOpensStillFindsItsNight() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)                                 // past the minute: clean until the news
        let happened = clock
        j.timerStopped(episode: false, reconciled: false, endedAt: clock + 1)
        XCTAssertEqual(j.verdicts.first?.clean, true)
        j.taint("player rebuilt", at: happened)               // lands with no night open
        XCTAssertEqual(j.verdicts.first?.clean, false)
        XCTAssertEqual(j.verdicts.first?.taints, ["player rebuilt"])
    }

    func testATaintOutsideEveryNightIsDropped() {
        let j = journal()
        j.taint("podcast failed", at: clock)                  // a daytime Focus podcast
        XCTAssertTrue(j.verdicts.isEmpty)
        XCTAssertNil(j.open)
    }

    func testANightLeftOpenWhilePlayingIsClosedAsDiedAtNextLaunch() {
        let a = journal()
        a.sessionStarted()
        play(a, seconds: Int(NightRules.allNightThreshold) + 5)  // 3 h, then the app dies
        a.drain()
        let b = journal()
        XCTAssertNil(b.open)
        XCTAssertEqual(b.verdicts.map(\.endedBy), [.died])
        XCTAssertEqual(b.verdicts.first?.clean, false)
    }

    func testANightLeftPausedIsClosedByThePersonAtNextLaunch() {
        let a = journal()
        a.sessionStarted()
        play(a, seconds: Int(NightRules.allNightThreshold) + 5)
        a.sessionStopped()
        let pausedAt = clock
        a.drain()
        clock += 8 * 3600
        let b = journal()
        XCTAssertEqual(b.verdicts.first?.endedBy, .person)
        XCTAssertEqual(b.verdicts.first?.end, pausedAt)
        XCTAssertEqual(b.verdicts.first?.clean, true)
    }

    func testTheTrailNeverHoldsALink() {
        let j = journal()
        j.sessionStarted()
        j.note("route change https://example.com/feed?token=abc")
        j.taint("podcast failed for https://feeds.example.com/x.mp3?key=secret", at: clock)
        XCTAssertFalse(fileText(j).contains("://"))
        XCTAssertFalse(fileText(j).contains("secret"))
    }

    func testOnlyTheTwoNewestNightFilesAreKept() {
        let j = journal()
        for _ in 0..<3 {
            j.sessionStarted()
            play(j, seconds: 5)
            j.timerStopped(episode: false, reconciled: false, endedAt: clock)
            clock += 24 * 3600
            j.drain()
        }
        j.drain()
        XCTAssertEqual(j.nightFiles().count, NightRules.keptNightFiles)
        XCTAssertEqual(j.verdicts.count, 3)                   // verdicts outlive the files
    }

    func testSummaryLine() {
        let j = journal()
        XCTAssertEqual(j.summaryLine(), "No night recorded yet.")
        j.sessionStarted(); play(j, seconds: 65)
        j.timerStopped(episode: false, reconciled: false, endedAt: clock)
        clock += 3600
        j.sessionStarted(); play(j, seconds: 65)
        j.timerStopped(episode: false, reconciled: true, endedAt: clock)
        XCTAssertEqual(j.summaryLine(), "Last 2 nights: 1 clean, 1 ended early or spoiled.")
    }

    /// A died night is the summary's "left open" (the signal support reads first), counted once.
    func testSummaryLineCountsADiedNightAsLeftOpen() {
        let a = journal()
        a.sessionStarted(); play(a, seconds: 5)
        a.drain()
        clock += 60
        let b = journal()                                     // recovery closes it as died
        XCTAssertEqual(b.summaryLine(), "Last 1 night: 0 clean, 1 left open.")
    }

    /// A timed night with hardly any sound isn't clean: a deadline that passed while the app
    /// slept, fired by a lock-screen Play in the morning, mustn't count.
    func testATimedNightNeedsAMinuteOfLiveAudio() {
        let j = journal()
        // play(seconds: n) counts n - 1 seconds: its first tick only sets the base.
        let minute = Int(NightRules.timedNightMinimumLive)
        for (episode, seconds) in [(false, minute), (true, minute), (false, minute + 1), (true, minute + 1)] {
            j.sessionStarted(); play(j, seconds: seconds)
            j.timerStopped(episode: episode, reconciled: false, endedAt: clock)
            clock += 3600
        }
        XCTAssertEqual(j.verdicts.map(\.endedBy), [.timer, .episodeEnd, .timer, .episodeEnd])
        XCTAssertEqual(j.verdicts.map(\.clean), [false, false, true, true])
    }

    /// News just after a night resumes from a pause is the pause's aftermath (a player the pause
    /// killed, rebuilt by the resume or found by the watchdog seconds later); later news spoils.
    func testNewsJustAfterAResumeIsANoteLaterNewsSpoils() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: Int(NightRules.allNightThreshold) + 5)
        j.sessionStopped()                                    // the alarm
        clock += 60
        j.sessionStarted()                                    // dismissed: the bed carries on
        clock += 4
        j.taint("player rebuilt", at: clock)                  // the watchdog, 4 s later
        XCTAssertEqual(j.open?.taints, [])
        clock += NightRules.graceAfterResume + 1
        j.taint("pipeline died (item failed)", at: clock)     // a real failure, later
        XCTAssertEqual(j.open?.taints, ["pipeline died (item failed)"])
        XCTAssertTrue(fileText(j).contains("player rebuilt just after the sound started"))
    }

    /// The resume grace has to outlast the watchdog that finds a player the pause killed, or the
    /// watchdog's rebuild a few seconds after Play would spoil the night.
    func testTheResumeGraceOutlastsThePlayerWatchdog() {
        XCTAssertGreaterThan(NightRules.graceAfterResume, RenderHeartbeatMonitor.deadAfter + 2)
    }

    /// The grace covers only a pause's aftermath, a dead or rebuilt player: a failed episode or
    /// the noise engine's error right after Play still spoils the night.
    func testOnlyADeadOrRebuiltPlayerIsAPausesAftermath() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)
        j.sessionStopped()
        clock += 60
        j.sessionStarted()
        clock += 2
        j.taint("podcast failed", at: clock)
        j.taint("sound engine error", at: clock)
        XCTAssertEqual(j.open?.taints, ["podcast failed", "sound engine error"])
    }

    /// A night can open on a player that died while it sat paused past the window (or overnight):
    /// the watchdog's rebuild a few seconds in is that aftermath, not this night's failure.
    func testAPlayerRebuiltJustAfterANightOpensIsANote() {
        let j = journal()
        j.sessionStarted()
        clock += 4
        j.taint("player rebuilt", at: clock)
        XCTAssertEqual(j.open?.taints, [])
        XCTAssertTrue(fileText(j).contains("player rebuilt just after the sound started"))
    }

    /// The noise engine's start error is stamped as the switch flips, a moment before the session
    /// edge opens the night: it's that night's. Well before the night, it's no night's.
    func testNewsAMomentBeforeTheNightOpensIsThatNights() {
        let j = journal()
        j.sessionStarted()
        j.taint("sound engine error", at: clock - 1)
        XCTAssertEqual(j.open?.taints, ["sound engine error"])
        j.taint("podcast failed", at: clock - 60)
        XCTAssertEqual(j.open?.taints, ["sound engine error"])
        XCTAssertTrue(j.verdicts.isEmpty)
    }

    /// Only a session edge ends a pause: ticks (a fading bed, a podcast scrubbed while paused)
    /// never resume a night nor count while it's paused.
    func testTicksNeverCarryOnAPause() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)
        j.sessionStopped()
        let live = j.open?.live ?? -1
        clock += 60
        play(j, seconds: 10)
        XCTAssertNotNil(j.open?.pausedAt)
        XCTAssertEqual(j.open?.live ?? 0, live, accuracy: 0.001)
    }

    /// A player's death stamped off main a moment before the Play's edge lands after it: it's the
    /// pause's aftermath, a note, like the same news a moment after.
    func testAPipelineDeathStampedJustBeforeThePlayIsANote() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)
        j.sessionStopped()
        clock += 600
        let died = clock
        clock += 1
        j.sessionStarted()                                    // the Play's edge
        j.taint(NightRules.pipelineDied + " (item failed)", at: died)   // the hop lands now
        XCTAssertEqual(j.open?.taints, [])
    }

    /// The first tick after a morning Play finds last night's deadline long past. When the Play
    /// opened a new night (the pause outlasted the window), that night never played: it's
    /// discarded, so it neither counts as a night nor pushes last night's file out of the two
    /// "Send feedback" keeps when Play is pressed again.
    func testAnOverdueStopDiscardsTheNightAMorningPlayOpened() throws {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 600)
        j.sessionStopped()                                    // 23:10, then the app is suspended
        let lastNight = try XCTUnwrap(j.open?.id)
        let deadline = clock + 35 * 60                        // the timer's deadline, 23:45
        clock += 8 * 3600                                     // a lock-screen Play at 07:10
        j.sessionStarted()                                    // last night closes, a new one opens
        let phantom = try XCTUnwrap(j.open?.id)
        j.timerStopped(episode: false, reconciled: true, endedAt: deadline)
        XCTAssertNil(j.open)
        XCTAssertEqual(j.verdicts.map(\.id), [lastNight])
        XCTAssertEqual(j.verdicts.first?.endedBy, .person)
        clock += 3
        j.sessionStarted()                                    // the sound stopped: Play again
        j.drain()
        let kept = j.nightFiles().map { $0.deletingPathExtension().lastPathComponent }
        XCTAssertTrue(kept.contains(lastNight), "last night's file was pruned: \(kept)")
        XCTAssertFalse(kept.contains(phantom))
    }

    /// An alarm's interruption and the player's death it causes reach main in either order: the
    /// pause takes the interruption's own time, and a dead player stamped a moment before it is
    /// still the pause's. A failed episode just before a pause still spoils the night.
    func testAPlayerDeathStampedJustBeforeAnInterruptionsPauseIsANote() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 120)
        let interrupted = clock
        let died = clock - 0.5                                // stamped off main, before the pause
        clock += 0.3                                          // the interruption's hop lands
        j.sessionStopped(at: interrupted)
        XCTAssertEqual(j.open?.pausedAt, interrupted)
        j.taint(NightRules.pipelineDied + " (item failed)", at: died)
        XCTAssertEqual(j.open?.taints, [])
        XCTAssertTrue(fileText(j).contains("item failed) while paused"))
        j.taint("podcast failed", at: died)
        XCTAssertEqual(j.open?.taints, ["podcast failed"])
        j.taint(NightRules.playerRebuilt, at: interrupted - NightRules.newsLead - 1)   // too early
        XCTAssertEqual(j.open?.taints, ["podcast failed", NightRules.playerRebuilt])
    }

    /// A paused night recovered at launch inside its window still ends where it paused once the
    /// window passes with no Play: the asks see it that morning.
    func testARecoveredPausedNightEndsWhereItPausedOnceItsWindowPasses() {
        let a = journal()
        a.sessionStarted()
        play(a, seconds: Int(NightRules.allNightThreshold) + 5)
        a.sessionStopped()
        let pausedAt = clock
        a.drain()
        clock += 600                                          // relaunched 10 minutes later
        let b = journal()
        XCTAssertNotNil(b.open?.pausedAt)
        b.closeLapsedPause()                                  // still inside the window
        XCTAssertNotNil(b.open)
        clock = pausedAt + UntimedNight.resumeWindow
        b.closeLapsedPause()
        XCTAssertNil(b.open)
        XCTAssertEqual(b.verdicts.map(\.endedBy), [.person])
        XCTAssertEqual(b.verdicts.first?.end, pausedAt)
        XCTAssertEqual(b.verdicts.first?.clean, true)
        b.drain()
    }

    func testFocusSwitchEndsTheNight() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: 5)
        j.switchedToFocus()
        XCTAssertNil(j.open)
        XCTAssertEqual(j.verdicts.first?.endedBy, .focusSwitch)
    }

    /// News after a pause outlasted the window isn't that night's (EV-1): the night ended at its
    /// pause, and a resume() that rebuilds a dead player the next evening lands in no night.
    func testATaintAfterThePauseOutlastedTheWindowIsNotThatNights() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: Int(NightRules.allNightThreshold) + 5)
        j.sessionStopped()
        clock += UntimedNight.resumeWindow + 12 * 3600
        j.taint("player rebuilt", at: clock)                  // before the playing edge
        j.sessionStarted()
        XCTAssertEqual(j.verdicts.first?.taints, [])
        XCTAssertEqual(j.verdicts.first?.clean, true)
    }

    /// While a night is paused (an alarm, the person's pause) nothing is meant to play: a player
    /// that dies then, and its rebuild on resume, go in the trail but don't spoil the night.
    func testATaintWhilePausedDoesntSpoilTheNight() {
        let j = journal()
        j.sessionStarted()
        play(j, seconds: Int(NightRules.allNightThreshold) + 5)
        j.sessionStopped()                                    // the alarm
        clock += 1
        j.taint("pipeline died (item failed)", at: clock)
        clock += 30
        j.taint("player rebuilt", at: clock)                  // resume() rebuilds, before the edge
        j.sessionStarted()                                    // within the window: the same night
        play(j, seconds: 60)
        j.switchedToFocus()
        XCTAssertEqual(j.verdicts.first?.taints, [])
        XCTAssertEqual(j.verdicts.first?.clean, true)
        XCTAssertTrue(fileText(j).contains("while paused"))   // still in the trail
    }

    /// Past the soft cap a file keeps only the lines that decide its verdict, and a pause is one:
    /// a paused night recovered at launch is the person's stop, with the live time it reached.
    func testAPausedNightPastTheSoftCapIsClosedByThePersonAtNextLaunch() {
        let a = journal()
        a.sessionStarted()
        let padding = String(repeating: "x", count: 1_000)
        for _ in 0..<(NightRules.fileSoftCap / 1_000 + 10) { a.note("route change \(padding)") }
        play(a, seconds: Int(NightRules.allNightThreshold) + 5)  // checkpoints aren't written now
        a.sessionStopped()
        a.drain()
        clock += 8 * 3600
        let b = journal()
        XCTAssertEqual(b.verdicts.first?.endedBy, .person)
        XCTAssertEqual(b.verdicts.first?.clean, true)
    }

    /// The app was ended while paused (iOS ends suspended apps) and play came back within the
    /// window: the same night carries on rather than splitting in two.
    func testAPausedNightRecoveredInsideItsWindowCarriesOn() {
        let a = journal()
        a.sessionStarted()
        let id = a.open?.id
        play(a, seconds: 3600)
        a.sessionStopped()
        a.drain()
        clock += 600                                          // relaunched 10 minutes later
        let b = journal()
        XCTAssertEqual(b.open?.id, id)
        XCTAssertNotNil(b.open?.pausedAt)
        XCTAssertTrue(b.verdicts.isEmpty)
        b.sessionStarted()                                    // play again: the same night
        XCTAssertEqual(b.open?.id, id)
        XCTAssertNil(b.open?.pausedAt)
        XCTAssertEqual(b.open?.live ?? 0, 3600, accuracy: 1)
        b.drain()
    }

    /// The threshold line, written past the cap too, counts at recovery on its own.
    func testTheThresholdLineAloneDecidesARecoveredNight() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let start = clock
        var data = Data()
        for e in [NightEvent(at: start, kind: "opened"),
                  NightEvent(at: start + NightRules.allNightThreshold, kind: "threshold", detail: "10800"),
                  NightEvent(at: start + NightRules.allNightThreshold + 60, kind: "paused")] {
            data.append(try enc.encode(e)); data.append(0x0A)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(NightRules.id(for: start)).appendingPathExtension("jsonl"))
        clock += 8 * 3600                                     // the next launch, the window long gone
        let j = journal()
        XCTAssertEqual(j.verdicts.first?.endedBy, .person)
        XCTAssertEqual(j.verdicts.first?.clean, true)
    }

    /// The process went between the closing line and the verdict (a force-quit): the next launch
    /// records the night from its file, once.
    func testAClosedNightWithNoVerdictIsRecordedAtLaunch() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let start = clock
        var data = Data()
        for e in [NightEvent(at: start, kind: "opened"),
                  NightEvent(at: start + 10_900, kind: "closed", detail: "person 10900")] {
            data.append(try enc.encode(e)); data.append(0x0A)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try data.write(to: dir.appendingPathComponent(NightRules.id(for: start)).appendingPathExtension("jsonl"))
        let a = journal()
        XCTAssertEqual(a.verdicts.map(\.endedBy), [.person])
        XCTAssertEqual(a.verdicts.first?.clean, true)
        a.drain()
        XCTAssertEqual(journal().verdicts.count, 1)            // not again on the next launch
    }

    /// iOS killed the app mid-write: the file ends in a partial line with no newline. The next
    /// launch skips the fragment, closes the night as died where the last whole line left it, and
    /// ends the fragment first, so the closing line sits on a line of its own.
    /// Value: protects=a night iOS killed mid-write still closes at the next launch, its closing
    /// line on a line of its own; fails_when=recovery stops skipping an undecodable line or the
    /// newline repair is removed (the closing line glued to the fragment); why_new=every recovery
    /// test writes whole lines; seam=none; no_claim=a real kill (TESTING §3U.1)
    func testANightCutOffMidLineIsClosedAsDiedOnALineOfItsOwn() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let start = clock
        var data = Data()
        for e in [NightEvent(at: start, kind: "opened"),
                  NightEvent(at: start + 600, kind: "live", detail: "600")] {
            data.append(try enc.encode(e)); data.append(0x0A)
        }
        let cut = try enc.encode(NightEvent(at: start + 900, kind: "live", detail: "900"))
        data.append(cut.prefix(cut.count / 2))                // the kill landed mid-line: no newline
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(NightRules.id(for: start)).appendingPathExtension("jsonl")
        try data.write(to: url)
        let j = journal()
        XCTAssertNil(j.open)
        XCTAssertEqual(j.verdicts.map(\.endedBy), [.died])
        XCTAssertEqual(j.verdicts.first?.end, start + 600, "closed where the last whole line left it")
        XCTAssertEqual(j.verdicts.first?.clean, false)
        j.drain()
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 4, "opened, live, the fragment, closed: \(text)")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let last = try XCTUnwrap(lines.last)
        let closing = try? dec.decode(NightEvent.self, from: Data(last.utf8))
        XCTAssertEqual(closing?.kind, "closed", "the closing line isn't on a line of its own: \(last)")
        XCTAssertEqual(closing?.detail, "died 600")
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testAForceQuitClosesTheNightByThePersonAndSavesItAtOnce() {
        let a = journal()
        a.sessionStarted()
        play(a, seconds: 60)
        a.appWillTerminate()
        XCTAssertNil(a.open)
        XCTAssertEqual(a.verdicts.map(\.endedBy), [.person])
        XCTAssertEqual(journal().verdicts.map(\.endedBy), [.person])   // on disk without a drain
    }

    /// The verdicts sit in the journal's own folder, the one excluded from backups.
    func testTheVerdictsLiveInTheJournalsOwnFolder() {
        let j = NightJournal(directory: dir, observeTermination: false)
        j.sessionStarted()
        j.switchedToFocus()
        j.drain()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("night-verdicts.json").path))
        XCTAssertEqual(j.nightFiles().count, 1)                // and never among the night files
    }
}

/// The journal only observes: AudioEngine's session edges open and pause a Sleep night, and the
/// terminal stop reaches the journal before stopAll's pause.
@MainActor
final class NightJournalWiringTests: XCTestCase {
    func testSleepSessionEdgesOpenAndPauseTheNight() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = AudioEngine()
        engine.nightLengthProvider = { 0 }                    // All night: no timer starts
        engine.nightJournal = NightJournal(directory: dir, storage: StorageManager(directory: dir), observeTermination: false)
        engine.focusMode = false
        engine.noiseOn = true
        XCTAssertNotNil(engine.nightJournal.open)
        XCTAssertNil(engine.nightJournal.open?.pausedAt)
        engine.noiseOn = false
        XCTAssertNotNil(engine.nightJournal.open?.pausedAt)
        engine.nightJournal.drain()
    }

    private func engineWithJournal(_ dir: URL) -> AudioEngine {
        let engine = AudioEngine()
        engine.nightLengthProvider = { 0 }                    // All night: no timer starts
        engine.nightJournal = NightJournal(directory: dir, storage: StorageManager(directory: dir), observeTermination: false)
        engine.focusMode = false
        return engine
    }

    private func interruption(_ type: AVAudioSession.InterruptionType, shouldResume: Bool = false) -> Notification {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended {
            info[AVAudioSessionInterruptionOptionKey] =
                (shouldResume ? AVAudioSession.InterruptionOptions.shouldResume : []).rawValue
        }
        return Notification(name: AVAudioSession.interruptionNotification, object: nil, userInfo: info)
    }

    /// An alarm or a call pauses the night (the bed's switches stay on through it, so no session
    /// edge reports it); its end, with the bed coming back, continues the same night.
    func testAnInterruptionPausesTheNightAndItsEndContinuesIt() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        engine.restartBedAfterInterruption = { true }         // not the simulator's audio
        engine.noiseOn = true
        let id = engine.nightJournal.open?.id
        engine.handleInterruption(note: interruption(.began))
        XCTAssertNotNil(engine.nightJournal.open?.pausedAt, "the interruption didn't pause the night")
        engine.handleInterruption(note: interruption(.ended, shouldResume: true))
        XCTAssertEqual(engine.nightJournal.open?.id, id)
        XCTAssertNil(engine.nightJournal.open?.pausedAt)
        engine.noiseOn = false
        engine.nightJournal.drain()
    }

    /// The night's pause takes the interruption's own time, stamped before the hop to main.
    func testAnInterruptionPausesTheNightAtItsOwnTime() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        engine.nightJournal.now = { clock }
        defer { engine.noiseOn = false }
        engine.noiseOn = true
        clock += 60
        let reached = clock - 0.4                             // it reached the app before the hop
        engine.handleInterruption(note: interruption(.began), at: reached)
        XCTAssertEqual(engine.nightJournal.open?.pausedAt, reached)
        engine.nightJournal.drain()
    }

    /// A bed that fails to restart after the interruption leaves the night paused: nothing plays.
    func testAFailedRestartAfterAnInterruptionLeavesTheNightPaused() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        defer { engine.noiseOn = false }
        engine.noiseOn = true
        engine.handleInterruption(note: interruption(.began))
        engine.restartBedAfterInterruption = { false }
        engine.handleInterruption(note: interruption(.ended, shouldResume: true))
        XCTAssertNotNil(engine.nightJournal.open?.pausedAt, "the night resumed over a bed that didn't restart")
        engine.restartBedAfterInterruption = { true }
        engine.handleInterruption(note: interruption(.began))
        engine.handleInterruption(note: interruption(.ended, shouldResume: true))
        XCTAssertNil(engine.nightJournal.open?.pausedAt)
        engine.nightJournal.drain()
    }

    /// An interruption that ends with nothing coming back (the bed turned off during the call)
    /// leaves the night paused, not playing over silence.
    func testAnInterruptionThatEndsWithNothingToResumeLeavesTheNightPaused() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        engine.noiseOn = true
        engine.handleInterruption(note: interruption(.began))
        engine.noiseOn = false                                // turned off during the call
        // iOS says resume: only the bed being off keeps the night paused.
        engine.handleInterruption(note: interruption(.ended, shouldResume: true))
        XCTAssertNotNil(engine.nightJournal.open?.pausedAt, "the night resumed with nothing playing")
        engine.nightJournal.drain()
    }

    /// Switching Focus → Sleep with the sound still on starts the night like Play (CLAUDE.md).
    func testFocusToSleepWithTheSoundOnOpensANight() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        defer { engine.noiseOn = false; engine.focusMode = false }
        engine.focusMode = true
        engine.noiseOn = true
        XCTAssertNil(engine.nightJournal.open)
        engine.focusMode = false
        XCTAssertNotNil(engine.nightJournal.open, "Focus to Sleep with the sound on didn't start the night")
        XCTAssertNil(engine.nightJournal.open?.pausedAt)
        engine.nightJournal.drain()
    }

    /// The timer's stop reaches the journal through the engine, as the timer's, not as a pause.
    func testTheEnginesTerminalStopClosesTheNightAsTheTimers() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        engine.noiseOn = true
        engine.sleepTimer.startSleepTimer(minutes: 0)         // deadline == now
        Thread.sleep(forTimeInterval: 0.01)
        engine.sleepTimer.reconcileIfExpired()                // onTerminalStop, then stopAll's pause
        XCTAssertNil(engine.nightJournal.open)
        XCTAssertEqual(engine.nightJournal.verdicts.map(\.endedBy), [.timer])
        engine.nightJournal.drain()
    }

    /// The usual timed night ends in the app, not on the morning foreground: the duration timer's
    /// fade-complete stop (its tick) closes the night as the timer's, and "stop after this
    /// episode" (the episode's last clock tick) as the episode's, both clean.
    /// Value: protects=the usual timed night is recorded as the timer's or episode's end and
    /// counted clean; fails_when=the in-app tick or episode path passes reconciled: true or loses
    /// the episode flag, so no timed night is ever clean; why_new=the engine test drives only
    /// reconcileIfExpired (reconciled, never clean); seam=none; no_claim=live ticks on a locked
    /// phone (TESTING §3U.4)
    func testAnInAppTimerStopAndAnEpisodesEndCloseCleanNights() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        // One clock for the journal and the timer: a night's id is its start to the second, and
        // two nights in the same second would be one.
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        engine.nightJournal.now = { clock }
        engine.sleepTimer.now = { clock }
        defer { engine.noiseOn = false; engine.sleepTimer.cancelTimer() }

        engine.noiseOn = true                                 // a Sleep night
        for _ in 0..<65 { clock += 1; engine.nightJournal.liveTick() }   // a minute of sound
        engine.sleepTimer.startSleepTimer(minutes: 0)         // deadline == now
        clock += 30 * 60
        Thread.sleep(forTimeInterval: 0.01)
        // The fade-complete stop, in the app: the tick's main-queue half, called directly (a fixed
        // pump for backgroundTick's hop to main lost the race on a slow CI simulator).
        engine.sleepTimer.handleTick(at: Date())
        XCTAssertNil(engine.nightJournal.open, "the timer's stop didn't close the night")
        XCTAssertFalse(engine.isAnythingPlaying)

        clock += 2 * 3600
        engine.noiseOn = true                                 // the next night
        for _ in 0..<65 { clock += 1; engine.nightJournal.liveTick() }
        engine.sleepTimer.startEndOfEpisode(remaining: 30 * 60)
        clock += 30 * 60
        engine.sleepTimer.externalTick(remaining: 0.3)        // the episode's last clock tick
        XCTAssertNil(engine.nightJournal.open, "the episode's end didn't close the night")
        XCTAssertEqual(engine.nightJournal.verdicts.map(\.endedBy), [.timer, .episodeEnd])
        XCTAssertEqual(engine.nightJournal.verdicts.map(\.clean), [true, true])
        engine.nightJournal.drain()
    }

    /// Focus listening is never a Sleep night: a Focus session doesn't open one, an interruption
    /// that begins and ends in Focus (with the bed on) doesn't open one, and switching a Sleep
    /// night into Focus closes it as the switch's.
    /// Value: protects=Focus listening never opens or extends a Sleep night; fails_when=
    /// sessionStarted moves out of beginSleepNight's !focusMode guard, the interruption-end guard
    /// loses !focusMode, or focusMode's didSet stops calling switchedToFocus; why_new=the wiring
    /// tests run only in Sleep; seam=none; no_claim=live-tick sources
    func testFocusNeverHoldsASleepNight() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        // Back in Sleep, as the other tests (and the hosted UI tests) expect the persisted mode.
        defer { engine.noiseOn = false; engine.focusMode = false }

        engine.focusMode = true
        engine.noiseOn = true                                 // a Focus session from rest
        XCTAssertNil(engine.nightJournal.open, "a Focus session opened a Sleep night")
        engine.handleInterruption(note: interruption(.began))
        engine.handleInterruption(note: interruption(.ended, shouldResume: true))
        XCTAssertNil(engine.nightJournal.open, "an interruption's end in Focus opened a Sleep night")
        engine.noiseOn = false

        engine.focusMode = false
        engine.noiseOn = true                                 // a Sleep night
        XCTAssertNotNil(engine.nightJournal.open)
        engine.focusMode = true                               // into Focus, the sound still going
        XCTAssertNil(engine.nightJournal.open, "the switch to Focus left the Sleep night open")
        XCTAssertEqual(engine.nightJournal.verdicts.map(\.endedBy), [.focusSwitch])
        engine.nightJournal.drain()
    }

    func testAPodcastFailureTaintsTheOpenSleepNight() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("njw-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let engine = engineWithJournal(dir)
        engine.noiseOn = true
        engine.handlePodcastFailure(episodeId: nil, at: Date())
        XCTAssertEqual(engine.nightJournal.open?.taints, ["podcast failed"])
        engine.noiseOn = false
        engine.nightJournal.drain()
    }

    func testTheTerminalStopIsReportedBeforeStopAll() {
        let svc = SleepTimerService()
        var order: [String] = []
        svc.onTerminalStop = { _, reconciled, _ in order.append(reconciled ? "terminal(reconciled)" : "terminal") }
        svc.stopAllFn = { order.append("stopAll") }
        svc.startSleepTimer(minutes: 0)                       // deadline == now
        Thread.sleep(forTimeInterval: 0.01)
        svc.reconcileIfExpired()
        XCTAssertEqual(order, ["terminal(reconciled)", "stopAll"])
        svc.cancelTimer()
    }
}

// MARK: - The asks, the tip card, the Rate row and the feedback message (E4, DT1–DT4, R1–R5)

/// SessionGuards' ask rules: the window, the waits, and what never lets an ask through.
@MainActor
final class AskRulesTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: hour, minute: minute))!
    }

    func testTheWindowIsNineToEightLocal() {
        XCTAssertFalse(SessionGuards.askWindowOpen(now: at(8, 59), lastNightEnd: nil, calendar: calendar))
        XCTAssertTrue(SessionGuards.askWindowOpen(now: at(9), lastNightEnd: nil, calendar: calendar))
        XCTAssertTrue(SessionGuards.askWindowOpen(now: at(19, 59), lastNightEnd: nil, calendar: calendar))
        XCTAssertFalse(SessionGuards.askWindowOpen(now: at(20), lastNightEnd: nil, calendar: calendar))
    }

    func testTheAsksWaitTwoHoursAfterTheNight() {
        let end = at(8)
        XCTAssertFalse(SessionGuards.askWindowOpen(now: at(9, 59), lastNightEnd: end, calendar: calendar))
        XCTAssertTrue(SessionGuards.askWindowOpen(now: at(10), lastNightEnd: end, calendar: calendar))
    }

    private func rating(clean: Int = 3, asked: Bool = false, cardToday: Bool = false, cardShowing: Bool = false,
                        playing: Bool = false, veil: Bool = false, hour: Int = 12) -> Bool {
        SessionGuards.mayAskForRating(cleanNights: clean, askedThisVersion: asked, tipCardShownToday: cardToday,
                                      tipCardShowing: cardShowing, playing: playing, veilDown: veil,
                                      now: at(hour), lastNightEnd: nil, calendar: calendar)
    }

    func testTheRatingAskNeedsThreeCleanNightsAndADaytimeBreak() {
        XCTAssertTrue(rating())
        XCTAssertFalse(rating(clean: 2))
        XCTAssertFalse(rating(asked: true))                   // once per version
        XCTAssertFalse(rating(cardToday: true))               // never the tip card's day
        XCTAssertFalse(rating(cardShowing: true))             // nor over the card on Home
        XCTAssertFalse(rating(playing: true))
        XCTAssertFalse(rating(veil: true))
        XCTAssertFalse(rating(hour: 21))
    }

    /// The rating waits on the card only while Home really shows it: the Home tab, and the card
    /// ahead in the coachmark band (not behind the first-run card or the night-ring note).
    func testTheTipCardIsShowingOnlyWhereHomeRendersIt() {
        func showing(home: Bool = true, focus: Bool = false, firstRun: Bool = true, ringSeen: Bool = true,
                     due: Bool = true, active: Bool = false) -> Bool {
            SessionGuards.tipCardShowing(onHomeTab: home, focusMode: focus, hasCompletedFirstRun: firstRun,
                                         hasSeenNightRingTip: ringSeen, tipCardDue: due, sessionActive: active)
        }
        XCTAssertTrue(showing())
        XCTAssertFalse(showing(home: false))                  // due, but on Podcasts or Settings
        XCTAssertFalse(showing(firstRun: false))              // behind the first-run card
        XCTAssertFalse(showing(ringSeen: false))              // behind the night-ring note
        XCTAssertFalse(showing(due: false))
        XCTAssertFalse(showing(focus: true))
        XCTAssertFalse(showing(active: true))
    }

    private func card(clean: Int = 5, tipped: Bool = false, spent: Bool = false, ready: Bool = true,
                      focus: Bool = false, playing: Bool = false, ratedToday: Bool = false, hour: Int = 12) -> Bool {
        SessionGuards.tipCardDue(cleanNights: clean, tipped: tipped, spent: spent, productsReady: ready,
                                 focusMode: focus, playing: playing, ratingAskedToday: ratedToday,
                                 now: at(hour), lastNightEnd: nil, calendar: calendar)
    }

    func testTheTipCardWaitsForEverythingAndEndsOnlyOnAnAnswer() {
        XCTAssertTrue(card())
        XCTAssertFalse(card(clean: 4))
        XCTAssertFalse(card(tipped: true))
        XCTAssertFalse(card(spent: true))
        XCTAssertFalse(card(ready: false))                    // can't offer what can't be bought
        XCTAssertFalse(card(focus: true))                     // Sleep Home only (design D10)
        XCTAssertFalse(card(playing: true))
        XCTAssertFalse(card(ratedToday: true))
        XCTAssertFalse(card(hour: 7))
    }
}

/// Sleep Home's morning read-back (`MorningReadback`): last night is every session mostly inside it,
/// any session that broke silences the line, and it shows only the morning after, at rest in Sleep.
final class MorningReadbackTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()

    private func at(day: Int = 12, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute,
                                           second: second))!
    }

    /// The clock time as the line writes it (ICU's, which can differ between runtimes).
    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: calendar.locale!,
                                        calendar: calendar, timeZone: calendar.timeZone))
    }

    /// Started 23:10 on the 11th; ended 00:41 on the 12th by the timer, 90 minutes of live audio.
    private func night(start: Date? = nil, end: Date? = nil, live: TimeInterval = 90 * 60,
                       clean: Bool = true, by: NightEndReason = .timer, taints: [String] = []) -> NightVerdict {
        NightVerdict(id: "n", start: start ?? at(day: 11, 23, 10), end: end ?? at(0, 41), live: live,
                     clean: clean, endedBy: by, taints: taints)
    }

    private func line(_ nights: [NightVerdict]? = nil, open: Date? = nil, focus: Bool = false,
                      playing: Bool = false, now: Date? = nil) -> MorningReadback.Line? {
        MorningReadback.line(nights: nights ?? [night()], openSince: open, focusMode: focus, playing: playing,
                             now: now ?? at(7, 30), calendar: calendar)
    }

    func testEachEndingReadsInPlainWords() {
        let late = clock(at(0, 41)), morning = clock(at(6, 40))
        XCTAssertTrue(late.contains("41"), late)
        XCTAssertEqual(line()?.text, "Last night · 1 hr 30 min, eased out at \(late)")
        XCTAssertEqual(line([night(live: 52 * 60, by: .episodeEnd)])?.text,
                       "Last night · 52 min, ended with the episode at \(late)")
        XCTAssertEqual(line([night(end: at(6, 40), live: 7 * 3600 + 12 * 60, by: .person)])?.text,
                       "Last night · 7 hr 12 min, until \(morning)")
        XCTAssertEqual(line([night(end: at(6, 40), live: 7 * 3600, by: .focusSwitch)])?.text,
                       "Last night · 7 hr, until \(morning)")
    }

    /// The span is rounded once, so the screen and VoiceOver can't disagree by a minute.
    func testVoiceOverHearsTheSameMinutesInWords() {
        let spoken = line()?.spoken ?? ""
        XCTAssertTrue(spoken.hasPrefix("Last night, 1 hour"), spoken)
        XCTAssertFalse(spoken.contains("hr"), spoken)
        XCTAssertTrue(spoken.hasSuffix("eased out at \(clock(at(0, 41)))"), spoken)
        let halfMinute = line([night(end: at(6, 40), live: 7 * 3600 + 12 * 60 + 30, by: .person)])
        XCTAssertTrue(halfMinute?.text.contains("7 hr 13 min") == true, halfMinute?.text ?? "nil")
        XCTAssertTrue(halfMinute?.spoken.contains("13 minutes") == true, halfMinute?.spoken ?? "nil")
    }

    func testABrokenSessionSilencesTheNight() {
        XCTAssertNil(line([night(clean: false, taints: ["player rebuilt"])]))
        XCTAssertNil(line([night(clean: false, by: .died)]))
        XCTAssertNil(line([night(clean: false)]))                    // a reconciled timer end
        XCTAssertNil(line([night(clean: false, by: .person, taints: ["podcast failed"])]))
    }

    /// The units are spoken in the calendar's locale, the clock time's, not the simulator's.
    func testTheSpokenUnitsFollowTheCalendarsLocale() {
        var french = calendar
        french.locale = Locale(identifier: "fr_FR")
        let spoken = MorningReadback.line(nights: [night()], openSince: nil, focusMode: false, playing: false,
                                          now: at(7, 30), calendar: french)?.spoken ?? ""
        XCTAssertTrue(spoken.contains("heure"), spoken)
        XCTAssertFalse(spoken.contains("hour"), spoken)
        let german = PlayerClock.spoken(5400, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(german.contains("Stunde"), german)
    }

    /// Each ending breaks by its own rule: an episode's end like a timer's, a Focus switch like a pause.
    func testEachEndingBreaksByItsOwnRule() {
        XCTAssertNil(line([night(live: 52 * 60, clean: false, by: .episodeEnd)]))    // reconciled
        XCTAssertNil(line([night(end: at(1, 30), live: 2 * 3600, clean: false, by: .focusSwitch,
                                 taints: ["podcast failed"])]))
        XCTAssertEqual(line([night(end: at(1, 30), live: 2 * 3600, clean: false, by: .focusSwitch)])?.text,
                       "Last night · 2 hr, until \(clock(at(1, 30)))")
    }

    /// Nothing failed; the person stopped it early. That's still a night that held.
    func testANightThePersonEndedEarlyStillReadsBack() {
        XCTAssertEqual(line([night(end: at(0, 10), live: 40 * 60, clean: false, by: .person)])?.text,
                       "Last night · 40 min, until \(clock(at(0, 10)))")
    }

    /// Live audio runs a little under a timer's length: a 10-minute night came in at 599 s.
    func testTenMinutesIsCountedAsTheLineShowsThem() {
        XCTAssertNotNil(line([night(live: 599.4)]))
        XCTAssertNil(line([night(live: 9 * 60 + 29)]))                // reads "9 min": a test, not a night
    }

    func testOnlyAtRestInSleep() {
        XCTAssertNil(line(focus: true))
        XCTAssertNil(line(playing: true))
        XCTAssertNil(line(open: at(day: 11, 23, 50)))                // last night still open (paused)
        XCTAssertNil(line([]))
    }

    func testTheMorningRunsFromFiveAMToSixPM() {
        XCTAssertNil(line(now: at(4, 59)))
        XCTAssertNotNil(line(now: at(5)))
        XCTAssertNotNil(line(now: at(17, 59)))
        XCTAssertNil(line(now: at(18)))                                 // by evening it's tonight
        let early = night(start: at(day: 11, 23), end: at(day: 11, 23, 30), live: 30 * 60)
        XCTAssertNil(line([early], now: at(day: 11, 23, 45)))           // 23:45: the window has closed
    }

    /// TESTING.md section X.3: a morning Play, then a pause or a trip to Focus, isn't last night.
    func testAMorningSessionNeverCountsAsLastNight() {
        let morning = night(start: at(8), end: at(8, 1), live: 45, clean: false, by: .focusSwitch)
        XCTAssertEqual(line([night(), morning], now: at(8, 5))?.text, line()?.text)
        XCTAssertNotNil(line([night()], open: at(8), now: at(8, 5)))    // paused morning session
    }

    /// The app died at 2 am and the person restarted the sound: that night didn't hold.
    func testEverySessionOfTheNightCounts() {
        let died = night(end: at(2), live: 2 * 3600, clean: false, by: .died)
        let restarted = night(start: at(2, 10), end: at(7), live: 4 * 3600 + 50 * 60, by: .person)
        XCTAssertNil(line([died, restarted]))
        let tainted = night(clean: false, taints: ["pipeline died"])
        XCTAssertNil(line([tainted, restarted]))
        // Woke at 3, played 20 minutes, paused: summed, and the line ends where the last one did.
        let wokeAtThree = night(start: at(3), end: at(3, 20), live: 20 * 60, clean: false, by: .person)
        XCTAssertEqual(line([night(), wokeAtThree])?.text,
                       "Last night · 1 hr 50 min, until \(clock(at(3, 20)))")
        // An early bedtime that died: started before 18:00, still last night's.
        let diedEarly = night(start: at(day: 11, 17, 50), end: at(2), live: 8 * 3600, clean: false, by: .died)
        XCTAssertNil(line([diedEarly, restarted]))
        XCTAssertNil(line([night()], open: at(day: 11, 17, 50)))        // still open from 17:50
    }

    /// Last night is 18:00 to 05:00: a session with at least half its span inside counts.
    func testASessionBelongsWhenMostOfItIsInsideTheNight() {
        XCTAssertNotNil(line([night(start: at(day: 11, 18), end: at(day: 11, 21), live: 3 * 3600, by: .person)]))
        XCTAssertNotNil(line([night(start: at(day: 11, 17, 59), end: at(day: 11, 21), live: 3 * 3600, by: .person)]))
        XCTAssertNil(line([night(start: at(day: 11, 17), end: at(day: 11, 17, 59), live: 59 * 60, by: .person)]))
        XCTAssertNotNil(line([night(start: at(4), end: at(5, 30))]))  // woke at 4, mostly night
        XCTAssertNil(line([night(start: at(4, 59), end: at(6, 15))])) // mostly morning
        XCTAssertNil(line([night(start: at(5), end: at(6, 30))]))    // up for the day
        XCTAssertNil(line([night(start: at(day: 11, 14), end: at(day: 11, 15))]))   // afternoon rest
        // An afternoon session that ran a few minutes past 18:00 is not last night...
        let afternoon = night(start: at(day: 11, 12), end: at(day: 11, 18, 5), live: 6 * 3600 + 5 * 60, by: .person)
        XCTAssertNil(line([afternoon]))
        // ...and isn't added to the night that follows.
        let nap = night(start: at(day: 11, 16, 30), end: at(day: 11, 18, 15), live: 105 * 60, by: .person)
        let short = night(start: at(day: 11, 23), end: at(day: 11, 23, 45), live: 45 * 60)
        XCTAssertEqual(line([nap, short])?.text, "Last night · 45 min, eased out at \(clock(at(day: 11, 23, 45)))")
    }

    /// A corrupt verdict file can't trap the minutes: PlayerClock's clamp, both ends.
    func testACorruptVerdictCannotTrapTheMinutes() {
        XCTAssertTrue(line([night(live: 1e300)])?.record.hasPrefix("999 hr") == true)
        XCTAssertNil(line([night(live: -1e300)]))
        XCTAssertNil(line([night(live: .infinity)]))
        XCTAssertNil(line([night(live: .nan)]))
    }

    /// Home re-reads the line where its window opens and closes, with nothing else to prompt it.
    func testTheLineIsReReadAtItsWindowsEdges() {
        XCTAssertEqual(MorningReadback.nextEdge(after: at(4), calendar: calendar), at(5))
        XCTAssertEqual(MorningReadback.nextEdge(after: at(7, 30), calendar: calendar), at(18))
        XCTAssertEqual(MorningReadback.nextEdge(after: at(18), calendar: calendar), at(day: 13, 5))
    }

    func testANightTwoDaysOldIsNotLastNight() {
        let old = night(start: at(day: 10, 23), end: at(day: 11, 1))
        XCTAssertNil(line([old], now: at(9)))
        XCTAssertNotNil(line([old], now: at(day: 11, 9)))
        // After midnight two nights back.
        XCTAssertNil(line([night(start: at(day: 11, 1, 15), end: at(day: 11, 2, 45))], now: at(9)))
    }

    func testANightEndingAfterNowSaysNothing() {
        XCTAssertNil(line([night(start: at(1, 15), end: at(8))], now: at(7, 30)))
    }

    /// Through the real journal: a clean timer night, then a morning Play and a switch to Focus.
    func testTheJournalsMorningSessionLeavesLastNightsLine() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mr-\(UUID().uuidString)")
        var now = at(day: 11, 23, 10)
        let j = NightJournal(directory: dir, storage: StorageManager(directory: dir), observeTermination: false,
                             now: { now })
        defer { j.drain(); try? FileManager.default.removeItem(at: dir) }
        j.sessionStarted()
        for _ in 0..<(90 * 60) { now += 1; j.liveTick() }
        j.timerStopped(episode: false, reconciled: false, endedAt: now)
        now = at(8)
        j.sessionStarted()
        for _ in 0..<45 { now += 1; j.liveTick() }
        j.sessionStopped()                                              // the morning session, paused
        XCTAssertEqual(MorningReadback.line(nights: j.verdicts, openSince: j.open?.start, focusMode: false,
                                            playing: false, now: now, calendar: calendar)?.record,
                       "1 hr 30 min, eased out at \(clock(at(0, 40)))")
        j.sessionStarted()                                              // resumed, then off to Focus
        j.switchedToFocus()
        XCTAssertEqual(j.verdicts.count, 2)
        XCTAssertEqual(MorningReadback.line(nights: j.verdicts, openSince: j.open?.start, focusMode: false,
                                            playing: false, now: now, calendar: calendar)?.record,
                       "1 hr 30 min, eased out at \(clock(at(0, 40)))")
    }

    /// TESTING.md section X.2 through the real journal: All night, paused at 06:10, read 35 minutes
    /// later, after refreshAsks closes the lapsed pause.
    func testALapsedMorningPauseReadsBackThroughTheJournal() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mr-\(UUID().uuidString)")
        var now = at(day: 11, 23, 10)
        let j = NightJournal(directory: dir, storage: StorageManager(directory: dir), observeTermination: false,
                             now: { now })
        defer { j.drain(); try? FileManager.default.removeItem(at: dir) }
        j.sessionStarted()
        for _ in 0..<(7 * 3600) { now += 1; j.liveTick() }
        j.sessionStopped()
        now += 35 * 60
        XCTAssertNil(MorningReadback.line(nights: j.verdicts, openSince: j.open?.start, focusMode: false,
                                          playing: false, now: now, calendar: calendar))   // still open
        j.closeLapsedPause()
        XCTAssertEqual(MorningReadback.line(nights: j.verdicts, openSince: j.open?.start, focusMode: false,
                                            playing: false, now: now, calendar: calendar)?.record,
                       "7 hr, until \(clock(at(6, 10)))")
    }
}

/// The coachmark band's order: first-run, the night-ring note, then the tip card; never in Focus,
/// and the tip card never over a playing session.
@MainActor
final class CoachmarkTipCardTests: XCTestCase {
    func testTheTipCardComesAfterTheOtherTipsAndOnlyAtRest() {
        XCTAssertEqual(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: false,
                                                hasSeenNightRingTip: false, tipCardDue: true), .firstRun)
        XCTAssertEqual(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: true,
                                                hasSeenNightRingTip: false, tipCardDue: true), .nightRing)
        XCTAssertEqual(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: true,
                                                hasSeenNightRingTip: true, tipCardDue: true), .tip)
        XCTAssertNil(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: true,
                                              hasSeenNightRingTip: true, tipCardDue: true, sessionActive: true))
        XCTAssertNil(CoachmarkContent.current(focusMode: true, hasCompletedFirstRun: true,
                                              hasSeenNightRingTip: true, tipCardDue: true))
        XCTAssertNil(CoachmarkContent.current(focusMode: false, hasCompletedFirstRun: true,
                                              hasSeenNightRingTip: true, tipCardDue: false))
    }
}

/// The Rate row shows only where it works (design D8).
@MainActor
final class RateRowRuleTests: XCTestCase {
    func testOnlyWithAnAppStoreIDOnAnAppStoreBuild() {
        XCTAssertFalse(RateRowRule.visible(appStoreID: nil, environment: .production))
        XCTAssertFalse(RateRowRule.visible(appStoreID: "", environment: .production))
        XCTAssertFalse(RateRowRule.visible(appStoreID: "123", environment: .other))   // Xcode, TestFlight
        XCTAssertTrue(RateRowRule.visible(appStoreID: "123", environment: .production))
        XCTAssertEqual(RateRowRule.writeReviewURL(appStoreID: "123")?.absoluteString,
                       "https://apps.apple.com/app/id123?action=write-review")
    }
}

/// The feedback message says what's attached and where it goes, in plain words (design D9).
@MainActor
final class FeedbackMessageTests: XCTestCase {
    func testTheBodyListsWhatsAttachedWithoutLinks() {
        let body = FeedbackMessage.body(nightSummary: "Last 2 nights: 1 clean.", nightFiles: 2,
                                        reportsSince: Date(timeIntervalSince1970: 1_800_000_000),
                                        version: "1.0", build: "7", iOS: "26.3", device: "iPhone")
        XCTAssertTrue(body.contains("Attached: the last 2 nights' playback events (no web addresses) and iOS reports since"))
        XCTAssertTrue(body.contains("Last 2 nights: 1 clean."))
        XCTAssertTrue(body.contains("Sleepulator 1.0 (7) · iOS 26.3 · iPhone"))
        XCTAssertFalse(body.contains("://"))
        XCTAssertTrue(body.hasPrefix("\n"))                    // room for the person's own words first
    }

    func testNothingAttachedYet() {
        let body = FeedbackMessage.body(nightSummary: "No night recorded yet.", nightFiles: 0, reportsSince: nil,
                                        version: "1.0", build: "1", iOS: "26", device: "iPhone")
        XCTAssertTrue(body.contains("Attached: nothing yet."))
        XCTAssertTrue(body.contains("No night recorded yet."))
    }

    func testTheShareTextCarriesTheAddress() {
        XCTAssertTrue(FeedbackMessage.shareText(address: "help@example.com", body: "x").hasPrefix("Please send this to help@example.com"))
        XCTAssertEqual(FeedbackMessage.shareText(address: nil, body: "x"), "x")
    }
}
