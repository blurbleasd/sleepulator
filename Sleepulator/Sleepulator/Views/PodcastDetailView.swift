import SwiftUI

struct PodcastDetailView: View {
    @State var podcast: Podcast
    @ObservedObject var audio: AudioEngine
    @Binding var libraryPodcasts: [Podcast]
    
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    @State private var expandedEpisodeId: String? = nil
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            ScrollView {
                VStack(spacing: 16) {
                    if isLoading && podcast.episodes.isEmpty {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                            .padding(.top, 40)
                    } else if let err = errorMessage {
                        Text(err)
                            .foregroundColor(.red)
                            .padding()
                    } else if podcast.episodes.isEmpty {
                        Text("No episodes found.")
                            .foregroundColor(.gray)
                            .padding()
                    } else {
                        // Action buttons
                        HStack(spacing: 12) {
                            if let first = podcast.episodes.first {
                                Button(action: {
                                    audio.queue = [first]
                                    audio.playEpisode(first)
                                }) {
                                    Text("Play Latest")
                                        .font(.system(.subheadline, design: .rounded).bold())
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 10)
                                        .background(Color(red: 0.9, green: 0.7, blue: 0.4))
                                        .cornerRadius(10)
                                }
                            }
                            
                            Button(action: {
                                for ep in podcast.episodes {
                                    if !audio.queue.contains(where: { $0.id == ep.id }) {
                                        audio.queue.append(ep)
                                    }
                                }
                            }) {
                                Text("Add All to Queue")
                                    .font(.system(.subheadline, design: .rounded).bold())
                                    .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(Color.white.opacity(0.1))
                                    .cornerRadius(10)
                            }
                            Spacer()
                        }
                        .padding(.horizontal)
                        
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(podcast.episodes) { ep in
                                EpisodeRowView(ep: ep, expandedEpisodeId: $expandedEpisodeId, audio: audio, podcast: podcast)
                                    .padding(.vertical, 8)
                                
                                if ep.id != podcast.episodes.last?.id {
                                    Divider().background(Color.white.opacity(0.1))
                                }
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                    }
                    
                    Spacer().frame(height: 100)
                }
                .padding(.top, 16)
            }
        }
        .navigationTitle(podcast.name)
        .navigationBarTitleDisplayMode(.inline)
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
                let eps = try await parser.parseFeed(url: url)
                DispatchQueue.main.async {
                    self.podcast.episodes = eps
                    // Update in library
                    if let idx = libraryPodcasts.firstIndex(where: { $0.id == podcast.id }) {
                        libraryPodcasts[idx].episodes = eps
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
        if let data = try? JSONEncoder().encode(libraryPodcasts) {
            UserDefaults.standard.set(data, forKey: "saved_podcasts")
        }
    }
}
