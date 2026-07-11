import XCTest
@testable import Sleepulator

/// Covers the launch-time migration (`PersistenceMigrator`) and `MixStore`'s legacy-format
/// reload — the most fragile, least-touched persistence code, which until now had no test
/// coverage (its `run()`/`reloadFromDisk()` mutate the shared store + UserDefaults). Each test
/// runs against a temp-dir `StorageManager` and a throwaway `UserDefaults` suite, so they're
/// hermetic, parallel-safe, and never touch the real on-disk state.
@MainActor
final class PersistenceTests: XCTestCase {

    // MARK: Fixtures (auto-cleaned via teardown blocks)

    private func freshStorage() -> StorageManager {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test.sleepulator.\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return StorageManager(directory: dir)
    }

    private func freshDefaults() -> UserDefaults {
        let name = "test.sleepulator.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        addTeardownBlock { d.removePersistentDomain(forName: name) }
        return d
    }

    private func makeSavedMix(name: String, noiseType: String = "brown",
                              binauralPreset: String = "delta") -> SavedMix {
        SavedMix(name: name, noiseOn: true, noiseVolume: 0.5, noiseType: noiseType,
                 binauralOn: true, binVolume: 0.3, binauralPreset: binauralPreset, podVolume: 1.0)
    }

    private func makePreset(name: String, mode: String = "sleep",
                            noiseType: String = "brown") -> SoundPreset {
        SoundPreset(name: name, mode: mode, noiseOn: true, noiseType: noiseType,
                    noiseVolume: 0.5, binauralOn: false, binauralPreset: "delta",
                    binVolume: 0.2, sceneId: nil)
    }

    // MARK: PersistenceMigrator — saved presets

    func testMigratesLegacySavedPlaylistsBlobToPresets() {
        let storage = freshStorage()
        let defaults = freshDefaults()
        let legacy = [makeSavedMix(name: "Old Mix")]
        defaults.set(try! JSONEncoder().encode(legacy), forKey: "savedPlaylists")

        let result = PersistenceMigrator(storage: storage, defaults: defaults).run()

        XCTAssertEqual(result.savedPresets.count, 1)
        XCTAssertEqual(result.savedPresets.first?.name, "Old Mix")
        XCTAssertEqual(result.savedPresets.first?.mode, "sleep",
                       "legacy mixes predate mode-scoping, so they're tagged sleep")
        XCTAssertNil(defaults.data(forKey: "savedPlaylists"),
                     "the consumed legacy key is cleared so it can't re-migrate")

        storage.flush()
        let onDisk: [SoundPreset]? = storage.load(from: "mixes.json")
        XCTAssertEqual(onDisk?.count, 1, "presets are persisted in the new mixes.json schema")
    }

    func testMigratesLegacyMixesJsonFileToPresets() {
        let storage = freshStorage()
        let defaults = freshDefaults()
        // No savedPlaylists key — the file itself is the old [SavedMix] schema (no `mode` field),
        // so the [SoundPreset] decode fails and the [SavedMix] fallback path runs.
        storage.save([makeSavedMix(name: "Legacy File")], to: "mixes.json")
        storage.flush()

        let result = PersistenceMigrator(storage: storage, defaults: defaults).run()

        XCTAssertEqual(result.savedPresets.count, 1)
        XCTAssertEqual(result.savedPresets.first?.name, "Legacy File")
        XCTAssertEqual(result.savedPresets.first?.mode, "sleep")
    }

    func testMigratesRetiredNoiseTypeInExistingPresets() {
        let storage = freshStorage()
        let defaults = freshDefaults()
        storage.save([makePreset(name: "X", noiseType: "blue")], to: "mixes.json")  // "blue" retired
        storage.flush()

        let result = PersistenceMigrator(storage: storage, defaults: defaults).run()

        XCTAssertEqual(result.savedPresets.first?.noiseType, "brown",
                       "an unknown/retired noise type migrates forward to brown")
    }

