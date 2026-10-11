import Foundation
import os

final class StorageManager {
    // Nonisolated, like the inits: they touch only the file system and an immutable URL, so
    // default arguments (`storage: StorageManager = .shared`) can name it without a warning.
    nonisolated static let shared = StorageManager()
    private let appSupportURL: URL
    private let ioQueue = DispatchQueue(label: "app.sleepulator.storage.ioQueue", qos: .utility)

    /// Suffix for the rolling backup sibling kept next to every persisted file. Each successful
    /// write lands the same bytes in both `<name>` and `<name>.bak`, so a primary truncated by a
    /// crash mid-replace (or corrupted at rest) can be recovered from the backup on the next load
    /// instead of silently decoding to `nil` and wiping the user's library/presets.
    nonisolated private static let backupSuffix = ".bak"

    /// How `loadResult` resolved — lets callers/tests tell a benign first-run miss from a
    /// corruption that was (or wasn't) recovered from the backup.
    enum LoadOutcome: Equatable { case missing, loaded, recovered, failed }

    nonisolated convenience init() {
        let fm = FileManager.default
        // Same rationale as AudioDownloader: never launch-crash on a missing Application Support
        // URL — fall back to the temp dir (persistence degrades for the session, app still runs).
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let appSupport = base.appendingPathComponent("Sleepulator")
        self.init(directory: appSupport)
    }

    /// Seam initializer: point the store at an arbitrary directory. Production uses `init()`
    /// (Application Support); unit tests pass a temp dir so they're hermetic and never touch — or
    /// race — the real on-disk store.
    nonisolated init(directory: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
        self.appSupportURL = directory
    }

    // Explicitly nonisolated: the implicit MainActor-isolated deinit aborts on iOS 18.4–26.3
    // runtimes (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}

    nonisolated private func fileURL(for filename: String) -> URL {
        return appSupportURL.appendingPathComponent(filename)
    }

    nonisolated private func backupURL(for filename: String) -> URL {
        return appSupportURL.appendingPathComponent(filename + Self.backupSuffix)
    }

    func save<T: Encodable>(_ object: T, to filename: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let data = try JSONEncoder().encode(object)
                try self.writeBoth(data, filename: filename)
            } catch {
                Log.storage.error("Failed to save \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Decoded value, or `nil` for any non-`.loaded`/.recovered outcome. Thin wrapper over
    /// `loadResult` so existing call sites are unchanged.
    func load<T: Decodable>(from filename: String) -> T? {
        return loadResult(from: filename).value
    }

    /// Load with an explicit outcome. Distinguishes a missing file (benign first-run) from a
    /// corrupt primary (logged, then recovered from `.bak` when possible, self-healing the
    /// primary). Reads happen on the caller's thread; any restore write is enqueued on `ioQueue`.
    func loadResult<T: Decodable>(from filename: String) -> (value: T?, outcome: LoadOutcome) {
        let primary = fileURL(for: filename)
        let backup = backupURL(for: filename)
        let fm = FileManager.default
        let hasPrimary = fm.fileExists(atPath: primary.path)
        let hasBackup = fm.fileExists(atPath: backup.path)

        if !hasPrimary && !hasBackup {
            return (nil, .missing)   // first run / never written — not an error
        }

        if hasPrimary {
            do {
                let data = try Data(contentsOf: primary)
                return (try JSONDecoder().decode(T.self, from: data), .loaded)
            } catch {
                Log.storage.error("Corrupt primary \(filename, privacy: .public): \(error.localizedDescription, privacy: .public) — trying backup")
            }
        }

        // Primary missing-but-backup-present, or primary corrupt: try the backup.
        if hasBackup, let data = try? Data(contentsOf: backup),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            writeRaw(data, to: filename)   // self-heal the primary from the good backup
            Log.storage.error("Recovered \(filename, privacy: .public) from backup")
            return (value, .recovered)
        }

        Log.storage.error("Failed to load \(filename, privacy: .public) — primary and backup both unusable")
        return (nil, .failed)
    }

    /// Raw JSON bytes for a file: the primary if it parses as JSON, else the `.bak` if that does,
    /// else nil. Lets Backup/Restore round-trip the file-backed collections (mixes/library/queue/
    /// positions) without coupling to their Codable types. An unparseable primary used to be
    /// returned as it was: the export then left that section out without a word, and Undo,
    /// finding it missing from its copy, wrote [] over both files, the good `.bak` included.
    /// Parses the file, so a big one is read off the main thread (Backup does). Nonisolated:
    /// it touches only the immutable directory URL and the file system.
    nonisolated func rawData(for filename: String) -> Data? {
        for url in [fileURL(for: filename), backupURL(for: filename)] {
            if let data = try? Data(contentsOf: url),
               (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil {
                return data
            }
        }
        return nil
    }

    /// Whether the file or its `.bak` is on disk, readable or not. Cheap: no read, no parse.
    nonisolated func exists(_ filename: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: fileURL(for: filename).path) || fm.fileExists(atPath: backupURL(for: filename).path)
    }

    /// `writeRaw`, but synchronous and throwing: the write is atomic (a temp file renamed over
    /// the old one), so when it throws the previous file is still there, untouched. The restore
    /// writes its Undo copy this way, and refuses to go ahead when it fails; a restore and its
    /// Undo write their files this way too, so a file that didn't land is known. Nonisolated, so
    /// the library-sized Undo copy can be written off the main thread.
    nonisolated func writeRawNow(_ data: Data, to filename: String) throws {
        try ioQueue.sync { try writeBoth(data, filename: filename) }
    }

    /// Atomically write raw JSON bytes to a file, keeping the `.bak` sibling in sync, without
    /// waiting (the self-heal in `loadResult`; tests). A restore and its Undo use `writeRawNow`,
    /// so they know when a file didn't land.
    func writeRaw(_ data: Data, to filename: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                try self.writeBoth(data, filename: filename)
            } catch {
                Log.storage.error("Failed to writeRaw \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Write `data` to the primary atomically, then mirror it to the backup. Sequenced so a crash
    /// between the two leaves at least one complete, valid file (primary new + backup old, or both
    /// new). MUST run on `ioQueue`.
    nonisolated private func writeBoth(_ data: Data, filename: String) throws {
        try data.write(to: fileURL(for: filename), options: .atomic)
        do {
            try data.write(to: backupURL(for: filename), options: .atomic)
        } catch {
            Log.storage.error("Backup write failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Block until all queued writes have flushed to disk: before a backup reads the store, and
    /// after a restore, so the reload can't read a file another queued write is still landing on.
    func flush() {
        ioQueue.sync { }
    }

    func delete(filename: String) {
        ioQueue.async { [weak self] in
            guard let self = self else { return }
            try? FileManager.default.removeItem(at: self.fileURL(for: filename))
            try? FileManager.default.removeItem(at: self.backupURL(for: filename))
        }
    }
}
