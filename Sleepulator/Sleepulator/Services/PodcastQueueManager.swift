import Foundation
import Combine
import SwiftUI
import os

final class PodcastQueueManager: ObservableObject {
    @Published var queue: [Episode] = [] {
        didSet {
            let q = queue
            storageQueue.async {
                StorageManager.shared.save(q, to: "queue.json")
            }
        }
    }
    
    @Published var autoPlay: Bool {
        didSet { UserDefaults.standard.set(autoPlay, forKey: "autoPlay") }
    }
    @Published var shuffleQueue: Bool {
        didSet { UserDefaults.standard.set(shuffleQueue, forKey: "shuffleQueue") }
    }
    @Published var deleteOnCompletion: Bool {
        didSet { UserDefaults.standard.set(deleteOnCompletion, forKey: "deleteOnCompletion") }
    }
    @Published var hideFinishedEpisodes: Bool {
        didSet { UserDefaults.standard.set(hideFinishedEpisodes, forKey: "hideFinishedEpisodes") }
    }
    @Published var finishedEpisodes: Set<String> = [] {
        didSet {
            // Persist the RECENCY order (`finishedOrder`), not `Array(finishedEpisodes)`: a Set has
            // no order, so saving it lost the recency the cap depends on — after relaunch the
            // trim-oldest cap would drop arbitrary entries. Every writer updates `finishedOrder`
            // before assigning `finishedEpisodes = Set(finishedOrder)`, so this is current here.
            let arr = finishedOrder
            storageQueue.async { UserDefaults.standard.set(arr, forKey: "finishedEpisodes") }
        }
    }
    
    private let storageQueue = DispatchQueue(label: "app.sleepulator.queueStorage", qos: .utility)

    // Recency order (newest last) that bounds `finishedEpisodes` — without it the set grew
    // forever in UserDefaults as every episode you ever finished accumulated.
    private var finishedOrder: [String] = []
    private let finishedCap = 1000
    
    // Dependencies
    /// `resume`: continue at the saved position (true for user-initiated plays) vs. start fresh at 0
    /// (false for auto-advancing to the next queued track).
    var loadPodcastFn: ((_ url: String, _ id: String, _ title: String, _ resume: Bool) -> Void)?
    var pausePodcastFn: (() -> Void)?
    
    init() {
        self.autoPlay = UserDefaults.standard.object(forKey: "autoPlay") as? Bool ?? true
        self.shuffleQueue = UserDefaults.standard.object(forKey: "shuffleQueue") as? Bool ?? false
        self.deleteOnCompletion = UserDefaults.standard.object(forKey: "deleteOnCompletion") as? Bool ?? false
        self.hideFinishedEpisodes = UserDefaults.standard.object(forKey: "hideFinishedEpisodes") as? Bool ?? false
        
        if let arr = UserDefaults.standard.array(forKey: "finishedEpisodes") as? [String] {
            // Trim any legacy bloat from before the cap existed (assignment re-persists it).
            let capped = arr.count > finishedCap ? Array(arr.suffix(finishedCap)) : arr
            self.finishedOrder = capped
            self.finishedEpisodes = Set(capped)
        }
        
        if let savedQueue: [Episode] = StorageManager.shared.load(from: "queue.json") {
            self.queue = savedQueue
        }
        

    }

    // Explicitly nonisolated: the implicit MainActor-isolated deinit aborts on iOS 18.4–26.3
    // runtimes (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}
    
    /// Reload all persisted queue state from disk/UserDefaults — used by the in-process Restore
    /// so the queue reflects the imported backup without an app relaunch.
    func reloadFromDisk() {
        autoPlay = UserDefaults.standard.object(forKey: "autoPlay") as? Bool ?? true
        shuffleQueue = UserDefaults.standard.object(forKey: "shuffleQueue") as? Bool ?? false
        deleteOnCompletion = UserDefaults.standard.object(forKey: "deleteOnCompletion") as? Bool ?? false
        hideFinishedEpisodes = UserDefaults.standard.object(forKey: "hideFinishedEpisodes") as? Bool ?? false

        if let arr = UserDefaults.standard.array(forKey: "finishedEpisodes") as? [String] {
            let capped = arr.count > finishedCap ? Array(arr.suffix(finishedCap)) : arr
            finishedOrder = capped
            finishedEpisodes = Set(capped)
        } else {
            finishedOrder = []
            finishedEpisodes = []
        }

        queue = StorageManager.shared.load(from: "queue.json") ?? []
    }

    /// Mark an episode finished, keeping the set bounded by recency. Replaces a raw
    /// `finishedEpisodes.insert`, which had no upper limit.
    func markFinished(_ id: String) {
        finishedOrder.removeAll { $0 == id }
        finishedOrder.append(id)
        if finishedOrder.count > finishedCap {
            finishedOrder.removeFirst(finishedOrder.count - finishedCap)
        }
        finishedEpisodes = Set(finishedOrder)   // triggers the persist in didSet
    }