    // MARK: PersistenceMigrator — positions coercion

    func testCoercesMixedTypePositionsAndDropsNonNumeric() {
        let storage = freshStorage()
        let defaults = freshDefaults()
        defaults.set(["a": 12.5, "b": Int(7), "c": "nope"] as [String: Any],
                     forKey: "episodePositions")

        let result = PersistenceMigrator(storage: storage, defaults: defaults).run()
        let pos = result.migratedPositions

        XCTAssertEqual(pos?["a"], 12.5)
        XCTAssertEqual(pos?["b"], 7.0, "an Int value is coerced to Double, not dropped")
        XCTAssertNil(pos?["c"], "a non-numeric value is dropped without failing the whole map")
        XCTAssertNil(defaults.dictionary(forKey: "episodePositions"),
                     "the consumed legacy positions key is cleared")
    }

    // MARK: PersistenceMigrator — library seed

    func testSeedsLibraryFromLegacyKeyWhenAbsent() {
        let storage = freshStorage()
        let defaults = freshDefaults()
        let pod = Podcast(id: "p1", name: "Pod", url: "http://x", episodes: [], artworkUrl: nil)
        defaults.set(try! JSONEncoder().encode([pod]), forKey: "savedPodcasts")

        _ = PersistenceMigrator(storage: storage, defaults: defaults).run()

        storage.flush()
        let lib: [Podcast]? = storage.load(from: "library.json")
        XCTAssertEqual(lib?.first?.id, "p1", "library.json is seeded from the legacy key")
        XCTAssertNil(defaults.data(forKey: "savedPodcasts"), "legacy key is always cleared")
    }

    func testDoesNotClobberExistingLibrary() {
        let storage = freshStorage()
        let defaults = freshDefaults()
        storage.save([Podcast(id: "keep", name: "Keep", url: "u", episodes: [], artworkUrl: nil)],
                     to: "library.json")
        storage.flush()
        let stale = Podcast(id: "legacy", name: "Legacy", url: "u2", episodes: [], artworkUrl: nil)
        defaults.set(try! JSONEncoder().encode([stale]), forKey: "savedPodcasts")

        _ = PersistenceMigrator(storage: storage, defaults: defaults).run()

        storage.flush()
        let lib: [Podcast]? = storage.load(from: "library.json")
        XCTAssertEqual(lib?.first?.id, "keep",
                       "an existing library.json is never overwritten by the legacy seed")
        XCTAssertNil(defaults.data(forKey: "savedPodcasts"),
                     "but the stale legacy key is still cleared so it can't clobber later")
    }

    // MARK: MixStore — legacy-aware reload

    func testMixStoreReloadsLegacySavedMixFormat() {
        let storage = freshStorage()
        storage.save([makeSavedMix(name: "Leg", noiseType: "ocean")], to: "mixes.json")
        storage.flush()

        let store = MixStore(lastMix: nil, savedPresets: [],
                             storageQueue: DispatchQueue(label: "test"), storage: storage)
        store.reloadFromDisk()

        XCTAssertEqual(store.savedPresets.count, 1)
        XCTAssertEqual(store.savedPresets.first?.name, "Leg")
        XCTAssertEqual(store.savedPresets.first?.mode, "sleep")
    }

    func testMixStoreReloadsCurrentPresetFormatAndMigratesNoise() {
        let storage = freshStorage()
        storage.save([makePreset(name: "Cur", mode: "focus", noiseType: "blue")], to: "mixes.json")
        storage.flush()

        let store = MixStore(lastMix: nil, savedPresets: [],
                             storageQueue: DispatchQueue(label: "test"), storage: storage)
        store.reloadFromDisk()

        XCTAssertEqual(store.savedPresets.first?.mode, "focus")
        XCTAssertEqual(store.savedPresets.first?.noiseType, "brown",
                       "retired noise type migrates forward on reload too")
    }
}
