import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var audio: AudioEngine
    /// The high-frequency playback position, observed directly so the 1 Hz progress updates
    /// re-render only this view, not the whole tree.
    @ObservedObject var progress: PlaybackProgress
    @Binding var selectedTab: Int
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @State private var showNowPlaying = false
    @ScaledMetric(relativeTo: .title) private var playGlyph: CGFloat = 32

    var pal: Palette { Palette(bedtime: bedtimeMode) }

    var body: some View {
        if audio.hasLoadedEpisode {
            VStack(spacing: 0) {
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
    }
}
