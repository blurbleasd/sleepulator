import SwiftUI

struct PodcastDetailView: View {
    @State var podcast: Podcast
    @ObservedObject var audio: AudioEngine
    @Binding var libraryPodcasts: [Podcast]
    
    @State private var opmlExporting = false
    @State private var exportedOPMLUrl: URL?
    
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    var pal: Palette { Palette(bedtime: bedtimeMode) }
    
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var episodeSearch = ""
    // Loaded once here instead of re-decoding positions.json in every EpisodeRowView.onAppear
    // (which janked the main thread while scrolling a long episode list).
    @State private var episodePositions: [String: Double] = [:]
    // Which episodes are downloaded — computed once on appear / after a feed load, so the rows
    // don't each do a synchronous disk stat + MD5 hash in onAppear while scrolling.
    @State private var downloadedUrls: Set<String> = []

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

            if !audio.isOnline && podcast.episodes.isEmpty {
                stateMessage("You're offline — connect to load feeds.", color: .red)
            } else if isLoading && podcast.episodes.isEmpty {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: pal.accent))
            } else if let err = errorMessage, podcast.episodes.isEmpty {
                stateMessage(err, color: .red)
            } else if podcast.episodes.isEmpty {
                stateMessage("No episodes found.", color: pal.dim)
            } else {
                // Header is PINNED above the List (not the first scrolling row). When it lived
                // inside the List, an inline title + always-on search drawer + the async feed
                // load left the List anchored partway down — the detail view "opened from the
                // middle." A fixed header guarantees the episode list always starts at its top.
                VStack(spacing: 0) {
                    compactHeader

                    // List (not ScrollView + LazyVStack) so rows recycle: a long feed no longer
                    // keeps every scrolled-past row realized — that retention, hit by the audio
                    // re-render storm, was the scroll overload + slow recovery.
                    List {
                        Section {
                            if visibleEpisodes.isEmpty {
                                Text(episodeSearch.isEmpty ? "All episodes played!" : "No episodes match \u{201C}\(episodeSearch)\u{201D}")
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
                    .contentMargins(.bottom, 80, for: .scrollContent)   // clear the floating mini-player
                }
            }
        }
        .navigationTitle(podcast.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $episodeSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search episodes")
        .onAppear {
            episodePositions = StorageManager.shared.load(from: "positions.json") ?? [:]
            refreshDownloaded()
            loadFeed()
        }
    }

    @ViewBuilder private func stateMessage(_ text: String, color: Color) -> some View {
        Text(text)
            .foregroundColor(color)
            .multilineTextAlignment(.center)
            .padding()
    }

    // Compact, fixed header (artwork + name + Play All / Shuffle). Kept deliberately short so a
    // pinned header doesn't eat the episode list, and laid out horizontally so it reads at a
    // glance. The artwork frame is reserved (88×88) so an async image load can't shift layout.
    @ViewBuilder private var compactHeader: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                if let artStr = podcast.artworkUrl, let url = URL(string: artStr) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.gray.opacity(0.3)
                        }
                    }
                    .frame(width: 88, height: 88)
                    .cornerRadius(14)
                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
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
                        Text("\(podcast.episodes.count) episodes")
                            .font(.system(.caption, design: .rounded))
                            .foregroundColor(pal.dim)
                    }
                }
                Spacer(minLength: 0)
            }

            // Action buttons
            HStack(spacing: 12) {
                Button(action: {
                    audio.playAll(podcast.episodes)
                }) {
                    Label("Play All", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(pal.bg)   // on pal.accent = 8.85:1 (white was 2.18:1, fails AA)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(pal.accent)
                        .cornerRadius(22)
                }
                .disabled(podcast.episodes.isEmpty)

                Button(action: {
                    audio.playAll(podcast.episodes.shuffled())
                }) {
                    Label("Shuffle", systemImage: "shuffle")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(pal.accent)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(pal.bg)
                        .cornerRadius(22)
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(pal.accent, lineWidth: 1))
                }
                .disabled(podcast.episodes.isEmpty)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
    
    func loadFeed() {
        guard let url = URL(string: podcast.url) else { return }
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
                    if self.podcast.name.isEmpty || self.podcast.name == "Podcast" || self.podcast.name.contains(".com") {
                        if !feed.title.isEmpty {
                            self.podcast.name = feed.title
                        }
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
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
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
