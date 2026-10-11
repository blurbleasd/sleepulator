import XCTest
@testable import Sleepulator

/// Export → (JSON file) → import fidelity for the settings backup. The picker can't be scripted,
/// so this drives the two pure halves the real Export/Import call — `backupUserDefaults` and
/// `restoreUserDefaults` — with a JSON serialize/deserialize between them (exactly what writing and
/// re-reading the backup file does). Guards the persistence-critical path: full round-trip, the
/// security allowlist, malformed-section tolerance, and the extraLayers gap this change closed.
final class BackupRoundTripTests: XCTestCase {

    private let suite = "BackupRoundTripTests.suite"
    private var d: UserDefaults!

    override func setUpWithError() throws {
        d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
    }
    override func tearDown() {
        d.removePersistentDomain(forName: suite)
        d = nil
    }

    /// What actually happens between export and import: the dict is written to a JSON file and read
    /// back. Round-tripping through JSONSerialization here reproduces any type coercion the file does.
    private func throughBackupFile(_ dict: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: full scalar round-trip (Double / Bool / Int / String all survive the JSON hop)

    func testNightLengthAndTailRoundTrip() throws {
        d.set(45.0, forKey: "nightLengthMinutes")
        d.set(30, forKey: "ambientTailMinutes")
        let file = try throughBackupFile(Backup.userDefaults(from: d))
        d.removePersistentDomain(forName: suite)
        let (restored, skipped) = Backup.restoreUserDefaults(from: file, into: d)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(d.double(forKey: "nightLengthMinutes"), 45, accuracy: 1e-9)
        XCTAssertEqual(d.integer(forKey: "ambientTailMinutes"), 30)
    }

    func testScalarsRoundTripThroughJSON() throws {
        d.set(0.42, forKey: "masterVolume")
        d.set(true,  forKey: "autoPlay")
        d.set(false, forKey: "shuffleQueue")
        d.set(30.0,  forKey: "skipInterval")
        d.set(20,    forKey: "timerMinutes")
        d.set("green", forKey: "noiseType")
        d.set(true,  forKey: "focusMode")
        d.set("still-water", forKey: "sceneSleep")

        let file = try throughBackupFile(Backup.userDefaults(from: d))
        d.removePersistentDomain(forName: suite)                 // wipe → prove restore, not leftover state
        let (restored, skipped) = Backup.restoreUserDefaults(from: file, into: d)

        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(restored, 8)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.42, accuracy: 1e-9)
        XCTAssertTrue(d.bool(forKey: "autoPlay"))
        XCTAssertFalse(d.bool(forKey: "shuffleQueue"))
        XCTAssertEqual(d.double(forKey: "skipInterval"), 30, accuracy: 1e-9)
        XCTAssertEqual(d.integer(forKey: "timerMinutes"), 20)
        XCTAssertEqual(d.string(forKey: "noiseType"), "green")
        XCTAssertTrue(d.bool(forKey: "focusMode"))
        XCTAssertEqual(d.string(forKey: "sceneSleep"), "still-water")
    }

    // MARK: extraLayers — the Data-encoded blob that was silently dropped from every backup

    func testExtraLayersRoundTrip() throws {
        let layers = [
            ExtraNoiseLayer(id: "a", type: "rain", volume: 0.6, muted: nil),
            ExtraNoiseLayer(id: "b", type: "fire", volume: 0.3, muted: true),
        ]
        d.set(try JSONEncoder().encode(layers), forKey: "extraLayers")

        let file = try throughBackupFile(Backup.userDefaults(from: d))
        XCTAssertNotNil(file["extraLayers"], "extraLayers must be included in the backup")

        d.removePersistentDomain(forName: suite)
        _ = Backup.restoreUserDefaults(from: file, into: d)

        let raw = try XCTUnwrap(d.data(forKey: "extraLayers"))
        XCTAssertEqual(try JSONDecoder().decode([ExtraNoiseLayer].self, from: raw), layers)
    }

    // MARK: security — restore writes nothing outside the allowlist

    func testUnknownKeysNeverWritten() throws {
        let dict: [String: Any] = ["evilKey": "pwned", "masterVolume": 0.5]
        let (restored, skipped) = Backup.restoreUserDefaults(from: dict, into: d)
        XCTAssertNil(d.object(forKey: "evilKey"))
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(skipped, 1)
    }

    // MARK: robustness — a malformed section is skipped, the rest still restores

