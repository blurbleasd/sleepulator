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
/// AVAudioSession delivers interruption / route notifications on an arbitrary system thread, so
/// each forward below hops to the main queue before invoking the handler — the handlers mutate
/// @Published state and reach the generative engine's updateParams (main-queue + single-writer).
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

    @objc private func forwardInterruption(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onInterruption?(note) }
    }
    @objc private func forwardRouteChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in self?.onRouteChange?(note) }
    }
    @objc private func forwardAppBackground() {
        DispatchQueue.main.async { [weak self] in self?.onAppBackground?() }
    }

    deinit {
        monitor.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
