import XCTest
@testable import Sleepulator

/// Export → (JSON file) → import fidelity for the settings backup. The picker can't be scripted,
/// so the round trips drive the export's `Backup.userDefaults` and the restore's two steps
/// (`restoreUserDefaults`, a convenience over `restorePlan` + `apply`, the steps `write` runs) with
/// a JSON serialize/deserialize between them, exactly what writing and re-reading the file does.
/// The @MainActor tests drive the shipping `Backup.read` / `restore` / `undo` against a temp store.
/// Guards the persistence-critical path: full round trip, the allowlist and its shapes,
/// malformed-section tolerance, the Sleep/Focus sorting, and Undo.
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
        d.set("still-water", forKey: "sceneSleep")

        let file = try throughBackupFile(Backup.userDefaults(from: d))
        d.removePersistentDomain(forName: suite)                 // wipe → prove restore, not leftover state
        let (restored, skipped) = Backup.restoreUserDefaults(from: file, into: d)

        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(restored, 7)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.42, accuracy: 1e-9)
        XCTAssertTrue(d.bool(forKey: "autoPlay"))
        XCTAssertFalse(d.bool(forKey: "shuffleQueue"))
        XCTAssertEqual(d.double(forKey: "skipInterval"), 30, accuracy: 1e-9)
        XCTAssertEqual(d.integer(forKey: "timerMinutes"), 20)
        XCTAssertEqual(d.string(forKey: "noiseType"), "green")
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
        XCTAssertEqual(Backup.validatedFileSection(key: "episodePositions", value: goodPositions)?.count, 1)
        XCTAssertNil(Backup.validatedFileSection(key: "episodePositions", value: ["ep1": "not-a-number"]))
        XCTAssertNil(Backup.validatedFileSection(key: "unknownFile", value: [String: Any]()))
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
        // Value: protects=every mode-memory key AudioEngine writes is in the backup allowlist; fails_when=pickKey's format changes and Backup's literal key list goes stale; why_new=the round trip above uses literals, blind to a rename; seam=none; no_claim=renamed kinds ("noise"/"binaural") or other persisted keys
        for kind in ["noise", "binaural"] {
            for focus in [false, true] {
                XCTAssertTrue(Backup.scalarKeys.contains(AudioEngine.pickKey(kind, focus: focus)),
                              "\(AudioEngine.pickKey(kind, focus: focus)) must be backed up")
            }
        }
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

    func testReplacingRemovesAllowlistedKeysTheSnapshotLacks() throws {
        d.set(1.2, forKey: "stereoWidth")          // set by the restore being undone
        d.set("keep", forKey: "notOurs")            // never ours to touch
        // Value: protects=Undo also removes encoded blobs (extra mixer layers) the restore added; fails_when=the replacing pass stops covering encodedKeys; why_new=this test covered scalar keys only; seam=none; no_claim=lastMix specifically
        d.set(try JSONEncoder().encode([ExtraNoiseLayer(id: "a", type: "rain", volume: 0.6, muted: nil)]),
              forKey: "extraLayers")               // also set by the restore being undone
        _ = Backup.restoreUserDefaults(from: ["masterVolume": 0.5], into: d, replacing: true)
        XCTAssertNil(d.object(forKey: "stereoWidth"))
        XCTAssertNil(d.object(forKey: "extraLayers"), "an encoded blob the snapshot lacks goes too")
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
        XCTAssertEqual(Backup.restoredMessage(Backup.Outcome(contents: c, skipped: 0)),
                       "Restored no mixes, 2 shows, 1 episode in Up Next and your settings.")
    }

    func testANonBackupRestoresNothing() {
        XCTAssertFalse(Backup.contents(of: ["name": "Not a backup", "evilKey": 1]).restoresAnything)
        XCTAssertFalse(Backup.contents(of: ["savedPodcasts": "garbage"]).restoresAnything)
        XCTAssertTrue(Backup.contents(of: ["autoPlay": true]).restoresAnything)
    }

    func testSkippedPartsAreMentionedWithoutCounts() {
        let o = Backup.Outcome(contents: Backup.Contents(settings: true), skipped: 3)
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
        XCTAssertTrue(Backup.undoAvailable(takenAt: now.addingTimeInterval(1e-6), now: now),
                      "the stored time can round a hair past now")
        XCTAssertTrue(Backup.undoAvailable(takenAt: now.addingTimeInterval(3_600), now: now),
                      "a clock set back an hour keeps Undo")
        XCTAssertFalse(Backup.undoAvailable(takenAt: now.addingTimeInterval(8 * 86_400), now: now),
                       "more than a week ahead is no clock correction; the copy isn't kept for it")
    }

    // Value: protects=a clock set back keeps the Undo snapshot and its date; fails_when=undoDate treats a future snapshot as expired and discards it; why_new=only undoAvailable's slack second was tested; seam=none; no_claim=how long a future snapshot stays offered
    @MainActor
    func testAClockSetBackKeepsTheUndoCopy() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupClock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        storage.writeRaw(Data("{}".utf8), to: Backup.undoFile)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let takenAt = now.addingTimeInterval(2 * 3_600)                      // the clock went back 2 hours
        d.set(takenAt.timeIntervalSince1970, forKey: Backup.undoTakenAtKey)
        XCTAssertEqual(Backup.undoDate(now: now, storage: storage, defaults: d), takenAt)
        storage.flush()
        XCTAssertEqual(storage.rawData(for: Backup.undoFile), Data("{}".utf8), "the copy isn't thrown away")
    }

    func testExportFilenameIsDated() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertEqual(Backup.filename(for: Date(timeIntervalSince1970: 1_791_763_200), calendar: cal),
                       "sleepulator-backup-2026-10-12")
        XCTAssertEqual(Backup.filename(for: Date(timeIntervalSince1970: 1_791_763_200), prefix: "sleepulator-log", calendar: cal),
                       "sleepulator-log-2026-10-12")
        // Value: protects=the file name's year is Gregorian whatever the device's calendar; fails_when=filename reads years from the calendar it's given (Calendar.current); why_new=the test only used a Gregorian calendar; seam=none; no_claim=the time zone's day boundary
        for identifier in [Calendar.Identifier.japanese, .buddhist, .hebrew] {
            var other = Calendar(identifier: identifier)
            other.timeZone = cal.timeZone
            XCTAssertEqual(Backup.filename(for: Date(timeIntervalSince1970: 1_791_763_200), calendar: other),
                           "sleepulator-backup-2026-10-12", "\(identifier)")
        }
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
        let restored = await Backup.restore(Backup.Pending(data: data, contents: Backup.contents(of: backup)),
                                            now: now, storage: storage, defaults: d)
        let outcome = try XCTUnwrap(restored, "the snapshot was saved, so the restore went ahead")
        XCTAssertEqual(outcome.skipped, 0)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.9, accuracy: 1e-9)
        XCTAssertEqual(d.double(forKey: "stereoWidth"), 1.2, accuracy: 1e-9)
        XCTAssertNotNil(storage.rawData(for: "library.json"), "an empty library in the backup empties it")
        XCTAssertEqual(try JSONDecoder().decode([String: Double].self, from: try XCTUnwrap(storage.rawData(for: "positions.json"))),
                       ["ep9": 5.0], "the restore wrote the backup's saved places")
        XCTAssertEqual(Backup.undoDate(now: now, storage: storage, defaults: d)?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 1e-3)

        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.3, accuracy: 1e-9)
        XCTAssertNil(d.object(forKey: "stereoWidth"), "a setting the restore added is gone again")
        // Emptied, not deleted: LibraryView ignores a missing file and saved the restored shows back.
        XCTAssertEqual(try JSONDecoder().decode([Podcast].self, from: try XCTUnwrap(storage.rawData(for: "library.json"))), [],
                       "the shows the restore added are gone again")
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
        XCTAssertEqual(undone, .gone)
    }

    // MARK: read: only a backup reaches the confirm

    // Value: protects=Backup.read lets only a recognisable backup reach "Replace" and maps each failure to its message; fails_when=read drops its dict/restoresAnything guard or calls an unreadable file "not a backup"; why_new=read(url) had no test, only contents(of:); seam=none; no_claim=which of noAccess/unreadable, or the picker UI
    @MainActor
    func testReadAcceptsAnExportAndRefusesEverythingElse() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRead-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try data.write(to: url)
            return url
        }
        func failure(_ result: Result<Backup.Pending, Backup.ReadFailure>) -> Backup.ReadFailure? {
            if case .failure(let f) = result { return f }
            return nil
        }

        // A real export, as Export a backup saves it and the person later picks it.
        let storage = StorageManager(directory: dir.appendingPathComponent("store"))
        let ep = Episode(id: "e", title: "E", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        storage.writeRaw(try JSONEncoder().encode([Podcast(id: "a", name: "A", url: "fa", episodes: [ep])]),
                         to: "library.json")
        d.set(0.6, forKey: "masterVolume")
        let at = Date(timeIntervalSince1970: 1_000_000)
        let exported = try await Backup.exportData(at: at, storage: storage, defaults: d)
        XCTAssertEqual(exported.leftOut, [])
        let read = await Backup.read(try file("export.json", exported.data))
        guard case .success(let pending) = read else { return XCTFail("an export must read back as a backup") }
        XCTAssertEqual(pending.contents.shows, 1)
        XCTAssertNil(pending.contents.mixes, "absent, so a restore leaves the mixes alone")
        XCTAssertTrue(pending.contents.settings)
        XCTAssertEqual(pending.contents.exportedAt, at)

        // Saved places alone still make a backup, and the confirm says what it restores.
        let positionsOnly = await Backup.read(try file("positions.json",
            JSONSerialization.data(withJSONObject: ["episodePositions": ["ep1": 12.5]])))
        guard case .success(let places) = positionsOnly else { return XCTFail("saved places alone are a backup") }
        XCTAssertTrue(places.contents.positions)
        XCTAssertEqual(Backup.confirmMessage(places.contents),
                       "This replaces what's on this iPhone with the backup's saved places in episodes. You can undo it afterwards.")

        // A file that can't be read is a read failure ("Pick it again from Files"), never "not a
        // backup". Which of the two depends on whether iOS grants a scope (the simulator does,
        // even for a temp file), so either is right here.
        let missing = await Backup.read(dir.appendingPathComponent("gone.json"))
        XCTAssertTrue([Backup.ReadFailure.noAccess, .unreadable].contains(failure(missing) ?? .notBackup),
                      "got \(String(describing: failure(missing)))")
        let notJSON = await Backup.read(try file("notes.json", Data("not json".utf8)))
        XCTAssertEqual(failure(notJSON), .notBackup)
        let empty = await Backup.read(try file("empty.json", Data()))
        XCTAssertEqual(failure(empty), .notBackup, "an empty file read fine; it just isn't a backup")
        let array = await Backup.read(try file("array.json", Data("[1, 2]".utf8)))
        XCTAssertEqual(failure(array), .notBackup)
        let otherApp = await Backup.read(try file("other.json", Data(#"{"name": "Another app", "evilKey": 1}"#.utf8)))
        XCTAssertEqual(failure(otherApp), .notBackup, "JSON with nothing of ours is not offered as a restore")
    }

    // MARK: a restore replaces only what the backup holds

    // Value: protects=a restore replaces only the sections a backup holds, and absent or malformed sections keep their files; fails_when=a merge restore deletes absent files or writes an unvalidated section; why_new=the e2e test's absent files never existed, so a deletion went unseen; seam=none; no_claim=the engine reload
    @MainActor
    func testARestoreLeavesWhatTheBackupLacksAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupMerge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let ep = Episode(id: "e", title: "E", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        let before: [String: Data] = [
            "library.json": try JSONEncoder().encode([Podcast(id: "a", name: "A", url: "fa", episodes: [ep])]),
            "queue.json": try JSONEncoder().encode([ep]),
            "mixes.json": Data("[]".utf8),
            "positions.json": try JSONEncoder().encode(["e": 30.0]),
        ]
        for (file, data) in before { storage.writeRaw(data, to: file) }

        // Settings, plus an Up Next that doesn't decode: the queue must survive it.
        let backup: [String: Any] = ["masterVolume": 0.8, "upNextQueue": [["bad": 1]], Backup.markerKey: 1]
        let data = try JSONSerialization.data(withJSONObject: backup)
        let restored = await Backup.restore(Backup.Pending(data: data, contents: Backup.contents(of: backup)),
                                            storage: storage, defaults: d)
        let outcome = try XCTUnwrap(restored)

        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.8, accuracy: 1e-9)
        XCTAssertEqual(outcome.skipped, 1, "the malformed Up Next is skipped, not written")
        XCTAssertNil(outcome.contents.upNext)
        XCTAssertNil(outcome.contents.shows)
        XCTAssertTrue(outcome.contents.settings)
        for (file, data) in before {
            XCTAssertEqual(storage.rawData(for: file), data, "\(file) isn't in the backup, so it stays as it was")
        }
    }

    // MARK: export skips what a restore wouldn't take back

    // Value: protects=a stored value JSON can't hold, or of the wrong shape, is left out of the export instead of failing it (and every restore's Undo copy); fails_when=userDefaults(from:) stops filtering by kinds; why_new=one NaN made every export throw; seam=none; no_claim=which values the app can store
    @MainActor
    func testExportSkipsASettingARestoreWouldntTakeBack() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupExport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        d.set(Double.nan, forKey: "masterVolume")      // JSON has no NaN
        d.set("loud", forKey: "podVolume")             // the wrong type
        d.set(0.4, forKey: "binVolume")
        let export = try await Backup.exportData(storage: storage, defaults: d)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: export.data) as? [String: Any])
        XCTAssertNil(dict["masterVolume"])
        XCTAssertNil(dict["podVolume"])
        XCTAssertEqual(dict["binVolume"] as? Double, 0.4)
    }

    // MARK: a setting must have the shape its reader expects

    // Value: protects=a null, wrong-typed or out-of-range setting is skipped, never written; fails_when=scalarValid stops checking the property-list shape, type or range; why_new=no test fed a null (UserDefaults raised an uncatchable exception on it: a crash after Replace) or a huge number; seam=none; no_claim=the readers' own clamping
    func testANullWrongTypeOrOutOfRangeSettingIsSkippedNotWritten() throws {
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("""
            {"masterVolume": null, "beatRouting": {"x": null}, "autoPlay": "yes",
             "skipInterval": 1e300, "podVolume": 1000, "pomoWork": -5, "noiseType": 7,
             "stereoWidth": 0.5}
            """.utf8)) as? [String: Any])
        let (restored, skipped) = Backup.restoreUserDefaults(from: dict, into: d)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(skipped, 7)
        for key in ["masterVolume", "beatRouting", "autoPlay", "skipInterval", "podVolume", "pomoWork", "noiseType"] {
            XCTAssertNil(d.object(forKey: key), "\(key) must not be written")
        }
        XCTAssertEqual(d.double(forKey: "stereoWidth"), 0.5, accuracy: 1e-9)
        XCTAssertFalse(Backup.contents(of: ["masterVolume": NSNull()]).restoresAnything,
                       "a backup of nothing but a null isn't offered as a restore")
    }

    // MARK: a restore never switches the mode

    // Value: protects=a restore keeps the current mode and puts a backup's sounds in the right mode's picks; fails_when=focusMode is restored, or the backup's sounds land in the wrong mode; why_new=restoring the mode cancelled a running sleep timer and overwrote the remembered sounds; seam=none; no_claim=AudioEngine's reload
    func testARestoreFromTheOtherModeKeepsTheModeAndSortsItsSounds() throws {
        // In Sleep now; the backup was made in Focus, playing White, remembering Rain for Sleep.
        let backup: [String: Any] = ["focusMode": true, "noiseType": "white", "binauralPreset": "beta",
                                     "lastPick.noise.sleep": "rain", "lastPick.noise.focus": "fan",
                                     "lastPick.binaural.sleep": "theta"]
        _ = Backup.restoreUserDefaults(from: try throughBackupFile(backup), into: d)
        XCTAssertNil(d.object(forKey: "focusMode"), "the mode is never restored")
        XCTAssertEqual(d.string(forKey: "noiseType"), "rain", "this mode's sound is the backup's pick for it")
        XCTAssertEqual(d.string(forKey: "binauralPreset"), "theta")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.focus"), "white", "the backup's playing sound is Focus's latest pick")
        XCTAssertEqual(d.string(forKey: "lastPick.binaural.focus"), "beta")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.sleep"), "rain")
    }

    func testARestoreFromTheSameModeKeepsItsPlayingSound() throws {
        d.set(true, forKey: "focusMode")
        let backup: [String: Any] = ["focusMode": true, "noiseType": "white", "lastPick.noise.focus": "fan"]
        _ = Backup.restoreUserDefaults(from: try throughBackupFile(backup), into: d)
        XCTAssertEqual(d.string(forKey: "noiseType"), "white", "the playing sound is already this mode's latest pick")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.focus"), "fan")
    }

    func testAnOtherModeBackupWithoutAPickKeepsTodaysSound() throws {
        d.set("brown", forKey: "noiseType")
        _ = Backup.restoreUserDefaults(from: try throughBackupFile(["focusMode": true, "noiseType": "white"]), into: d)
        XCTAssertEqual(d.string(forKey: "noiseType"), "brown")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.focus"), "white")
    }

    // MARK: a lost snapshot stops being offered

    // Value: protects=an Undo whose snapshot is gone or unreadable reports failure and stops being offered; fails_when=undo keeps the key when the file is missing, or says "undone" after putting nothing back; why_new=only the expired case was tested; seam=none; no_claim=why the snapshot went missing
    @MainActor
    func testAnUndoWhoseSnapshotIsGoneOrUnreadableStopsBeingOffered() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupGone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        d.set(now.timeIntervalSince1970, forKey: Backup.undoTakenAtKey)    // a timestamp, no snapshot file
        let gone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(gone, .gone)
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d), "a failed Undo must not keep offering itself")

        storage.writeRaw(Data("not json".utf8), to: Backup.undoFile)
        d.set(now.timeIntervalSince1970, forKey: Backup.undoTakenAtKey)
        let unreadable = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(unreadable, .gone, "nothing was put back, so it must not report Restore undone")
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d))

        // JSON, but not a backup: it gets past the read and stops at the parse.
        d.set(0.3, forKey: "masterVolume")
        storage.writeRaw(Data("[]".utf8), to: Backup.undoFile)
        d.set(now.timeIntervalSince1970, forKey: Backup.undoTakenAtKey)
        let notABackup = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(notABackup, .gone)
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d))
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.3, accuracy: 1e-9, "nothing was touched")
    }

    // MARK: the confirm names an old backup's year

    func testConfirmTitleShowsTheYearOnlyWhenItIsNotThisOne() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let now = Date(timeIntervalSince1970: 1_791_763_200)                 // 12 Oct 2026
        let thisYear = Backup.Contents(settings: true, exportedAt: now.addingTimeInterval(-86_400))
        let lastYear = Backup.Contents(settings: true, exportedAt: now.addingTimeInterval(-366 * 86_400))
        // The year as the device's own locale writes it (the title formats with it too).
        let year = { (date: Date) in date.formatted(.dateTime.year()) }
        XCTAssertFalse(Backup.confirmTitle(thisYear, now: now, calendar: cal).contains(year(now)))
        XCTAssertTrue(Backup.confirmTitle(lastYear, now: now, calendar: cal).contains(year(lastYear.exportedAt!)))
        XCTAssertEqual(Backup.confirmTitle(Backup.Contents(settings: true), now: now, calendar: cal), "Replace with this backup?")
    }

    // MARK: pass 2: the export's mode, mode-less backups, Undo's remapped picks

    // Value: protects=a real export names its mode, so a restore in the other mode sorts its sounds; fails_when=the export stops writing modeKey; why_new=the sorting tests build their dicts by hand; seam=none; no_claim=the never-switched case (the next test)
    func testAnExportFromFocusRestoredInSleepSortsItsSounds() throws {
        d.set(true, forKey: "focusMode")
        d.set("white", forKey: "noiseType")
        let file = try throughBackupFile(Backup.userDefaults(from: d))
        XCTAssertEqual(file["focusMode"] as? Bool, true, "the export names the mode its sounds belong to")
        d.removePersistentDomain(forName: suite)
        d.set("brown", forKey: "noiseType")                                  // now in Sleep
        _ = Backup.restoreUserDefaults(from: file, into: d)
        XCTAssertNil(d.object(forKey: "focusMode"))
        XCTAssertEqual(d.string(forKey: "noiseType"), "brown")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.focus"), "white")
    }

    func testAnExportAlwaysNamesItsModeEvenNeverSwitched() throws {
        XCTAssertEqual(try throughBackupFile(Backup.userDefaults(from: d))["focusMode"] as? Bool, false,
                       "no key means Sleep, and the export says so")
    }

    // Value: protects=a backup that predates the mode key is read as Sleep's; fails_when=restorePlan only sorts when the key is present; why_new=a mode-less Sleep backup restored in Focus put Sleep's sound into Focus and lost the Sleep pick; seam=none; no_claim=older formats beyond a missing key
    func testABackupWithoutAModeIsReadAsSleep() throws {
        d.set(true, forKey: "focusMode")                                     // in Focus now
        _ = Backup.restoreUserDefaults(from: try throughBackupFile(["noiseType": "brown", "lastPick.noise.focus": "fan"]), into: d)
        XCTAssertEqual(d.string(forKey: "noiseType"), "fan", "Focus plays the backup's Focus pick")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.sleep"), "brown", "the backup's sound is Sleep's latest pick")
    }

    // Value: protects=Undo keeps a remembered pick its own sorting writes; fails_when=absent keys are worked out before the remap, so apply removes what it just set; why_new=the replacing tests never crossed modes; seam=none; no_claim=AudioEngine's reload
    func testUndoAcrossModesKeepsThePickItSorts() throws {
        // The snapshot was taken in Focus with no remembered Focus pick; Undo runs in Sleep.
        let snapshot: [String: Any] = ["focusMode": true, "noiseType": "white"]
        _ = Backup.restoreUserDefaults(from: try throughBackupFile(snapshot), into: d, replacing: true)
        XCTAssertEqual(d.string(forKey: "lastPick.noise.focus"), "white")
    }

    // Value: protects=whole-number settings and text lengths match what their readers take; fails_when=a fraction or an over-long string is written; why_new=the shapes test had neither; seam=none; no_claim=the UI's exact ranges
    func testFractionsWhereWholeNumbersAreReadAndOverlongTextAreSkipped() {
        let dict: [String: Any] = ["pomoWork": 25.5, "ambientTailMinutes": 10, "sceneSleep": String(repeating: "x", count: 300),
                                   "finishedEpisodes": ["ok", String(repeating: "y", count: 17_000)]]
        let (restored, skipped) = Backup.restoreUserDefaults(from: dict, into: d)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(skipped, 3)
        XCTAssertNil(d.object(forKey: "pomoWork"))
        XCTAssertEqual(d.integer(forKey: "ambientTailMinutes"), 10)
    }

    // Value: protects=the text caps count UTF-8 bytes, and the played list's total is capped; fails_when=maxTextBytes is checked against Character count, or the list's total byte cap is dropped; why_new=the cap test only used ASCII, where Characters and bytes agree, and lists under the total; seam=none; no_claim=the exact caps
    func testTextCapsCountBytesNotCharacters() {
        let marked = String(repeating: "e\u{0301}", count: 200)            // é as e + a combining acute
        XCTAssertEqual(marked.count, 200)
        XCTAssertEqual(marked.utf8.count, 600)
        // 600 items of 2,000 bytes: each under the item cap, 1.2 MB in all.
        let played = (0..<600).map { String(format: "%04d", $0) + String(repeating: "y", count: 1_996) }
        let (restored, skipped) = Backup.restoreUserDefaults(from: ["sceneSleep": marked, "finishedEpisodes": played,
                                                                    "sceneFocus": "current"], into: d)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(skipped, 2)
        XCTAssertNil(d.object(forKey: "sceneSleep"), "200 Characters, but 600 bytes")
        XCTAssertNil(d.object(forKey: "finishedEpisodes"), "every item fits, the list doesn't")
        XCTAssertEqual(d.string(forKey: "sceneFocus"), "current")
    }

    // Value: protects=a file over the size cap is refused; fails_when=both the size check and the bounded read's count check are removed or compare the wrong way; why_new=the read test only uses small files; seam=none; no_claim=which of the two checks refused it
    @MainActor
    func testReadRefusesAFileOverTheSizeCap() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupBig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.json")
        FileManager.default.createFile(atPath: url.path, contents: Data("{}".utf8))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(Backup.maxFileBytes + 1))      // sparse: nothing is written
        try handle.close()
        guard case .failure(let failure) = await Backup.read(url) else { return XCTFail("an oversized file must be refused") }
        XCTAssertEqual(failure, .tooLarge)
    }

    // Value: protects=a restore whose Undo copy can't be written replaces nothing and leaves the previous Undo (copy and date) as it was; fails_when=the snapshot write's failure is ignored, the Undo date is set first, or the earlier copy is dropped; why_new=an export that fails can't be staged any more (it skips what JSON can't hold), so the write is where it fails; seam=none; no_claim=why the write failed
    @MainActor
    func testARestoreWhoseUndoCopyDoesntLandReplacesNothing() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRO-\(UUID().uuidString)")
        let storage = StorageManager(directory: dir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let earlier = now.addingTimeInterval(-3_600)
        try storage.writeRawNow(Data("{}".utf8), to: Backup.undoFile)        // an earlier restore's copy
        d.set(earlier.timeIntervalSince1970, forKey: Backup.undoTakenAtKey)
        // An earlier Undo that couldn't finish: its restarted week mustn't be lost either.
        let keptAt = now.addingTimeInterval(-1_800)
        d.set(keptAt.timeIntervalSince1970, forKey: Backup.undoKeptAtKey)
        d.set(0.3, forKey: "masterVolume")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let backup: [String: Any] = ["masterVolume": 0.9, Backup.markerKey: 1]
        let outcome = await Backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: backup),
                                                          contents: Backup.contents(of: backup)),
                                           now: now, storage: storage, defaults: d)
        XCTAssertNil(outcome, "the confirm promised Undo, so nothing is replaced without one")
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.3, accuracy: 1e-9)
        XCTAssertEqual(Backup.undoDate(now: now, storage: storage, defaults: d)?.timeIntervalSince1970 ?? 0,
                       earlier.timeIntervalSince1970, accuracy: 1e-3,
                       "nothing changed, so the earlier Undo still describes a real state and stays")
        XCTAssertEqual(storage.rawData(for: Backup.undoFile), Data("{}".utf8), "and its copy is still there")
        XCTAssertEqual(d.double(forKey: Backup.undoKeptAtKey), keptAt.timeIntervalSince1970, accuracy: 1e-3,
                       "a restore that replaced nothing leaves the restarted week as it was")
    }

    // MARK: pass 3: the shipping restore in Focus; a second restore within the week

    // Value: protects=the shipping restore sorts a Sleep backup's sounds when run in Focus; fails_when=write passes the wrong current mode into prepare; why_new=the sorting tests go through restoreUserDefaults, a test convenience; seam=none; no_claim=AudioEngine's reload
    @MainActor
    func testTheShippingRestoreInFocusSortsASleepBackupsSounds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupFocus-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        d.set(true, forKey: "focusMode")
        let backup: [String: Any] = ["focusMode": false, "noiseType": "brown", "lastPick.noise.focus": "fan", Backup.markerKey: 1]
        let restored = await Backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: backup),
                                                           contents: Backup.contents(of: backup)),
                                            storage: storage, defaults: d)
        XCTAssertNotNil(restored)
        XCTAssertEqual(d.string(forKey: "noiseType"), "fan")
        XCTAssertEqual(d.string(forKey: "lastPick.noise.sleep"), "brown")
        XCTAssertTrue(d.bool(forKey: "focusMode"), "still in Focus")
    }

    // Value: protects=a second restore within the week replaces the Undo copy, and Undo returns to the state before the latest restore; fails_when=the copy can't overwrite an existing one (every later restore refused) or Undo goes back too far; why_new=every restore test started with no Undo; seam=none; no_claim=the week window (tested above)
    @MainActor
    func testASecondRestoreReplacesTheUndoAndUndoReturnsToTheFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupTwice-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        d.set(0.1, forKey: "masterVolume")
        func pending(_ volume: Double) throws -> Backup.Pending {
            let backup: [String: Any] = ["masterVolume": volume, Backup.markerKey: 1]
            return Backup.Pending(data: try JSONSerialization.data(withJSONObject: backup), contents: Backup.contents(of: backup))
        }
        let now = Date()
        let first = await Backup.restore(try pending(0.5), now: now, storage: storage, defaults: d)
        XCTAssertNotNil(first)
        let second = await Backup.restore(try pending(0.9), now: now.addingTimeInterval(60), storage: storage, defaults: d)
        XCTAssertNotNil(second, "an existing Undo copy is replaced, not a reason to refuse")
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.9, accuracy: 1e-9)
        let undone = await Backup.undo(now: now.addingTimeInterval(120), storage: storage, defaults: d)
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.5, accuracy: 1e-9, "Undo returns to before the latest restore")
    }

    // Value: protects=the confirm only names an export time that could be real; fails_when=prepare stops bounding exportedAt; why_new=a hand-edited 1e300 went through Calendar and the formatter unchecked; seam=none; no_claim=the title's wording
    func testAnImpossibleExportTimeIsTreatedAsMissing() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func exportedAt(_ seconds: Double) -> Date? {
            Backup.contents(of: ["autoPlay": true, Backup.exportedAtKey: seconds], now: now).exportedAt
        }
        XCTAssertEqual(exportedAt(1_000), Date(timeIntervalSince1970: 1_000))
        XCTAssertNotNil(exportedAt(now.timeIntervalSince1970 + 3_600), "a clock a little fast is fine")
        XCTAssertNil(exportedAt(1e300))
        XCTAssertNil(exportedAt(-1))
        XCTAssertNil(exportedAt(now.timeIntervalSince1970 + 2 * 86_400))
        XCTAssertEqual(Backup.confirmTitle(Backup.contents(of: ["autoPlay": true, Backup.exportedAtKey: 1e300], now: now)),
                       "Replace with this backup?")
    }

    // MARK: pass 4: an unreadable file, and the export's size

    /// A temp store holding one show in library.json (both copies).
    @MainActor
    private func storeWithAShow(_ name: String) throws -> (StorageManager, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
        let storage = StorageManager(directory: dir)
        let ep = Episode(id: "e", title: "E", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        try storage.writeRawNow(JSONEncoder().encode([Podcast(id: "a", name: "A", url: "fa", episodes: [ep])]),
                                to: "library.json")
        return (storage, dir)
    }

    // Value: protects=an unparseable primary falls back to its .bak, so export and Undo keep the shows; fails_when=rawData returns the primary's bytes whether or not they parse; why_new=the export dropped the section silently and Undo wrote [] over the good .bak; seam=none; no_claim=how the primary got corrupted
    @MainActor
    func testAnUnreadablePrimaryFallsBackToItsBackupCopy() async throws {
        let (storage, dir) = try storeWithAShow("BackupBak")
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{ truncated".utf8).write(to: dir.appendingPathComponent("library.json"))

        let export = try await Backup.exportData(storage: storage, defaults: d)
        XCTAssertEqual(export.leftOut, [], "the .bak is read instead")
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: export.data) as? [String: Any])
        XCTAssertEqual((dict["savedPodcasts"] as? [Any])?.count, 1)

        // A restore that brings in no shows, then Undo: the shows come back from the copy.
        let backup: [String: Any] = ["savedPodcasts": [Any](), Backup.markerKey: 1]
        let now = Date()
        let restored = await Backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: backup),
                                                           contents: Backup.contents(of: backup)),
                                            now: now, storage: storage, defaults: d)
        XCTAssertNotNil(restored)
        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(undone, .undone)
        let shows = try JSONDecoder().decode([Podcast].self, from: try XCTUnwrap(storage.rawData(for: "library.json")))
        XCTAssertEqual(shows.map(\.id), ["a"], "Undo put back the shows, not []")
    }

    // Value: protects=a section neither copy of which parses is named in the export's result; fails_when=currentFiles stops reporting files that exist but can't be read; why_new=the export left the section out without a word; seam=none; no_claim=the alert's presentation
    @MainActor
    func testAnExportSaysWhichSectionItLeftOut() async throws {
        let (storage, dir) = try storeWithAShow("BackupGap")
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["library.json", "library.json.bak"] {
            try Data("{ truncated".utf8).write(to: dir.appendingPathComponent(name))
        }
        let export = try await Backup.exportData(storage: storage, defaults: d)
        XCTAssertEqual(export.leftOut, ["savedPodcasts"])
        XCTAssertNil((try JSONSerialization.jsonObject(with: export.data) as? [String: Any])?["savedPodcasts"])
        XCTAssertEqual(Backup.leftOutMessage(export.leftOut),
                       "It was saved without your podcasts, which couldn't be read. Everything else is in it.")
        XCTAssertEqual(Backup.leftOutMessage(["upNextQueue", "savedPlaylists"]),
                       "It was saved without your mixes and Up Next, which couldn't be read. Everything else is in it.")
        XCTAssertNil(Backup.leftOutMessage([]))
    }

    // Value: protects=a saved backup always fits under the size a restore reads; fails_when=exportData ignores maxBytes or stops falling back to compact JSON; why_new=export never checked the import cap, so a big library saved a file restore refused; seam=maxBytes (the real cap is 50 MB); no_claim=the alert copy
    @MainActor
    func testASavedBackupFitsTheRestoreCapOrIsRefused() async throws {
        let (storage, dir) = try storeWithAShow("BackupCap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let at = Date(timeIntervalSince1970: 1_000_000)                   // one length for every call
        let pretty = try await Backup.exportData(at: at, storage: storage, defaults: d).data
        let compact = try await Backup.exportData(at: at, storage: storage, defaults: d, pretty: false).data
        XCTAssertLessThan(compact.count, pretty.count)

        // Lengths, not bytes: the keys can come out in another order each time.
        let newline = UInt8(ascii: "\n")
        XCTAssertTrue(pretty.contains(newline))
        XCTAssertFalse(compact.contains(newline))
        let fits = try await Backup.exportData(at: at, storage: storage, defaults: d, maxBytes: pretty.count)
        XCTAssertEqual(fits.data.count, pretty.count)
        XCTAssertTrue(fits.data.contains(newline), "pretty-printed when that fits")
        let squeezed = try await Backup.exportData(at: at, storage: storage, defaults: d, maxBytes: compact.count)
        XCTAssertEqual(squeezed.data.count, compact.count, "compact when only that fits")
        XCTAssertFalse(squeezed.data.contains(newline))
        do {
            _ = try await Backup.exportData(at: at, storage: storage, defaults: d, maxBytes: compact.count - 1)
            XCTFail("a backup a restore would refuse isn't made")
        } catch {
            XCTAssertEqual(error as? Backup.ExportFailure, .tooLarge)
        }
    }

    // MARK: pass 4: queued writes land first

    // Value: protects=the app's queued writes land before the Undo copy and again before the restore's writes; fails_when=restore or undo stops calling settle at those points; why_new=nothing flushed the engine's queues, so a queued write landed after a restore and reverted part of it, and the copy missed it; seam=settle (the app passes AudioEngine.flushPendingWrites); no_claim=the engine's own queues (RestoreReloadTests)
    @MainActor
    func testARestoreLandsQueuedWritesFirst() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupSettle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        try storage.writeRawNow(JSONEncoder().encode(["ep1": 10.0]), to: "positions.json")
        func places() -> [String: Double]? {
            storage.flush()
            return storage.rawData(for: "positions.json").flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) }
        }
        var calls: [(copyTaken: Bool, restoreWritten: Bool)] = []
        let settle = {
            calls.append((storage.rawData(for: Backup.undoFile) != nil, places() == ["ep9": 5.0]))
            // The first time, the place the engine still held in memory: the copy must hold it.
            if calls.count == 1, let held = try? JSONEncoder().encode(["ep1": 42.0]) {
                storage.writeRaw(held, to: "positions.json")
            }
        }
        let backup: [String: Any] = ["episodePositions": ["ep9": 5.0], Backup.markerKey: 1]
        let now = Date()
        let restored = await Backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: backup),
                                                           contents: Backup.contents(of: backup)),
                                            now: now, storage: storage, defaults: d, settle: settle)
        XCTAssertNotNil(restored)
        XCTAssertEqual(calls.map(\.copyTaken), [false, true], "before the copy, and again after it")
        XCTAssertEqual(calls.map(\.restoreWritten), [false, false], "both before the restore writes")
        XCTAssertEqual(places(), ["ep9": 5.0])

        // Value: protects=Undo's settle runs before its writes, so a queued write can't land on the put-back state; fails_when=undo() calls settle after write() instead of passing it in; why_new=Undo's settle was only counted, never placed relative to the writes; seam=settle (non-test callers: 1, via grep -rn "settle:" Sleepulator/Sleepulator); no_claim=the engine's own queues
        var undoSettles: [[String: Double]?] = []
        let undone = await Backup.undo(now: now, storage: storage, defaults: d, settle: { undoSettles.append(places()) })
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(undoSettles, [["ep9": 5.0]], "once, while the restored place is still there: before the Undo's writes")
        XCTAssertEqual(places(), ["ep1": 42.0], "the copy held the write that was still queued")
    }

    // MARK: pass 4: what a restore stores is what decoded

    // Value: protects=a restore stores the decoded, trimmed and clamped blobs, never the backup's own JSON; fails_when=encodedValue stores the backup's bytes again, or stops trimming layers or clamping volumes and the place; why_new=the blobs were only checked to decode, so unknown keys and any number of layers reached the plist; seam=none; no_claim=the file sections (below)
    func testARestoreStoresTheDecodedBlobsNotTheBackupsJSON() throws {
        let junk = String(repeating: "j", count: 100_000)
        let layer: [String: Any] = ["id": "a", "type": "rain", "volume": 5.0]
        var paddedLayer = layer
        paddedLayer["junk"] = junk
        let mix: [String: Any] = ["id": "m", "name": "Last night", "noiseOn": true, "noiseVolume": 3.0, "noiseType": "brown",
                                  "binauralOn": false, "binVolume": -1.0, "binauralPreset": "delta", "podVolume": 0.5,
                                  "podcastPosition": 1e300, "junk": junk,
                                  "extraLayers": Array(repeating: paddedLayer, count: 5)]
        let dict: [String: Any] = ["lastMix": mix, "extraLayers": Array(repeating: layer, count: 1_000)]
        let (restored, skipped) = Backup.restoreUserDefaults(from: try throughBackupFile(dict), into: d)
        XCTAssertEqual(restored, 2)
        XCTAssertEqual(skipped, 0)

        let layersData = try XCTUnwrap(d.data(forKey: "extraLayers"))
        let layers = try JSONDecoder().decode([ExtraNoiseLayer].self, from: layersData)
        XCTAssertEqual(layers.count, AudioEngine.maxExtraLayers, "no more layers than the engine stacks")
        XCTAssertEqual(layers.map(\.volume), Array(repeating: 1.0, count: AudioEngine.maxExtraLayers))

        let mixData = try XCTUnwrap(d.data(forKey: "lastMix"))
        XCTAssertLessThan(mixData.count, 2_000, "the junk fields aren't stored")
        XCTAssertFalse(String(decoding: mixData, as: UTF8.self).contains("junk"))
        let saved = try JSONDecoder().decode(SavedMix.self, from: mixData)
        XCTAssertEqual(saved.noiseVolume, 1)
        XCTAssertEqual(saved.binVolume, 0)
        XCTAssertEqual(saved.podVolume, 0.5)
        XCTAssertEqual(saved.podcastPosition, Backup.maxPosition)
        XCTAssertEqual(saved.extraLayers?.count, AudioEngine.maxExtraLayers)
    }

    // Value: protects=a blob padded in a field its type knows is refused, not stored; fails_when=the re-encoded blob's byte cap is dropped; why_new=re-encoding drops unknown keys but keeps a padded name; seam=none; no_claim=the exact cap
    func testABlobPaddedInAKnownFieldIsSkipped() {
        var mix: [String: Any] = ["id": "m", "name": "Last night", "noiseOn": true, "noiseVolume": 0.5,
                                  "noiseType": "brown", "binauralOn": false, "binVolume": 0.3, "binauralPreset": "delta",
                                  "podVolume": 0.7]
        XCTAssertEqual(Backup.restoreUserDefaults(from: ["lastMix": mix], into: d).restored, 1,
                       "the same snapshot with a short name restores")
        d.removeObject(forKey: "lastMix")
        mix["name"] = String(repeating: "n", count: 20_000)
        let (restored, skipped) = Backup.restoreUserDefaults(from: ["lastMix": mix], into: d)
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(skipped, 1)
        XCTAssertNil(d.data(forKey: "lastMix"))
    }

    // Value: protects=a file section is written as its decoded value, saved places clamped; fails_when=validatedFileSection returns the backup's own bytes again or stops clamping places; why_new=testFileBackedValidationGate only checks the count; seam=none; no_claim=each type's field contents
    func testAFileSectionIsStoredAsItDecoded() throws {
        let show = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            Podcast(id: "a", name: "A", url: "fa", episodes: []))) as? [String: Any])
        var padded = show
        padded["junk"] = String(repeating: "j", count: 10_000)
        let shows = try XCTUnwrap(Backup.validatedFileSection(key: "savedPodcasts", value: [padded]))
        XCTAssertEqual(shows.count, 1)
        XCTAssertFalse(String(decoding: shows.data, as: UTF8.self).contains("junk"))
        XCTAssertEqual(try JSONDecoder().decode([Podcast].self, from: shows.data).first?.id, "a")

        let places = try XCTUnwrap(Backup.validatedFileSection(key: "episodePositions",
                                                               value: ["ep1": 1e300, "ep2": -5.0, "ep3": 12.5]))
        XCTAssertEqual(try JSONDecoder().decode([String: Double].self, from: places.data),
                       ["ep1": Backup.maxPosition, "ep2": 0, "ep3": 12.5])

        // Value: protects=a pre-preset-rework backup (mixes as [SavedMix], no mode) still restores its mixes, stored as what decoded; fails_when=validatedFileSection's [SavedMix] fallback is dropped, returns nil, or stores bytes MixStore can't load; why_new=the test covers shows and places only; seam=none; no_claim=MixStore's [SavedMix]-to-preset conversion (PersistenceTests covers it)
        var legacyMix = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SavedMix(id: "m", name: "Old mix", noiseOn: true, noiseVolume: 0.5, noiseType: "brown",
                     binauralOn: false, binVolume: 0.3, binauralPreset: "delta", podVolume: 0.7))) as? [String: Any])
        XCTAssertNil(legacyMix["mode"], "the old schema has no mode, so it isn't a [SoundPreset]")
        legacyMix["junk"] = String(repeating: "j", count: 10_000)
        let mixes = try XCTUnwrap(Backup.validatedFileSection(key: "savedPlaylists", value: [legacyMix]))
        XCTAssertEqual(mixes.count, 1)
        XCTAssertFalse(String(decoding: mixes.data, as: UTF8.self).contains("junk"))
        XCTAssertEqual(try JSONDecoder().decode([SavedMix].self, from: mixes.data).first?.name, "Old mix")

        // Value: protects=an older backup's mix padded past the settings' text limit is dropped like a current preset; fails_when=sanitizedLegacyPreset stops checking its texts or the legacy branch maps instead of compactMaps; why_new=the legacy block held only an in-bounds mix; seam=none; no_claim=MixStore's conversion
        var paddedLegacy = legacyMix
        paddedLegacy["id"] = "p"
        paddedLegacy["noiseType"] = String(repeating: "n", count: 300)
        let bounded = try XCTUnwrap(Backup.validatedFileSection(key: "savedPlaylists", value: [legacyMix, paddedLegacy]))
        XCTAssertEqual(bounded.count, 1)
        XCTAssertEqual(try JSONDecoder().decode([SavedMix].self, from: bounded.data).map(\.id), ["m"], "the padded mix is dropped")
    }

    // MARK: pass 5: Undo puts back exactly what was there

    /// A restore of `backup` into `storage` with `d`, made at `now`.
    @MainActor
    private func restored(_ backup: [String: Any], into storage: StorageManager, now: Date) async throws -> Backup.Outcome {
        let pending = Backup.Pending(data: try JSONSerialization.data(withJSONObject: backup), contents: Backup.contents(of: backup))
        let outcome = await Backup.restore(pending, now: now, storage: storage, defaults: d)
        return try XCTUnwrap(outcome)
    }

    // Value: protects=Restore then Undo puts back a setting the app wrote but the backup rules refuse (a played list with a long episode id); fails_when=the Undo copy is built from kinds-valid values only, or Undo applies the kinds bounds; why_new=the export filter left it out and Undo removed the key; seam=none; no_claim=other over-bound settings
    @MainActor
    func testUndoPutsBackAPlayedListTheBackupRulesRefuse() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupLongId-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let longId = String(repeating: "g", count: 20_000)                 // an audio-address id: the parser has no cap there
        d.set(["short", longId], forKey: "finishedEpisodes")
        // A backup with its own played list, and one from before the list was backed up.
        for backup: [String: Any] in [["finishedEpisodes": ["other"], Backup.markerKey: 1], ["masterVolume": 0.5, Backup.markerKey: 1]] {
            let now = Date()
            _ = try await restored(backup, into: storage, now: now)
            let undone = await Backup.undo(now: now, storage: storage, defaults: d)
            XCTAssertEqual(undone, .undone)
            XCTAssertEqual(d.stringArray(forKey: "finishedEpisodes"), ["short", longId], "\(backup.keys.sorted())")
        }
    }

    // Value: protects=Undo leaves alone a file its copy couldn't read; fails_when=prepare treats a section the copy left out as absent and writes [] over it; why_new=Undo emptied both copies of an unreadable file the restore never touched; seam=none; no_claim=how the file got unreadable
    @MainActor
    func testUndoLeavesAFileItCouldNotReadAlone() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupUnread-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let garbage = Data("{ truncated".utf8)
        for name in ["library.json", "library.json.bak"] { try garbage.write(to: dir.appendingPathComponent(name)) }
        let now = Date()
        _ = try await restored(["masterVolume": 0.5, Backup.markerKey: 1], into: storage, now: now)
        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(undone, .undone)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("library.json")), garbage, "left as it was, not emptied")
    }

    // Value: protects=Undo puts back a section today's types can't decode (an update's schema change); fails_when=Undo runs its own copy through validatedFileSection again; why_new=such a section was skipped, the restored file stayed, and the copy was discarded; seam=none; no_claim=PersistenceMigrator's handling of the file
    @MainActor
    func testUndoPutsBackASectionTodaysTypesCantDecode() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupDrift-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        try storage.writeRawNow(Data(#"[{"fromAnOlderBuild": true}]"#.utf8), to: "library.json")
        let now = Date()
        _ = try await restored(["savedPodcasts": [Any](), Backup.markerKey: 1], into: storage, now: now)
        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(undone, .undone)
        let back = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(storage.rawData(for: "library.json"))) as? [[String: Bool]])
        XCTAssertEqual(back, [["fromAnOlderBuild": true]])
    }

    // Value: protects=an Undo that can't save a file keeps its copy and stays offered, and a second Undo finishes; fails_when=undo discards the copy whatever the writes did, or reports undone; why_new=a full disk lost the pre-restore library under "back as they were"; seam=none; no_claim=which errors a full disk raises
    @MainActor
    func testAnUndoThatCantSaveAFileKeepsItsCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupUndoRO-\(UUID().uuidString)")
        let storage = StorageManager(directory: dir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try storage.writeRawNow(JSONEncoder().encode(["ep1": 30.0]), to: "positions.json")
        let now = Date()
        _ = try await restored(["episodePositions": ["ep9": 5.0], Backup.markerKey: 1], into: storage, now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let fiveDaysOn = now.addingTimeInterval(5 * 86_400)
        let first = await Backup.undo(now: fiveDaysOn, storage: storage, defaults: d)
        guard case .incomplete(let unwritten) = first else { return XCTFail("got \(first)") }
        XCTAssertTrue(unwritten.contains("episodePositions"))
        XCTAssertNotNil(storage.rawData(for: Backup.undoFile), "its copy is kept")
        XCTAssertTrue(Backup.undoIncompleteMessage(unwritten).contains("places in episodes"))
        // The copy now holds what couldn't be saved, so its week starts again: past the restore's.
        let tenDaysOn = now.addingTimeInterval(10 * 86_400)
        XCTAssertEqual(Backup.undoDate(now: tenDaysOn, storage: storage, defaults: d)?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 1e-3, "still offered, named for the restore")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        let second = await Backup.undo(now: tenDaysOn, storage: storage, defaults: d)
        XCTAssertEqual(second, .undone)
        XCTAssertEqual(try JSONDecoder().decode([String: Double].self, from: try XCTUnwrap(storage.rawData(for: "positions.json"))),
                       ["ep1": 30.0])
    }

    // Value: protects=a restore names a section whose file couldn't be saved and doesn't count it as restored; fails_when=write goes back to unchecked async writes; why_new=the result listed sections that never landed; seam=none; no_claim=the Undo of it (left alone: its copy couldn't read it)
    @MainActor
    func testARestoreSaysWhichSectionItCouldNotSave() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupBlocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        // A directory where the show list goes: no file can be saved over it.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        let outcome = try await restored(["savedPodcasts": [Any](), "masterVolume": 0.4, Backup.markerKey: 1],
                                         into: storage, now: Date())
        XCTAssertEqual(outcome.unwritten, ["savedPodcasts"])
        XCTAssertNil(outcome.contents.shows, "not counted as restored")
        XCTAssertEqual(Backup.restoredMessage(outcome),
                       "Restored your settings. Your podcasts couldn't be saved on this iPhone and weren't changed.")
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.4, accuracy: 1e-9, "the rest still restored")
    }

    // Value: protects=Restore then Undo puts stored layers back as Data and leaves a value its copy couldn't hold (a NaN, a bad lastMix) alone, and a NaN doesn't refuse it; fails_when=undoUserDefaults copies a non-JSON value (restore refused) or drops one unlisted, restorePlan removes a left-out key, or trusted stores the object; why_new=no Restore-then-Undo test held a blob or a value its copy couldn't hold; seam=none; no_claim=how such a value gets stored
    @MainActor
    func testUndoLeavesWhatItsCopyCouldNotHoldAndPutsBackTheBlobs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupUnholdable-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        let layers = [ExtraNoiseLayer(id: "a", type: "rain", volume: 0.6, muted: nil)]
        d.set(try JSONEncoder().encode(layers), forKey: "extraLayers")
        d.set(Double.nan, forKey: "masterVolume")
        d.set(Data("not json".utf8), forKey: "lastMix")
        let now = Date()
        // `restored` unwraps the outcome: a stored NaN mustn't refuse the restore.
        _ = try await restored(["extraLayers": [["id": "b", "type": "fan", "volume": 0.2]], Backup.markerKey: 1],
                               into: storage, now: now)
        let undone = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertEqual(undone, .undone)
        let raw = try XCTUnwrap(d.data(forKey: "extraLayers"), "put back as a Data blob")
        XCTAssertEqual(try JSONDecoder().decode([ExtraNoiseLayer].self, from: raw), layers)
        XCTAssertTrue(d.double(forKey: "masterVolume").isNaN, "left alone, not removed")
        XCTAssertEqual(d.data(forKey: "lastMix"), Data("not json".utf8), "left alone, not removed")
    }

    // Value: protects=a restore whose only section couldn't be saved says Nothing could be restored and names it, and a places-only restore still says so; fails_when=Contents.record stops clearing positions for an unwritten key, or write stops recording unwritten keys, or restoredMessage loses a branch; why_new=only the shows arm and a non-empty message were tested; seam=none; no_claim=the mixes/Up Next arms
    @MainActor
    func testARestoreThatSavedNothingSaysSo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupNothing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        // A directory where the saved places go: no file can be saved over it.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("positions.json"), withIntermediateDirectories: true)
        let outcome = try await restored(["episodePositions": ["ep9": 5.0], Backup.markerKey: 1], into: storage, now: Date())
        XCTAssertEqual(outcome.unwritten, ["episodePositions"])
        XCTAssertFalse(outcome.contents.positions, "not counted as restored")
        XCTAssertEqual(Backup.restoredMessage(outcome),
                       "Nothing could be restored. Your places in episodes couldn't be saved on this iPhone and weren't changed.")
        XCTAssertEqual(Backup.restoredMessage(Backup.Outcome(contents: Backup.Contents(positions: true), skipped: 0)),
                       "Restored where you'd got to in each episode.")
    }

    // Value: protects=restored presets are held to the settings' text limit, volumes and layer count; fails_when=validatedFileSection stops sanitizing presets; why_new=a padded preset reached the preferences plist when tapped; seam=none; no_claim=applyPreset itself
    func testRestoredPresetsAreBoundedLikeTheSettings() throws {
        let layers = (0..<5).map { ExtraNoiseLayer(id: "l\($0)", type: "fan", volume: 2, muted: nil) }
        let rain = SoundPreset(name: "Rain", mode: "sleep", noiseOn: true, noiseType: "rain", noiseVolume: 3, binauralOn: false,
                               binauralPreset: "delta", binVolume: -1, sceneId: "still-water", extraLayers: layers)
        var padded = rain
        padded.name = "Padded"
        padded.sceneId = String(repeating: "s", count: 300)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode([rain, padded]))
        let section = try XCTUnwrap(Backup.validatedFileSection(key: "savedPlaylists", value: value))
        XCTAssertEqual(section.count, 1)
        XCTAssertEqual(Backup.contents(of: ["savedPlaylists": value]).mixes, 1, "the confirm counts what the restore keeps")
        let kept = try JSONDecoder().decode([SoundPreset].self, from: section.data)
        XCTAssertEqual(kept.map(\.name), ["Rain"], "the padded preset is dropped")
        XCTAssertEqual(kept.first?.noiseVolume, 1)
        XCTAssertEqual(kept.first?.binVolume, 0)
        XCTAssertEqual(kept.first?.extraLayers?.count, AudioEngine.maxExtraLayers)
        XCTAssertEqual(kept.first?.extraLayers?.map(\.volume), Array(repeating: 1.0, count: AudioEngine.maxExtraLayers))
    }

    // Value: protects=a restored episode's date is dropped when it couldn't be real; fails_when=validatedFileSection stops bounding pubDate; why_new=exportedAt was bounded but episode dates went to the formatters unchecked; seam=none; no_claim=how the formatters treat extreme dates
    func testAnImpossibleEpisodeDateIsDropped() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let real = Episode(id: "a", title: "A", audioUrl: "u", duration: nil, pubDate: Date(timeIntervalSince1970: 1_000_000), description: nil)
        let wild = Episode(id: "b", title: "B", audioUrl: "u", duration: nil, pubDate: Date(timeIntervalSince1970: 1e300), description: nil)
        let queue = try JSONSerialization.jsonObject(with: JSONEncoder().encode([real, wild]))
        let section = try XCTUnwrap(Backup.validatedFileSection(key: "upNextQueue", value: queue, now: now))
        let episodes = try JSONDecoder().decode([Episode].self, from: section.data)
        XCTAssertEqual(episodes.map(\.pubDate), [Date(timeIntervalSince1970: 1_000_000), nil])
        let shows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([Podcast(id: "p", name: "P", url: "f", episodes: [wild])]))
        let library = try XCTUnwrap(Backup.validatedFileSection(key: "savedPodcasts", value: shows, now: now))
        XCTAssertNil(try JSONDecoder().decode([Podcast].self, from: library.data).first?.episodes.first?.pubDate)
    }

    // Value: protects=the alerts quote the real size cap, and every file-backed section has a name; fails_when=maxFileBytes changes without the copy, or a section is added without a name; why_new=both were literals beside their sources; seam=none; no_claim=the wording
    func testTheCopyNamesTheRealCapAndEverySection() {
        XCTAssertTrue(Backup.failureMessage(.tooLarge).contains("\(Backup.maxFileMB) MB"))
        XCTAssertTrue(Backup.tooLargeToExportMessage.contains("\(Backup.maxFileMB) MB"))
        XCTAssertEqual(Set(Backup.sectionNames.map(\.key)), Set(Backup.fileBacked.keys))
        for key in Backup.fileBacked.keys {
            XCTAssertNotNil(Backup.leftOutMessage([key]), "\(key) would be left out without a word")
        }
    }

    // MARK: pass 6: episodes, the played list, the reload after Undo

    // Value: protects=a restored episode or show with a text over the feed limit is dropped, and the count says so; fails_when=validatedFileSection stops bounding episode/show texts; why_new=a crafted address reached the plist once played (Last Night, the played list); seam=none; no_claim=the parser's own caps
    func testRestoredEpisodesAndShowsAreBoundedLikeAFeed() throws {
        let fine = Episode(id: "a", title: "A", audioUrl: "https://x/a.mp3", duration: nil, pubDate: nil, description: nil)
        let padded = Episode(id: "b", title: "B", audioUrl: "https://x/" + String(repeating: "u", count: 20_000), duration: nil,
                             pubDate: nil, description: nil)
        let queue = try JSONSerialization.jsonObject(with: JSONEncoder().encode([fine, padded]))
        let upNext = try XCTUnwrap(Backup.validatedFileSection(key: "upNextQueue", value: queue))
        XCTAssertEqual(upNext.count, 1)
        XCTAssertEqual(try JSONDecoder().decode([Episode].self, from: upNext.data).map(\.id), ["a"])
        XCTAssertEqual(Backup.contents(of: ["upNextQueue": queue]).upNext, 1, "the confirm counts what's kept")

        let shows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([
            Podcast(id: "p", name: "P", url: "f", episodes: [fine, padded]),
            Podcast(id: "q", name: String(repeating: "n", count: 20_000), url: "g", episodes: []),
        ]))
        let library = try XCTUnwrap(Backup.validatedFileSection(key: "savedPodcasts", value: shows))
        XCTAssertEqual(library.count, 1)
        let kept = try JSONDecoder().decode([Podcast].self, from: library.data)
        XCTAssertEqual(kept.map(\.id), ["p"])
        XCTAssertEqual(kept.first?.episodes.map(\.id), ["a"])
    }

    // Value: protects=the export keeps the played list minus what a restore can't take (an over-long id; the oldest past the size); fails_when=userDefaults(from:) goes back to leaving the whole list out; why_new=one long id dropped the person's whole played history from a backup; seam=none; no_claim=the list's own recency order
    func testTheExportKeepsThePlayedListItCanCarry() throws {
        d.set(["old", String(repeating: "g", count: 20_000), "new"], forKey: "finishedEpisodes")
        var file = try throughBackupFile(Backup.userDefaults(from: d))
        XCTAssertEqual(file["finishedEpisodes"] as? [String], ["old", "new"], "only the over-long id is left out")

        // 600 ids of 2,000 bytes: 1.2 MB, over the list's 1 MB. The newest that fit are kept.
        let many = (0..<600).map { String(format: "%04d", $0) + String(repeating: "y", count: 1_996) }
        d.set(many, forKey: "finishedEpisodes")
        file = try throughBackupFile(Backup.userDefaults(from: d))
        let exported = try XCTUnwrap(file["finishedEpisodes"] as? [String])
        XCTAssertEqual(exported.last, many.last, "the newest are kept")
        XCTAssertLessThanOrEqual(exported.reduce(0) { $0 + $1.utf8.count }, 1_000_000)
        XCTAssertEqual(Backup.restoreUserDefaults(from: file, into: d).skipped, 0, "and a restore takes it")
    }

    // MARK: pass 7: the last review's tests

    // Value: protects=restore keeps episodes and shows with real-length texts, clears over-long artwork instead of dropping the item, and says how many it left out; fails_when=the bound falls back to 256 bytes, artwork drops the item, or dropped items go uncounted; why_new=every kept fixture text was under 20 bytes; seam=none; no_claim=the exact 16 KB boundary
    func testRestoreKeepsRealLengthTextsClearsLongArtworkAndCountsWhatItDrops() throws {
        let longTitle = String(repeating: "t", count: 4_000)                      // the parser's title cap
        let longAddress = "https://x/" + String(repeating: "a", count: 5_000)     // a tracking redirect
        let bigArtwork = "data:image/png;base64," + String(repeating: "A", count: 30_000)
        let real = Episode(id: "a", title: longTitle, audioUrl: longAddress, duration: nil, pubDate: nil, description: nil)
        var pictured = Episode(id: "b", title: "B", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        pictured.artworkUrl = bigArtwork
        let badId = Episode(id: String(repeating: "i", count: 20_000), title: "C", audioUrl: "u", duration: nil, pubDate: nil, description: nil)
        var show = Podcast(id: "p", name: "P", url: "f", episodes: [real, pictured, badId])
        show.artworkUrl = bigArtwork
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode([show]))

        let section = try XCTUnwrap(Backup.validatedFileSection(key: "savedPodcasts", value: value))
        XCTAssertEqual(section.count, 1, "the show stays")
        XCTAssertEqual(section.dropped, 1, "only the episode whose id is too long is left out")
        let kept = try XCTUnwrap(try JSONDecoder().decode([Podcast].self, from: section.data).first)
        XCTAssertNil(kept.artworkUrl, "over-long artwork is cleared, not the show")
        XCTAssertEqual(kept.episodes.map(\.id), ["a", "b"])
        XCTAssertEqual(kept.episodes.first?.audioUrl, longAddress)
        XCTAssertEqual(kept.episodes.first?.title, longTitle)
        XCTAssertNil(kept.episodes.last?.artworkUrl)

        let contents = Backup.contents(of: ["savedPodcasts": value])
        XCTAssertEqual(contents.tooLong, 1)
        XCTAssertEqual(Backup.restoredMessage(Backup.Outcome(contents: contents, skipped: 0)),
                       "Restored 1 show. One item was left out: a text in it was too long.")
    }

    // Value: protects=a played-list id between 2 KB and 16 KB survives export and restore; fails_when=maxListItemBytes goes back to 2,048; why_new=every accepted id in the suite was under 2 KB; seam=none; no_claim=the 1 MB and 20,000-item caps
    func testAPlayedListIdOfAFewKilobytesSurvives() throws {
        let guid = String(repeating: "g", count: 10_000)
        d.set(["a", guid], forKey: "finishedEpisodes")
        let file = try throughBackupFile(Backup.userDefaults(from: d))
        d.removePersistentDomain(forName: suite)
        XCTAssertEqual(Backup.restoreUserDefaults(from: file, into: d).skipped, 0)
        XCTAssertEqual(d.stringArray(forKey: "finishedEpisodes"), ["a", guid])
    }

    // Value: protects=after an incomplete Undo, the copy still goes once both weeks are over; fails_when=undoDate treats any kept date as available or skips the discard; why_new=only the extension was tested, not that it ends; seam=none; no_claim=the clock-set-back slack
    @MainActor
    func testTheRestartedUndoWeekAlsoEnds() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupWeekEnds-\(UUID().uuidString)")
        let storage = StorageManager(directory: dir)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let now = Date()
        _ = try await restored(["episodePositions": ["ep9": 5.0], Backup.markerKey: 1], into: storage, now: now)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let first = await Backup.undo(now: now.addingTimeInterval(5 * 86_400), storage: storage, defaults: d)
        guard case .incomplete = first else { return XCTFail("got \(first)") }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        XCTAssertNil(Backup.undoDate(now: now.addingTimeInterval(13 * 86_400), storage: storage, defaults: d))
        storage.flush()
        XCTAssertNil(storage.rawData(for: Backup.undoFile), "the copy is thrown away")
        XCTAssertNil(d.object(forKey: Backup.undoKeptAtKey))
    }

    // Value: protects=a new restore's copy gets its own week, not an earlier incomplete Undo's; fails_when=restore stops clearing undoKeptAtKey; why_new=no test set it before a restore; seam=none; no_claim=reachability (needs the clock set back)
    @MainActor
    func testANewRestoreStartsItsOwnUndoWeek() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackupOwnWeek-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let storage = StorageManager(directory: dir)
        d.set(Date().timeIntervalSince1970, forKey: Backup.undoKeptAtKey)
        _ = try await restored(["masterVolume": 0.5, Backup.markerKey: 1], into: storage, now: Date())
        XCTAssertNil(d.object(forKey: Backup.undoKeptAtKey))
    }

    // Value: protects=a restored Last Night snapshot's sound names are held to the settings' limit; fails_when=sanitized(SavedMix) stops checking its texts; why_new=it was bounded only by the blob's size, and Resume wrote the name into the plist; seam=none; no_claim=the episode fields' bound
    func testALastMixWithAnOverlongSoundNameIsSkipped() {
        var mix: [String: Any] = ["id": "m", "name": "Last Night", "noiseOn": true, "noiseVolume": 0.5, "noiseType": "brown",
                                  "binauralOn": false, "binVolume": 0.3, "binauralPreset": "delta", "podVolume": 0.7,
                                  "podcastUrl": "https://x/" + String(repeating: "a", count: 10_000)]
        XCTAssertEqual(Backup.restoreUserDefaults(from: ["lastMix": mix], into: d).restored, 1, "a long episode address is fine")
        d.removeObject(forKey: "lastMix")
        mix["binauralPreset"] = String(repeating: "b", count: 300)
        let (restored, skipped) = Backup.restoreUserDefaults(from: ["lastMix": mix], into: d)
        XCTAssertEqual(restored, 0)
        XCTAssertEqual(skipped, 1)
        XCTAssertNil(d.data(forKey: "lastMix"))
    }

    // Value: protects=the Undo row names the date once the restore is a week old; fails_when=undoWhen goes back to the weekday alone; why_new=an incomplete Undo keeps the copy past the week, and a weekday read as last week's; seam=none; no_claim=the locale's wording
    @MainActor
    func testTheUndoRowNamesTheDateOnceItIsOld() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let recent = now.addingTimeInterval(-2 * 86_400)
        let old = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(BackupController.undoWhen(recent, now: now), recent.formatted(.dateTime.weekday(.wide).hour().minute()))
        XCTAssertEqual(BackupController.undoWhen(old, now: now),
                       old.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute()))
    }

    // MARK: after the review cap: the adversarial pass's fixes

    // Value: protects=restored saved places are held to the feed bound on keys and to the player's 100, and what's dropped is counted; fails_when=the places case keeps every key again; why_new=a hundred half-megabyte keys made a 50 MB file rewritten every 30 s; seam=none; no_claim=which 100 are kept
    func testRestoredPlacesAreBoundedInKeysAndCount() throws {
        var places: [String: Double] = [:]
        for i in 0..<105 { places[String(format: "ep%03d", i)] = Double(i) }
        places[String(repeating: "k", count: 20_000)] = 1
        let section = try XCTUnwrap(Backup.validatedFileSection(key: "episodePositions", value: places))
        XCTAssertEqual(section.count, Backup.maxPlaces)
        XCTAssertEqual(section.dropped, 6, "the over-long key and the five past the player's hundred")
        let kept = try JSONDecoder().decode([String: Double].self, from: section.data)
        XCTAssertTrue(kept.keys.allSatisfy { $0.utf8.count < 100 })
        XCTAssertEqual(Backup.contents(of: ["episodePositions": places]).tooLong, 6)
    }

    // Value: protects=a mix the person named at length (CJK, emoji) survives a restore, and the confirm says when items will be left out; fails_when=the preset name goes back to the 256-byte settings bound, or the confirm ignores tooLong; why_new=86 Japanese characters lost the mix; seam=none; no_claim=the mix name fields' own limits
    func testALongMixNameSurvivesAndTheConfirmSaysWhatsLeftOut() throws {
        let name = String(repeating: "夜の雨", count: 100)                              // 900 bytes
        let mix = SoundPreset(name: name, mode: "sleep", noiseOn: true, noiseType: "rain", noiseVolume: 0.5, binauralOn: false,
                              binauralPreset: "delta", binVolume: 0.3, sceneId: nil, extraLayers: nil)
        var padded = mix
        padded.binauralPreset = String(repeating: "b", count: 300)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode([mix, padded]))
        let section = try XCTUnwrap(Backup.validatedFileSection(key: "savedPlaylists", value: value))
        XCTAssertEqual(try JSONDecoder().decode([SoundPreset].self, from: section.data).map(\.name), [name])
        let contents = Backup.contents(of: ["savedPlaylists": value])
        XCTAssertEqual(contents.tooLong, 1)
        XCTAssertEqual(Backup.confirmMessage(contents),
                       "This replaces what's on this iPhone with the backup's 1 mix. One item will be left out: a text in it is too long. You can undo it afterwards.")
    }
}


