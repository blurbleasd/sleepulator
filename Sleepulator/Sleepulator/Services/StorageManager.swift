import Foundation
import os

final class StorageManager {
    static let shared = StorageManager()
    private let appSupportURL: URL
    private let ioQueue = DispatchQueue(label: "app.sleepulator.storage.ioQueue", qos: .utility)

    /// Suffix for the rolling backup sibling kept next to every persisted file. Each successful
    /// write lands the same bytes in both `<name>` and `<name>.bak`, so a primary truncated by a
    /// crash mid-replace (or corrupted at rest) can be recovered from the backup on the next load
    /// instead of silently decoding to `nil` and wiping the user's library/presets.
    private static let backupSuffix = ".bak"

    /// How `loadResult` resolved — lets callers/tests tell a benign first-run miss from a
    /// corruption that was (or wasn't) recovered from the backup.
    enum LoadOutcome: Equatable { case missing, loaded, recovered, failed }

    init() {
        let fm = FileManager.default
        let urls = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupport = urls.first!.appendingPathComponent("Sleepulator")
        if !fm.fileExists(atPath: appSupport.path) {
            try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true, attributes: nil)
        }
        self.appSupportURL = appSupport
    }

    private func fileURL(for filename: String) -> URL {
        return appSupportURL.appendingPathComponent(filename)
    }

    private func backupURL(for filename: String) -> URL {
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

    /// Raw JSON bytes for a file, or nil if it doesn't exist. Lets Backup/Restore
    /// round-trip the file-backed collections (mixes/library/queue/positions)
    /// without coupling to their Codable types.
    func rawData(for filename: String) -> Data? {
        if let data = try? Data(contentsOf: fileURL(for: filename)) { return data }
        // Fall back to the backup so an export still captures recoverable data.
        return try? Data(contentsOf: backupURL(for: filename))
    }

    /// Atomically write raw JSON bytes to a file (Backup/Restore import path), keeping the
    /// `.bak` sibling in sync.
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
    private func writeBoth(_ data: Data, filename: String) throws {
        try data.write(to: fileURL(for: filename), options: .atomic)
        do {
            try data.write(to: backupURL(for: filename), options: .atomic)
        } catch {
            Log.storage.error("Backup write failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Block until all queued writes have flushed to disk. Used by the in-process Restore so a
    /// reload can't read a file before its just-written bytes have landed (the writes are async).
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
