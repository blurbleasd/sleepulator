import Foundation
import AVFoundation
import Network

/// Owns the audio-session plumbing AudioEngine used to carry inline (Slice A3 of
/// ARCHITECTURE-REFACTOR-PLAN.md): session activation, the interruption / route-change /
/// app-background observers, and the NWPathMonitor. It owns only the *plumbing* —
/// registration, the monitor lifecycle, session activation — and forwards each event to
/// AudioEngine through closures, so the actual policy (what to pause / resume / re-assert)
/// stays in AudioEngine, unchanged.
///
/// The notification observers are selector-based and queue-less, exactly as before, so the
/// interruption / route handlers still run synchronously on the notification's posting thread
/// (a system thread, not main) — the original timing is preserved, not changed.
final class AudioSessionController {
    var onInterruption: ((Notification) -> Void)?
    var onRouteChange: ((Notification) -> Void)?
    var onAppBackground: (() -> Void)?
    var onOnlineChanged: ((Bool) -> Void)?

    private let monitor = NWPathMonitor()

    /// Activate the shared playback session. (AudioEngine's interruption-resume path
    /// re-activates the session directly; this is the initial activation at startup.)
    func activateSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default, options: [])
        try? s.setActive(true)
    }

    func start() {
        activateSession()

        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.onOnlineChanged?(path.status == .satisfied) }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(forwardInterruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        nc.addObserver(self, selector: #selector(forwardRouteChange(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(forwardAppBackground), name: Notification.Name("AppDidEnterBackground"), object: nil)
    }

    @objc private func forwardInterruption(_ note: Notification) { onInterruption?(note) }
    @objc private func forwardRouteChange(_ note: Notification) { onRouteChange?(note) }
    @objc private func forwardAppBackground() { onAppBackground?() }

    deinit {
        monitor.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
