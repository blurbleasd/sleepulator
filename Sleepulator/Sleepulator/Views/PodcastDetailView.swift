import SwiftUI
import os

struct PodcastDetailView: View {
    @State var podcast: Podcast
    @ObservedObject var audio: AudioEngine
    @ObservedObject var connectivity: Connectivity
    @Binding var libraryPodcasts: [Podcast]
    
    @State private var opmlExporting = false
    @State private var exportedOPMLUrl: URL?
    
    /// Mode-aware like Home: Focus is cool everywhere, not just on Home. Read from the persisted
    /// "focusMode" key (AudioEngine writes it) so this view needn't observe the whole engine.
    @AppStorage("focusMode") private var focusMode = false
    var pal: Palette { Palette(focusMode: focusMode) }
    /// At accessibility text sizes the pinned header took half the screen and left ~1.5 episodes
    /// visible; there it keeps only the actions (the show's name is already in the nav bar).
    @Environment(\.dynamicTypeSize) private var typeSize
    
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var episodeSearch = ""
    // Loaded once here instead of re-decoding positions.json in every EpisodeRowView.onAppear
    // (which janked the main thread while scrolling a long episode list).
    @State private var episodePositions: [String: Double] = [:]
    // Which episodes are downloaded — computed once on appear / after a feed load, so the rows
    // don't each do a synchronous disk stat + MD5 hash in onAppear while scrolling.
    @State private var downloadedUrls: Set<String> = []
    /// The night ring's length (0 = All night), for the Resume line's "runs past your night" note.
    @AppStorage("nightLengthMinutes") private var nightLength: Double = 0
    /// Episodes waiting on "Replace your queue?" (Play All / Shuffle over a non-empty queue).
    @State private var pendingPlayAll: [Episode]? = nil

    /// The episode Resume would continue, if any: last night's from this show, else the newest
    /// one you're partway through.
    private var resumeTarget: (episode: Episode, position: TimeInterval)? {
        TonightShelf.showResumeTarget(podcast: podcast,
                                      lastEpisodeId: audio.lastMix?.podcastId,
                                      lastPosition: audio.lastMix?.podcastPosition,
                                      savedPositions: episodePositions,
                                      finished: audio.finishedEpisodes)
    }

    private func playPrimary() {
        if let target = resumeTarget {
            audio.playEpisode(target.episode, startAt: target.position)
        } else if let latest = TonightShelf.latestUnplayed(in: podcast, finished: audio.finishedEpisodes, excluding: nil)
                    ?? podcast.episodes.first {
            audio.queueManager.playEpisode(latest)
        }
    }

    /// Play All / Shuffle replace the queue; ask first when there's something in it to lose.
    private func requestPlayAll(_ episodes: [Episode]) {
        if audio.queueManager.queue.isEmpty {
            audio.playAll(episodes)
        } else {
            pendingPlayAll = episodes
        }
    }

    private func progress(for ep: Episode) -> Double {
        guard let pos = episodePositions[ep.id], let dur = ep.duration, dur > 0 else { return 0 }
        return min(1.0, pos / dur)
    }

    private var visibleEpisodes: [Episode] {
        podcast.episodes.filter { ep in
            let notHidden = !audio.hideFinishedEpisodes || !audio.finishedEpisodes.contains(ep.id)
            let matchesSearch = episodeSearch.isEmpty || ep.title.localizedCaseInsensitiveContains(episodeSearch)
            return notHidden && matchesSearch
        }
    }

    private func refreshDownloaded() {
        downloadedUrls = AudioDownloader.shared.downloadedUrlStrings(among: podcast.episodes.map { $0.audioUrl })
    }
    
