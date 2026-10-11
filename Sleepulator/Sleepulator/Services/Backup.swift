import Foundation

/// The settings backup: the user's mixes, podcasts, queue and settings as one JSON file, and the
/// restore that reads one back.
///
/// A restore is read → confirm → write. `read` parses and validates the file and says what's in it
/// without touching anything, so the person can confirm in their own terms ("4 mixes, 12 shows").
/// `restore` saves a snapshot of what's here first (`undoFile`), so a restore can be undone: it
/// replaces a curated library in one tap, and used to do it straight from the file picker.
enum Backup {

    /// Scalar UserDefaults keys in a backup. Single source of truth for both the export and the
    /// restore allowlist: restore writes nothing outside this set plus the file-backed collections
    /// below, so a malformed or hostile backup can't inject arbitrary defaults. Keep new persisted
    /// settings in sync here. `holdQueueDuringSleepTimer`, `finishedEpisodes` and the mode's last
    /// picks were missing until 2026-10, so a restore lost them.
    nonisolated static let scalarKeys: [String] = [
        "noiseVolume", "noiseType", "binVolume", "binauralPreset", "podVolume", "stereoWidth",
        "masterVolume", "autoPlay", "shuffleQueue", "deleteOnCompletion", "hideFinishedEpisodes",
        "holdQueueDuringSleepTimer", "finishedEpisodes",
        "nightLimiterEnabled", "sleepEQEnabled", "sleepEQIntensity", "limiterByMode",
        "beatRouting", "skipInterval", "playbackSpeed", "focusMode", "sceneSleep", "sceneFocus",
        "bedtimeMode", "autoNightDim", "breathingOnRamp", "ambientMotion", "timerMinutes",
        "nightLengthMinutes", "ambientTailMinutes",
        "pomoWork", "pomoRest", "pomoLongRest", "pomoCycles",
        "lastPick.noise.sleep", "lastPick.noise.focus", "lastPick.binaural.sleep", "lastPick.binaural.focus"
    ]

    /// Backup keys that map to StorageManager files (not UserDefaults). Each must decode into its
    /// Codable type before restore will write it (`validatedFileSection`).
    nonisolated static let fileBacked: [String: String] = [
        "savedPlaylists": "mixes.json",
        "savedPodcasts": "library.json",
        "upNextQueue": "queue.json",
        "episodePositions": "positions.json"
    ]

    /// Keys whose UserDefaults value is a Data-encoded Codable blob, not a plain scalar. Data can't
    /// go through JSON, so these expand to a nested JSON object on export and are re-encoded on
    /// import. `extraLayers` was in NEITHER list until 2026-07: the extra mixer layers were
    /// silently dropped from every backup and lost on restore.
    nonisolated static let encodedKeys: [String] = ["lastMix", "extraLayers"]

    /// Marks a file as a Sleepulator backup, and when it was made (seconds since 1970). Never
    /// written to defaults. Backups from before 2026-10 have neither and still restore.
    nonisolated static let markerKey = "sleepulatorBackup"
    nonisolated static let exportedAtKey = "exportedAt"

    /// What was here before the last restore, which Undo puts back.
    nonisolated static let undoFile = "before-restore.json"
    /// When that snapshot was taken (seconds since 1970). Its own key so the Backup rows needn't
    /// parse a library-sized file to decide whether to offer Undo. Deliberately not backed up.
    nonisolated static let undoTakenAtKey = "restoreUndoTakenAt"
    /// How long Undo is offered. Past a week it would roll back everything since, which nobody
    /// reaching for "undo" means.
    nonisolated static let undoWindow: TimeInterval = 7 * 24 * 3600

    // MARK: What a backup holds

    /// A backup's recognisable contents, for the confirm and the result. nil counts mean the
    /// section is absent (a restore leaves that part alone); 0 means it's there and empty (a
    /// restore empties it, which the confirm must say).
    struct Contents: Equatable, Sendable {
        var mixes: Int?
        var shows: Int?
        var upNext: Int?
        var positions = false
        var settings = false
        var exportedAt: Date?

        nonisolated var restoresAnything: Bool {
            mixes != nil || shows != nil || upNext != nil || positions || settings
        }
    }

    /// A read, validated backup awaiting the person's confirm. Holds the file's bytes (Sendable),
    /// not the parsed dictionary; the write re-parses them off the main thread.
    struct Pending: Sendable {
        let data: Data
        let contents: Contents
    }

    /// What a restore wrote. `skipped` counts sections that weren't recognised or didn't validate.
    struct Outcome: Sendable {
        let contents: Contents
        let skipped: Int
        let undoAvailable: Bool
    }

    enum ReadFailure: Error, Equatable, Sendable { case noAccess, unreadable, notBackup }

