import XCTest
@testable import Sleepulator

/// Export → (JSON file) → import fidelity for the settings backup. The picker can't be scripted,
/// so this drives the two pure halves the real Export/Import call — `backupUserDefaults` and
/// `restoreUserDefaults` — with a JSON serialize/deserialize between them (exactly what writing and
/// re-reading the backup file does). Guards the persistence-critical path: full round-trip, the
/// security allowlist, malformed-section tolerance, and the extraLayers gap this change closed.
final class BackupRoundTripTests: XCTestCase {

    private let suite = "BackupRoundTripTests.suite"
    private var d: UserDefaults!

    override func setUpWithError() throws {
        d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
    }
    override func tearDown() {
        d.removePersistentDomain(forName: suite)
        d = nil
    }

    /// What actually happens between export and import: the dict is written to a JSON file and read
    /// back. Round-tripping through JSONSerialization here reproduces any type coercion the file does.
    private func throughBackupFile(_ dict: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: full scalar round-trip (Double / Bool / Int / String all survive the JSON hop)

    func testScalarsRoundTripThroughJSON() throws {
        d.set(0.42, forKey: "masterVolume")
        d.set(true,  forKey: "autoPlay")
        d.set(false, forKey: "shuffleQueue")
        d.set(30.0,  forKey: "skipInterval")
        d.set(20,    forKey: "timerMinutes")
        d.set("green", forKey: "noiseType")
        d.set(true,  forKey: "focusMode")
        d.set("still-water", forKey: "sceneSleep")

        let file = try throughBackupFile(SettingsView.backupUserDefaults(from: d))
        d.removePersistentDomain(forName: suite)                 // wipe → prove restore, not leftover state
        let (restored, skipped) = SettingsView.restoreUserDefaults(from: file, into: d)

        XCTAssertEqual(skipped, 0)
        XCTAssertEqual(restored, 8)
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.42, accuracy: 1e-9)
        XCTAssertTrue(d.bool(forKey: "autoPlay"))
        XCTAssertFalse(d.bool(forKey: "shuffleQueue"))
        XCTAssertEqual(d.double(forKey: "skipInterval"), 30, accuracy: 1e-9)
        XCTAssertEqual(d.integer(forKey: "timerMinutes"), 20)
        XCTAssertEqual(d.string(forKey: "noiseType"), "green")
        XCTAssertTrue(d.bool(forKey: "focusMode"))
        XCTAssertEqual(d.string(forKey: "sceneSleep"), "still-water")
    }

    // MARK: extraLayers — the Data-encoded blob that was silently dropped from every backup

    func testExtraLayersRoundTrip() throws {
        let layers = [
            ExtraNoiseLayer(id: "a", type: "rain", volume: 0.6, muted: nil),
            ExtraNoiseLayer(id: "b", type: "fire", volume: 0.3, muted: true),
        ]
        d.set(try JSONEncoder().encode(layers), forKey: "extraLayers")

        let file = try throughBackupFile(SettingsView.backupUserDefaults(from: d))
        XCTAssertNotNil(file["extraLayers"], "extraLayers must be included in the backup")

        d.removePersistentDomain(forName: suite)
        _ = SettingsView.restoreUserDefaults(from: file, into: d)

        let raw = try XCTUnwrap(d.data(forKey: "extraLayers"))
        XCTAssertEqual(try JSONDecoder().decode([ExtraNoiseLayer].self, from: raw), layers)
    }

    // MARK: security — restore writes nothing outside the allowlist

    func testUnknownKeysNeverWritten() throws {
        let dict: [String: Any] = ["evilKey": "pwned", "masterVolume": 0.5]
        let (restored, skipped) = SettingsView.restoreUserDefaults(from: dict, into: d)
        XCTAssertNil(d.object(forKey: "evilKey"))
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.5, accuracy: 1e-9)
        XCTAssertEqual(restored, 1)
        XCTAssertEqual(skipped, 1)
    }

    // MARK: robustness — a malformed section is skipped, the rest still restores

    func testMalformedEncodedBlobSkippedButRestContinues() throws {
        let dict: [String: Any] = ["extraLayers": ["not": "a layer array"], "masterVolume": 0.7]
        let (_, skipped) = SettingsView.restoreUserDefaults(from: dict, into: d)
        XCTAssertNil(d.data(forKey: "extraLayers"))                              // garbage rejected
        XCTAssertEqual(d.double(forKey: "masterVolume"), 0.7, accuracy: 1e-9)    // rest still restored
        XCTAssertGreaterThanOrEqual(skipped, 1)
    }

    // MARK: file-backed validation gate

    func testFileBackedValidationGate() throws {
        let goodPositions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(["ep1": 12.5]))
        XCTAssertNotNil(SettingsView.validatedFileData(key: "episodePositions", value: goodPositions))
        XCTAssertNil(SettingsView.validatedFileData(key: "episodePositions", value: ["ep1": "not-a-number"]))
        XCTAssertNil(SettingsView.validatedFileData(key: "unknownFile", value: [String: Any]()))
    }
}
