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

    init(lastMix: SavedMix?, savedPresets: [SoundPreset], storageQueue: DispatchQueue) {
        self.lastMix = lastMix
        self.savedPresets = savedPresets
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
        storageQueue.async { StorageManager.shared.save(presets, to: "mixes.json") }
    }

    /// Reload the last-mix snapshot and saved presets from disk — used by the in-process Restore.
    /// Accepts the current `[SoundPreset]` schema or a legacy `[SavedMix]` mixes.json (converting
    /// it the same way `PersistenceMigrator` does), so a restore never shows an empty preset list.
    func reloadFromDisk() {
        if let data = UserDefaults.standard.data(forKey: "lastMix"),
           let mix = try? JSONDecoder().decode(SavedMix.self, from: data) {
            lastMix = mix
        } else {
            lastMix = nil
        }

        if let presets: [SoundPreset] = StorageManager.shared.load(from: "mixes.json") {
            savedPresets = presets.map { var p = $0; p.noiseType = NoiseType.migrate(p.noiseType); return p }
        } else if let old: [SavedMix] = StorageManager.shared.load(from: "mixes.json") {
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