    /// Re-encode a file-backed section, confirm it decodes into the Codable type its file expects,
    /// and count its items. nil if the section is malformed or unexpected.
    nonisolated static func validatedFileSection(key: String, value: Any) -> (data: Data, count: Int)? {
        guard let data = jsonData(value) else { return nil }
        let decoder = JSONDecoder()
        let count: Int?
        switch key {
        case "savedPlaylists":   // current schema is [SoundPreset]; older backups are [SavedMix]
            count = (try? decoder.decode([SoundPreset].self, from: data))?.count
                 ?? (try? decoder.decode([SavedMix].self, from: data))?.count
        case "savedPodcasts":
            count = (try? decoder.decode([Podcast].self, from: data))?.count
        case "upNextQueue":
            count = (try? decoder.decode([Episode].self, from: data))?.count
        case "episodePositions":
            count = (try? decoder.decode([String: Double].self, from: data))?.count
        default:
            count = nil
        }
        return count.map { (data, $0) }
    }

    /// The JSON bytes to write for a file-backed section, or nil if it doesn't validate.
    nonisolated static func validatedFileData(key: String, value: Any) -> Data? {
        validatedFileSection(key: key, value: value)?.data
    }

    /// Whether an allowlisted scalar's value has the shape the app reads back. Most keys accept
    /// anything (a wrong type reads as the default); the played list must be strings, or the
    /// whole set reads as empty.
    nonisolated private static func scalarValid(key: String, value: Any) -> Bool {
        key == "finishedEpisodes" ? value is [String] : true
    }

    /// Validate that a Data-encoded backup blob decodes into its expected type before restore.
    nonisolated private static func decodesForRestore(key: String, data: Data) -> Bool {
        let dec = JSONDecoder()
        switch key {
        case "lastMix":     return (try? dec.decode(SavedMix.self, from: data)) != nil
        case "extraLayers": return (try? dec.decode([ExtraNoiseLayer].self, from: data)) != nil
        default:            return false
        }
    }

