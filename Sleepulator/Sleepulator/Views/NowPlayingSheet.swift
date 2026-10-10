import SwiftUI
import MediaPlayer

struct NowPlayingSheet: View {
    @ObservedObject var audio: AudioEngine
    /// Observed directly so the Up Next queue list refreshes after Phase 3 dropped the
    /// queueManager objectWillChange forward into AudioEngine.
    @ObservedObject var queue: PodcastQueueManager
    /// High-frequency playback position, observed directly (see PlaybackProgress).
    @ObservedObject var progress: PlaybackProgress
    @Binding var isPresented: Bool
    let pal: Palette

    @State private var isDraggingScrubber = false
    @State private var scrubProgress: Double = 0.0
    @ScaledMetric(relativeTo: .largeTitle) private var playGlyph: CGFloat = 64
    @Environment(\.dynamicTypeSize) private var typeSize

    /// One source for what's playing and what follows (see NowPlayingState).
    private var state: NowPlayingState { NowPlayingState(loaded: audio.loadedEpisode, queue: queue.queue) }
    private var phase: NowPlayingState.Phase {
        NowPlayingState.phase(isLoaded: audio.loadedEpisode != nil, failed: audio.podcastFailed,
                              isPlaying: audio.isPodPlaying,
                              elapsed: progress.elapsed, duration: progress.duration)
    }
    /// The scrubber and skips work only once the player knows where it is.
    private var canSeek: Bool { [.playing, .paused, .finished].contains(phase) }

    @ViewBuilder
    private func queueRow(ep: Episode, isFirst: Bool, isLast: Bool) -> some View {
        let title = Text(ep.title)
            .font(.system(.headline, design: .rounded))
            .foregroundColor(pal.text)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)

