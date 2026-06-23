import CoreMotion
import simd
import Foundation

/// Held-only gyro parallax source, shared by any scene that wants a subtle tilt-driven
/// parallax (originally `RainGlassDepthView`, now also general scenes via `SceneContext.tilt`).
///
/// Owns a single `CMMotionManager`, started only while a motion-using scene is on screen and
/// animating, and stopped the moment it settles or disappears — so it costs nothing on the
/// all-night occluded screen the app is built for. `setActive(_:)` is the one-call reconcile
/// the owner uses to gate it.
///
/// Crucially it does **not** publish per frame. The smoothed tilt is a plain property that the
/// view reads inside its existing `TimelineView` redraw; pushing it through `@Published` would
/// invalidate `HomeView` 30×/sec — exactly the re-render storm `CLAUDE.md` warns about
/// (the `rmsPower` mistake). It is therefore a plain `class`, not an `ObservableObject`.
///
/// Parallax is **relative to the hold position when the scene appears** (attitude is taken
/// against a reference frame captured on the first sample). That means it recentres each time
/// and is orientation-independent — and when the phone lies flat on a nightstand, tilt stays ~0,
/// so parallax is a pure bonus during the watching window, not a load-bearing cue.
final class TiltSource {
    /// Smoothed tilt, roughly [-1, 1] per axis: x = roll (left/right), y = pitch (toward/away).
    /// Written on the main queue by CoreMotion; read on the main thread in the render loop.
    private(set) var tilt = SIMD2<Float>(0, 0)

    private let manager = CMMotionManager()
    private var reference: CMAttitude?
    private var smoothed = SIMD2<Float>(0, 0)
    private var running = false

    /// ~28° of tilt maps to the full parallax throw — gentle, so a resting hand barely moves it.
    private let maxTilt: Float = 0.5
    /// Low-pass factor per sample (0 = frozen, 1 = no smoothing). Glides instead of jittering.
    private let smoothing: Float = 0.12

    func start() {
        guard !running, manager.isDeviceMotionAvailable else { return }
        running = true
        reference = nil
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let m = motion else { return }
            // Re-express attitude relative to the hold captured on the first sample.
            guard let a = m.attitude.copy() as? CMAttitude else { return }
            if let ref = self.reference {
                a.multiply(byInverseOf: ref)
            } else {
                self.reference = m.attitude.copy() as? CMAttitude
            }
            let target = SIMD2<Float>(
                max(-1, min(1, Float(a.roll) / self.maxTilt)),
                max(-1, min(1, Float(a.pitch) / self.maxTilt))
            )
            self.smoothed += (target - self.smoothed) * self.smoothing
            self.tilt = self.smoothed
        }
    }

    /// One-call reconcile for the owner: start when a motion-using scene is active and visible,
    /// stop otherwise. Idempotent (start/stop already guard redundant calls).
    func setActive(_ on: Bool) { on ? start() : stop() }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
        reference = nil
        // Ease back toward neutral so a later restart doesn't snap the far world.
        smoothed = .zero
        tilt = .zero
    }

    deinit { stop() }
}
