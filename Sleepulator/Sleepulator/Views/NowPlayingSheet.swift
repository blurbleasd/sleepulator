import SwiftUI
import MediaPlayer

/// The full player. Sleep is its hard case: opened in a dark room to check the time left or step
/// back 15 seconds, then left alone. It speaks Home's night language (OrbButton, VolumeBar,
/// ChipRow): depth from darkness, accents as hairlines and glyphs, no solid fills, nothing
/// cold-white. In Sleep the artwork sits back a long way and the title is held to two lines;
/// Focus, a daytime mode, keeps the artwork full.
///
/// Built for a drowsy thumb: back · play · forward, symmetric, with play dead centre; nothing
/// moves under the finger (the status line has a fixed slot); big scrubs can be taken back; a
/// queue removal can be undone; and Next lives with the queue it acts on, not beside skip-15.
struct NowPlayingSheet: View {
    @ObservedObject var audio: AudioEngine
    /// Observed directly so the Up Next queue list refreshes after Phase 3 dropped the
    /// queueManager objectWillChange forward into AudioEngine.
    @ObservedObject var queue: PodcastQueueManager
    /// High-frequency playback position, observed directly (see PlaybackProgress).
    @ObservedObject var progress: PlaybackProgress
    @Binding var isPresented: Bool
    let pal: Palette
    /// Any touch in the sheet. The night veil counts its 60 s from the last interaction; without
    /// this, a sheet in use could be swept away when the veil drops (ContentView).
    var onInteraction: () -> Void = {}

    @State private var isDraggingScrubber = false
    @State private var scrubProgress: Double = 0.0
    /// Where a scrub began, so a long jump can be taken back.
    @State private var scrubFrom: Double = 0
    /// "Back to 3:20": offered for a few seconds after a scrub jumps more than two minutes.
    @State private var seekUndo: Double?
    /// The last queue removal, offered back for a few seconds.
    @State private var removed: RemovedEpisode?
    @ScaledMetric(relativeTo: .largeTitle) private var playDisc: CGFloat = 76
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct RemovedEpisode: Equatable {
        let episode: Episode
        let index: Int
    }

    /// One source for what's playing and what follows (see NowPlayingState).
    private var state: NowPlayingState { NowPlayingState(loaded: audio.loadedEpisode, queue: queue.queue) }
    private var phase: NowPlayingState.Phase {
        NowPlayingState.phase(isLoaded: audio.loadedEpisode != nil, failed: audio.podcastFailed,
                              isPlaying: audio.isPodPlaying,
                              elapsed: progress.elapsed, duration: progress.duration)
    }
    /// The scrubber and skips work only once the player knows where it is.
    private var canSeek: Bool { [.playing, .paused, .finished].contains(phase) }
    /// Sleep's dusk palette, the dark-room case.
    private var night: Bool { pal.warm }

    private func withMotion(_ change: () -> Void) {
        if reduceMotion { change() } else { withAnimation(.easeOut(duration: 0.25)) { change() } }
    }

    // MARK: Up Next rows

