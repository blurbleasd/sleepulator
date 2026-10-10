import Foundation

/// What the Podcasts tab offers at the top: pick up the episode you drifted off in, and the next
/// one from that show. Built from the "Last Night" snapshot (`SavedMix.podcastId` +
/// `podcastPosition`), saved positions, and the library, so it needs no new tracking.
nonisolated struct TonightPlan: Equatable {
    struct Resume: Equatable {
        let episode: Episode
        let podcast: Podcast
        let position: TimeInterval
        let remaining: TimeInterval?
    }
    struct Next: Equatable {
        let episode: Episode
        let podcast: Podcast
    }
    var resume: Resume?
    var next: Next?
    var isEmpty: Bool { resume == nil && next == nil }
}

/// Pure rules behind the Tonight shelf and the show page's Resume button. Unit-tested in
/// `TonightShelfTests`.
nonisolated enum TonightShelf {
    /// Below this the episode was cued, not listened to (the queue advanced overnight), so it's
    /// offered as "next", not "resume".
    static let minimumResumePosition: TimeInterval = 30
    /// Within this of the end, an episode is done in all but name (an end-of-episode timer can
    /// stop it a moment short of being marked finished): neither resumed nor offered next.
    static let nearEndMargin: TimeInterval = 30
    /// "Back 5 min": where you last remember it, not where you fell asleep.
    static let backUpInterval: TimeInterval = 300
    static var backUpLabel: String { "Back \(Int(backUpInterval / 60)) min" }
    static var backUpSpokenLabel: String { "Resume \(Int(backUpInterval / 60)) minutes earlier" }

    static func plan(library: [Podcast], lastEpisodeId: String?, lastPosition: TimeInterval?,
                     savedPositions: [String: Double], finished: Set<String>) -> TonightPlan {
        guard let id = lastEpisodeId,
              let podcast = library.first(where: { show in show.episodes.contains(where: { $0.id == id }) }),
              let episode = podcast.episodes.first(where: { $0.id == id }) else { return TonightPlan() }

        var plan = TonightPlan()
        var spent = finished.contains(id)
        if !spent {
            let position = resumePosition(savedPositions[id], snapshot: lastPosition)
            if isResumable(position: position, duration: episode.duration) {
                plan.resume = .init(episode: episode, podcast: podcast, position: position,
                                    remaining: remaining(duration: episode.duration, position: position))
            } else if position < minimumResumePosition {
                plan.next = .init(episode: episode, podcast: podcast)
            } else {
                spent = true   // stopped within seconds of the end
            }
        }
        if plan.next == nil,
           let next = latestUnplayed(in: podcast, finished: finished, excluding: plan.resume?.episode.id ?? (spent ? id : nil)) {
            plan.next = .init(episode: next, podcast: podcast)
        }
        return plan
    }

    /// Under way, and not so close to the end that resuming would play a few seconds and stop.
    static func isResumable(position: TimeInterval, duration: TimeInterval?) -> Bool {
        guard position >= minimumResumePosition else { return false }
        if let duration, duration > 0, position >= duration - nearEndMargin { return false }
        return true
    }

    static func backUpPosition(from position: TimeInterval) -> TimeInterval {
        max(0, position - backUpInterval)
    }

    static func remaining(duration: TimeInterval?, position: TimeInterval) -> TimeInterval? {
        guard let duration, duration > 0 else { return nil }
        return max(0, duration - position)
    }

    /// The show page's Resume target: last night's episode when it's from this show and under
    /// way, else the newest episode you're partway through.
    static func showResumeTarget(podcast: Podcast, lastEpisodeId: String?, lastPosition: TimeInterval?,
                                 savedPositions: [String: Double],
                                 finished: Set<String>) -> (episode: Episode, position: TimeInterval)? {
        if let id = lastEpisodeId, !finished.contains(id),
           let episode = podcast.episodes.first(where: { $0.id == id }) {
            let position = resumePosition(savedPositions[id], snapshot: lastPosition)
            if isResumable(position: position, duration: episode.duration) { return (episode, position) }
        }
        let inProgress = podcast.episodes.filter { ep in
            guard !finished.contains(ep.id), let position = savedPositions[ep.id] else { return false }
            return isResumable(position: position, duration: ep.duration)
        }
        guard let target = newest(inProgress), let position = savedPositions[target.id] else { return nil }
        return (target, position)
    }

    /// The newest episode you haven't finished, other than `excluding`.
    static func latestUnplayed(in podcast: Podcast, finished: Set<String>, excluding: String?) -> Episode? {
        newest(podcast.episodes.filter { !finished.contains($0.id) && $0.id != excluding })
    }

    // MARK: - Helpers

    /// The saved-positions map wins: it's written on every pause and every 30 s of play. The
    /// Last Night snapshot is only rewritten on pause-all, stop and backgrounding, so after a
    /// podcast-only pause (mini-player, lock screen, AirPods) it can be hours behind.
    private static func resumePosition(_ saved: Double?, snapshot: TimeInterval?) -> TimeInterval {
        if let saved, saved > 0 { return saved }
        return snapshot ?? 0
    }

    /// Newest by publish date in one pass; undated episodes rank after dated ones and feed order
    /// breaks ties (feeds list newest first).
    private static func newest(_ episodes: [Episode]) -> Episode? {
        var best: Episode? = nil
        for ep in episodes {
            guard let current = best else { best = ep; continue }
            switch (ep.pubDate, current.pubDate) {
            case let (a?, b?) where a > b: best = ep
            case (.some, nil): best = ep
            default: break
            }
        }
        return best
    }
}
