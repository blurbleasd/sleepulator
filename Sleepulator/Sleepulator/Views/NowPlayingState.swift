import Foundation

/// What the player views (mini-player and Now Playing) show, resolved from ONE source: the episode
/// the player is actually on. The queue can move on without it (a failure with Auto-Play off, the
/// sleep-aware hold, a removal while it plays), so "now playing" is never read off the queue head.
/// The sheet used to take its artwork from the head, its title from the player and Up Next from
/// `dropFirst()`, and after a failure the three disagreed and the real next episode vanished.
/// Pure and `nonisolated` (like the models), so the tests can pin it off the main actor.
nonisolated struct NowPlayingState {
    /// The episode the player leads with: the loaded one, or with nothing loaded, the queue's
    /// head, ready to play.
    let hero: Episode?
    /// Whether `hero` is loaded in the player (vs. waiting at the head of the queue).
    let isLoaded: Bool
    /// Everything queued after the hero, in queue order. Never contains the hero.
    let upNext: [Episode]

    init(loaded: Episode?, queue: [Episode]) {
        if let loaded {
            hero = loaded
            isLoaded = true
            upNext = queue.filter { $0.id != loaded.id }
        } else {
            hero = queue.first
            isLoaded = false
            upNext = Array(queue.dropFirst())
        }
    }

    /// Where playback stands, for the status line and the transport.
    enum Phase: Equatable {
        /// Nothing loaded; the hero waits at the head of the queue.
        case ready
        /// A load is in flight, or it's playing and the player hasn't reported a position yet.
        case loading
        /// The episode wouldn't play.
        case failed
        /// A stream with no end: playing, a clock but no duration.
        case live
        case playing
        case paused
        /// Paused at the end of the episode.
        case finished
    }

    /// `loading`: a load is in flight (set by the engine at load, cleared by the player's first
    /// play/pause report or a failure). `elapsed` / `duration` are the player's last report; a
    /// duration of 0 means none yet, or a live stream once the clock moves.
    ///
    /// Paused without a known length is `.paused`, never `.loading`: a call or AirPods coming out
    /// before the first report used to leave a disabled spinner where Play should be.
    static func phase(isLoaded: Bool, failed: Bool, loading: Bool, isPlaying: Bool,
                      elapsed: Double, duration: Double) -> Phase {
        guard isLoaded else { return .ready }
        if failed { return .failed }
        if loading { return .loading }
        guard duration > 0 else {
            guard isPlaying else { return .paused }
            return elapsed > 0 ? .live : .loading
        }
        if isPlaying { return .playing }
        return duration - elapsed < 1.5 ? .finished : .paused
    }

    /// Whether the scrubber and the skips can act: the player is somewhere in an episode of known
    /// length. (Not while loading or failed, when a skip landed on the previous item.)
    static func canSeek(_ phase: Phase, duration: Double) -> Bool {
        [.playing, .paused, .finished].contains(phase) && duration > 0
    }

    /// Whether the relative skips (back/forward 15) can act: the player has an item and a
    /// position, length known or not. Live streams keep them (only the scrubber needs a length).
    static func canSkip(_ phase: Phase) -> Bool {
        [.playing, .paused, .finished, .live].contains(phase)
    }

    /// The one wording for a failed episode (engine note, mini-player, full player).
    static let failedCopy = "Couldn't play this episode"
}

/// Playback times as people read and hear them. `75:00` reads as a clock time; past an hour the
/// labels show hours (1:16:47), and VoiceOver hears words rather than digits. Every input is
/// clamped before it meets `Int`: a speed or duration from a restored backup or a bad feed
/// (1e300) would otherwise trap the conversion and crash the player on open.
nonisolated enum PlayerClock {
    /// Longest span shown: 999 hours. Anything past it is a bad value, not an episode.
    private static let ceiling: Double = 999 * 3600

    private static func clamped(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(0, seconds), ceiling) : 0
    }

    /// "4:05", "1:16:47". Negative or non-finite input reads as 0:00.
    static func string(_ seconds: Double) -> String {
        let total = Int(clamped(seconds).rounded(.down))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1×", "1.2×": the multiplication sign, and no trailing ".0".
    static func speedLabel(_ speed: Double) -> String {
        // Typed: inside the variadic String(format:) a bare `1` became an Int, which "%.1f" misreads.
        let value: Double = speed.isFinite ? min(max(0, speed), 100) : 1
        let text = String(format: "%.1f", value)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "\u{00D7}"
    }

    /// "1 hr 16 min", "45 min", "2 hr": a length at a glance, to the nearest minute (never "0 min").
    /// The player's one short style for durations. `roundingUp` is for countdowns, which must never
    /// claim less than is left (the night line).
    static func short(_ seconds: Double, roundingUp: Bool = false) -> String {
        let minutes = clamped(seconds) / 60
        let mins = max(1, Int(roundingUp ? minutes.rounded(.up) : minutes.rounded()))
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// "1 hour, 16 minutes": minutes are the useful grain when listening; seconds only under one.
    /// A value-type format style, so the scrubber's accessibility value costs no formatter
    /// allocation on each render.
    static func spoken(_ seconds: Double) -> String {
        let total = clamped(seconds)
        if total < 60 {
            return Duration.seconds(Int64(total)).formatted(.units(allowed: [.seconds], width: .wide))
        }
        return Duration.seconds(Int64(total)).formatted(
            .units(allowed: [.hours, .minutes], width: .wide, zeroValueUnits: .hide))
    }
}

/// The Sleep player's one line on how tonight ends for this episode (NowPlayingSheet's night
/// line): whether the timer cuts the story off, or the story ends first. Pure so the tests can pin
/// every case.
nonisolated enum NightLineCopy {
    /// - `timerRemaining`: seconds left on the sleep timer; 0 when none runs.
    /// - `endOfEpisode`: the timer follows this episode.
    /// - `inTail`: the podcast has stopped and the sounds are fading out.
    /// - `episodeRemaining`: wall-clock seconds to the episode's end (speed-scaled); nil when it
    ///   isn't known (a live stream, or before the player reports a length).
    /// - `tailMinutes`: the "keep sounds going" setting.
    static func line(timerRemaining: Double, endOfEpisode: Bool, inTail: Bool,
                     episodeRemaining: Double?, tailMinutes: Int) -> String {
        if inTail { return "Sounds fading · \(span(timerRemaining)) left" }
        guard timerRemaining > 0 else { return "Plays all night" }
        if endOfEpisode {
            let after = tailMinutes > 0 ? " · sounds go on \(tailMinutes) min" : ""
            return "Stops with this episode · in \(span(timerRemaining))" + after
        }
        guard let episode = episodeRemaining else { return "Timer ends in \(span(timerRemaining))" }
        let gap = episode - timerRemaining
        // Within a minute either way, they end together as far as anyone in bed can tell.
        if abs(gap) < 60 { return "Timer ends with this episode · in \(span(timerRemaining))" }
        if gap > 0 { return "Timer ends in \(span(timerRemaining)) · \(span(gap)) before this episode does" }
        return "This episode ends \(span(-gap)) before the timer"
    }

    /// "38 min", "1 hr 12 min", "2 hr". Rounded up: a countdown never claims less than is left.
    static func span(_ seconds: Double) -> String {
        PlayerClock.short(seconds, roundingUp: true)
    }
}
