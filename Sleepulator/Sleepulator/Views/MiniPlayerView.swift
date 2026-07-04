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
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @State private var showNowPlaying = false
    @ScaledMetric(relativeTo: .title) private var playGlyph: CGFloat = 32

    var pal: Palette { Palette(bedtime: bedtimeMode) }

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
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(pal.bg.opacity(0.85))
                .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: -5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(pal.text.opacity(0.1), lineWidth: 1)
        )
        .padding(.horizontal)
        .padding(.bottom, 80) // float above the tab bar
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingSheet(audio: audio, queue: audio.queueManager, progress: progress, isPresented: $showNowPlaying, pal: pal)
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
            }
            .frame(minWidth: 40, minHeight: 44)
            .accessibilityLabel("Skip back \(Int(audio.skipInterval)) seconds")

            // Play/Pause — its own button, NOT nested inside the open-player button.
            Button(action: { audio.togglePodcast() }) {
                Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: min(playGlyph, 40)))
                    .foregroundColor(pal.accent)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(audio.isPodPlaying ? "Pause podcast" : "Play podcast")

            Button(action: { audio.seekPodcast(seconds: audio.skipInterval) }) {
                Image(systemName: audio.skipForwardSymbol)
                    .font(.title3)
                    .foregroundColor(pal.accent)
            }
            .frame(minWidth: 40, minHeight: 44)
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
