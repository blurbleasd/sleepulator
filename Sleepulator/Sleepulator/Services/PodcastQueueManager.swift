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
            let arr = Array(finishedEpisodes)
            storageQueue.async { UserDefaults.standard.set(arr, forKey: "finishedEpisodes") }
        }
    }
    
    private let storageQueue = DispatchQueue(label: "app.sleepulator.queueStorage", qos: .utility)

    // Recency order (newest last) that bounds `finishedEpisodes` — without it the set grew
    // forever in UserDefaults as every episode you ever finished accumulated.
    private var finishedOrder: [String] = []
    private let finishedCap = 1000
    
    // Dependencies
    var loadPodcastFn: ((_ url: String, _ id: String, _ title: String) -> Void)?
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

    func playEpisode(_ episode: Episode) {
        if !self.queue.contains(where: { $0.id == episode.id }) {
            self.queue.insert(episode, at: 0)
        } else {
            self.queue.removeAll(where: { $0.id == episode.id })
            self.queue.insert(episode, at: 0)
        }
        loadPodcastFn?(episode.audioUrl, episode.id, episode.title)
    }
    
    func playAll(_ episodes: [Episode]) {
        guard let first = episodes.first else { return }
        self.queue = episodes
        loadPodcastFn?(first.audioUrl, first.id, first.title)
    }

    func addToQueue(_ episode: Episode) {
        if !queue.contains(where: { $0.id == episode.id }) { queue.append(episode) }
    }
    
    func moveQueue(fromOffsets source: IndexSet, toOffset destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    func moveUp(episode: Episode) {
        guard let idx = queue.firstIndex(where: { $0.id == episode.id }), idx > 1 else { return }
        queue.swapAt(idx, idx - 1)
    }
    
    func moveDown(episode: Episode) {
        guard let idx = queue.firstIndex(where: { $0.id == episode.id }), idx > 0, idx < queue.count - 1 else { return }
        queue.swapAt(idx, idx + 1)
    }
    
    func shuffleRemainingQueue() {
        guard queue.count > 1 else { return }
        let current = queue[0]
        let remaining = queue.dropFirst().shuffled()
        queue = [current] + remaining
    }

    func advanceQueue(finishedEpId: String? = nil) {
        if !self.queue.isEmpty {
            let finishedEp = self.queue.removeFirst()
            if deleteOnCompletion, let url = URL(string: finishedEp.audioUrl) {
                AudioDownloader.shared.deleteCachedEpisode(for: url)
            }
        }
        
        if !self.autoPlay || self.queue.isEmpty {
            pausePodcastFn?()
            return
        }
        
        let nextIndex = self.shuffleQueue ? Int.random(in: 0..<self.queue.count) : 0
        let next = self.queue[nextIndex]
        
        if self.shuffleQueue {
            self.queue.remove(at: nextIndex)
            self.queue.insert(next, at: 0)
        }
        
        loadPodcastFn?(next.audioUrl, next.id, next.title)
    }
}
