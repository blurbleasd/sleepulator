import Foundation

/// Pure rules for the moments where one half-asleep tap could cost the night: a mode switch that
/// would end or reshape a live session, a timer committed over silence, the night veil dropping
/// over nothing. Kept free of SwiftUI state so the unit tests can pin them (like
/// `HomeScreensaverPolicy`).
enum SessionGuards {
    struct ModeSwitchWarning: Equatable {
        let title: String
        let message: String
        let confirm: String
        let cancel: String
    }

    /// The confirm to show before switching mode, or nil to switch straight away. Sleep → Focus
    /// warns whenever a sleep session is live: the switch cancels the sleep timer, swaps the bed
    /// into the Focus palette and (when the limiter follows the mode) drops the limiter, so a
    /// stray tap at 2am would quietly end the night. Focus → Sleep only warns over a running
    /// Pomodoro, which the switch stops; moving toward Sleep is otherwise the natural direction.
    static func modeSwitchWarning(toFocus: Bool,
                                  sleepTimerActive: Bool,
                                  sleepSoundsPlaying: Bool,
                                  pomodoroRunning: Bool) -> ModeSwitchWarning? {
        if toFocus {
            guard sleepTimerActive || sleepSoundsPlaying else { return nil }
            return ModeSwitchWarning(
                title: "Switch to Focus?",
                message: sleepTimerActive
                    ? "Your sleep timer stops and your sounds change to the Focus set."
                    : "Your sounds change to the Focus set.",
                confirm: "Switch to Focus",
                cancel: "Stay in Sleep")
        }
        guard pomodoroRunning else { return nil }
        return ModeSwitchWarning(
            title: "Switch to Sleep?",
            message: "Your focus session ends.",
            confirm: "Switch to Sleep",
            cancel: "Stay in Focus")
    }

    /// The night veil drops only over a sleep session that is actually playing. A countdown over
    /// silence (timer running, everything paused) used to blank the screen on nothing.
    static func mayNightDim(autoNightDim: Bool, focusMode: Bool, timerActive: Bool, playing: Bool) -> Bool {
        autoNightDim && !focusMode && timerActive && playing
    }

    /// Play in Sleep honours the night ring: the minutes to time, or nil for All night or when a
    /// countdown is already running (resuming from a pause keeps the night you set).
    static func timerOnPlay(lengthMinutes: Double, timerActive: Bool) -> Int? {
        guard !timerActive, lengthMinutes >= 5 else { return nil }
        return Int(lengthMinutes)
    }

    /// The timer sheet's commit button. With nothing playing it starts the mix as well, so the
    /// timer can never be set against silence.
    static func timerCommitTitle(playing: Bool, timerActive: Bool) -> String {
        if !playing { return "Play & start timer" }
        return timerActive ? "Restart timer" : "Start timer"
    }
}
