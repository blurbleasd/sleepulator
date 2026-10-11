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
        XCTAssertTrue(undone)
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
        XCTAssertFalse(undone)
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
        XCTAssertFalse(gone)
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d), "a failed Undo must not keep offering itself")

        storage.writeRaw(Data("not json".utf8), to: Backup.undoFile)
        d.set(now.timeIntervalSince1970, forKey: Backup.undoTakenAtKey)
        let unreadable = await Backup.undo(now: now, storage: storage, defaults: d)
        XCTAssertFalse(unreadable, "nothing was put back, so it must not report Restore undone")
        XCTAssertNil(Backup.undoDate(now: now, storage: storage, defaults: d))
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

    // Value: protects=a real export names its mode, so a restore in the other mode sorts its sounds; fails_when=exportOnlyKeys is emptied; why_new=the sorting tests build their dicts by hand; seam=none; no_claim=the never-switched case (the next test)
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
                                   "finishedEpisodes": ["ok", String(repeating: "y", count: 3_000)]]
        let (restored, skipped) = Backup.restoreUserDefaults(from: dict, into: d)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(skipped, 3)
        XCTAssertNil(d.object(forKey: "pomoWork"))
        XCTAssertEqual(d.integer(forKey: "ambientTailMinutes"), 10)
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
        XCTAssertTrue(undone)
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
        XCTAssertTrue(undone)
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

        let fits = try await Backup.exportData(at: at, storage: storage, defaults: d, maxBytes: pretty.count)
        XCTAssertEqual(fits.data, pretty, "pretty-printed when that fits")
        let squeezed = try await Backup.exportData(at: at, storage: storage, defaults: d, maxBytes: compact.count)
        XCTAssertEqual(squeezed.data.count, compact.count, "compact when only that fits")
        do {
            _ = try await Backup.exportData(at: at, storage: storage, defaults: d, maxBytes: compact.count - 1)
            XCTFail("a backup a restore would refuse isn't made")
        } catch {
            XCTAssertEqual(error as? Backup.ExportFailure, .tooLarge)
        }
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
    }
}

