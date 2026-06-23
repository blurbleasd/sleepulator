import os

/// Centralized loggers. Replaces scattered `print()` calls so diagnostics are categorized,
/// queryable in Console.app, and dropped from release output by the unified logging system
/// (instead of printing on the audio/network paths all night).
enum Log {
    private static let subsystem = "app.sleepulator"
    static let audio   = Logger(subsystem: subsystem, category: "audio")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let network = Logger(subsystem: subsystem, category: "network")
}
