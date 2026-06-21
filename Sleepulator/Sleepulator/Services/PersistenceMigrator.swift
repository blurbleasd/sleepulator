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
        var savedPlaylists: [SavedMix]
        /// Non-nil only when legacy `episodePositions` was migrated this launch; the caller
        /// hands it to `PodcastPlayer` so its first flush can't clobber positions.json.
        var migratedPositions: [String: Double]?
    }

    func run() -> Result {
        var result = Result(lastMix: nil, savedPlaylists: [], migratedPositions: nil)
        let defaults = UserDefaults.standard

        // lastMix lived in UserDefaults as JSON; migrate any retired noise type forward.
        if let data = defaults.data(forKey: "lastMix"),
           var mix = try? JSONDecoder().decode(SavedMix.self, from: data) {
            mix.noiseType = NoiseType.migrate(mix.noiseType)
            result.lastMix = mix
        }

        // savedPlaylists: migrate the legacy UserDefaults blob → mixes.json once, else load
        // the canonical file. Retired noise types are migrated on the way through either path.
        if let data = defaults.data(forKey: "savedPlaylists"),
           let mixes = try? JSONDecoder().decode([SavedMix].self, from: data) {
            let migrated = mixes.map { m -> SavedMix in var m2 = m; m2.noiseType = NoiseType.migrate(m.noiseType); return m2 }
            StorageManager.shared.save(migrated, to: "mixes.json")
            defaults.removeObject(forKey: "savedPlaylists")
            result.savedPlaylists = migrated
        } else if let mixes: [SavedMix] = StorageManager.shared.load(from: "mixes.json") {
            let migrated = mixes.map { m -> SavedMix in var m2 = m; m2.noiseType = NoiseType.migrate(m.noiseType); return m2 }
            result.savedPlaylists = migrated
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
