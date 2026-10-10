import Foundation

/// What the Podcasts tab offers at the top: pick up the episode you drifted off in, and the next
/// one from that show. Built from the "Last Night" snapshot (`SavedMix.podcastId` +
/// `podcastPosition`) and the library, so it needs no new tracking.
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
    /// "Back 5 min": where you last remember it, not where you fell asleep.
    static let backUpInterval: TimeInterval = 300

    static func plan(library: [Podcast], lastEpisodeId: String?, lastPosition: TimeInterval?,
                     savedPositions: [String: Double], finished: Set<String>) -> TonightPlan {
        guard let id = lastEpisodeId,
              let podcast = library.first(where: { show in show.episodes.contains(where: { $0.id == id }) }),
              let episode = podcast.episodes.first(where: { $0.id == id }) else { return TonightPlan() }

        var plan = TonightPlan()
        if !finished.contains(id) {
            let position = resumePosition(id: id, lastEpisodeId: id, lastPosition: lastPosition, savedPositions: savedPositions)
            if position >= minimumResumePosition {
                plan.resume = .init(episode: episode, podcast: podcast, position: position,
                                    remaining: remaining(duration: episode.duration, position: position))
            } else {
                plan.next = .init(episode: episode, podcast: podcast)
            }
        }
        if plan.next == nil, let next = latestUnplayed(in: podcast, finished: finished, excluding: plan.resume?.episode.id) {
            plan.next = .init(episode: next, podcast: podcast)
        }
        return plan
    }

    static func backUpPosition(from position: TimeInterval) -> TimeInterval {
        max(0, position - backUpInterval)
    }

    static func remaining(duration: TimeInterval?, position: TimeInterval) -> TimeInterval? {
        guard let duration, duration > 0 else { return nil }
        return max(0, duration - position)
    }

    /// The show page's Resume target: last night's episode when it's from this show and under
    /// way, else the newest episode you're partway through (not within 30 s of its end).
    static func showResumeTarget(podcast: Podcast, lastEpisodeId: String?, lastPosition: TimeInterval?,
                                 savedPositions: [String: Double],
                                 finished: Set<String>) -> (episode: Episode, position: TimeInterval)? {
        if let id = lastEpisodeId, !finished.contains(id),
           let episode = podcast.episodes.first(where: { $0.id == id }) {
            let position = resumePosition(id: id, lastEpisodeId: id, lastPosition: lastPosition, savedPositions: savedPositions)
            if position >= minimumResumePosition { return (episode, position) }
        }
        let inProgress = podcast.episodes.compactMap { ep -> (Episode, TimeInterval)? in
            guard !finished.contains(ep.id), let position = savedPositions[ep.id], position >= minimumResumePosition else { return nil }
            if let duration = ep.duration, duration > 0, position >= duration - 30 { return nil }
            return (ep, position)
        }
        guard let newest = newestFirst(inProgress.map(\.0)).first,
              let match = inProgress.first(where: { $0.0.id == newest.id }) else { return nil }
        return (match.0, match.1)
    }

    /// The newest episode you haven't finished, other than `excluding`.
    static func latestUnplayed(in podcast: Podcast, finished: Set<String>, excluding: String?) -> Episode? {
        newestFirst(podcast.episodes.filter { !finished.contains($0.id) && $0.id != excluding }).first
    }

    // MARK: - Helpers

    /// The snapshot's live position wins (it's read from the player itself); the periodic
    /// positions map is the fallback.
    private static func resumePosition(id: String, lastEpisodeId: String?, lastPosition: TimeInterval?,
                                       savedPositions: [String: Double]) -> TimeInterval {
        if id == lastEpisodeId, let lastPosition, lastPosition > 0 { return lastPosition }
        return savedPositions[id] ?? 0
    }

    /// Newest by publish date; undated episodes after dated ones; feed order breaks ties (feeds
    /// list newest first).
    private static func newestFirst(_ episodes: [Episode]) -> [Episode] {
        episodes.enumerated().sorted { a, b in
            switch (a.element.pubDate, b.element.pubDate) {
            case let (da?, db?) where da != db: return da > db
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.offset < b.offset
            }
        }.map(\.element)
    }
}