    func testMalformedEncodedBlobSkippedButRestContinues() throws {
        let dict: [String: Any] = ["extraLayers": ["not": "a layer array"], "masterVolume": 0.7]
        let (_, skipped) = Backup.restoreUserDefaults(from: dict, into: d)
        XCTAssertNil(d.data(forKey: "extraLayers"))                              // garbage rejected
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.7, accuracy: 1e-9)    // rest still restored
        XCTAssertGreaterThanOrEqual(skipped, 1)
    }

    // MARK: file-backed validation gate

    func testFileBackedValidationGate() throws {
        let goodPositions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["ep1": 12.5]))
        XCTAssertNotNil(Backup.validatedFileData(key: "episodePositions", value: goodPositions))
        XCTAssertNil(Backup.validatedFileData(key: "episodePositions", value: ["ep1": "not-a-number"]))
        XCTAssertNil(Backup.validatedFileData(key: "unknownFile", value: [String: Any]()))
    }

    // MARK: settings that used to be left out

    func testHoldPlayedAndLastPicksRoundTrip() throws {
        d.set(true, forKey: "holdQueueDuringSleepTimer")
        d.set(["ep1", "ep2"], forKey: "finishedEpisodes")
        d.set("rain", forKey: "lastPick.noise.sleep")
        d.set("beta", forKey: "lastPick.binaural.focus")
        let file = try throughBackupFile(Backup.userDefaults(from: d))
        d.removePersistentDomain(forName: suite)
        let (restored, skipped) = Backup.restoreUserDefaults(from: file, into: d)
        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(restored, 4)
        XCTAssertTrue(d.bool(forKey: "holdQueueDuringSleepTimer"))
        XCTAssertEqual(d.stringArray(forKey: "finishedEpisodes"), ["ep1", "ep2"])
        XCTAssertEqual(d.string(forKey: "lastPick.noise.sleep"), "rain")
        XCTAssertEqual(d.string(forKey: "lastPick.binaural.focus"), "beta")
    }

    func testPlayedListMustBeStrings() {
        let (restored, skipped) = Backup.restoreUserDefaults(from: ["finishedEpisodes": [1, 2]], into: d)
        XCTAssertNil(d.object(forKey: "finishedEpisodes"))
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(skipped, 1)
    }

    // MARK: the marker and Undo's exact replace

    func testMarkerIsNeitherWrittenNorCountedAsSkipped() throws {
        let dict = Backup.exportDictionary(defaults: d, files: [:], at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(dict[Backup.markerKey] as? Int, 1)
        let (restored, skipped) = Backup.restoreUserDefaults(from: try throughBackupFile(dict), into: d)
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(skipped, 0)
        XCTAssertNil(d.object(forKey: Backup.markerKey))
        XCTAssertNil(d.object(forKey: Backup.exportedAtKey))
    }

    func testReplacingRemovesAllowlistedKeysTheSnapshotLacks() {
        d.set(1.2, forKey: "stereoWidth")          // set by the restore being undone
        d.set("keep", forKey: "notOurs")            // never ours to touch
        _ = Backup.restoreUserDefaults(from: ["masterVolume": 0.5], into: d, replacing: true)
        XCTAssertNil(d.object(forKey: "stereoWidth"))
        XCTAssertEqual(d.string(forKey: "notOurs"), "keep")
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.5, accuracy: 1e-9)
    }

    func testMergeLeavesKeysTheBackupLacks() {
        d.set(1.2, forKey: "stereoWidth")
        _ = Backup.restoreUserDefaults(from: ["masterVolume": 0.5], into: d)
        XCTAssertEqual(d.double(forKey: "stereoWidth"), 1.2, accuracy: 1e-9)
    }

    func testExportDictionaryCarriesTheFiles() throws {
        let positions = try JSONEncoder().encode(["ep1": 12.5])
        let dict = Backup.exportDictionary(defaults: d, files: ["positions.json": positions],
                                           at: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual((dict["episodePositions"] as? [String: Double])?["ep1"], 12.5)
        XCTAssertEqual(dict[Backup.exportedAtKey] as? Double, 1_000)
    }

    // MARK: what the confirm and the result say

    func testContentsCountsAndSaysEmptySectionsOut() throws {
        let ep = Episode(id: "e", title: "E", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        let shows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([
            Podcast(id: "a", name: "A", url: "fa", episodes: [ep]),
            Podcast(id: "b", name: "B", url: "fb", episodes: []),
        ]))
        let queue = try JSONSerialization.jsonObject(with: JSONEncoder().encode([ep]))
        let dict: [String: Any] = ["savedPlaylists": [Any](), "savedPodcasts": shows, "upNextQueue": queue,
                                   "masterVolume": 0.5, Backup.exportedAtKey: 1_000.0]
        let c = Backup.contents(of: dict)
        XCTAssertEqual(c.mixes, 0)
        XCTAssertEqual(c.shows, 2)
        XCTAssertEqual(c.upNext, 1)
        XCTAssertTrue(c.settings)
        XCTAssertEqual(c.exportedAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(Backup.confirmMessage(c),
                       "This replaces what's on this iPhone with the backup's no mixes, 2 shows, 1 episode in Up Next and settings. You can undo it afterwards.")
        XCTAssertEqual(Backup.restoredMessage(Backup.Outcome(contents: c, skipped: 0, undoAvailable: true)),
                       "Restored no mixes, 2 shows, 1 episode in Up Next and your settings.")
    }

    func testANonBackupRestoresNothing() {
        XCTAssertFalse(Backup.contents(of: ["name": "Not a backup", "evilKey": 1]).restoresAnything)
        XCTAssertFalse(Backup.contents(of: ["savedPodcasts": "garbage"]).restoresAnything)
        XCTAssertTrue(Backup.contents(of: ["autoPlay": true]).restoresAnything)
    }

    func testSkippedPartsAreMentionedWithoutCounts() {
        let o = Backup.Outcome(contents: Backup.Contents(settings: true), skipped: 3, undoAvailable: true)
        XCTAssertEqual(Backup.restoredMessage(o),
                       "Restored your settings. A few parts of the file weren't recognised and were left as they were.")
    }

    func testListCopy() {
        XCTAssertEqual(Backup.counted(0, "mix", "mixes"), "no mixes")
        XCTAssertEqual(Backup.counted(1, "mix", "mixes"), "1 mix")
        XCTAssertEqual(Backup.counted(4, "mix", "mixes"), "4 mixes")
        XCTAssertEqual(Backup.joined([]), "")
        XCTAssertEqual(Backup.joined(["a"]), "a")
        XCTAssertEqual(Backup.joined(["a", "b"]), "a and b")
        XCTAssertEqual(Backup.joined(["a", "b", "c"]), "a, b and c")
    }

    func testUndoIsOfferedForAWeek() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertFalse(Backup.undoAvailable(takenAt: nil, now: now))
        XCTAssertTrue(Backup.undoAvailable(takenAt: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(Backup.undoAvailable(takenAt: now.addingTimeInterval(-6 * 86_400), now: now))
        XCTAssertFalse(Backup.undoAvailable(takenAt: now.addingTimeInterval(-8 * 86_400), now: now))
        XCTAssertFalse(Backup.undoAvailable(takenAt: now.addingTimeInterval(60), now: now), "a clock set back")
        XCTAssertTrue(Backup.undoAvailable(takenAt: now.addingTimeInterval(1e-6), now: now),
                      "the stored time can round a hair past now")
    }

    func testExportFilenameIsDated() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(Backup.filename(for: Date(timeIntervalSince1970: 1_791_763_200), calendar: cal),
                       "sleepulator-backup-2026-10-12")
        XCTAssertEqual(Backup.filename(for: Date(timeIntervalSince1970: 1_791_763_200), prefix: "sleepulator-log", calendar: cal),
                       "sleepulator-log-2026-10-12")
    }

    // MARK: restore → undo, end to end against a temp store

    @MainActor
    func testRestoreThenUndoPutsEverythingBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupUndo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let positionsBefore = try JSONEncoder().encode(["ep1": 30.0])
        storage.writeRaw(positionsBefore, to: "positions.json")
        d.set(0.3, forKey: "masterVolume")

        let backup: [String: Any] = [
            "masterVolume": 0.9, "stereoWidth": 1.2,
            "episodePositions": ["ep9": 5.0], "savedPodcasts": [Any](),
            Backup.markerKey: 1,
        ]
        let data = try JSONSerialization.data(withJSONObject: backup)
        let now = Date()
        let outcome = await Backup.restore(Backup.Pending(data: data, contents: Backup.contents(of: backup)),
                                           now: now, storage: storage, defaults: d)
        XCTAssertTrue(outcome.undoAvailable)
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.9, accuracy: 1e-9)
        XCTAssertEqual(d.double(forKey: "stereoWidth"), 1.2, accuracy: 1e-9)
        XCTAssertNotNil(storage.rawData(for: "library.json"), "an empty library in the backup empties it")
        XCTAssertEqual(Backup.undoDate(now: now, storage: storage, defaults: d)?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 1e-3)

        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertTrue(undone)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.3, accuracy: 1e-9)
        XCTAssertNil(d.object(forKey: "stereoWidth"), "a setting the restore added is gone again")
        XCTAssertNil(storage.rawData(for: "library.json"), "a file the restore added is gone again")
        let positions = try JSONDecoder().decode([String: Double].self, from: try XCTUnwrap(storage.rawData(for: "positions.json")))
        XCTAssertEqual(positions, ["ep1": 30.0])
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d), "Undo is offered once")
        XCTAssertNil(storage.rawData(for: Backup.undoFile))
    }

    @MainActor
    func testAnExpiredUndoIsClearedAndRefused() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupUndo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        storage.writeRaw(Data("{}".utf8), to: Backup.undoFile)
        let now = Date()
        d.set(now.addingTimeInterval(-8 * 86_400).timeIntervalSince1970, forKey: Backup.undoTakenAtKey)
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d))
        storage.flush()
        XCTAssertNil(storage.rawData(for: Backup.undoFile))
        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertFalse(undone)
    }
}
