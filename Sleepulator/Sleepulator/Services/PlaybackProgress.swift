import Foundation
import Combine

/// High-frequency podcast playback position, isolated in its own `ObservableObject` so the
/// ~1/sec time-observer updates invalidate only the now-playing views (MiniPlayer, NowPlaying)
/// — not every view holding the `AudioEngine`. `AudioEngine` owns this and writes it from the
/// player's time observer, but deliberately does NOT forward its `objectWillChange`, which is the
/// whole point: progress ticks no longer re-render HomeView / the tab bar / the other tabs.
final class PlaybackProgress: ObservableObject {
    @Published var progress: Double = 0.0   // 0…1
    @Published var elapsed: Double = 0.0     // seconds
    @Published var duration: Double = 1.0    // seconds (1.0 sentinel until a real duration is known)
}