    @ViewBuilder
    private func queueRow(ep: Episode, isFirst: Bool, isLast: Bool) -> some View {
        // The title plays the episode now (it couldn't be reached from the queue before).
        let title = Button(action: { queue.playEpisode(ep) }) {
            Text(ep.title)
                .font(.system(.headline, design: .rounded))
                .foregroundColor(pal.text)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays now")
        .layoutPriority(1)

        let nowPlayingId = audio.loadedEpisode?.id
        // Fixed slots: up, down and remove keep their places on every row (a missing "up" on the
        // first row used to slide the others over, so the same spot did different things).
        let controls = HStack(spacing: UI.xs) {
            rowButton("chevron.up.circle", label: "Move \(ep.title) up", hidden: isFirst) {
                withMotion { queue.moveInUpNext(ep, by: -1, nowPlayingId: nowPlayingId) }
            }
            rowButton("chevron.down.circle", label: "Move \(ep.title) down", hidden: isLast) {
                withMotion { queue.moveInUpNext(ep, by: 1, nowPlayingId: nowPlayingId) }
            }
            rowButton("xmark.circle", label: "Remove \(ep.title) from queue", hidden: false) {
                withMotion {
                    if let i = queue.remove(ep) { removed = RemovedEpisode(episode: ep, index: i) }
                }
                let token = ep.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if removed?.episode.id == token { withMotion { removed = nil } }
                }
            }
        }

        // At accessibility sizes the title can't share a row with three buttons — stack them.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: UI.sm) {
                    title
                    HStack { Spacer(); controls }
                }
            } else {
                HStack(spacing: UI.md) {
                    title
                    controls
                }
            }
        }
        .padding(.vertical, UI.xs)
        .padding(.horizontal, UI.lg)
        .background(RoundedRectangle(cornerRadius: UI.cardRadius).fill(pal.text.opacity(0.05)))
        .padding(.horizontal, UI.xxl)
    }

    /// An outlined row glyph in the dim tone (the filled discs read as lit buttons). A hidden one
    /// keeps its slot.
    private func rowButton(_ symbol: String, label: String, hidden: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundColor(pal.dim)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(hidden ? 0 : 1)
        .disabled(hidden)
        .accessibilityHidden(hidden)
        .accessibilityLabel(label)
    }

    // MARK: Status

    /// Under the title, in a slot of fixed height, so a note arriving after Play (buffering, the
    /// limiter) no longer pushes the transport down under the thumb that just pressed it. A
    /// failure gets its way out right here, not a raw system error. Notes are information, not
    /// alarms: dim, not amber.
    private var statusSlot: some View {
        // A clear 44 pt base holds the slot open when it's empty (a frame on an empty Group
        // collapses), so the chip, a note or nothing all leave the scrubber where it was.
        ZStack {
            Color.clear.frame(height: 44)
            statusContent
        }
        .padding(.horizontal, UI.xxl)
    }

    @ViewBuilder
    private var statusContent: some View {
        Group {
            if phase == .failed {
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
            } else if let back = seekUndo, canSeek {
                Button(action: {
                    audio.seekPodcast(to: progress.duration > 0 ? back / progress.duration : 0)
                    withMotion { seekUndo = nil }
                }) {
                    Label("Back to \(PlayerClock.string(back))", systemImage: "arrow.uturn.backward")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(pal.text)
                        .padding(.horizontal, UI.lg)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(pal.text.opacity(0.10)))
                        .overlay(Capsule().stroke(pal.accent.opacity(0.28), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to \(PlayerClock.spoken(back))")
            } else if phase == .loading {
                Text("Loading…").font(.subheadline).foregroundColor(pal.dim)
            } else if phase == .ready {
                Text(readyLine).font(.subheadline).foregroundColor(pal.dim)
            } else if let note = audio.playbackNote {
                Text(note)
                    .font(.subheadline)
                    .foregroundColor(pal.dim)
                    .multilineTextAlignment(.center)
            } else if audio.limiterOffForStream {
                // The one quiet word on the limiter: here, in dim, where the podcast is. It used
                // to be an amber ⚠ banner on Home and replaced "Playing" in the mini-player.
                Text("Night Limiter can't soften this stream")
                    .font(.caption)
                    .foregroundColor(pal.dim)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// "Up next · 1 hour, 16 minutes" for an episode waiting at the head of the queue.
    private var readyLine: String {
        guard let d = state.hero?.duration, d > 0 else { return "Up next" }
        return "Up next · \(PlayerClock.spoken(d))"
    }

    // MARK: Scrubber

    /// The position fader: Home's VolumeBar, not the system Slider, whose iOS 26 thumb was a
    /// pure-white capsule, the brightest object on the Sleep sheet. Relative drag, so a graze
    /// can't throw you 50 minutes, with fine trim when the finger drifts off the track. In Sleep
    /// the thumb is the dim tone, not cream.
    @ViewBuilder
    private var scrubber: some View {
        if phase == .live {
            Text("Live · \(PlayerClock.string(progress.elapsed))")
                .font(.caption).foregroundColor(pal.dim).monospacedDigit()
                .padding(.horizontal, UI.xxl)
        } else {
            // Before the player knows the length, show the episode's own (from its feed) rather
            // than a placeholder "-0:01".
            let duration = canSeek ? progress.duration : (state.hero?.duration ?? 0)
            let elapsed = canSeek ? (isDraggingScrubber ? scrubProgress * duration : progress.elapsed) : 0
            let skip = audio.skipInterval
            VStack(spacing: UI.xs) {
                VolumeBar(
                    value: Binding(
                        get: { canSeek ? (isDraggingScrubber ? scrubProgress : progress.progress) : 0 },
                        set: { scrubProgress = $0 }
                    ),
                    accent: night ? pal.accent.opacity(0.75) : pal.accent,
                    thumbColor: night ? pal.dim : pal.text,
                    style: .channel,
                    customAccessibility: true,
                    onEditingChanged: { editing in
                        onInteraction()
                        if editing {
                            scrubProgress = progress.progress
                            scrubFrom = progress.elapsed
                            isDraggingScrubber = true
                        } else {
                            isDraggingScrubber = false
                            audio.seekPodcast(to: scrubProgress)
                            offerSeekUndo(from: scrubFrom, to: scrubProgress * progress.duration)
                        }
                    }
                )
                .allowsHitTesting(canSeek)
                .opacity(canSeek ? 1 : 0.4)
                // VoiceOver steps by the skip interval, committing each step. (A stand-in Slider
                // moved in ~10% jumps, about 8 minutes of a long episode.)
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue(duration > 0
                                    ? "\(PlayerClock.spoken(elapsed)) of \(PlayerClock.spoken(duration))"
                                    : "Not started")
                .accessibilityAdjustableAction { direction in
                    guard canSeek else { return }
                    switch direction {
                    case .increment: audio.seekPodcast(seconds: skip)
                    case .decrement: audio.seekPodcast(seconds: -skip)
                    @unknown default: break
                    }
                }

                HStack {
                    Text(duration > 0 ? PlayerClock.string(elapsed) : "--:--")
                    Spacer()
                    Text(duration > 0 ? "-" + PlayerClock.string(duration - elapsed) : "--:--")
                }
                .font(.caption2).foregroundColor(pal.dim).monospacedDigit().lineLimit(1)
                .accessibilityHidden(true)
            }
            .padding(.horizontal, UI.xxl)
        }
    }

    /// A scrub that lands more than two minutes away keeps the way back for eight seconds.
    private func offerSeekUndo(from: Double, to: Double) {
        guard abs(to - from) > 120 else { return }
        withMotion { seekUndo = from }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if seekUndo == from { withMotion { seekUndo = nil } }
        }
    }

    // MARK: Transport

    @ViewBuilder
    private var playButton: some View {
        let d = min(playDisc, 92)
        switch phase {
        case .loading:
            PlayerDiscButton(systemImage: nil, diameter: d, pal: pal) {}
                .disabled(true)
                .accessibilityLabel("Loading episode")
        case .failed:
            PlayerDiscButton(systemImage: "arrow.clockwise", diameter: d, pal: pal) { audio.retryLoadedEpisode() }
                .accessibilityLabel("Try again")
        default:
            PlayerDiscButton(systemImage: audio.isPodPlaying ? "pause.fill" : "play.fill", diameter: d, pal: pal) {
                audio.togglePodcast()
            }
            .accessibilityLabel(audio.isPodPlaying ? "Pause" : "Play")
        }
    }

    private func skipButton(forward: Bool) -> some View {
        Button(action: { audio.seekPodcast(seconds: forward ? audio.skipInterval : -audio.skipInterval) }) {
            Image(systemName: forward ? audio.skipForwardSymbol : audio.skipBackSymbol)
                .font(.title2)
                .foregroundColor(pal.accent.opacity(canSeek ? 1 : 0.35))
                .frame(minWidth: 56, minHeight: 56)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSeek)
        .accessibilityLabel("Skip \(forward ? "forward" : "back") \(Int(audio.skipInterval)) seconds")
    }

    // MARK: Body

    var body: some View {
        // At accessibility text sizes the cover gives way, so the transport stays on the first
        // screen.
        let artSize: CGFloat = (night ? 150 : 250) * (typeSize.isAccessibilitySize ? 0.6 : 1)
        ScrollView {
            VStack(spacing: UI.xxl) {
                // Drag indicator
                Capsule()
                    .fill(pal.dim)
                    .frame(width: 40, height: 5)
                    .padding(.top, 10)

                // Sleep: a smaller, desaturated cover under a dark scrim, so the show's (often
                // near-white) art no longer outshines everything else at 2am. Focus keeps it full.
                EpisodeArtwork(url: state.hero?.artworkUrl, pal: pal, size: artSize,
                               dim: night ? 0.5 : 0)
                    .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)

                VStack(spacing: UI.sm) {
                    Text(state.hero?.title ?? "Nothing queued")
                        .font(night ? .headline : .title3.weight(.semibold))
                        .foregroundColor(pal.text)
                        .multilineTextAlignment(.center)
                        .lineLimit(night ? 2 : 3)
                        .truncationMode(.tail)
                        .padding(.horizontal, UI.xxl)

                    if state.hero == nil {
                        Text("Add episodes from a show's page.")
                            .font(.subheadline)
                            .foregroundColor(pal.dim)
                    } else {
                        statusSlot
                    }
                }

                if state.hero != nil {
                    scrubber

                    // Back · play · forward: symmetric, play centred under the thumb.
                    HStack(spacing: UI.xxl) {
                        skipButton(forward: false)
                        playButton
                        skipButton(forward: true)
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
                    upNextSection
                }

                Spacer().frame(height: 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg.ignoresSafeArea())
        // Taps anywhere count as interaction for the night veil (simultaneous: never steals one).
        .simultaneousGesture(TapGesture().onEnded { onInteraction() })
        .overlay(alignment: .bottom) {
            if let removed {
                undoToast(removed)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: UI.md) {
            HStack(spacing: UI.xs) {
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
                headerButton("shuffle", label: "Shuffle up next") { withMotion { queue.shuffleRemainingQueue() } }
                // Next lives with the queue it acts on. Beside skip-15, at the same weight, it was
                // a 2am mis-tap away from dropping the episode.
                if state.isLoaded {
                    headerButton("forward.end", label: "Play next episode") { audio.skipToNextEpisode() }
                }
            }
            .padding(.horizontal, UI.xxl)

            let upNext = state.upNext
            ForEach(Array(upNext.enumerated()), id: \.element.id) { i, ep in
                queueRow(ep: ep, isFirst: i == 0, isLast: i == upNext.count - 1)
            }
        }
        .padding(.top, UI.xl)
    }

    private func headerButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundColor(pal.accent)
                .frame(minWidth: 44, minHeight: 44)
                .background(Capsule().fill(pal.text.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func undoToast(_ r: RemovedEpisode) -> some View {
        HStack(spacing: UI.md) {
            Text("Removed \u{201C}\(r.episode.title)\u{201D}")
                .font(.subheadline)
                .foregroundColor(pal.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: UI.sm)
            Button("Undo") {
                withMotion {
                    queue.restore(r.episode, at: r.index)
                    removed = nil
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundColor(pal.accent)
            .frame(minHeight: 44)
        }
        .padding(.horizontal, UI.lg)
        .background(Capsule().fill(.ultraThinMaterial).overlay(Capsule().fill(pal.bg.opacity(0.7))))
        .overlay(Capsule().stroke(pal.text.opacity(0.1), lineWidth: 1))
        .padding(.horizontal, UI.lg)
        .padding(.bottom, UI.lg)
        .accessibilityElement(children: .combine)
    }
}

/// Play/pause in the orb's language (OrbButton): a dark disc, an accent hairline, an accent
/// glyph. Press tightens, never brightens. It replaces the solid accent `play.circle.fill`, the
/// loudest control on the 2am screen (and on Sleep Home, louder than the orb beside it).
/// `systemImage` nil shows a spinner (loading).
struct PlayerDiscButton: View {
    let systemImage: String?
    let diameter: CGFloat
    let pal: Palette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(Color(white: 0.09).opacity(0.85))
                Circle().stroke(pal.accent.opacity(0.35), lineWidth: 1)
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: diameter * 0.36, weight: .medium, design: .rounded))
                        .foregroundColor(pal.accent)
                } else {
                    ProgressView().tint(pal.accent)
                }
            }
            .frame(width: diameter, height: diameter)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
        }
        .buttonStyle(PressTightens())
    }
}

private struct PressTightens: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

/// An episode's artwork, with a quiet placeholder while it loads, when it fails, or when the feed
/// has none. (The old fallback looked for an "AppIcon" / "icon-512" image that doesn't resolve at
/// runtime, leaving an empty grey slab.)
struct EpisodeArtwork: View {
    let url: String?
    let pal: Palette
    let size: CGFloat
    /// 0…1: how far the art sits back, as darkness laid over it (and half its colour drained at
    /// full). Darkness, not transparency: the app's depth comes from dark, and `.opacity` on the
    /// image didn't hold once a colour filter joined it (white still measured 255 on screen).
    var dim: Double = 0

    var body: some View {
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .saturation(1 - dim)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .overlay(Color.black.opacity(dim))
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
