import SwiftUI

struct LibraryView: View {
    @ObservedObject var audio: AudioEngine
    @State private var feedUrlInput = ""
    @State private var podcasts: [Podcast] = []
    @State private var isLoading = false
    
    // Default fallback feed for testing if empty
    let defaultFeed = "https://feeds.simplecast.com/tOaZvgCO"
    
    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    TextField("RSS Feed URL...", text: $feedUrlInput)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                    
                    Button(action: loadFeed) {
                        if isLoading {
                            ProgressView().progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Text("Add")
                        }
                    }
                    .disabled(feedUrlInput.isEmpty || isLoading)
                }
                .padding()
                
                List {
                    ForEach(podcasts) { podcast in
                        Section(header: Text(podcast.name).lineLimit(1).truncationMode(.tail)) {
                            ForEach(podcast.episodes.prefix(10)) { ep in
                                Button(action: {
                                    audio.podTitle = ep.title
                                    audio.loadPodcast(ep.audioUrl)
                                }) {
                                    VStack(alignment: .leading) {
                                        // This fixes the 'wide podcast names' bug securely in SwiftUI
                                        Text(ep.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                            
                                        Text("Tap to play")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Podcasts")
            .onAppear {
                if podcasts.isEmpty {
                    feedUrlInput = defaultFeed
                }
            }
        }
    }
    
    func loadFeed() {
        guard let url = URL(string: feedUrlInput) else { return }
        isLoading = true
        
        Task {
            let parser = PodcastParser()
            do {
                let eps = try await parser.parseFeed(url: url)
                // Extract host from url as fallback name
                let name = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Podcast"
                let pod = Podcast(id: url.absoluteString, name: name, url: url.absoluteString, episodes: eps)
                
                DispatchQueue.main.async {
                    self.podcasts.insert(pod, at: 0)
                    self.feedUrlInput = ""
                    self.isLoading = false
                }
            } catch {
                print("Feed parse error: \(error)")
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }
}