    /// Manually un-mark an episode as played (the inverse of `markFinished`).
    func markUnfinished(_ id: String) {
        guard finishedOrder.contains(id) || finishedEpisodes.contains(id) else { return }
        finishedOrder.removeAll { $0 == id }
        finishedEpisodes = Set(finishedOrder)   // triggers the persist in didSet
    }

    /// Called when a person starts playback here (a row, a swipe, Play All), not on the
    /// queue's own auto-advance. AudioEngine cancels the ambient tail on it.
    var userStartedPlaybackFn: (() -> Void)?

    func playEpisode(_ episode: Episode) {
        userStartedPlaybackFn?()
        resetFailureStreak()
        moveToHead(episode)
        loadPodcastFn?(episode.audioUrl, episode.id, episode.title, true)
    }

    /// Put `episode` first in the queue (dropping any other copy of it) in one write: one persist,
    /// one publish. No write when it's already the head.
    func moveToHead(_ episode: Episode) {
        guard queue.first?.id != episode.id || queue.dropFirst().contains(where: { $0.id == episode.id }) else { return }
        var q = queue
        q.removeAll { $0.id == episode.id }
        q.insert(episode, at: 0)
        queue = q
    }

    func playAll(_ episodes: [Episode]) {
        guard let first = episodes.first else { return }
        userStartedPlaybackFn?()
        resetFailureStreak()
        self.queue = episodes
        loadPodcastFn?(first.audioUrl, first.id, first.title, true)
    }

    func addToQueue(_ episode: Episode) {
        if !queue.contains(where: { $0.id == episode.id }) { queue.append(episode) }
    }

    /// Append several episodes to the end of the queue at once, skipping any already queued.
    /// One mutation → one persist + one publish (vs. N appends). Returns the number actually added
    /// so the caller can confirm to the user. Used by the detail view's "add filtered" bulk action.
    @discardableResult
    func addAllToQueue(_ episodes: [Episode]) -> Int {
        let existing = Set(queue.map { $0.id })
        let toAdd = episodes.filter { !existing.contains($0.id) }
        guard !toAdd.isEmpty else { return 0 }
        queue.append(contentsOf: toAdd)
        return toAdd.count
    }
    
    func moveQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    /// Move an episode one place up (`step` -1) or down (+1) within Up Next: the queue as the
    /// player lists it, which leaves out the episode the player is on. That episode can sit
    /// anywhere in the queue, or nowhere (the sleep-aware hold drops it; Resume Last Night can load
    /// one that isn't queued), so the head-pinned `moveUp`/`moveDown` (index > 1) could do nothing
    /// or move it. Swapping the two queue slots of neighbours in Up Next leaves the playing episode
    /// where it is.
    /// `nowPlayingId` nil means nothing is loaded: the head is what plays next, and stays put.
    func moveInUpNext(_ episode: Episode, by step: Int, nowPlayingId: String?) {
        let pinned = nowPlayingId ?? queue.first?.id
        let upNext = queue.filter { $0.id != pinned }
        guard let i = upNext.firstIndex(where: { $0.id == episode.id }),
              upNext.indices.contains(i + step),
              let a = queue.firstIndex(where: { $0.id == episode.id }),
              let b = queue.firstIndex(where: { $0.id == upNext[i + step].id }) else { return }
        queue.swapAt(a, b)
    }

    /// Take an episode out of the queue. Never touches its download. Returns where it was, so the
    /// player can offer Undo (`restore`); nil if it wasn't queued.
    @discardableResult
    func remove(_ episode: Episode) -> Int? {
        guard let i = queue.firstIndex(where: { $0.id == episode.id }) else { return nil }
        queue.remove(at: i)
        return i
    }

    /// Undo a `remove`: put the episode back where it was (clamped, in case the queue has since
    /// shrunk). A no-op if it's already queued again.
    func restore(_ episode: Episode, at index: Int) {
        guard !queue.contains(where: { $0.id == episode.id }) else { return }
        queue.insert(episode, at: min(max(0, index), queue.count))
    }

    /// The player's Next: drop the episode being skipped and play the one after it. A skip is not
    /// a finish, so unlike `advanceQueue` it never deletes the download (delete-on-completion is
    /// for episodes you heard) and never marks it played. It plays the next one whatever Auto-Play
    /// says: Auto-Play is about an episode ending on its own, not a tap on Next (which used to
    /// pause and silently drop the episode). Shuffle picks the next one as it does at an episode's
    /// end. Returns false, changing nothing, when nothing follows.
    @discardableResult
    func skipToNext(currentId: String?) -> Bool {
        var rest = queue.filter { $0.id != currentId }
        guard !rest.isEmpty else { return false }
        userStartedPlaybackFn?()   // a person's Next: lifts the ambient tail like any other pick
        resetFailureStreak()
        let next = rest.remove(at: shuffleQueue ? Int.random(in: 0..<rest.count) : 0)
        queue = [next] + rest
        loadPodcastFn?(next.audioUrl, next.id, next.title, true)
        return true
    }

