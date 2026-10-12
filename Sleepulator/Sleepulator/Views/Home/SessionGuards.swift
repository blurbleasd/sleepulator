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

    /// The night veil drops over a Sleep session that is actually playing: everywhere while a
    /// timer runs, and on the bedside screens (Home, or the Now Playing sheet) for an untimed (All
    /// night) night. A countdown
    /// over silence (timer running, everything paused) used to blank the screen on nothing. It
    /// used to need a timer, so All night, the default, never got the veil and the scene showed at
    /// bedtime brightness until auto-lock; on any tab it would black out daytime listening in
    /// Sleep mode (reading show notes in Podcasts).
    static func mayNightDim(autoNightDim: Bool, focusMode: Bool, playing: Bool,
                            timerActive: Bool, onBedsideScreen: Bool) -> Bool {
        autoNightDim && !focusMode && playing && (timerActive || onBedsideScreen)
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

    enum VeilTimeout: Equatable { case drop, wait, stand, closeNowPlaying }

    /// The 3am glance's timing: it shows for `glanceHold`, then fades over `glanceFade`.
    static let glanceHold: TimeInterval = 6
    static let glanceFade: TimeInterval = 2
    /// A second tap this soon after the first is the same reach for the phone, not a request to
    /// wake: it would skip the glance while it's still arriving.
    static let glanceSettle: TimeInterval = 0.8

    enum VeilTap: Equatable { case glance, wake, ignore }

    /// What a tap on the veil does. The first shows the glance (the ember and the night line on
    /// black); a tap while the glance shows or is still fading wakes the scene and the controls.
    /// VoiceOver and Switch Control wake in one step: the veil's label already says what it is,
    /// and they never needed the light. `sinceGlance` is nil when no glance has shown this veil.
    static func veilTap(sinceGlance: TimeInterval?, assistiveTech: Bool) -> VeilTap {
        if assistiveTech { return .wake }
        // Negative only if the clock behind it stepped back: treat it as a stale glance.
        guard let t = sinceGlance, t >= 0, t < glanceHold + glanceFade else { return .glance }
        return t < glanceSettle ? .ignore : .wake
    }

    /// What the veil's countdown does when it runs out (~60 s after the last touch). The veil is
    /// part of the root view, so a sheet, dialog or full-screen cover sits above it: dropping it
    /// then left that presentation lit on a black screen (a red "Switch to Focus?" at 2am). It
    /// waits another round instead, which also spares the untouched breathing exercise.
    ///
    /// The exception is an idle Now Playing sheet: its artwork and transport are the brightest
    /// surface on the night screen, and with no touch for the veil's minute nobody is using it, so
    /// it closes and the veil drops (`.closeNowPlaying`).
    ///
    /// Never under VoiceOver or Switch Control: they navigate without the touches that restart
    /// the countdown, so the veil dropped every minute mid-navigation (the same reason Home's
    /// screensaver stands down for them, `HomeScreensaverPolicy.mayFade`).
    static func veilTimeout(mayDim: Bool, presenting: Bool, nowPlayingUp: Bool = false,
                            assistiveTech: Bool = false) -> VeilTimeout {
        guard mayDim, !assistiveTech else { return .stand }
        guard presenting else { return .drop }
        return nowPlayingUp ? .closeNowPlaying : .wait
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

// MARK: - The rating and tip asks (docs/designs/APP-STORE-LAUNCH-1.0.md: RP-1, TJ-1, NT-1;
// design D6, D10–D13)

extension SessionGuards {
    /// The asks land only in the day: from 09:00 to 20:00 local, the wind-down hour kept clear
    /// (design D11), and at least 2 hours after the last night ended.
    static let askOpensAtHour = 9
    static let askClosesAtHour = 20
    static let askAfterNight: TimeInterval = 2 * 3600
    static let ratingAfterCleanNights = 3
    static let tipCardAfterCleanNights = 5

    static func askWindowOpen(now: Date, lastNightEnd: Date?, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: now)
        guard hour >= askOpensAtHour, hour < askClosesAtHour else { return false }
        if let lastNightEnd, now.timeIntervalSince(lastNightEnd) < askAfterNight { return false }
        return true
    }

    /// Whether Apple's rating prompt may be requested now, at a natural break (a sheet just
    /// closed, or the person just left Settings; design D12). Either mode (design D10). Once per
    /// app version, never on a day the tip card showed.
    static func mayAskForRating(cleanNights: Int, askedThisVersion: Bool, tipCardShownToday: Bool,
                                playing: Bool, veilDown: Bool, now: Date, lastNightEnd: Date?,
                                calendar: Calendar = .current) -> Bool {
        guard cleanNights >= ratingAfterCleanNights, !askedThisVersion, !tipCardShownToday,
              !playing, !veilDown else { return false }
        return askWindowOpen(now: now, lastNightEnd: lastNightEnd, calendar: calendar)
    }

    /// Whether the tip card is due on Sleep Home. It waits (never lapses) while anything plays,
    /// outside the window, on a day the rating prompt was asked, until the tips can be bought,
    /// and in Focus (design D10). It ends only on an answer (`spent`, design D6) or a tip.
    static func tipCardDue(cleanNights: Int, tipped: Bool, spent: Bool, productsReady: Bool,
                           focusMode: Bool, playing: Bool, ratingAskedToday: Bool, now: Date,
                           lastNightEnd: Date?, calendar: Calendar = .current) -> Bool {
        guard cleanNights >= tipCardAfterCleanNights, !tipped, !spent, productsReady, !focusMode,
              !playing, !ratingAskedToday else { return false }
        return askWindowOpen(now: now, lastNightEnd: lastNightEnd, calendar: calendar)
    }
}
