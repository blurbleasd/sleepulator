import os
import AVFoundation

/// Centralized loggers. Replaces scattered `print()` calls so diagnostics are categorized,
/// queryable in Console.app, and dropped from release output by the unified logging system
/// (instead of printing on the audio/network paths all night).
enum Log {
    private static let subsystem = "app.sleepulator"
    static let audio   = Logger(subsystem: subsystem, category: "audio")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let network = Logger(subsystem: subsystem, category: "network")

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
