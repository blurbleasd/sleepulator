import Foundation

/// Owns the one-time, launch-only migration of legacy persisted state into the
/// `StorageManager` file store. Pulled out of `AudioEngine.init` (Slice A1 of
/// ARCHITECTURE-REFACTOR-PLAN.md) — it's the most fragile, least-touched code on the
/// launch path and has nothing to do with the live audio state.
///
/// Side-effects are confined to persistence: it reads `UserDefaults` + `StorageManager`,
/// performs the file writes, clears the consumed legacy keys, and returns the values
/// `AudioEngine` seeds its `@Published` state from. It holds no reference to `AudioEngine`.
struct PersistenceMigrator {
    struct Result {
        var lastMix: SavedMix?
        var savedPresets: [SoundPreset]
        /// Non-nil only when legacy `episodePositions` was migrated this launch; the caller
        /// hands it to `PodcastPlayer` so its first flush can't clobber positions.json.
        var migratedPositions: [String: Double]?
    }

    /// A legacy podcast-coupled `SavedMix` → a pure `SoundPreset`: drop the transient podcast,
    /// migrate any retired noise type, and tag it Sleep (old saves predate mode-scoping).
    private func toPreset(_ m: SavedMix) -> SoundPreset {
        SoundPreset(name: m.name, mode: "sleep",
                    noiseOn: m.noiseOn, noiseType: NoiseType.migrate(m.noiseType), noiseVolume: m.noiseVolume,
                    binauralOn: m.binauralOn, binauralPreset: m.binauralPreset, binVolume: m.binVolume,
                    sceneId: nil)
    }

    func run() -> Result {
        var result = Result(lastMix: nil, savedPresets: [], migratedPositions: nil)
        let defaults = UserDefaults.standard

        // lastMix lived in UserDefaults as JSON; migrate any retired noise type forward.
        if let data = defaults.data(forKey: "lastMix"),
           var mix = try? JSONDecoder().decode(SavedMix.self, from: data) {
            mix.noiseType = NoiseType.migrate(mix.noiseType)
            result.lastMix = mix
        }

        // Saved presets live in mixes.json. New schema is [SoundPreset]; older data (a legacy
        // UserDefaults blob, or a mixes.json from before the preset rework) is [SavedMix] and is
        // migrated forward once — dropping the podcast that never belonged in a reusable recipe.
        if let data = defaults.data(forKey: "savedPlaylists"),
           let mixes = try? JSONDecoder().decode([SavedMix].self, from: data) {
            let presets = mixes.map(toPreset)
            StorageManager.shared.save(presets, to: "mixes.json")
            defaults.removeObject(forKey: "savedPlaylists")
            result.savedPresets = presets
        } else if let presets: [SoundPreset] = StorageManager.shared.load(from: "mixes.json") {
            result.savedPresets = presets.map { var p = $0; p.noiseType = NoiseType.migrate(p.noiseType); return p }
        } else if let oldMixes: [SavedMix] = StorageManager.shared.load(from: "mixes.json") {
            let presets = oldMixes.map(toPreset)
            StorageManager.shared.save(presets, to: "mixes.json")   // rewrite in the new schema
            result.savedPresets = presets
        }

        // One-time library.json seed from the legacy savedPodcasts key. Only seed if the
        // canonical file doesn't exist yet; always clear the legacy key so a stray legacy
        // write can never clobber a newer library on a later launch.
        if StorageManager.shared.rawData(for: "library.json") == nil,
           let data = defaults.data(forKey: "savedPodcasts"),
           let podcasts = try? JSONDecoder().decode([Podcast].self, from: data) {
            StorageManager.shared.save(podcasts, to: "library.json")
        }
        defaults.removeObject(forKey: "savedPodcasts")

        // episodePositions: legacy UserDefaults dict → positions.json.
        if let data = defaults.dictionary(forKey: "episodePositions") as? [String: Double] {
            StorageManager.shared.save(data, to: "positions.json")
            defaults.removeObject(forKey: "episodePositions")
            result.migratedPositions = data
        }

        return result
    }
}
