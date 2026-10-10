import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var audio: AudioEngine
    /// The high-frequency playback position, observed directly so the 1 Hz progress updates
    /// re-render only this view, not the whole tree.
    @ObservedObject var progress: PlaybackProgress
    /// Observed so the bar can show "Up next" the moment something is queued, before any episode
    /// is loaded (user-action frequency — no re-render storm, same as NowPlayingSheet).
    @ObservedObject var queue: PodcastQueueManager
    @Binding var selectedTab: Int
    /// Owned by ContentView so Home's screensaver knows the full player is up (it must not fade
    /// Home, the tab bar and this bar behind the sheet).
    @Binding var showNowPlaying: Bool
    /// A touch in the full player, for the night veil's countdown (see NowPlayingSheet).
    var onSheetInteraction: () -> Void = {}
    @ScaledMetric(relativeTo: .title) private var playGlyph: CGFloat = 32

    /// Mode-aware like Home: Focus is cool everywhere, not just on Home. Read from the persisted
    /// "focusMode" key (AudioEngine writes it) so this view needn't observe the whole engine.
    @AppStorage("focusMode") private var focusMode = false
    var pal: Palette { Palette(focusMode: focusMode) }

    var body: some View {
        // Always present (per design): full controls when an episode is loaded, an actionable
        // "Up next" when the queue has items but nothing's loaded yet, and a quiet "Nothing
        // playing" otherwise — so transport/queue access is always one tap away.
        VStack(spacing: 0) {
            // The loaded episode, not the queue head: the queue can move on without it.
            if let loaded = audio.loadedEpisode {
                loadedBar(loaded)
            } else if let next = queue.queue.first {
                upNextBar(next)
            } else {
                idleBar
            }
        }
        // A real material under the dusk tint: at 85% flat fill, the rows scrolling beneath
        // ghosted through and overprinted the subtitle. Reduce Transparency is honoured by the
        // material itself.
        .background(
            RoundedRectangle(cornerRadius: UI.cardRadius)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: UI.cardRadius).fill(pal.bg.opacity(0.7)))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: -5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: UI.cardRadius)
                .stroke(pal.text.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal)
        // A compact bar: past accessibility size 2 it grew to a third of the screen and covered
        // Home's controls. The transport buttons adopt the Large Content Viewer, so a long press
        // still shows them large.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .padding(.bottom, 80) // float above the tab bar
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingSheet(audio: audio, queue: audio.queueManager, progress: progress,
                            isPresented: $showNowPlaying, pal: pal, onInteraction: onSheetInteraction)
        }
    }

    // MARK: Loaded — full transport

    private var phase: NowPlayingState.Phase {
        NowPlayingState.phase(isLoaded: audio.loadedEpisode != nil, failed: audio.podcastFailed,
                              isPlaying: audio.isPodPlaying,
                              elapsed: progress.elapsed, duration: progress.duration)
    }

    /// What the player is doing, always shown; a note (buffering, stream lost) joins it rather
    /// than replacing it.
    private var statusText: String {
        let state: String
        switch phase {
        case .failed: return "Couldn't play this episode"
        case .loading: state = "Loading…"
        case .live: state = "Live"
        case .finished: state = queue.queue.isEmpty ? "Queue finished" : "Finished"
        case .playing: state = "Playing"
        case .paused, .ready: state = "Paused"
        }
        if let note = audio.playbackNote { return "\(state) · \(note)" }
        return state
    }

    @ViewBuilder
    private func loadedBar(_ episode: Episode) -> some View {
        // Thin progress bar
        ProgressView(value: max(0, min(1, progress.progress)))
            .progressViewStyle(LinearProgressViewStyle(tint: pal.accent))
            .frame(height: 2)
            .accessibilityLabel("Episode progress")
            .accessibilityValue("\(Int(progress.progress * 100)) percent")

        HStack(spacing: 6) {
            Button(action: { audio.seekPodcast(seconds: -audio.skipInterval) }) {
                Image(systemName: audio.skipBackSymbol)
                    .font(.title3)
                    .foregroundColor(pal.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel("Skip back \(Int(audio.skipInterval)) seconds")

            // Play/Pause — its own button, NOT nested inside the open-player button. While the
            // episode loads it's a spinner (a tap there used to resume the previous item); after
            // a failure it retries.
            // The orb's dark disc, small: a solid amber disc here outshone the orb on Sleep Home.
            if phase == .loading {
                PlayerDiscButton(systemImage: nil, diameter: min(playGlyph + 6, 40), pal: pal) {}
                    .disabled(true)
                    .accessibilityLabel("Loading episode")
            } else {
                let failed = phase == .failed
                PlayerDiscButton(systemImage: failed ? "arrow.clockwise" : audio.isPodPlaying ? "pause.fill" : "play.fill",
                                 diameter: min(playGlyph + 6, 40), pal: pal) {
                    failed ? audio.retryLoadedEpisode() : audio.togglePodcast()
                }
                .accessibilityShowsLargeContentViewer()
                .accessibilityLabel(failed ? "Try again" : audio.isPodPlaying ? "Pause podcast" : "Play podcast")
            }

            Button(action: { audio.seekPodcast(seconds: audio.skipInterval) }) {
                Image(systemName: audio.skipForwardSymbol)
                    .font(.title3)
                    .foregroundColor(pal.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel("Skip forward \(Int(audio.skipInterval)) seconds")

            // Title region — a separate sibling button that opens Now Playing.
            Button(action: { showNowPlaying = true }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(episode.title)
                            .font(.subheadline.bold())
                            .foregroundColor(pal.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)

                        Text(statusText)
                            .font(.caption2)
                            .foregroundColor(phase == .failed ? pal.accent : pal.dim)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(episode.title), \(statusText)")
            .accessibilityHint("Opens the full player")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Up next — queue has items, nothing loaded yet

    @ViewBuilder
    private func upNextBar(_ next: Episode) -> some View {
        HStack(spacing: 6) {
            PlayerDiscButton(systemImage: "play.fill", diameter: min(playGlyph + 6, 40), pal: pal) {
                audio.playAll(queue.queue)
            }
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel("Play queue")

            Button(action: { showNowPlaying = true }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(next.title)
                            .font(.subheadline.bold())
                            .foregroundColor(pal.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)
                        // Counts what follows this episode, the way the full player's Up Next does
                        // (it used to count the head too: "5 in queue" over a list of 4).
                        let more = queue.queue.count - 1
                        Text(more == 0 ? "Up next" : "Up next · \(more) more after it")
                            .font(.caption2)
                            .foregroundColor(pal.dim)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Up next: \(next.title)")
            .accessibilityHint("Opens the queue")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Idle — nothing loaded, empty queue

    @ViewBuilder
    private var idleBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "play.circle.fill")
                .font(.system(size: min(playGlyph, 40)))
                .foregroundColor(pal.dim.opacity(0.5))
                .frame(minWidth: 44, minHeight: 44)

            Text("Nothing playing")
                .font(.subheadline)
                .foregroundColor(pal.dim)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nothing playing")
    }
}
