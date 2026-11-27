import Foundation
import os

// The playback log's files: every `Log` line is also appended to a rolling file in Application
// Support/Sleepulator/logs (excluded from iCloud and computer backups), so a failure at 3 a.m. is
// still there after a relaunch. The unified log only gives a process its own lines, and reading
// last night's took a cable, `devicectl` and `sudo log collect` (2026-11-13).
//
//   Log.audio.error(…) ── caller's thread: the line is built, then handed over ──┐
//                          (a lock held for an array append; never a write)      │
//                                                                                v
//   LogFile.pending (bounded: past `maxPending` lines are counted, not kept) ──> queue (utility):
//       scrub URLs (NightRules.scrub) ──> playback-2026-11-27.log  (a day per file, a new part
//                                          past 256 KB; files past 3 days or 1 MB in all go)
//
// Never from the audio render block or the podcast tap: building a line allocates. Nothing there
// logs today (checked 2026-11-27); keep it that way.

/// How the files roll: a file per day, a new part past the size cap, and the oldest dropped past
/// the age or the total cap. Pure, so the tests pin it.
nonisolated enum LogRetention {
    struct Limits: Equatable, Sendable {
        var maxFileBytes: Int
        var maxTotalBytes: Int
        var maxAge: TimeInterval
        /// Lines waiting for the writer; past this they're counted and dropped (a runaway logger
        /// must not grow memory all night).
        var maxPending: Int

        /// A night logs tens of KB (event-level lines, plus a scene line every 30 s while a scene
        /// is on screen), so 1 MB holds the 3 days with room, and fits Send feedback's 2 MB.
        static let standard = Limits(maxFileBytes: 256 * 1024, maxTotalBytes: 1024 * 1024,
                                     maxAge: 3 * 24 * 3600, maxPending: 500)
    }

    struct FileInfo: Equatable {
        let name: String
        let bytes: Int
        let modified: Date
    }

    static let prefix = "playback-"
    static let pathExtension = "log"

    /// "playback-2026-11-27.log", then "playback-2026-11-27.2.log" for the day's second part.
    static func name(day: String, part: Int) -> String {
        part <= 1 ? "\(prefix)\(day).\(pathExtension)" : "\(prefix)\(day).\(part).\(pathExtension)"
    }

    /// The day and part a file's name carries; nil for anything that isn't one of the log's files.
    static func parse(_ name: String) -> (day: String, part: Int)? {
        guard name.hasPrefix(prefix), name.hasSuffix("." + pathExtension) else { return nil }
        let pieces = name.dropFirst(prefix.count).dropLast(pathExtension.count + 1).split(separator: ".")
        guard let day = pieces.first, day.count == 10 else { return nil }
        switch pieces.count {
        case 1: return (String(day), 1)
        case 2:
            guard let part = Int(pieces[1]), part > 1 else { return nil }
            return (String(day), part)
        default: return nil
        }
    }

    /// The file `adding` bytes for `day` go to: the day's newest part while it has room (or is
    /// empty: one batch bigger than the cap still lands somewhere), else the next part.
    static func target(day: String, existing: [FileInfo], adding: Int, limits: Limits) -> String {
        let parts = existing.compactMap { f -> (part: Int, file: FileInfo)? in
            guard let p = parse(f.name), p.day == day else { return nil }
            return (p.part, f)
        }
        guard let newest = parts.max(by: { $0.part < $1.part }) else { return name(day: day, part: 1) }
        if newest.file.bytes == 0 || newest.file.bytes + adding <= limits.maxFileBytes {
            return newest.file.name
        }
        return name(day: day, part: newest.part + 1)
    }

    /// The files to delete, oldest first: any past the age, and the oldest while the total is
    /// over its cap. Never `keep` (the file being written), nor a file that isn't the log's.
    static func expired(_ files: [FileInfo], now: Date, keep: String?, limits: Limits) -> [String] {
        let ours = files.filter { parse($0.name) != nil }
            .sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
        var total = ours.reduce(0) { $0 + $1.bytes }
        var out: [String] = []
        for f in ours where f.name != keep {
            if now.timeIntervalSince(f.modified) > limits.maxAge || total > limits.maxTotalBytes {
                out.append(f.name)
                total -= f.bytes
            }
        }
        return out
    }
}

