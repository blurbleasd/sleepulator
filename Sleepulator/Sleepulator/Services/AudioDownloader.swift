import Foundation
import CryptoKit

/// Downloads and caches podcast episodes for offline playback.
///
/// Storage lives in **Application Support/Sleepulator/episodes** (not Documents):
/// Documents is iCloud/iTunes-backed and user-visible, and Apple's data-storage
/// guideline (2.5.x) says re-downloadable content must not be backed up. App Support
/// is private and persistent (unlike Caches, which the OS can purge mid-playback);
/// we additionally mark it `isExcludedFromBackup`. A size cap evicts least-recently-
/// used files so the cache can't grow without bound.
class AudioDownloader {
    static let shared = AudioDownloader()
    private let fm = FileManager.default

    /// Soft ceiling for the on-disk episode cache. Oldest-accessed files are evicted
    /// after a download pushes the total over this.
    private let maxCacheBytes: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GB

    /// Refuse to start a download when the volume has less than this free. A pre-flight check so
    /// the cache can't push a near-full disk to the wall mid-write (and so a doomed download fails
    /// fast with a clear error instead of an opaque `moveItem` failure).
    private let minFreeSpaceBytes: Int64 = 500 * 1024 * 1024 // 500 MB headroom

    private lazy var cacheDir: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("Sleepulator/episodes", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        excludeFromBackup(dir)
        return dir
    }()

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    private func filename(for url: URL) -> String {
        let hash = Insecure.MD5.hash(data: Data(url.absoluteString.utf8))
        let hashStr = hash.map { String(format: "%02hhx", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "mp3" : url.pathExtension
        return "\(hashStr).\(ext)"
    }

    private func getLocalUrl(for url: URL) -> URL? {
        return cacheDir.appendingPathComponent(filename(for: url))
    }

    /// Pre-2026-06 builds wrote episodes into the Documents directory. Migrate those
    /// lazily so existing offline downloads aren't orphaned by the move to App Support.
    private func legacyUrl(for url: URL) -> URL? {
        guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return docDir.appendingPathComponent(filename(for: url))
    }

    private func migrateLegacyIfNeeded(_ url: URL) {
        guard let new = getLocalUrl(for: url), let old = legacyUrl(for: url) else { return }
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path) {
            try? fm.moveItem(at: old, to: new)
            excludeFromBackup(new)
        }
    }

    func download(url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        migrateLegacyIfNeeded(url)
        guard let localUrl = getLocalUrl(for: url) else {
            throw NSError(domain: "AudioDownloader", code: 2, userInfo: nil)
        }

        if fm.fileExists(atPath: localUrl.path) {
            touchAccess(localUrl)
            return localUrl
        }

        if let free = availableCapacity(), free < minFreeSpaceBytes {
            throw NSError(domain: "AudioDownloader", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Not enough free space to download this episode."])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let task = Net.download.downloadTask(with: url) { [weak self] tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    continuation.resume(throwing: NSError(domain: "AudioDownloader", code: 1, userInfo: nil))
                    return
                }

                do {
                    if FileManager.default.fileExists(atPath: localUrl.path) {
                        try FileManager.default.removeItem(at: localUrl)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: localUrl)
                    self?.excludeFromBackup(localUrl)
                    self?.enforceCacheLimit()
                    continuation.resume(returning: localUrl)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            let observation = task.progress.observe(\.fractionCompleted) { prog, _ in
                progress(prog.fractionCompleted)
            }

            // Keep the KVO observation alive until the task completes.
            objc_setAssociatedObject(task, "progressObservation", observation, .OBJC_ASSOCIATION_RETAIN)

            task.resume()
        }
    }

    func getCachedUrl(for url: URL) -> URL? {
        migrateLegacyIfNeeded(url)
        guard let localUrl = getLocalUrl(for: url) else { return nil }
        guard fm.fileExists(atPath: localUrl.path) else { return nil }
        // Mark the file as recently used so LRU eviction protects episodes you actually replay.
        // Streaming a cached file doesn't reliably bump the access date on its own.
        touchAccess(localUrl)
        return localUrl
    }

    /// Free space available for "important" usage on the cache's volume, or nil if unknown.
    private func availableCapacity() -> Int64? {
        guard let vals = try? cacheDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) else {
            return nil
        }
        return vals.volumeAvailableCapacityForImportantUsage
    }

    /// Bump a cached file's modification date to now, so `enforceCacheLimit` ranks it as recently
    /// used. (Modification date is reliably writable; access date is not.)
    private func touchAccess(_ url: URL) {
        var u = url
        var vals = URLResourceValues()
        vals.contentModificationDate = Date()
        try? u.setResourceValues(vals)
    }

    /// Which of these remote URL strings have a cached download (new App Support store or an
    /// un-migrated legacy Documents copy). One directory listing + an in-memory filename test
    /// per URL — replaces the per-row `getCachedUrl` (`fileExists` + MD5 + legacy migration)
    /// that ran in every `EpisodeRowView.onAppear` and janked the main thread while scrolling.
    /// Call once (e.g. on a detail view's appear / after a feed load), not per row.
    func downloadedUrlStrings(among urlStrings: [String]) -> Set<String> {
        let newNames = Set((try? fm.contentsOfDirectory(atPath: cacheDir.path)) ?? [])
        let legacyNames: Set<String> = {
            guard let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
                  let names = try? fm.contentsOfDirectory(atPath: docDir.path) else { return [] }
            return Set(names)
        }()
        var result = Set<String>()
        for s in urlStrings {
            guard let url = URL(string: s) else { continue }
            let name = filename(for: url)
            if newNames.contains(name) || legacyNames.contains(name) { result.insert(s) }
        }
        return result
    }

    func deleteCachedEpisode(for url: URL) {
        if let new = getLocalUrl(for: url), fm.fileExists(atPath: new.path) {
            try? fm.removeItem(at: new)
        }
        // Also clear any un-migrated legacy copy.
        if let old = legacyUrl(for: url), fm.fileExists(atPath: old.path) {
            try? fm.removeItem(at: old)
        }
    }

    /// A cache entry as seen by the (pure, testable) eviction planner.
    struct CacheFile: Equatable {
        let url: URL
        let size: UInt64
        let recency: Date   // most-recent of access/modification date
    }

    /// Which files to evict to bring `files` back under `maxBytes`, least-recently-used first.
    /// Pure + static so the eviction policy is unit-tested without touching the filesystem.
    static func evictionPlan(files: [CacheFile], maxBytes: UInt64) -> [URL] {
        let total = files.reduce(UInt64(0)) { $0 + $1.size }
        guard total > maxBytes else { return [] }
        var running = total
        var toRemove: [URL] = []
        for f in files.sorted(by: { $0.recency < $1.recency }) {
            if running <= maxBytes { break }
            toRemove.append(f.url)
            running = running >= f.size ? running - f.size : 0
        }
        return toRemove
    }

    /// Evict least-recently-used files until the cache is back under `maxCacheBytes`. Recency is
    /// the more recent of access/modification date, so an episode you re-play (which `touchAccess`
    /// bumps) is protected even though it was downloaded long ago.
    private func enforceCacheLimit() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: Array(keys)) else { return }

        var files: [CacheFile] = []
        for u in items {
            guard let vals = try? u.resourceValues(forKeys: keys), vals.isRegularFile == true else { continue }
            let size = UInt64(vals.fileSize ?? 0)
            let accessed = vals.contentAccessDate ?? .distantPast
            let modified = vals.contentModificationDate ?? .distantPast
            files.append(CacheFile(url: u, size: size, recency: max(accessed, modified)))
        }

        for url in Self.evictionPlan(files: files, maxBytes: maxCacheBytes) {
            try? fm.removeItem(at: url)
        }
    }
}
