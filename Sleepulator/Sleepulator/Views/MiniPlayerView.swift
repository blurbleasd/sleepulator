import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var audio: AudioEngine
    @Binding var selectedTab: Int
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @State private var showNowPlaying = false
    @ScaledMetric(relativeTo: .title) private var playGlyph: CGFloat = 32

    var pal: Palette { Palette(bedtime: bedtimeMode) }

    var body: some View {
        if audio.hasLoadedEpisode {
            VStack(spacing: 0) {
                // Thin progress bar
                ProgressView(value: max(0, min(1, audio.podcastProgress)))
                    .progressViewStyle(LinearProgressViewStyle(tint: pal.accent))
                    .frame(height: 2)
                    .accessibilityLabel("Episode progress")
                    .accessibilityValue("\(Int(audio.podcastProgress * 100)) percent")

                HStack(spacing: 6) {
                    Button(action: { audio.seekPodcast(seconds: -15) }) {
                        Image(systemName: "gobackward.15")
                            .font(.title3)
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 40, minHeight: 44)
                    .accessibilityLabel("Skip back 15 seconds")

                    // Play/Pause — its own button, NOT nested inside the open-player button.
                    Button(action: { audio.togglePodcast() }) {
                        Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: min(playGlyph, 40)))
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(audio.isPodPlaying ? "Pause podcast" : "Play podcast")

                    Button(action: { audio.seekPodcast(seconds: 15) }) {
                        Image(systemName: "goforward.15")
                            .font(.title3)
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 40, minHeight: 44)
                    .accessibilityLabel("Skip forward 15 seconds")

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
            .padding(.bottom, 80) // Elevate above tab bar
            .sheet(isPresented: $showNowPlaying) {
                NowPlayingSheet(audio: audio, isPresented: $showNowPlaying, pal: pal)
            }
        }
    }
}