/// The writer. `append` is called from any thread and never waits on the disk; the files are
/// written on one serial utility queue, best effort. A failed write is reported once through a
/// plain `Logger`, never through `Log` (that would feed the failure back into this writer).
nonisolated final class LogFile: @unchecked Sendable {
    /// The app's log. Inside a unit-test host or a UI test run, a throwaway folder, as the night
    /// journal's (`NightJournal.makeDefault`): a test run's lines never reach the phone's log.
    static let shared = LogFile(directory: defaultDirectory())

    struct Entry: Sendable {
        let at: Date
        let category: String
        let level: LogLevel
        let text: String
    }

    private struct Pending: Sendable {
        var entries: [Entry] = []
        var dropped = 0
        var scheduled = false
    }

    let directory: URL
    let limits: LogRetention.Limits
    private let now: @Sendable () -> Date
    private let pending = OSAllocatedUnfairLock(initialState: Pending())
    private let queue = DispatchQueue(label: "app.sleepulator.logfile", qos: .utility)
    private static let failureLog = Logger(subsystem: Log.subsystem, category: "storage")

    // Writer state, touched only on `queue`.
    private var prepared = false
    private var lastTarget: String?
    private var reportedFailure = false
    /// Used only on `queue` (a DateFormatter isn't thread-safe).
    private let stampFormatter: DateFormatter
    private let dayFormatter: DateFormatter

    /// `calendar` names the days and stamps the lines (local time); `now` stamps them and ages the
    /// files. Tests pass a temp folder, small limits and their own clock.
    init(directory: URL, limits: LogRetention.Limits = .standard, calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.limits = limits
        self.now = now
        stampFormatter = Self.formatter("yyyy-MM-dd HH:mm:ss.SSS", calendar: calendar)
        dayFormatter = Self.formatter("yyyy-MM-dd", calendar: calendar)
    }
    // No isolated deinit to guard against (CLAUDE.md "Isolated deinits"): the class is
    // `nonisolated`, so the tests can create and free it.

    static func defaultDirectory() -> URL {
        if AppInfo.isUnitTestHost || AppInfo.isUITestRun {
            return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("sleepulator-test-logs", isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("Sleepulator/logs", isDirectory: true)
    }

    /// Hand a line to the writer. Cheap and non-blocking: a short lock around an array append,
    /// and a hop to the writer queue for the first line of a batch.
    func append(_ level: LogLevel, category: String, _ text: String) {
        let entry = Entry(at: now(), category: category, level: level, text: text)
        let max = limits.maxPending
        let schedule = pending.withLock { p -> Bool in
            guard p.entries.count < max else {
                p.dropped += 1
                return false
            }
            p.entries.append(entry)
            if p.scheduled { return false }
            p.scheduled = true
            return true
        }
        if schedule { queue.async { self.drain() } }
    }

    /// Wait for the lines handed over so far to reach the file (the export, Send feedback, tests).
    /// Never from the writer queue.
    func flush() {
        queue.sync { drain() }
    }

    /// The log's files, oldest first.
    func files() -> [URL] {
        fileInfos().sorted { ($0.modified, $0.name) < ($1.modified, $1.name) }
            .map { directory.appendingPathComponent($0.name) }
    }

    /// Every kept line, oldest first, after the queued ones land; nil when there are none.
    func exportText() -> String? {
        flush()
        let text = files().compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        return text.isEmpty ? nil : text
    }

    // MARK: Writer (on `queue`)

    private func drain() {
        let (entries, dropped) = pending.withLock { p -> ([Entry], Int) in
            let taken = (p.entries, p.dropped)
            p = Pending()
            return taken
        }
        guard !entries.isEmpty || dropped > 0 else { return }
        var text = ""
        for e in entries { text += line(e) }
        if dropped > 0 {
            text += line(Entry(at: now(), category: "log", level: .notice,
                               text: "\(dropped) line\(dropped == 1 ? "" : "s") dropped: the log fell behind"))
        }
        write(text, day: dayFormatter.string(from: entries.first?.at ?? now()))
    }

    /// "2026-11-27 03:12:45.123 [audio] error: podcast stream lost …", one line per entry, with
    /// anything shaped like a URL scrubbed (private feeds keep a subscriber's secret in theirs).
    private func line(_ e: Entry) -> String {
        let text = NightRules.scrub(e.text).replacingOccurrences(of: "\n", with: " ")
        return "\(stampFormatter.string(from: e.at)) [\(e.category)] \(e.level.rawValue): \(text)\n"
    }

    private func write(_ text: String, day: String) {
        let data = Data(text.utf8)
        do {
            if !prepared {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var dir = directory
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? dir.setResourceValues(values)
                prepared = true
            }
            let name = LogRetention.target(day: day, existing: fileInfos(), adding: data.count, limits: limits)
            try Self.append(data, to: directory.appendingPathComponent(name))
            // On a new file (a launch, a new day, a new part): drop what's past the age or the cap.
            if name != lastTarget {
                lastTarget = name
                for old in LogRetention.expired(fileInfos(), now: now(), keep: name, limits: limits) {
                    try? FileManager.default.removeItem(at: directory.appendingPathComponent(old))
                }
            }
        } catch {
            guard !reportedFailure else { return }
            reportedFailure = true
            Self.failureLog.error("playback log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// A plain FileHandle append: a line written survives the app being killed.
    private static func append(_ data: Data, to url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            try data.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func fileInfos() -> [LogRetention.FileInfo] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys,
                                                                 options: .skipsHiddenFiles)) ?? []
        return urls.compactMap { url in
            guard LogRetention.parse(url.lastPathComponent) != nil else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LogRetention.FileInfo(name: url.lastPathComponent, bytes: values?.fileSize ?? 0,
                                         modified: values?.contentModificationDate ?? .distantPast)
        }
    }

    private static func formatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    // MARK: Tests

    /// Hold the writer, so lines pile up in `pending` (the bound's test). Internal for the tests.
    func suspendWriter() { queue.suspend() }
    func resumeWriter() { queue.resume() }
}
