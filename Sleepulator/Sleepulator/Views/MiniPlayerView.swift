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
            if audio.hasLoadedEpisode {
                loadedBar
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
        // The UI tests find the bar by this, whatever state it shows; `.contain` keeps its
        // controls separate elements for VoiceOver.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("miniPlayer")
        .padding(.bottom, 80) // float above the tab bar
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingSheet(audio: audio, queue: audio.queueManager, progress: progress, isPresented: $showNowPlaying, pal: pal)
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: Loaded — full transport (unchanged behaviour)

    @ViewBuilder
    private var loadedBar: some View {
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

            // Play/Pause — its own button, NOT nested inside the open-player button.
            Button(action: { audio.togglePodcast() }) {
                Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: min(playGlyph, 40)))
                    .foregroundColor(pal.accent)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityShowsLargeContentViewer()
            .accessibilityLabel(audio.isPodPlaying ? "Pause podcast" : "Play podcast")

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
                        Text(audio.podTitle)
                            .font(.subheadline.bold())
                            .foregroundColor(pal.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .truncationMode(.tail)

                        if let note = audio.playbackNote {
                            Text(note)
                                .font(.caption2)
                                .foregroundColor(pal.accent)
                                .lineLimit(1)
                        } else {
                            Text(audio.isPodPlaying ? "Playing" : "Paused")
                                .font(.caption2)
                                .foregroundColor(pal.dim)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Now playing: \(audio.podTitle)")
            .accessibilityHint("Opens the full player")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Up next — queue has items, nothing loaded yet

    @ViewBuilder
    private func upNextBar(_ next: Episode) -> some View {
        HStack(spacing: 6) {
            Button(action: { audio.playAll(queue.queue) }) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: min(playGlyph, 40)))
                    .foregroundColor(pal.accent)
            }
            .frame(minWidth: 44, minHeight: 44)
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
                        Text(queue.queue.count == 1 ? "Up next" : "Up next · \(queue.queue.count) in queue")
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
            // Not a play button: with nothing loaded there's nothing to play, and a dim ▶ that did
            // nothing read as broken. A plain podcast mark instead.
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.body)
                .foregroundColor(pal.dim)
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
