import Foundation
import Combine

/// Owns the persisted mixes — the "Last Night" resume snapshot plus the user's saved
/// playlists — and their storage (UserDefaults for `lastMix`, mixes.json for the list).
/// Extracted from `AudioEngine` (Slice A2 of ARCHITECTURE-REFACTOR-PLAN.md): the facade no
/// longer holds this state or its persistence. It keeps building the `SavedMix` from live
/// engine + queue state (the construction reads engine-side values) and hands it here to store.
///
/// An `ObservableObject`: `AudioEngine` forwards `objectWillChange` so views binding to
/// `audio.lastMix` / `audio.savedPlaylists` (via read-only passthrough computed vars) still
/// update when a mix is saved or deleted.
final class MixStore: ObservableObject {
    @Published private(set) var lastMix: SavedMix?
    @Published private(set) var savedPlaylists: [SavedMix]

    /// Shared with AudioEngine so all persistence stays serialized on one queue, exactly as
    /// when the mixes.json write lived in `savedPlaylists.didSet`.
    private let storageQueue: DispatchQueue

    init(lastMix: SavedMix?, savedPlaylists: [SavedMix], storageQueue: DispatchQueue) {
        self.lastMix = lastMix
        self.savedPlaylists = savedPlaylists
        self.storageQueue = storageQueue
    }

    /// Store the latest "Last Night" snapshot. Synchronous UserDefaults write under the legacy
    /// "lastMix" key, so Settings backup/restore keeps reading it unchanged.
    func saveLast(_ mix: SavedMix) {
        lastMix = mix
        if let data = try? JSONEncoder().encode(mix) {
            UserDefaults.standard.set(data, forKey: "lastMix")
        }
    }

    /// Append a saved playlist and persist the list to mixes.json.
    func add(_ mix: SavedMix) {
        savedPlaylists.append(mix)
        persistPlaylists()
    }

    /// Remove a saved playlist by id and persist the list to mixes.json.
    func delete(_ mix: SavedMix) {
        savedPlaylists.removeAll(where: { $0.id == mix.id })
        persistPlaylists()
    }

    private func persistPlaylists() {
        let mixes = savedPlaylists
        storageQueue.async { StorageManager.shared.save(mixes, to: "mixes.json") }
    }
}
