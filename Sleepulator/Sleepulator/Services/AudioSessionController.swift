import Foundation
import AVFoundation
import Network
import os

/// Single source of truth for the shared playback session's category options. The app is
/// exclusive-`.playback` by default (the all-night Sleep case must not let other audio bleed in),
/// but while Apple Music is an active *parallel* Focus source we layer in `.mixWithOthers` so our
/// session activation doesn't duck or stop MusicKit's system player. Centralized here because the
/// category is set from two places (this controller's `activateSession` and
/// `GenerativeAudioEngine.setupEngine`); both must read the same desired options or a generative
/// (re)start would silently clobber the mix option mid-session. See APPLE-MUSIC-FOCUS-SPEC.md.
enum AudioSessionConfig {
    /// Extra options layered onto the base `.playback` category. Empty = exclusive playback.
    static var options: AVAudioSession.CategoryOptions = []

    /// Re-assert the `.playback` category with the current `options`. Does NOT activate the
    /// session — callers that need it active follow with `Log.activateAudioSession(_:)`. Logs
    /// (rather than swallows) a failure: a category that didn't take is another way the bed can
    /// misbehave overnight, and it belongs in the exported log trail.
    static func applyCategory() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: options)
        } catch {
            Log.audio.error("setCategory(.playback) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

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
        AudioSessionConfig.applyCategory()
        // Route the initial activation through the logged helper too — a failed startup
        // activation is exactly the kind of silent breadcrumb the log export is for.
        Log.activateAudioSession("startup")
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
