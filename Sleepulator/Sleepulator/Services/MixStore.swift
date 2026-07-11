import Foundation
import Combine

/// Owns the persisted mixes — the "Last Night" resume snapshot (`lastMix`, UserDefaults) plus
/// the user's saved sound presets (`savedPresets`, mixes.json). Extracted from `AudioEngine`
/// (Slice A2 of ARCHITECTURE-REFACTOR-PLAN.md): the facade no longer holds this state or its
/// persistence.
///
/// An `ObservableObject`: `AudioEngine` forwards `objectWillChange` so views binding to
/// `audio.lastMix` / `audio.savedPresets` (via read-only passthrough computed vars) still
/// update when a preset is saved, renamed, or deleted.
final class MixStore: ObservableObject {
    @Published private(set) var lastMix: SavedMix?
    @Published private(set) var savedPresets: [SoundPreset]

    /// Shared with AudioEngine so all persistence stays serialized on one queue, exactly as
    /// when the mixes.json write lived in the array's `didSet`.
    private let storageQueue: DispatchQueue

    /// Injected so unit tests can point preset persistence at a temp-dir store. Production
    /// constructs `MixStore(...)` without it → the real singleton.
    private let storage: StorageManager

    /// Pending (coalesced + deferred) mixes.json write — see `persistPresets`. Main-actor only.
    private var persistWork: DispatchWorkItem?

    init(lastMix: SavedMix?, savedPresets: [SoundPreset], storageQueue: DispatchQueue,
         storage: StorageManager = .shared) {
        self.lastMix = lastMix
        self.savedPresets = savedPresets
        self.storageQueue = storageQueue
        self.storage = storage
    }

    /// Store the latest "Last Night" snapshot. Synchronous UserDefaults write under the legacy
    /// "lastMix" key, so Settings backup/restore keeps reading it unchanged.
    func saveLast(_ mix: SavedMix) {
        lastMix = mix
        if let data = try? JSONEncoder().encode(mix) {
            UserDefaults.standard.set(data, forKey: "lastMix")
        }
    }

    /// Append a new preset and persist.
    func addPreset(_ preset: SoundPreset) {
        savedPresets.append(preset)
        persistPresets()
    }

    /// Replace an existing preset (matched by id) and persist — the overwrite path.
    func replacePreset(_ preset: SoundPreset) {
        if let i = savedPresets.firstIndex(where: { $0.id == preset.id }) {
            savedPresets[i] = preset
        } else {
            savedPresets.append(preset)
        }
        persistPresets()
    }

    /// Rename a preset by id and persist.
    func renamePreset(_ id: String, to name: String) {
        guard let i = savedPresets.firstIndex(where: { $0.id == id }) else { return }
        savedPresets[i].name = name
        persistPresets()
    }

    /// Remove a preset by id and persist.
    func deletePreset(_ preset: SoundPreset) {
        savedPresets.removeAll(where: { $0.id == preset.id })
        persistPresets()
    }

    private func persistPresets() {
        let presets = savedPresets
        let storage = self.storage
        // Coalesce + defer the encode/write off the save-tap moment. Saving a preset otherwise
        // fires a JSON encode + double file write in the same instant as the alert dismiss, the
        // list re-render, and the haptic — a burst that's harmless to the robust generative bed but
        // can crackle the heavier streaming-podcast decode/limiter pipeline. A short defer takes the
        // write out of that pile-up (and coalesces rapid edits into one write). The in-memory
        // savedPresets already updated, so the UI is unaffected; only the disk write waits.
        persistWork?.cancel()
        let work = DispatchWorkItem { storage.save(presets, to: "mixes.json") }
        persistWork = work
        storageQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Run any deferred `mixes.json` write immediately and durably (called on app-background).
    /// `persistPresets` coalesces its write behind a 0.5 s timer; without this, a preset saved in
    /// that window is lost if the app is jettisoned overnight. The write must actually land before
    /// we return: `save` re-dispatches onto StorageManager's io queue, so we enqueue it then block
    /// on `flush()` (an `ioQueue.sync {}` barrier) until it's on disk. Bounded to one small JSON
    /// write on the storage queue — only on app-background, never a hot path. No-op unless a
    /// preset was actually saved this session (`persistWork` stays nil otherwise).
    func flushPendingWrites() {
        guard persistWork != nil else { return }
        persistWork?.cancel()
        persistWork = nil
        let presets = savedPresets
        let storage = self.storage
        storageQueue.sync {
            storage.save(presets, to: "mixes.json")
            storage.flush()   // ioQueue barrier — return only once the bytes are written
        }
    }

    /// Reload the last-mix snapshot and saved presets from disk — used by the in-process Restore.
    /// Accepts the current `[SoundPreset]` schema or a legacy `[SavedMix]` mixes.json (converting
    /// it the same way `PersistenceMigrator` does), so a restore never shows an empty preset list.
    func reloadFromDisk() {
        // Drop any deferred preset write so it can't fire after the restore and clobber the
        // just-restored mixes.json with stale pre-restore presets.
        persistWork?.cancel()
        persistWork = nil

        if let data = UserDefaults.standard.data(forKey: "lastMix"),
           let mix = try? JSONDecoder().decode(SavedMix.self, from: data) {
            lastMix = mix
        } else {
            lastMix = nil
        }

        if let presets: [SoundPreset] = storage.load(from: "mixes.json") {
            savedPresets = presets.map { var p = $0; p.noiseType = NoiseType.migrate(p.noiseType); return p }
        } else if let old: [SavedMix] = storage.load(from: "mixes.json") {
            savedPresets = old.map {
                SoundPreset(name: $0.name, mode: "sleep",
                            noiseOn: $0.noiseOn, noiseType: NoiseType.migrate($0.noiseType), noiseVolume: $0.noiseVolume,
                            binauralOn: $0.binauralOn, binauralPreset: $0.binauralPreset, binVolume: $0.binVolume,
                            sceneId: nil)
            }
        } else {
            savedPresets = []
        }
    }
}
