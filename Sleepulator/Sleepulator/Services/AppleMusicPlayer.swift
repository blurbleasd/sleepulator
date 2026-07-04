import Foundation
import MusicKit
import Combine

/// Apple Music as a **parallel** Focus-mode source.
///
/// Unlike `PodcastPlayer` — which owns its `AVPlayer`, taps the stream, and shapes volume / EQ /
/// the Night Limiter sample-by-sample — Apple Music catalog audio is DRM-protected. The app gets
/// **no PCM access**, so it can't flow through `GenerativeAudioEngine`'s `AVAudioSourceNode` mixer
/// or the limiter tap. It plays through MusicKit's system `ApplicationMusicPlayer`, *alongside* the
/// generative bed, with the audio session set to `.mixWithOthers` (see `AudioSessionConfig`).
///
/// Scoped to Focus on purpose: the Night Limiter is already off in Focus, and Focus isn't the
/// all-night screen-locked case, so losing per-source volume + the sleep-timer fade matters far
/// less there. Volume is whatever the device's system music volume is — there is no clean
/// per-instance output level on `ApplicationMusicPlayer`. See APPLE-MUSIC-FOCUS-SPEC.md.
///
/// The module defaults to `@MainActor` isolation (SWIFT_DEFAULT_ACTOR_ISOLATION); MusicKit's
/// player is main-actor friendly, so this stays on the main actor and posts plain callbacks
/// (matching `PodcastPlayer`'s closure style) rather than being an `ObservableObject` itself —
/// `AudioEngine` republishes the low-frequency bits it needs.
final class AppleMusicPlayer {
    /// Fired when playback starts/stops (true = playing).
    var onPlaybackStateChanged: ((Bool) -> Void)?
    /// Fired when the now-playing entry changes — (title, subtitle e.g. artist/album).
    var onNowPlayingChanged: ((String, String?) -> Void)?
    /// Non-fatal note for the UI (auth denied, no subscription, transient failure). Mirrors
    /// `PodcastPlayer.onPlaybackNote` — never implies the rest of the mix has stopped.
    var onNote: ((String) -> Void)?

    private let player = ApplicationMusicPlayer.shared
    private var stateObserver: AnyCancellable?
    private var queueObserver: AnyCancellable?

    /// True while the system player reports `.playing`.
    var isPlaying: Bool { player.state.playbackStatus == .playing }
    /// True once a queue has been set — i.e. the user has chosen something to play at least once
    /// this session. Drives the UI's "pick music" CTA vs. an on/off toggle.
    private(set) var hasSelection = false

    init() {
        // `ApplicationMusicPlayer.state` and `.queue` are ObservableObjects; mirror their changes
        // out as callbacks so `AudioEngine` can publish coarse UI state without polling. The
        // `objectWillChange` fires *before* the value settles, so we hop a runloop turn (Task) to
        // read the updated status/entry.
        stateObserver = player.state.objectWillChange.sink { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.onPlaybackStateChanged?(self.isPlaying) }
        }
        queueObserver = player.queue.objectWillChange.sink { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if let entry = self.player.queue.currentEntry {
                    self.onNowPlayingChanged?(entry.title, entry.subtitle)
                }
            }
        }
    }

    // MARK: - Authorization / subscription

    var isAuthorized: Bool { MusicAuthorization.currentStatus == .authorized }

    /// Ensure the app is authorized to use Apple Music, prompting on first use. Returns whether
    /// playback can proceed. Denied / restricted is surfaced as a gentle note, not a hard failure —
    /// the rest of the Focus mix keeps playing.
    @discardableResult
    func ensureAuthorized() async -> Bool {
        switch MusicAuthorization.currentStatus {
        case .authorized:
            return true
        case .notDetermined:
            let status = await MusicAuthorization.request()
            if status != .authorized {
                onNote?("Apple Music access is off. Enable it in Settings to use it in Focus.")
            }
            return status == .authorized
        default:
            onNote?("Apple Music access is off. Enable it in Settings ▸ Sleepulator.")
            return false
        }
    }

    /// Whether the signed-in account can actually stream catalog content (an active subscription).
    func canPlayCatalog() async -> Bool {
        do { return try await MusicSubscription.current.canPlayCatalogContent }
        catch { return false }
    }

    // MARK: - Content selection

    /// Search the Apple Music catalog for the picker UI. Returns songs / albums / playlists.
    func search(_ term: String) async -> MusicCatalogSearchResponse? {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isAuthorized, !trimmed.isEmpty else { return nil }
        var request = MusicCatalogSearchRequest(term: trimmed, types: [Song.self, Album.self, Playlist.self])
        request.limit = 20
        do {
            return try await request.response()
        } catch is CancellationError {
            return nil  // superseded search-as-you-type request; not an error
        } catch {
            // A failed search (offline, lapsed subscription, server error) must not look
            // identical to "no results" — tell the picker why it's empty.
            onNote?("Apple Music search failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Set the queue to a playable item (Song / Album / Playlist) and start playback.
    /// The caller is responsible for having set `.mixWithOthers` + activated the session first.
    func play<Item: PlayableMusicItem>(_ item: Item) async {
        do {
            player.queue = [item]
            hasSelection = true
            try await player.play()
        } catch {
            onNote?("Couldn't start Apple Music: \(error.localizedDescription)")
        }
    }

    // MARK: - Transport

    func resume() async {
        guard hasSelection else { return }
        do { try await player.play() }
        catch { onNote?("Couldn't resume Apple Music.") }
    }

    func pause() { player.pause() }

    /// Stop and clear so the next start is a fresh queue. Used on mode-exit and global stop.
    func stop() {
        player.stop()
        // Leave `hasSelection` as-is: the user's choice persists for the Focus session so the row
        // stays a toggle rather than reverting to the picker CTA after a transient stop.
    }
}