// MARK: - The Backup page's controller

/// `BackupController` against a temp store and defaults, with no alert delay. SwiftUI's own parts
/// (the file exporter, the alert) aren't here: the controller's state is what they read.
@MainActor
final class BackupControllerTests: XCTestCase {

    private struct Fixture {
        let controller: BackupController
        let storage: StorageManager
        let dir: URL
        let defaults: UserDefaults
        let suite: String
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func fixture(settle: @escaping () -> Void = {}, reload: @escaping () -> Void = {}) throws -> Fixture {
        let suite = "BackupControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let storage = StorageManager(directory: dir)
        let controller = BackupController(storage: storage, defaults: defaults,
                                          alertDelay: 0, settle: settle, reload: reload)
        return Fixture(controller: controller, storage: storage, dir: dir, defaults: defaults, suite: suite)
    }

    /// Waits up to 5 s, and fails the test if the condition never held.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if !condition() { XCTFail("timed out waiting", file: file, line: line) }
    }

    // Value: protects=a failure that lands while Backup & support is closed is shown when it opens again, and a result with a one-tap Undo is still dropped; fails_when=present drops failures again, or keeps every result; why_new="Couldn't save a copy …, so nothing was replaced" was lost when the page had closed; seam=alertDelay 0, a temp store; no_claim=SwiftUI's alert presentation
    func testAFailureWaitsForThePageButARestoreResultIsDropped() async throws {
        var reloaded = false
        let f = try fixture(reload: { reloaded = true })
        defer { f.cleanUp() }
        let backup = f.controller

        backup.picked(.failure(CocoaError(.fileReadNoPermission)))           // the page is closed
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(backup.prompt)
        backup.pageAppeared()
        try await waitUntil { backup.prompt != nil }
        guard case .failed(let title, _)? = backup.prompt else { return XCTFail("the failure is shown once the page opens") }
        XCTAssertEqual(title, "Couldn't restore")
        backup.isPrompting.wrappedValue = false

        backup.pageDisappeared()
        let file: [String: Any] = ["masterVolume": 0.9, Backup.markerKey: 1]
        backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: file), contents: Backup.contents(of: file)))
        try await waitUntil { reloaded && !backup.busy }
        XCTAssertEqual(f.defaults.double(forKey: "masterVolume"), 0.9, accuracy: 1e-9, "the restore itself finished")
        backup.pageAppeared()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(backup.prompt, "\"Backup restored\" with its one-tap Undo isn't shown out of context")
    }

    // Value: protects=the export's document is let go once the exporter closes, and a section the export left out is said after the save; fails_when=isExporting's didSet stops clearing the document, or exported(.success) stops reporting leftOut; why_new=the document (tens of MB) was kept all session, and a left-out section went unmentioned; seam=alertDelay 0, a temp store; no_claim=the file exporter's UI
    func testTheExportLetsGoOfItsDocumentAndSaysWhatItLeftOut() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let backup = f.controller
        try FileManager.default.createDirectory(at: f.dir, withIntermediateDirectories: true)
        for name in ["library.json", "library.json.bak"] {
            try Data("{ truncated".utf8).write(to: f.dir.appendingPathComponent(name))
        }
        backup.pageAppeared()
        backup.export()
        try await waitUntil { backup.isExporting }
        XCTAssertNotNil(backup.exportDocument)

        backup.exported(.success(f.dir.appendingPathComponent("saved.json")))
        backup.isExporting = false                                           // SwiftUI resets it as the exporter closes
        XCTAssertNil(backup.exportDocument)
        try await waitUntil { backup.prompt != nil }
        guard case .notice(_, let message)? = backup.prompt else { return XCTFail("the save says what it left out") }
        XCTAssertEqual(message, Backup.leftOutMessage(["savedPodcasts"]))
    }

    // Value: protects=an Undo that couldn't save every file says so and stays offered; fails_when=the controller maps .incomplete to "Restore undone" or drops the Undo row; why_new=Undo said "back as they were" over a library a full disk kept out; seam=alertDelay 0, a temp store; no_claim=the alert's presentation
    func testAnIncompleteUndoSaysSoAndStaysOffered() async throws {
        var reloads = 0
        let f = try fixture(reload: { reloads += 1 })
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.dir.path)
            f.cleanUp()
        }
        let backup = f.controller
        backup.pageAppeared()
        let file: [String: Any] = ["episodePositions": ["ep9": 5.0], Backup.markerKey: 1]
        backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: file), contents: Backup.contents(of: file)))
        try await waitUntil { reloads == 1 && !backup.busy && backup.prompt != nil }
        backup.isPrompting.wrappedValue = false
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: f.dir.path)

        backup.undo()
        try await waitUntil { reloads == 2 && !backup.busy && backup.prompt != nil }
        guard case .failed(let title, _)? = backup.prompt else { return XCTFail("got \(String(describing: backup.prompt))") }
        XCTAssertEqual(title, "Couldn't put everything back")
        XCTAssertEqual(reloads, 2, "an incomplete Undo still reloads what it put back")
        XCTAssertNotNil(backup.undoDate, "Undo is still offered")
    }

    // Value: protects=a restore that didn't land whole is still said when the page reopens, without its one-tap Undo; fails_when=present drops every .restored again; why_new=the only word that a section couldn't be saved was lost if you'd left the page; seam=alertDelay 0, a temp store; no_claim=the alert's presentation
    func testAPartialRestoreIsSaidWhenThePageReopens() async throws {
        var reloads = 0
        let f = try fixture(reload: { reloads += 1 })
        defer { f.cleanUp() }
        let backup = f.controller
        // A directory where the show list goes: that section can't be saved.
        try FileManager.default.createDirectory(at: f.dir.appendingPathComponent("library.json"), withIntermediateDirectories: true)
        let file: [String: Any] = ["savedPodcasts": [Any](), "masterVolume": 0.4, Backup.markerKey: 1]
        backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: file), contents: Backup.contents(of: file)))
        try await waitUntil { reloads == 1 && !backup.busy }
        XCTAssertNil(backup.prompt, "the page is closed")
        backup.pageAppeared()
        try await waitUntil { backup.prompt != nil }
        guard case .notice(let title, let message)? = backup.prompt else { return XCTFail("got \(String(describing: backup.prompt))") }
        XCTAssertEqual(title, "Backup restored")
        XCTAssertTrue(message.contains("couldn't be saved"), message)
    }

    // Value: protects=a cancelled export lets go of its document too; fails_when=the document is only cleared in the completion handler (not called on cancel); why_new=see above; seam=none; no_claim=the exporter's UI
    func testACancelledExportLetsGoOfItsDocument() async throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let backup = f.controller
        backup.pageAppeared()
        backup.export()
        try await waitUntil { backup.isExporting }
        XCTAssertNotNil(backup.exportDocument)
        backup.isExporting = false                                           // cancelled: no completion call
        XCTAssertNil(backup.exportDocument)
        XCTAssertNil(backup.prompt)
    }

    // Value: protects=the Backup page's export, restore and Undo call the injected settle, so the engine's queued writes land first; fails_when=BackupController stops passing settle to Backup.restore/undo, or export() stops calling it; why_new=Backup.restore/undo are driven with a settle (testARestoreLandsQueuedWritesFirst), the controller never was; seam=settle (non-test callers: 1, via grep -rn "settle:" Sleepulator/Sleepulator); no_claim=that SettingsView hands it AudioEngine.flushPendingWrites (SwiftUI wiring)
    func testTheExportRestoreAndUndoSettleTheQueuedWritesFirst() async throws {
        var settles = 0
        var reloads = 0
        var store: StorageManager?
        let f = try fixture(settle: {
            settles += 1
            // The first time (the export's), a place the engine still had queued: the backup must hold it.
            if settles == 1, let held = try? JSONEncoder().encode(["ep1": 42.0]) { store?.writeRaw(held, to: "positions.json") }
        }, reload: { reloads += 1 })
        defer { f.cleanUp() }
        store = f.storage
        let backup = f.controller
        backup.pageAppeared()

        backup.export()
        try await waitUntil { backup.isExporting }
        let exported = try XCTUnwrap(backup.exportDocument?.data)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
        XCTAssertEqual(dict["episodePositions"] as? [String: Double], ["ep1": 42.0], "the export settled before it read the store")
        let exportSettles = settles
        XCTAssertGreaterThanOrEqual(exportSettles, 1)
        backup.isExporting = false

        let file: [String: Any] = ["episodePositions": ["ep9": 5.0], Backup.markerKey: 1]
        backup.restore(Backup.Pending(data: try JSONSerialization.data(withJSONObject: file), contents: Backup.contents(of: file)))
        try await waitUntil { reloads == 1 && !backup.busy }
        XCTAssertEqual(reloads, 1, "the restore finished")
        XCTAssertEqual(settles - exportSettles, 2, "the restore settles before its Undo copy and again before its writes")

        backup.undo()
        try await waitUntil { reloads == 2 && !backup.busy }
        XCTAssertEqual(reloads, 2, "the Undo finished")
        XCTAssertEqual(settles - exportSettles, 3, "the Undo settles once, before its writes")
    }
}
