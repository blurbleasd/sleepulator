import UIKit
import os

/// Overnight render diagnostics (visual-moat plan, F3): periodic per-scene frame-rate + thermal +
/// battery samples in the `Log.scene` trail, so the depth-scene A/B (P3) and the power budget (P1)
/// are *measured*, not eyeballed. Fed one `frame()` per rendered frame by the scene hosts; flushes one
/// summary line every `interval` seconds of actual rendering. No samples while a scene is frozen (it
/// renders no frames) — exactly right: the settled state's power is trivially fine and proves nothing.
///
/// A plain class, deliberately not observed (the `SceneClock` / `TiltSource` pattern): `frame()` runs
/// inside the hosts' `TimelineView` render closures, so routing it through `@Published` would trigger
/// the 30 Hz re-render storm CLAUDE.md warns about. The closures evaluate on the main thread, same as
/// the `SceneClock` it sits beside.
final class SceneDiagnostics {
    static let shared = SceneDiagnostics()

    /// The visible scene's id, set by HomeView on appear / scene change — tags each sample so a
    /// depth-vs-flat A/B is attributable in the log.
    var activeScene: String = "—"

    /// Seconds of rendering between summary lines. 30 s → 2 lines/min while animating: enough to catch
    /// a thermal ramp, not enough to bloat the overnight trail.
    private let interval: TimeInterval = 30

    private var windowStart: TimeInterval?
    private var frames = 0

    private init() {
        UIDevice.current.isBatteryMonitoringEnabled = true   // -1 on Simulator; a real level on device
    }

    /// Call once per *rendered* frame (frozen frames don't render, so they're skipped upstream). Cheap:
    /// a counter plus an elapsed check. Flushes a `Log.scene` line every `interval` seconds of rendering.
    func frame(now: TimeInterval) {
        guard let start = windowStart else { windowStart = now; frames = 1; return }
        frames += 1
        let elapsed = now - start
        guard elapsed >= interval else { return }
        flush(fps: Double(frames) / elapsed)
        windowStart = now
        frames = 0
    }

    private func flush(fps: Double) {
        let thermal = Self.thermalName(ProcessInfo.processInfo.thermalState)
        let level = UIDevice.current.batteryLevel
        let battery = level >= 0 ? Int((level * 100).rounded()) : -1
        let fpsStr = String(format: "%.1f", fps)
        Log.scene.info("scene=\(self.activeScene, privacy: .public) fps=\(fpsStr, privacy: .public) thermal=\(thermal, privacy: .public) battery=\(battery, privacy: .public)%")
    }

    private static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
