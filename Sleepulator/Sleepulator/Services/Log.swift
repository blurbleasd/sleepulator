import os
import OSLog
import AVFoundation

/// Centralized loggers. Replaces scattered `print()` calls so diagnostics are categorized,
/// queryable in Console.app, and dropped from release output by the unified logging system
/// (instead of printing on the audio/network paths all night).
enum Log {
    /// Internal (not private) so `LogExport` can filter the store to just this app's entries.
    static let subsystem = "app.sleepulator"
    static let audio   = Logger(subsystem: subsystem, category: "audio")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let network = Logger(subsystem: subsystem, category: "network")
    /// The overnight trail: sleep-timer start/bump/fade/terminal-stop plus the session events
    /// (interruption, route change, limiter attach) that explain a silent bed at 3 a.m. Kept in
    /// its own category so "export last night's log" reads as a coherent timeline.
    static let timer   = Logger(subsystem: subsystem, category: "timer")
    /// Ambient scene / Metal shader diagnostics — e.g. a stitchable shader missing from the
    /// compiled metallib (which would otherwise render a silent black backdrop). See `MetalShaders`.
    static let scene   = Logger(subsystem: subsystem, category: "scene")

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

/// Pulls this app's recent log entries out of the unified logging store for the in-app
/// "Export logs" button — the bedside way to retrieve the overnight trail when the phone isn't
/// tethered to Console.app. Uses `.currentProcessIdentifier` scope: an all-night session keeps
/// one process alive (background audio), so this captures the whole night since launch.
enum LogExport {
    /// Collect the last `hours` of this app's log lines as plain text, newest-friendly order.
    /// Runs the store scan off the main thread (it can be slow); returns a user-shareable string.
    static func collect(hours: Double = 12) async -> String {
        await Task.detached(priority: .utility) {
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
                    lines.append("\(fmt.string(from: e.date)) [\(e.category)] \(e.composedMessage)")
                }
                if lines.isEmpty {
                    return "No Sleepulator log entries in the last \(Int(hours))h."
                }
                let header = "Sleepulator log — last \(Int(hours))h, \(lines.count) entries\n"
                return header + lines.joined(separator: "\n")
            } catch {
                return "Could not read logs: \(error.localizedDescription)"
            }
        }.value
    }
}
