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

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    @ViewBuilder
    private func queueRow(ep: Episode, isFirst: Bool, isLast: Bool) -> some View {
        let title = Text(ep.title)
            .font(.system(.headline, design: .rounded))
            .foregroundColor(pal.text)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .layoutPriority(1)

        let controls = HStack(spacing: 8) {
            if !isFirst {
                Button(action: { queue.moveUp(episode: ep) }) {
                    Image(systemName: "chevron.up.circle.fill").foregroundColor(pal.dim).font(.title3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Move \(ep.title) up")
            }
            if !isLast {
                Button(action: { queue.moveDown(episode: ep) }) {
                    Image(systemName: "chevron.down.circle.fill").foregroundColor(pal.dim).font(.title3)
                }
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Move \(ep.title) down")
            }
            Button(action: { queue.queue.removeAll(where: { $0.id == ep.id }) }) {
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
    
    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                // Drag indicator
                Capsule()
                    .fill(pal.dim)
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)
                
                // Cover Art
                if let first = queue.queue.first, let urlStr = first.artworkUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            RoundedRectangle(cornerRadius: 20).fill(pal.text.opacity(0.1))
                        }
                    }
                    .frame(width: 250, height: 250)
                    .cornerRadius(20)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                } else if let image = UIImage(named: "AppIcon") ?? UIImage(named: "icon-512") {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 250, height: 250)
                        .cornerRadius(20)
                        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(pal.text.opacity(0.1))
                        .frame(width: 250, height: 250)
                }
                
                // Title & Note
                VStack(spacing: 8) {
                    Text(audio.podTitle)
                        .font(.title2.bold())
                        .foregroundColor(pal.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    if let note = audio.playbackNote {
                        Text(note)
                            .font(.subheadline)
                            .foregroundColor(pal.accent)
                    }
                }
                
                // Scrubber
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { isDraggingScrubber ? scrubProgress : progress.progress },
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
                    .accessibilityLabel("Playback position")
                    .accessibilityValue("\(formatTime(progress.elapsed)) of \(formatTime(progress.duration))")

                    HStack {
                        Text(formatTime(isDraggingScrubber ? scrubProgress * progress.duration : progress.elapsed))
                            .font(.caption2).foregroundColor(pal.dim).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                        Spacer()
                        Text("-" + formatTime(progress.duration - (isDraggingScrubber ? scrubProgress * progress.duration : progress.elapsed)))
                            .font(.caption2).foregroundColor(pal.dim).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .accessibilityHidden(true)
                }
                .padding(.horizontal, 30)
                
                // Transports
                HStack(spacing: 20) {
                    Button(action: { audio.seekPodcast(seconds: -audio.skipInterval) }) {
                        Image(systemName: audio.skipBackSymbol)
                            .font(.title2)
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Skip back \(Int(audio.skipInterval)) seconds")

                    Button(action: { audio.togglePodcast() }) {
                        Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: min(playGlyph, 80)))
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 64, minHeight: 64)
                    .accessibilityLabel(audio.isPodPlaying ? "Pause" : "Play")

                    Button(action: { audio.seekPodcast(seconds: audio.skipInterval) }) {
                        Image(systemName: audio.skipForwardSymbol)
                            .font(.title2)
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Skip forward \(Int(audio.skipInterval)) seconds")

                    Button(action: { queue.advanceQueue() }) {
                        Image(systemName: "forward.end.fill")
                            .font(.title2)
                            .foregroundColor(pal.accent)
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Next episode")
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
                
                // Up Next Queue Section
                if queue.queue.count > 1 { // More than just the currently playing item
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Image(systemName: "list.dash")
                                .foregroundColor(pal.accent)
                                .accessibilityHidden(true)
                            Text("Up Next")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(pal.text)
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

                        let remainingQueue = Array(queue.queue.dropFirst())
                        ForEach(remainingQueue.indices, id: \.self) { i in
                            queueRow(ep: remainingQueue[i], isFirst: i == 0, isLast: i == remainingQueue.count - 1)
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