    /// Shuffle Up Next. Like `moveInUpNext`, the episode that stays put is the one the player is
    /// on, wherever it sits (or nowhere: the sleep-aware hold, Resume Last Night); only with nothing
    /// loaded is it the head. Pinning `queue[0]` regardless froze Up Next's first row, the very
    /// episode Next and auto-advance play, whenever the loaded episode had left the queue.
    func shuffleRemainingQueue(nowPlayingId: String? = nil) {
        let pinned = nowPlayingId ?? queue.first?.id
        let pinnedIndex = queue.firstIndex { $0.id == pinned }
        var shuffled = queue.filter { $0.id != pinned }.shuffled()
        guard shuffled.count > 1 || pinnedIndex == nil else { return }
        if let i = pinnedIndex { shuffled.insert(queue[i], at: min(i, shuffled.count)) }
        queue = shuffled
    }

    /// `suppressAutoPlay`: advance the queue data (drop the finished head, honor
    /// delete-on-completion) but do NOT start the next episode — used by the sleep-aware
    /// hold, so the morning queue is clean while the night stays ambient-only.
    func advanceQueue(finishedEpId: String? = nil, suppressAutoPlay: Bool = false) {
        resetFailureStreak()   // an episode played to its end: loads are working
        // Remove the episode that ACTUALLY finished, identified by id — not just the head. The
        // head is normally the playing episode, but if the queue was reordered (or the head
        // removed) while it played, `removeFirst()` would drop the wrong episode and, with
        // delete-on-completion, DELETE the wrong cached download. Fall back to the head only when
        // no id is given (legacy callers); if the id is already gone, remove nothing.
        let finishedEp: Episode?
        if let id = finishedEpId {
            if let idx = queue.firstIndex(where: { $0.id == id }) {
                finishedEp = queue.remove(at: idx)
            } else {
                finishedEp = nil   // already removed elsewhere — don't drop/delete an innocent one
            }
        } else if !queue.isEmpty {
            finishedEp = queue.removeFirst()
        } else {
            finishedEp = nil
        }
        if deleteOnCompletion, let ep = finishedEp, let url = URL(string: ep.audioUrl) {
            AudioDownloader.shared.deleteCachedEpisode(for: url)
        }

        if !self.autoPlay || suppressAutoPlay || self.queue.isEmpty {
            pausePodcastFn?()
            return
        }
        
        let nextIndex = self.shuffleQueue ? Int.random(in: 0..<self.queue.count) : 0
        let next = self.queue[nextIndex]
        
        if self.shuffleQueue {
            self.queue.remove(at: nextIndex)
            self.queue.insert(next, at: 0)
        }
        
        // Fresh start: the next queued track must begin at 0, never resume a stale/poisoned position.
        loadPodcastFn?(next.audioUrl, next.id, next.title, false)
    }

    /// Auto-Play gives up after this many failed or lost episodes in a row.
    static let failureLimit = 3
    /// Failed or lost episodes since one last played to its end or a person started one.
    private(set) var failuresInARow = 0
    /// Their ids, in the order they failed (the queue's order: each failure moves to the next).
    private var failedInARow: [String] = []

    /// A person started an episode, or one played to its end: Auto-Play may try again.
    func resetFailureStreak() {
        failuresInARow = 0
        failedInARow = []
    }

    /// The loaded episode failed, or its stream was lost. Unlike `advanceQueue` this never takes
    /// the episode out of the queue or deletes its download: a failure isn't a listen, and offline
    /// every load fails within a second or two, so advancing as for a finish emptied the whole
    /// queue before morning. With Auto-Play on and `mayContinue` (false in the ambient tail and the
    /// sleep-aware hold), play the first queued episode that hasn't failed in this run, at the head
    /// with the failed ones right behind it. Otherwise, or after `failureLimit` failures in a row,
    /// stop with the failed episodes back at the head in the order they were queued. Returns
    /// whether another episode was started.
    @discardableResult
    func advancePastFailure(failedEpId: String?, mayContinue: Bool = true) -> Bool {
        failuresInARow += 1
        if let id = failedEpId, !failedInARow.contains(id) { failedInARow.append(id) }
        let failed = failedInARow.compactMap { id in queue.first { $0.id == id } }
        let others = queue.filter { !failedInARow.contains($0.id) }
        guard mayContinue, autoPlay, failuresInARow < Self.failureLimit, !others.isEmpty else {
            if failuresInARow >= Self.failureLimit {
                Log.audio.notice("auto-play stopped: \(self.failuresInARow, privacy: .public) failed episodes in a row, all kept queued")
            }
            let arranged = failed + others
            if arranged.map(\.id) != queue.map(\.id) { queue = arranged }
            pausePodcastFn?()
            return false
        }
        let next = others[shuffleQueue ? Int.random(in: 0..<others.count) : 0]
        queue = [next] + failed + others.filter { $0.id != next.id }
        // From the start, as any auto-advance (see `advanceQueue`).
        loadPodcastFn?(next.audioUrl, next.id, next.title, false)
        return true
    }
}
