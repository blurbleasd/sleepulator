import Foundation
import MetricKit
import os

/// Battery / hang / crash telemetry via MetricKit — on-device, no third-party SDK, near-zero
/// cost. The app runs all-night shaders and real-time audio with no visibility; this turns
/// "the aurora feels expensive" and "did it hang overnight?" into data.
///
/// iOS delivers `MXMetricPayload` roughly once a day (battery, GPU time, hang rate, launch
/// times…) and `MXDiagnosticPayload` on the next launch after a crash/hang/disk-write spike.
/// Payloads are written as JSON to Application Support/Sleepulator/metrics/ (not iCloud-backed,
/// pruned to the newest `cap`) and surfaced in Settings ▸ Diagnostics for AirDrop/share.
///
/// Registration is `start()` from the app entry — MetricKit only accumulates while a
/// subscriber exists, so register early and exactly once.
final class MetricsCollector: NSObject, MXMetricManagerSubscriber {
    static let shared = MetricsCollector()

    private let cap = 30   // newest N files kept, metrics + diagnostics combined

    private lazy var dir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let d = base.appendingPathComponent("Sleepulator/metrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var u = d
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
        return d
    }()

    private override init() { super.init() }

    func start() {
        MXMetricManager.shared.add(self)
    }

    // Called by MetricKit on a background queue — file I/O is fine here.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads { write(p.jsonRepresentation(), kind: "metrics") }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads { write(p.jsonRepresentation(), kind: "diagnostic") }
    }

    private func write(_ data: Data, kind: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("\(kind)-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            Log.storage.info("MetricKit \(kind, privacy: .public) payload stored (\(data.count) bytes)")
        } catch {
            Log.storage.error("MetricKit \(kind, privacy: .public) write failed: \(error.localizedDescription, privacy: .public)")
        }
        prune()
    }

    private func prune() {
        let files = payloadFiles()
        guard files.count > cap else { return }
        // `payloadFiles` is newest-first; drop everything past the cap.
        for url in files.dropFirst(cap) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stored payload files, newest first. Read by the Settings ▸ Diagnostics list.
    func payloadFiles() -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey],
                                                options: .skipsHiddenFiles)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return da > db
            }
    }
}