    /// Re-encode a parsed section. A section that isn't an array or object (a string where the
    /// show list should be) makes JSONSerialization raise an Objective-C exception that `try?`
    /// can't catch, which crashed the app on a hand-edited backup, so it's refused first.
    nonisolated private static func jsonData(_ value: Any) -> Data? {
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [])
    }

    nonisolated private static func encodedValue(key: String, value: Any) -> Data? {
        guard let encoded = jsonData(value),
              decodesForRestore(key: key, data: encoded) else { return nil }
        return encoded
    }

    /// What a parsed backup would restore, without writing anything.
    nonisolated static func contents(of dict: [String: Any]) -> Contents {
        var c = Contents()
        for (key, _) in fileBacked {
            guard let value = dict[key], let section = validatedFileSection(key: key, value: value) else { continue }
            switch key {
            case "savedPlaylists":   c.mixes = section.count
            case "savedPodcasts":    c.shows = section.count
            case "upNextQueue":      c.upNext = section.count
            default:                 c.positions = true
            }
        }
        c.settings = scalarKeys.contains { key in dict[key].map { scalarValid(key: key, value: $0) } ?? false }
            || encodedKeys.contains { key in dict[key].flatMap { encodedValue(key: key, value: $0) } != nil }
        if let seconds = dict[exportedAtKey] as? Double { c.exportedAt = Date(timeIntervalSince1970: seconds) }
        return c
    }

    // MARK: Copy (pure, unit-tested)

    /// "no mixes" / "1 mix" / "4 mixes".
    nonisolated static func counted(_ n: Int, _ singular: String, _ plural: String) -> String {
        switch n {
        case 0:  return "no \(plural)"
        case 1:  return "1 \(singular)"
        default: return "\(n) \(plural)"
        }
    }

    /// "a", "a and b", "a, b and c": the app's list style (no serial comma).
    nonisolated static func joined(_ parts: [String]) -> String {
        guard parts.count > 1 else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }

    /// The contents as a phrase list; `settings` names the settings ("settings", "your settings").
    nonisolated static func phrases(_ c: Contents, settings: String) -> [String] {
        var parts: [String] = []
        if let n = c.mixes { parts.append(counted(n, "mix", "mixes")) }
        if let n = c.shows { parts.append(counted(n, "show", "shows")) }
        if let n = c.upNext { parts.append(counted(n, "episode", "episodes") + " in Up Next") }
        if c.settings { parts.append(settings) }
        return parts
    }

    nonisolated static func confirmTitle(_ c: Contents) -> String {
        guard let date = c.exportedAt else { return "Replace with this backup?" }
        return "Replace with the backup from \(date.formatted(.dateTime.day().month(.abbreviated)))?"
    }

    nonisolated static func confirmMessage(_ c: Contents) -> String {
        let parts = phrases(c, settings: "settings")
        let what = parts.isEmpty ? "the backup's saved places in episodes" : "the backup's " + joined(parts)
        return "This replaces what's on this iPhone with \(what). You can undo it afterwards."
    }

    nonisolated static func restoredMessage(_ o: Outcome) -> String {
        let parts = phrases(o.contents, settings: "your settings")
        var message = parts.isEmpty ? "Restored where you'd got to in each episode." : "Restored \(joined(parts))."
        if o.skipped > 0 { message += " A few parts of the file weren't recognised and were left as they were." }
        return message
    }

    nonisolated static func failureMessage(_ failure: ReadFailure) -> String {
        switch failure {
        case .noAccess:   return "Couldn't open that file. Pick it again from Files; if it's in iCloud, let it download first."
        case .unreadable: return "Couldn't read that file. Pick it again from Files; if it's in iCloud, let it download first."
        case .notBackup:  return "That isn't a Sleepulator backup. Make one with Export a backup."
        }
    }

    /// Whether Undo is still offered for a snapshot taken at `takenAt`.
    nonisolated static func undoAvailable(takenAt: Date?, now: Date) -> Bool {
        guard let takenAt else { return false }
        let age = now.timeIntervalSince(takenAt)
        // A second of slack: the time goes through UserDefaults as seconds since 1970, and the
        // round trip can land a hair after `now`. Without it Undo was refused (and its snapshot
        // thrown away) right after the restore that made it.
        return age > -1 && age < undoWindow
    }

    /// "sleepulator-backup-2026-10-11": dated, so a second export doesn't overwrite the first.
    nonisolated static func filename(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "sleepulator-backup-%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: UserDefaults halves (pure + parameterized on `defaults`, unit-tested)

    /// The UserDefaults side of an export: scalar settings + the Data-encoded blobs, ready to merge
    /// into the backup dictionary. The shipping export calls this too, so the test covers the real
    /// path.
    nonisolated static func userDefaults(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in scalarKeys {
            if let v = defaults.object(forKey: key) { out[key] = v }
        }
        for key in encodedKeys {
            if let data = defaults.data(forKey: key),
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                out[key] = obj
            }
        }
        return out
    }

    /// The UserDefaults side of a restore: writes allowlisted scalars and re-encodes the Data
    /// blobs, never writing anything outside the allowlist (a malformed or hostile section is
    /// skipped, not written). File-backed keys and the marker are passed over without counting.
    /// `replacing` (Undo) also removes allowlisted keys the dictionary lacks, so the snapshot comes
    /// back exactly. Returns (restored, skipped) for the UserDefaults keys only.
    nonisolated static func restoreUserDefaults(from dict: [String: Any], into defaults: UserDefaults,
                                                replacing: Bool = false) -> (restored: Int, skipped: Int) {
        let allowed = Set(scalarKeys)
        var restored = 0, skipped = 0
        for (key, value) in dict {
            if fileBacked[key] != nil || key == markerKey || key == exportedAtKey {
                continue                                       // files are the caller's; the marker isn't a setting
            } else if encodedKeys.contains(key) {
                if let encoded = encodedValue(key: key, value: value) {
                    defaults.set(encoded, forKey: key); restored += 1
                } else { skipped += 1 }
            } else if allowed.contains(key), scalarValid(key: key, value: value) {
                defaults.set(value, forKey: key); restored += 1
            } else {
                skipped += 1                                   // unknown or malformed: never blind-write
            }
        }
        if replacing {
            for key in scalarKeys + encodedKeys where dict[key] == nil { defaults.removeObject(forKey: key) }
        }
        return (restored, skipped)
    }

    /// The whole backup dictionary: defaults, the file-backed collections' JSON, and the marker.
    nonisolated static func exportDictionary(defaults: UserDefaults, files: [String: Data], at date: Date) -> [String: Any] {
        var dict = userDefaults(from: defaults)
        for (key, file) in fileBacked {
            if let data = files[file],
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                dict[key] = obj
            }
        }
        dict[markerKey] = 1
        dict[exportedAtKey] = date.timeIntervalSince1970
        return dict
    }

    // MARK: I/O

    // The I/O below takes the store and defaults as parameters (the shared ones by default) so
    // the restore → undo round trip is tested against a temp store, never the app's own data.

    /// The file-backed collections as they are on disk, after any queued writes land.
    private static func currentFiles(_ storage: StorageManager) -> [String: Data] {
        storage.flush()
        var files: [String: Data] = [:]
        for file in fileBacked.values {
            if let data = storage.rawData(for: file) { files[file] = data }
        }
        return files
    }

    /// A backup of everything here now, serialized off the main thread (a large library would
    /// otherwise stall the UI).
    static func exportData(at date: Date = Date(), storage: StorageManager = .shared,
                           defaults: UserDefaults = .standard) async throws -> Data {
        let files = currentFiles(storage)
        return try await Task.detached(priority: .userInitiated) {
            let dict = exportDictionary(defaults: defaults, files: files, at: date)
            // Refuse rather than raise: a non-JSON value would throw an uncatchable exception.
            guard JSONSerialization.isValidJSONObject(dict) else { throw CocoaError(.coderInvalidValue) }
            return try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        }.value
    }

    /// Read and validate a picked file. Writes nothing.
    static func read(_ url: URL) async -> Result<Pending, ReadFailure> {
        await Task.detached(priority: .userInitiated) { () -> Result<Pending, ReadFailure> in
            // A file in the app's own container needs no security scope and returns false here,
            // so only a failed read counts as no access.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return .failure(scoped ? .unreadable : .noAccess) }
            guard let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else {
                return .failure(.notBackup)
            }
            let contents = contents(of: dict)
            guard contents.restoresAnything else { return .failure(.notBackup) }
            return .success(Pending(data: data, contents: contents))
        }.value
    }

    /// Write a confirmed backup. Snapshots what's here first, so Undo can put it back even if the
    /// write goes wrong part-way. The caller reloads the engine afterwards.
    static func restore(_ pending: Pending, now: Date = Date(), storage: StorageManager = .shared,
                        defaults: UserDefaults = .standard) async -> Outcome {
        var undoAvailable = false
        if let snapshot = try? await exportData(at: now, storage: storage, defaults: defaults) {
            storage.writeRaw(snapshot, to: undoFile)
            defaults.set(now.timeIntervalSince1970, forKey: undoTakenAtKey)
            undoAvailable = true
        }
        let written = await write(pending.data, replacing: false, storage: storage, defaults: defaults)
        return Outcome(contents: written.contents, skipped: written.skipped, undoAvailable: undoAvailable)
    }

    /// When the snapshot Undo would put back was taken, if it's still offered. Clears an expired
    /// one, so a month-old library never sits in Application Support waiting to be "undone" to.
    static func undoDate(now: Date = Date(), storage: StorageManager = .shared,
                         defaults: UserDefaults = .standard) -> Date? {
        let seconds = defaults.object(forKey: undoTakenAtKey) as? Double
        let takenAt = seconds.map { Date(timeIntervalSince1970: $0) }
        if undoAvailable(takenAt: takenAt, now: now) { return takenAt }
        if takenAt != nil { discardUndo(storage, defaults) }
        return nil
    }

    /// Put back what was here before the last restore. False if there's nothing to put back.
    static func undo(now: Date = Date(), storage: StorageManager = .shared,
                     defaults: UserDefaults = .standard) async -> Bool {
        storage.flush()
        guard undoDate(now: now, storage: storage, defaults: defaults) != nil,
              let data = storage.rawData(for: undoFile) else { return false }
        _ = await write(data, replacing: true, storage: storage, defaults: defaults)
        discardUndo(storage, defaults)
        storage.flush()
        return true
    }

    private static func discardUndo(_ storage: StorageManager, _ defaults: UserDefaults) {
        storage.delete(filename: undoFile)
        defaults.removeObject(forKey: undoTakenAtKey)
    }

    /// The validated writes a backup asks for, worked out off the main thread.
    private struct Prepared: Sendable {
        var files: [String: Data] = [:]      // filename → bytes
        var absentFiles: [String] = []       // files a replacing write removes
        var contents = Contents()
        var skipped = 0
    }

    /// Parse, validate and write a backup's bytes. UserDefaults is written off-main (thread-safe);
    /// the files go through StorageManager, then flush so the caller's reload reads them.
    private static func write(_ data: Data, replacing: Bool, storage: StorageManager,
                              defaults: UserDefaults) async -> (contents: Contents, skipped: Int) {
        let prepared = await Task.detached(priority: .userInitiated) { () -> Prepared in
            var p = Prepared()
            guard let dict = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any] else { return p }
            for (key, file) in fileBacked {
                guard let value = dict[key] else { p.absentFiles.append(file); continue }
                if let section = validatedFileSection(key: key, value: value) {
                    p.files[file] = section.data
                } else { p.skipped += 1 }
            }
            p.contents = contents(of: dict)
            p.skipped += restoreUserDefaults(from: dict, into: defaults, replacing: replacing).skipped
            return p
        }.value
        for (file, bytes) in prepared.files { storage.writeRaw(bytes, to: file) }
        if replacing { prepared.absentFiles.forEach { storage.delete(filename: $0) } }
        storage.flush()
        return (prepared.contents, prepared.skipped)
    }
}
