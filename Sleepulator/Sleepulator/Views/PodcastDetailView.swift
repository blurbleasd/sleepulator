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
                // List (not ScrollView + LazyVStack) so rows recycle: a long feed no longer
                // keeps every scrolled-past row realized — that retention, hit by the audio
                // re-render storm, was the scroll overload + slow recovery.
                List {
                    Section {
                        headerContent
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 24, leading: 16, bottom: 8, trailing: 16))
                    }

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
                                               initiallyDownloaded: downloadedUrls.contains(ep.audioUrl))
                                    .listRowBackground(pal.text.opacity(0.05))
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .contentMargins(.bottom, 80, for: .scrollContent)   // clear the floating mini-player
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

    @ViewBuilder private var headerContent: some View {
        VStack(spacing: 16) {
            VStack(spacing: 16) {
                if let artStr = podcast.artworkUrl, let url = URL(string: artStr) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.gray.opacity(0.3)
                        }
                    }
                    .frame(width: 160, height: 160)
                    .cornerRadius(16)
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                }

                Text(podcast.name)
                    .font(.system(.title2, design: .rounded).weight(.bold))
                    .multilineTextAlignment(.center)
                    .foregroundColor(pal.text)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity)

            // Action buttons
            HStack(spacing: 12) {
                Button(action: {
                    audio.playAll(podcast.episodes)
                }) {
                    Text("Play All")
                        .font(.headline)
                        .foregroundColor(pal.bg)   // on pal.accent = 8.85:1 (white was 2.18:1, fails AA)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(pal.accent)
                        .cornerRadius(24)
                }

                Button(action: {
                    audio.playAll(podcast.episodes.shuffled())
                }) {
                    Text("Shuffle All")
                        .font(.headline)
                        .foregroundColor(pal.accent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(pal.bg)
                        .cornerRadius(24)
                        .overlay(RoundedRectangle(cornerRadius: 24).stroke(pal.accent, lineWidth: 1))
                }
                Spacer()
            }
        }
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
