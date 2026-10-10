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
        /// Loaded, but the player hasn't reported a position yet.
        case loading
        /// The episode wouldn't play.
        case failed
        /// A stream with no end: a clock but no duration.
        case live
        case playing
        case paused
        /// Paused at the end of the episode.
        case finished
    }

    /// `elapsed` / `duration` are the player's last report; a duration of 0 means none yet (or a
    /// live stream, once the clock moves).
    static func phase(isLoaded: Bool, failed: Bool, isPlaying: Bool,
                      elapsed: Double, duration: Double) -> Phase {
        guard isLoaded else { return .ready }
        if failed { return .failed }
        guard duration > 0 else { return elapsed > 0 ? .live : .loading }
        if isPlaying { return .playing }
        return duration - elapsed < 1.5 ? .finished : .paused
    }
}

/// Playback times as people read and hear them. `75:00` reads as a clock time; past an hour the
/// labels show hours (1:16:47), and VoiceOver hears words rather than digits.
nonisolated enum PlayerClock {
    /// "4:05", "1:16:47". Negative or non-finite input reads as 0:00.
    static func string(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "1×", "1.2×": the multiplication sign, and no trailing ".0".
    static func speedLabel(_ speed: Double) -> String {
        let s = speed == speed.rounded() ? String(Int(speed)) : String(format: "%.1f", speed)
        return s + "\u{00D7}"
    }

    /// "1 hr 16 min", "45 min", "2 hr": a length at a glance, to the nearest minute (never "0 min").
    /// The player's one short style for durations (Up Next totals, a waiting episode); the
    /// night line's countdowns share it (NightLineCopy.span, which rounds up).
    static func short(_ seconds: Double) -> String {
        let mins = max(1, Int(((seconds.isFinite ? max(0, seconds) : 0) / 60).rounded()))
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// "1 hour, 16 minutes": minutes are the useful grain when listening; seconds only under one.
    static func spoken(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, seconds) : 0
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.allowedUnits = total < 60 ? [.second] : [.hour, .minute]
        f.zeroFormattingBehavior = .dropAll
        let words = f.string(from: total < 60 ? total.rounded(.down) : total) ?? ""
        return words.isEmpty ? string(total) : words
    }
}