        let nowPlayingId = audio.loadedEpisode?.id
        let controls = HStack(spacing: 8) {
            if !isFirst {
                Button(action: { queue.moveInUpNext(ep, by: -1, nowPlayingId: nowPlayingId) }) {
                    Image(systemName: "chevron.up.circle.fill").foregroundColor(pal.dim).font(.title3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Move \(ep.title) up")
            }
            if !isLast {
                Button(action: { queue.moveInUpNext(ep, by: 1, nowPlayingId: nowPlayingId) }) {
                    Image(systemName: "chevron.down.circle.fill").foregroundColor(pal.dim).font(.title3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Move \(ep.title) down")
            }
            Button(action: { queue.remove(ep) }) {
                Image(systemName: "xmark.circle.fill").foregroundColor(pal.accent).font(.title3)
            }
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel("Remove \(ep.title) from queue")
        }

        // At accessibility sizes the title can't share a row with three buttons — stack them.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    title
                    HStack { Spacer(); controls }
                }
            } else {
                HStack(spacing: 12) {
                    title
                    Spacer()
                    controls
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(pal.text.opacity(0.05))
        .cornerRadius(12)
        .padding(.horizontal, 30)
    }

    /// Under the title: what the player is doing when that needs saying. A failure gets its way
    /// out right here, not a raw system error.
    @ViewBuilder
    private var statusLine: some View {
        switch phase {
        case .failed:
            VStack(spacing: UI.sm) {
                Text("Couldn't play this episode")
                    .font(.subheadline)
                    .foregroundColor(pal.accent)
                HStack(spacing: UI.md) {
                    Button("Try again") { audio.retryLoadedEpisode() }
                    if !state.upNext.isEmpty {
                        Button("Play next") { audio.skipToNextEpisode() }
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(pal.text)
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(pal.text)
            }
        case .ready:
            Text(readyLine)
                .font(.subheadline)
                .foregroundColor(pal.dim)
        case .loading:
            Text("Loading…")
                .font(.subheadline)
                .foregroundColor(pal.dim)
        default:
            if let note = audio.playbackNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundColor(pal.accent)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// "Up next · 1 hour, 16 minutes" for an episode waiting at the head of the queue.
    private var readyLine: String {
        guard let d = state.hero?.duration, d > 0 else { return "Up next" }
        return "Up next · \(PlayerClock.spoken(d))"
    }

    @ViewBuilder
    private var scrubber: some View {
        if phase == .live {
            Text("Live · \(PlayerClock.string(progress.elapsed))")
                .font(.caption).foregroundColor(pal.dim).monospacedDigit()
                .padding(.horizontal, 30)
        } else {
            // Before the player knows the length, show the episode's own (from its feed) rather
            // than a placeholder "-0:01".
            let duration = canSeek ? progress.duration : (state.hero?.duration ?? 0)
            let elapsed = canSeek ? (isDraggingScrubber ? scrubProgress * duration : progress.elapsed) : 0
            VStack(spacing: 4) {
                Slider(value: Binding(
                    get: { canSeek ? (isDraggingScrubber ? scrubProgress : progress.progress) : 0 },
                    set: { newVal in
                        scrubProgress = newVal
                        isDraggingScrubber = true
                    }
                ), in: 0...1) { editing in
                    if !editing {
                        isDraggingScrubber = false
                        audio.seekPodcast(to: scrubProgress)
                    }
                }
                .tint(pal.accent)
                .disabled(!canSeek)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(PlayerClock.spoken(elapsed)) of \(PlayerClock.spoken(duration))")

                HStack {
                    Text(duration > 0 ? PlayerClock.string(elapsed) : "--:--")
                        .font(.caption2).foregroundColor(pal.dim).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    Spacer()
                    Text(duration > 0 ? "-" + PlayerClock.string(duration - elapsed) : "--:--")
                        .font(.caption2).foregroundColor(pal.dim).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                }
                .accessibilityHidden(true)
            }
            .padding(.horizontal, 30)
        }
    }

    @ViewBuilder
    private var playButton: some View {
        let size = min(playGlyph, 80)
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .tint(pal.accent)
                .frame(width: size, height: size)
                .accessibilityLabel("Loading episode")
        case .failed:
            Button(action: { audio.retryLoadedEpisode() }) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: size))
                    .foregroundColor(pal.accent)
            }
            .frame(minWidth: 64, minHeight: 64)
            .accessibilityLabel("Try again")
        default:
            Button(action: { audio.togglePodcast() }) {
                Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: size))
                    .foregroundColor(pal.accent)
            }
            .frame(minWidth: 64, minHeight: 64)
            .accessibilityLabel(audio.isPodPlaying ? "Pause" : "Play")
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                // Drag indicator
                Capsule()
                    .fill(pal.dim)
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)

                EpisodeArtwork(url: state.hero?.artworkUrl, pal: pal, size: 250)
                    // Show artwork is often near-white and was the brightest thing in the app at
                    // night; in Sleep it sits back a step (Focus keeps it full).
                    .opacity(pal.warm ? 0.78 : 1)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)

                // Title & status
                VStack(spacing: 8) {
                    Text(state.hero?.title ?? "Nothing queued")
                        .font(.title2.bold())
                        .foregroundColor(pal.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if state.hero == nil {
                        Text("Add episodes from a show's page.")
                            .font(.subheadline)
                            .foregroundColor(pal.dim)
                    } else {
                        statusLine
                    }
                }

                if state.hero != nil {
                    scrubber

                    // Transports
                    HStack(spacing: 20) {
                        Button(action: { audio.seekPodcast(seconds: -audio.skipInterval) }) {
                            Image(systemName: audio.skipBackSymbol)
                                .font(.title2)
                                .foregroundColor(pal.accent)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!canSeek)
                        .accessibilityLabel("Skip back \(Int(audio.skipInterval)) seconds")

                        playButton

                        Button(action: { audio.seekPodcast(seconds: audio.skipInterval) }) {
                            Image(systemName: audio.skipForwardSymbol)
                                .font(.title2)
                                .foregroundColor(pal.accent)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!canSeek)
                        .accessibilityLabel("Skip forward \(Int(audio.skipInterval)) seconds")

                        // Safe Next: plays the next episode, never deletes the skipped one's
                        // download. Off when nothing is loaded (play starts the head) or nothing
                        // follows.
                        Button(action: { audio.skipToNextEpisode() }) {
                            Image(systemName: "forward.end.fill")
                                .font(.title2)
                                .foregroundColor(pal.accent)
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(!state.isLoaded || state.upNext.isEmpty)
                        .accessibilityLabel("Play next episode")
                    }
                }

                // Speed & Audio Options
                HStack {
                    Text("Speed:")
                        .font(.subheadline)
                        .foregroundColor(pal.dim)

                    Menu {
                        ForEach([0.8, 1.0, 1.2, 1.5, 2.0], id: \.self) { speed in
                            Button(action: { audio.playbackSpeed = speed }) {
                                Text(String(format: "%.1fx", speed))
                            }
                        }
                    } label: {
                        Text(String(format: "%.1fx", audio.playbackSpeed))
                            .font(.headline)
                            .foregroundColor(pal.accent)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .frame(minHeight: 44)
                            .background(pal.text.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(String(format: "%.1f times", audio.playbackSpeed))
                }

                // Up Next: everything after the hero, wherever the playing episode sits.
                if !state.upNext.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "list.dash")
                                .foregroundColor(pal.accent)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Up Next")
                                    .font(.system(.title3, design: .rounded).bold())
                                    .foregroundColor(pal.text)
                                // Total remaining time — handy when picking a sleep-timer length.
                                // Durations of 0 (unknown/live) are simply not counted.
                                let secs = state.upNext.reduce(0.0) { $0 + max(0, $1.duration ?? 0) }
                                let count = state.upNext.count
                                Text("\(count) episode\(count == 1 ? "" : "s")" + (secs > 60 ? " · \(Int(secs) / 3600 > 0 ? "\(Int(secs) / 3600)h " : "")\((Int(secs) % 3600) / 60)m" : ""))
                                    .font(.caption)
                                    .foregroundColor(pal.dim)
                            }
                            Spacer()
                            Button(action: { queue.shuffleRemainingQueue() }) {
                                Image(systemName: "shuffle")
                                    .foregroundColor(pal.accent)
                                    .padding(8)
                                    .background(pal.text.opacity(0.1))
                                    .cornerRadius(8)
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel("Shuffle up next")
                        }
                        .padding(.horizontal, 30)

                        let upNext = state.upNext
                        ForEach(Array(upNext.enumerated()), id: \.element.id) { i, ep in
                            queueRow(ep: ep, isFirst: i == 0, isLast: i == upNext.count - 1)
                        }
                    }
                    .padding(.top, 20)
                }

                Spacer().frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg.ignoresSafeArea())
    }
}

/// An episode's artwork, with a quiet placeholder while it loads, when it fails, or when the feed
/// has none. (The old fallback looked for an "AppIcon" / "icon-512" image that doesn't resolve at
/// runtime, leaving an empty grey slab.)
struct EpisodeArtwork: View {
    let url: String?
    let pal: Palette
    let size: CGFloat

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: UI.cardRadius))
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: UI.cardRadius)
            .fill(pal.text.opacity(0.06))
            .overlay(
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.28, weight: .light))
                    .foregroundColor(pal.dim.opacity(0.6))
            )
    }
}