    var body: some View {
        ZStack {
            pal.bg.ignoresSafeArea()

            if isLoading && podcast.episodes.isEmpty {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: pal.accent))
            } else if !connectivity.isOnline && podcast.episodes.isEmpty {
                unavailable("You're offline", systemImage: "wifi.slash",
                            detail: "Connect to load this show's episodes.")
            } else if let err = errorMessage, podcast.episodes.isEmpty {
                unavailable("Couldn't load episodes", systemImage: "exclamationmark.triangle", detail: err)
            } else if podcast.episodes.isEmpty {
                unavailable("No episodes yet", systemImage: "dot.radiowaves.left.and.right",
                            detail: "This feed doesn't have any episodes to play.")
            } else {
                // Header is PINNED above the List (not the first scrolling row). When it lived
                // inside the List, an inline title + always-on search drawer + the async feed
                // load left the List anchored partway down — the detail view "opened from the
                // middle." A fixed header guarantees the episode list always starts at its top.
                VStack(spacing: 0) {
                    compactHeader

                    // A failed refresh with saved episodes still on screen used to say nothing.
                    if let err = errorMessage {
                        staleNotice(err)
                    }

                    // List (not ScrollView + LazyVStack) so rows recycle: a long feed no longer
                    // keeps every scrolled-past row realized — that retention, hit by the audio
                    // re-render storm, was the scroll overload + slow recovery.
                    List {
                        Section {
                            if visibleEpisodes.isEmpty {
                                Text(episodeSearch.isEmpty
                                     ? "You've finished every episode. Turn off Hide Finished Episodes in Settings to see them again."
                                     : "No episodes match \u{201C}\(episodeSearch)\u{201D}")
                                    .multilineTextAlignment(.center)
                                    .foregroundColor(pal.dim)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding()
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            } else {
                                ForEach(visibleEpisodes) { ep in
                                    EpisodeRowView(ep: ep,
                                                   queueManager: audio.queueManager,
                                                   podcast: podcast,
                                                   savedProgress: progress(for: ep),
                                                   initiallyDownloaded: downloadedUrls.contains(ep.audioUrl),
                                                   initiallyPlayed: audio.finishedEpisodes.contains(ep.id))
                                        .listRowBackground(pal.text.opacity(0.05))
                                        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                        .listRowSeparator(.hidden)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .miniPlayerClearance()   // clear the floating mini-player, measured
                }
            }
        }
        .navigationTitle(podcast.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $episodeSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search episodes")
        .confirmationDialog("Replace your queue?",
                            isPresented: Binding(get: { pendingPlayAll != nil }, set: { if !$0 { pendingPlayAll = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingPlayAll) { episodes in
            Button("Replace Queue") { audio.playAll(episodes) }
            Button("Add to End") { _ = audio.queueManager.addAllToQueue(episodes) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Your queue has \(PodcastText.episodeCount(audio.queueManager.queue.count)) in it.")
        }
        .onAppear {
            episodePositions = StorageManager.shared.load(from: "positions.json") ?? [:]
            refreshDownloaded()
            loadFeed()
        }
    }

    /// Empty, offline and error states, with a way to try again. These were bare lines of
    /// system-red text, one of them the raw system error.
    private func unavailable(_ title: String, systemImage: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
                .foregroundStyle(pal.text)
        } description: {
            Text(detail)
                .foregroundStyle(pal.dim)
        } actions: {
            Button("Try Again") { loadFeed() }
                .buttonStyle(.bordered)
                .tint(pal.accent)
        }
    }

    /// One quiet line between the header and a list of saved episodes when the refresh failed.
    private func staleNotice(_ err: String) -> some View {
        HStack(spacing: UI.sm) {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundColor(pal.accent)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: UI.sm)
            Button("Try Again") { loadFeed() }
                .font(.footnote.weight(.semibold))
                .foregroundColor(pal.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, UI.lg)
    }

    // Compact, fixed header (artwork + name + Play All / Shuffle). Kept deliberately short so a
    // pinned header doesn't eat the episode list, and laid out horizontally so it reads at a
    // glance. The artwork frame is reserved (88×88) so an async image load can't shift layout.
    @ViewBuilder private var compactHeader: some View {
        VStack(spacing: 14) {
            if !typeSize.isAccessibilitySize {
                HStack(spacing: 14) {
                    if let artStr = podcast.artworkUrl, let url = URL(string: artStr) {
                        CachedAsyncImage(url: url, size: 88, cornerRadius: 14)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 34))
                            .foregroundColor(pal.accent)
                            .frame(width: 88, height: 88)
                            .background(pal.text.opacity(0.08))
                            .cornerRadius(14)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(podcast.name)
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundColor(pal.text)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                        if !podcast.episodes.isEmpty {
                            Text(PodcastText.episodeCount(podcast.episodes.count))
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(pal.dim)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // One clear next step: pick up the episode you're partway through, else the newest.
            // Play All (every episode, replacing your queue) used to be the loudest button here.
            VStack(alignment: .leading, spacing: UI.xs) {
                HStack(spacing: UI.sm) {
                    Button(action: playPrimary) {
                        Label(resumeTarget == nil ? "Play Latest" : "Resume", systemImage: "play.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(pal.bg)   // on pal.accent = 8.85:1 (white was 2.18:1, fails AA)
                            .padding(.horizontal, UI.xl)
                            .frame(minHeight: 44)
                            .background(pal.accent, in: Capsule())
                    }
                    .disabled(podcast.episodes.isEmpty)

                    Menu {
                        Button { requestPlayAll(podcast.episodes) } label: {
                            Label("Play All", systemImage: "play.square.stack")
                        }
                        Button { requestPlayAll(podcast.episodes.shuffled()) } label: {
                            Label("Shuffle", systemImage: "shuffle")
                        }
                        // Append the currently-shown (filtered) episodes to the queue — respects Hide
                        // Finished + the search filter, unlike Play All / Shuffle which take every episode.
                        Button {
                            _ = audio.queueManager.addAllToQueue(visibleEpisodes)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Label("Add \(PodcastText.episodeCount(visibleEpisodes.count)) to Queue", systemImage: "text.badge.plus")
                        }
                        .disabled(visibleEpisodes.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(pal.accent)
                            .frame(width: 44, height: 44)
                            .background(pal.text.opacity(0.08), in: Capsule())
                    }
                    .disabled(podcast.episodes.isEmpty)
                    .accessibilityLabel("More actions")

                    Spacer(minLength: 0)
                }

                if let target = resumeTarget {
                    let remaining = TonightShelf.remaining(duration: target.episode.duration, position: target.position)
                    let cue = PodcastText.nightCue(remaining: remaining, nightMinutes: nightLength, focusMode: focusMode)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.episode.title)
                            .foregroundColor(pal.dim)
                            .lineLimit(1)
                        Text([PodcastText.timeLeft(remaining), cue].compactMap { $0 }.joined(separator: " · "))
                            .foregroundColor(cue == nil ? pal.dim : pal.accent)
                    }
                    .font(.footnote)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
    
    func loadFeed() {
        guard let url = URL(string: podcast.url), !isLoading else { return }
        isLoading = true
        errorMessage = nil
        
        Task {
            let parser = PodcastParser()
            do {
                let feed = try await parser.parseFeed(url: url)
                DispatchQueue.main.async {
                    self.podcast.episodes = feed.episodes
                    if self.podcast.artworkUrl == nil && feed.artworkUrl != nil {
                        self.podcast.artworkUrl = feed.artworkUrl
                    }
                    if !feed.title.isEmpty, PodcastText.isPlaceholderName(self.podcast.name, feedURL: self.podcast.url) {
                        self.podcast.name = feed.title
                    }
                    // Update in library
                    if let idx = libraryPodcasts.firstIndex(where: { $0.id == podcast.id }) {
                        libraryPodcasts[idx] = self.podcast
                        self.savePodcasts()
                    }
                    self.isLoading = false
                    // Episodes just arrived — recompute which are downloaded (one listing, off
                    // the scroll path) so rows get the right badge without per-row disk stats.
                    self.refreshDownloaded()
                }
            } catch {
                Log.network.error("Show feed load failed: \(error.localizedDescription, privacy: .public)")
                // Plain recovery copy instead of the raw system error (logged above).
                let offline = (error as? URLError)?.code == .notConnectedToInternet
                DispatchQueue.main.async {
                    if self.podcast.episodes.isEmpty {
                        self.errorMessage = offline
                            ? "You're offline. Connect and try again."
                            : "The show's feed didn't load. Check your connection and try again."
                    } else {
                        self.errorMessage = offline
                            ? "You're offline. Showing saved episodes."
                            : "Couldn't refresh. Showing saved episodes."
                    }
                    self.isLoading = false
                }
            }
        }
    }
    
    private func savePodcasts() {
        // Write the canonical library.json (the same store LibraryView uses). Writing the
        // legacy "savedPodcasts" UserDefaults key here re-armed the launch-time migration,
        // which then clobbered newer library edits on the next cold launch.
        StorageManager.shared.save(libraryPodcasts, to: "library.json")
    }
}
