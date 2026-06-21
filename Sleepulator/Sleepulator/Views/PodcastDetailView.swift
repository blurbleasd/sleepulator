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
    
    var body: some View {
        ZStack {
            pal.bg.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    if !audio.isOnline && podcast.episodes.isEmpty {
                        Text("You're offline — connect to load feeds.")
                            .foregroundColor(.red)
                            .padding()
                    } else if isLoading && podcast.episodes.isEmpty {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: pal.accent))
                            .padding(.top, 40)
                    } else if let err = errorMessage {
                        Text(err)
                            .foregroundColor(.red)
                            .padding()
                    } else if podcast.episodes.isEmpty {
                        Text("No episodes found.")
                            .foregroundColor(pal.dim)
                            .padding()
                    } else {
                        // Podcast Header
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
                        .padding(.top, 24)
                        .padding(.bottom, 16)
                        
                        // Action buttons
                        HStack(spacing: 12) {
                            if !podcast.episodes.isEmpty {
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
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                        
                        let visibleEpisodes = podcast.episodes.filter { ep in
                            let notHidden = !audio.hideFinishedEpisodes || !audio.finishedEpisodes.contains(ep.id)
                            let matchesSearch = episodeSearch.isEmpty || ep.title.localizedCaseInsensitiveContains(episodeSearch)
                            return notHidden && matchesSearch
                        }
                        
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if visibleEpisodes.isEmpty {
                                Text(episodeSearch.isEmpty ? "All episodes played!" : "No episodes match \u{201C}\(episodeSearch)\u{201D}")
                                    .foregroundColor(pal.dim)
                                    .padding()
                            } else {
                                ForEach(visibleEpisodes) { ep in
                                    EpisodeRowView(ep: ep, audio: audio, podcast: podcast)
                                        .padding(.vertical, 8)
                                    
                                    if ep.id != visibleEpisodes.last?.id {
                                        Divider().background(pal.text.opacity(0.1))
                                    }
                                }
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                    }
                    
                    Spacer().frame(height: 80)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle(podcast.name)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $episodeSearch, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search episodes")
        .onAppear {
            loadFeed()
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
