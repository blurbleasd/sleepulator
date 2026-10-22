import Foundation

/// The night a scene shows, eased toward the timer's (`EasedNight.follow`), for scenes whose night
/// is in their structure (Fireflies' fireflies going out, Lamplight's snow thinning and footprints
/// filling), where a jump would add or remove things in one frame. A plain class mutated inside the
/// redraw, like `SceneClock`, and never observed: a published change would re-render the view on
/// every frame.
final class EasedNightFollower {
    private var shown: Double?
    private var last: TimeInterval?
    /// Whether the last read was drawn in sight (an animated frame, or the still frame with Moving
    /// scenes off), so the time since was watched.
    private var lastInSight = false
    /// When the scene was last read in sight (or first read): where the time no one has watched
    /// starts. Reads out of sight (Home re-evaluated on another tab, under the veil) don't move it, or
    /// they'd keep restarting `EasedNight.freshAfter`'s 30 minutes.
    private var lastSeen: TimeInterval?

    // Explicitly nonisolated: the implicit MainActor-isolated deinit aborts on iOS 18.4–26.3
    // runtimes (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}

    /// The night to draw at `now` (seconds), given the timer's, and whether this read is in sight.
    func night(_ target: Double, now: TimeInterval, inSight: Bool = true) -> Double {
        let dt = last.map { now - $0 } ?? 0
        let next = EasedNight.follow(shown: shown, target: target, dt: dt,
                                     watched: lastInSight && dt <= EasedNight.watchedGap,
                                     unseen: lastSeen.map { now - $0 } ?? 0)
        shown = next
        last = now
        lastInSight = inSight
        if inSight || lastSeen == nil { lastSeen = now }
        return next
    }
}

/// How fast a scene's shown night may follow the timer's. Pure, so it's unit-tested.
nonisolated enum EasedNight {
    /// The fastest the shown night may move back (things the night took away coming back), in nights
    /// per second: a whole night in two minutes. "Still awake? +15m" or a seek back moves the timer's
    /// night back at once, and what had gone would come back in one frame (a third of Fireflies'
    /// fireflies mid-flash).
    static let backRate = 1.0 / 120

    /// The fastest it may move on: a night in 30 s. A timer's night set with 30 s or more left moves
    /// no faster, so it's followed as it is; a "Stop after this episode" set with less can trail the
    /// stop by up to 30 s. A jump ahead (a seek) is eased over a few seconds.
    static let onRate = 1.0 / 30

    /// The most time a read after an unwatched gap may count toward moving back: half a second,
    /// `SceneClock`'s own step cap (a 2 fps hitch). After the screen was out of sight (locked, under
    /// the veil) the first read would otherwise count the whole gap, and a "+15m" on the lock screen
    /// would bring everything back in the first frame after unlocking. Going on, the gap counts in
    /// full: the night moved on while no one watched.
    static let maxBackStep = 0.5

    /// The longest gap between reads that were both in sight: the still frame (Moving scenes off)
    /// re-reads every `ShaderBackdrop.stillRereadInterval` (20 s, pinned under this by a test).
    /// Longer, or after a read out of sight, the gap wasn't watched.
    static let watchedGap = 21.0

    /// Unseen this long (since the last read in sight), a scene starts afresh, the night as it is: the
    /// night's own resume window (`UntimedNight.resumeWindow`, pinned by a test), past which it is
    /// over or a new one has begun, so the next bedtime opens as bedtime rather than easing back from
    /// last night's end.
    static let freshAfter: TimeInterval = 30 * 60

    /// The night to show after `dt` seconds, moving toward `target` no faster than `onRate` going on
    /// and `backRate` coming back, over the whole of `dt` if it was `watched` (both reads in sight)
    /// and at most `maxBackStep` of it if not. Nothing shown yet (the scene just appeared), or an
    /// unwatched read `unseen` `freshAfter` or more since the scene was last in sight (nil: `dt`):
    /// the night as it is.
    static func follow(shown: Double?, target: Double, dt: Double, watched: Bool = true,
                       unseen: Double? = nil) -> Double {
        let goal = clamped(target)
        guard let shown else { return goal }
        let elapsed = max(dt, 0)
        if !watched && (unseen ?? elapsed) >= freshAfter { return goal }
        if goal >= shown { return min(goal, shown + onRate * elapsed) }
        return max(goal, shown - backRate * (watched ? elapsed : min(elapsed, maxBackStep)))
    }

    /// A night in 0…1; NaN reads as bedtime.
    static func clamped(_ night: Double) -> Double {
        night.isFinite ? min(max(night, 0), 1) : 0
    }
}
