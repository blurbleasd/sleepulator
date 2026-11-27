import os
import OSLog
import AVFoundation

/// Centralized loggers. Replaces scattered `print()` calls so diagnostics are categorized,
/// queryable in Console.app, and kept out of release output by the unified logging system
/// (instead of printing on the audio/network paths all night). Each line also goes to the
/// playback log's files (`LogFile`), so last night's trail survives a relaunch. Nonisolated:
/// loggers are written to from every thread (the storage queue, the audio threads), but never
/// from the render block or the podcast tap (building a line allocates).
nonisolated enum Log {
    /// Internal (not private) so `LogExport` can filter the store to just this app's entries.
    static let subsystem = "app.sleepulator"
    static let audio   = LogChannel("audio")
    static let storage = LogChannel("storage")
    static let network = LogChannel("network")
    /// The overnight trail: sleep-timer start/bump/fade/terminal-stop plus the session events
    /// (interruption, route change, limiter attach) that explain a silent bed at 3 a.m. Kept in
    /// its own category so "Export the playback log" reads as a coherent timeline.
    static let timer   = LogChannel("timer")
    /// Ambient scene / Metal shader diagnostics — e.g. a stitchable shader missing from the
    /// compiled metallib (which would otherwise render a silent black backdrop). See `MetalShaders`.
    static let scene   = LogChannel("scene")
    /// The app's own lifecycle: each launch, so a relaunch after a 3 a.m. death shows in the file.
    static let app     = LogChannel("app")

    /// Activate the shared audio session, logging (rather than silently swallowing) any failure.
    /// A lost activation race on a resume/interruption path is exactly how the bed goes silent at
    /// 3 a.m., so these failures get a breadcrumb in Console even though control flow is unchanged.
    /// `context` names the call site (e.g. "podcast resume", "interruption").
    @discardableResult
    static func activateAudioSession(_ context: String) -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            return true
        } catch {
            audio.error("AVAudioSession.setActive(true) failed [\(context, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}

nonisolated enum LogLevel: String, Sendable {
    case debug, info, notice, warning, error, fault

    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning, .error: return .error   // as `Logger.warning`
        case .fault: return .fault
        }
    }
}

/// One category's logger, with `Logger`'s calls and interpolation (`privacy: .public`), so the
/// call sites read as before. A line goes to the unified log, then to the playback log's files.
nonisolated struct LogChannel: Sendable {
    let category: String
    private let logger: Logger

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: Log.subsystem, category: category)
    }

    func debug(_ message: LogMessage)   { emit(.debug, message) }
    func info(_ message: LogMessage)    { emit(.info, message) }
    func notice(_ message: LogMessage)  { emit(.notice, message) }
    func warning(_ message: LogMessage) { emit(.warning, message) }
    func error(_ message: LogMessage)   { emit(.error, message) }
    func fault(_ message: LogMessage)   { emit(.fault, message) }

    private func emit(_ level: LogLevel, _ message: LogMessage) {
        // Private values are already "<private>" in the text, so the whole line is public here.
        logger.log(level: level.osLogType, "\(message.text, privacy: .public)")
        LogFile.shared.append(level, category: category, message.text)
    }
}

/// `privacy:` on a log interpolation, as `Logger`'s: a private value reads "<private>", in the
/// unified log and the files alike.
nonisolated enum LogPrivacy: Sendable {
    case `public`, `private`
}

/// A log line built from an interpolation, as `Logger`'s: strings and other values are private
/// unless marked `.public`; numbers and Bools are public (OSLog's `.auto`). Built eagerly, on the
/// caller's thread: fine for event-level lines, never in the render block or the tap.
nonisolated struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String

    init(stringLiteral value: String) { text = value }
    init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }

    struct StringInterpolation: StringInterpolationProtocol {
        var text = ""

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + 16 * interpolationCount)
        }

        mutating func appendLiteral(_ literal: String) { text += literal }

        mutating func appendInterpolation(_ value: String, privacy: LogPrivacy = .private) {
            add(value, privacy)
        }
        mutating func appendInterpolation(_ value: Bool, privacy: LogPrivacy = .public) {
            add(value ? "true" : "false", privacy)
        }
        mutating func appendInterpolation<T: BinaryInteger>(_ value: T, privacy: LogPrivacy = .public) {
            add(String(value), privacy)
        }
        mutating func appendInterpolation(_ value: Double, privacy: LogPrivacy = .public) {
            add(String(format: "%g", value), privacy)
        }
        mutating func appendInterpolation(_ value: Float, privacy: LogPrivacy = .public) {
            add(String(format: "%g", Double(value)), privacy)
        }
        mutating func appendInterpolation<T>(_ value: T, privacy: LogPrivacy = .private) {
            add(String(describing: value), privacy)
        }

        private mutating func add(_ value: String, _ privacy: LogPrivacy) {
            text += privacy == .public ? value : "<private>"
        }
    }
}

/// The in-app "Export the playback log": the playback log's files (the last 3 days, across
/// relaunches, web addresses removed). The process's own unified log is the fallback when the
/// files hold nothing (a write that failed), as it was the only source before.
nonisolated enum LogExport {
    static func collect() async -> String {
        await Task.detached(priority: .utility) {
            let zone = TimeZone.current
            let offset = zone.secondsFromGMT()
            let utc = String(format: "UTC%@%02d:%02d", offset < 0 ? "-" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
            let header = "Sleepulator playback log: up to the last 3 days on this iPhone, web addresses removed. "
                + "Times are local (\(zone.identifier), \(utc)).\n"
            if let text = LogFile.shared.exportText() {
                return header + text
            }
            return header + fromUnifiedLog(hours: 12)
        }.value
    }

    /// This process's lines from the unified log (`OSLogStore`, current process), scrubbed as the
    /// files are.
    private static func fromUnifiedLog(hours: Double) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let since = store.position(date: Date().addingTimeInterval(-hours * 3600))
            // Filter at the store (not in Swift): an all-night process logs a lot under its
            // PID across system frameworks, and materializing every composedMessage to discard
            // most would make the export scan seconds of entries.
            let predicate = NSPredicate(format: "subsystem == %@", Log.subsystem)
            let entries = try store.getEntries(at: since, matching: predicate)
            var lines: [String] = []
            for case let e as OSLogEntryLog in entries {
                lines.append("\(fmt.string(from: e.date)) [\(e.category)] \(NightRules.scrub(e.composedMessage))")
            }
            if lines.isEmpty {
                return "No Sleepulator log entries in the files, nor in the last \(Int(hours))h of this run."
            }
            return "The log's files were empty; this run's last \(Int(hours))h instead, \(lines.count) entries:\n"
                + lines.joined(separator: "\n")
        } catch {
            return "Could not read logs: \(error.localizedDescription)"
        }
    }
}
