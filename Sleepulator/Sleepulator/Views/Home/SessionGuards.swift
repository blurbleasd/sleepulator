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

    enum Begin: Equatable { case resume, firstBed, transport }

    /// What the orb starts from rest: the last mix if there is one, else (only before any session
    /// has started) the layered first bed, noise + binaural, so the first tap shows what the app
    /// does; else the transport's own resume. Its own flag, not the first-run tip's: dismissing
    /// the tip (touching the ring counts) used to cost the first bed, and play started bare Brown.
    static func begin(hasResumableMix: Bool, firstSessionStarted: Bool) -> Begin {
        if hasResumableMix { return .resume }
        return firstSessionStarted ? .transport : .firstBed
    }

    enum VeilTimeout: Equatable { case drop, wait, stand }

    /// What the veil's countdown does when it runs out (~60 s after the last touch). The veil is
    /// part of the root view, so a sheet, dialog or full-screen cover sits above it: dropping it
    /// then left that presentation lit on a black screen (a red "Switch to Focus?" at 2am). It
    /// waits another round instead, which also spares the untouched breathing exercise.
    static func veilTimeout(mayDim: Bool, presenting: Bool) -> VeilTimeout {
        guard mayDim else { return .stand }
        return presenting ? .wait : .drop
    }

    /// Whether the status bar and home indicator go: under the veil, and under the Sleep
    /// screensaver, where a white clock and battery were the brightest thing in a dark room all
    /// night. Focus's screensaver keeps them; it's the daytime desk, where the clock is useful.
    static func hidesSystemOverlays(nightDimmed: Bool, screensaver: Bool, focusMode: Bool) -> Bool {
        nightDimmed || (screensaver && !focusMode)
    }

    /// Play in Sleep honours the night ring: the minutes to time, or nil in Focus (the Pomodoro is
    /// its timer), for All night, or when a countdown is already running (resuming from a pause
    /// keeps the night you set). The stored length is sanitized: a restored backup could hold
    /// anything, and `Int` of a huge Double traps.
    static func timerOnPlay(focusMode: Bool, lengthMinutes: Double, timerActive: Bool) -> Int? {
        let length = NightRingMath.sanitized(lengthMinutes)
        guard !focusMode, !timerActive, length >= 5 else { return nil }
        return Int(length)
    }

    /// The timer sheet's commit button. With nothing playing it starts the mix as well, so the
    /// timer can never be set against silence.
    static func timerCommitTitle(playing: Bool, timerActive: Bool) -> String {
        if !playing { return "Play & start timer" }
        return timerActive ? "Restart timer" : "Start timer"
    }
}
