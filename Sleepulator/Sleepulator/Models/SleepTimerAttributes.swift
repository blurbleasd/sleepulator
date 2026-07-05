import Foundation
import AppIntents
#if canImport(ActivityKit)
import ActivityKit

public struct SleepTimerAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var timerRemaining: TimeInterval
        var endDate: Date?
        /// When true the timer ends with the current episode (not a fixed duration), so the
        /// Live Activity hides the "+15m" button — you can't extend an episode.
        var isEndOfEpisode: Bool = false
    }

    public init() {}
}

/// Focus-mode Pomodoro Live Activity — the phase ring you actually glance at. Shared with the
/// widget target the same way as SleepTimerAttributes (this file is in both memberships).
public struct PomodoroAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var isWork: Bool
        var isLongBreak: Bool
        /// The current phase's end — ActivityKit renders the countdown from this for free.
        var endDate: Date?
        var cycle: Int
        var totalCycles: Int
    }

    public init() {}
}
#endif

// MARK: - Live Activity intents (shared app + widget target)
//
// LiveActivityIntent runs in the APP's process (waking it in the background if needed), so these
// can drive the running engine. They stay decoupled by posting the same NotificationCenter
// names AudioEngine already listens for — no direct reference to the engine from the widget.

@available(iOS 17.0, *)
struct BumpSleepTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Add 15 Minutes"
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("BumpSleepulatorTimer"), object: nil)
        return .result()
    }
}

@available(iOS 17.0, *)
struct StopSleepTimerIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop"
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("StopSleepulatorTimer"), object: nil)
        return .result()
    }
}
