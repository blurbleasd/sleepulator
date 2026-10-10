import Foundation
import Combine
import SwiftUI

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

    func playEpisode(_ episode: Episode) {
        if !self.queue.contains(where: { $0.id == episode.id }) {
            self.queue.insert(episode, at: 0)
        } else {
            self.queue.removeAll(where: { $0.id == episode.id })
            self.queue.insert(episode, at: 0)
        }
        loadPodcastFn?(episode.audioUrl, episode.id, episode.title, true)
    }

    func playAll(_ episodes: [Episode]) {
        guard let first = episodes.first else { return }
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
    /// anywhere in the queue, or nowhere (a failure or the sleep-aware hold drops it), so the
    /// head-pinned `moveUp`/`moveDown` (index > 1) could do nothing or move it. Swapping the two
    /// queue slots of neighbours in Up Next leaves the playing episode where it is.
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
        let next = rest.remove(at: shuffleQueue ? Int.random(in: 0..<rest.count) : 0)
        queue = [next] + rest
        loadPodcastFn?(next.audioUrl, next.id, next.title, true)
        return true
    }

    func shuffleRemainingQueue() {
        guard queue.count > 1 else { return }
        let current = queue[0]
        let remaining = queue.dropFirst().shuffled()
        queue = [current] + remaining
    }

    /// `suppressAutoPlay`: advance the queue data (drop the finished head, honor
    /// delete-on-completion) but do NOT start the next episode — used by the sleep-aware
    /// hold, so the morning queue is clean while the night stays ambient-only.
    func advanceQueue(finishedEpId: String? = nil, suppressAutoPlay: Bool = false) {
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
}
