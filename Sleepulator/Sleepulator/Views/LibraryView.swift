import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @ObservedObject var audio: AudioEngine
    @State private var feedUrlInput = ""
    @State private var podcasts: [Podcast] = []
    @State private var isLoading = false
    @State private var expandedEpisodeId: String? = nil
    
    let defaultFeed = "https://feeds.simplecast.com/tOaZvgCO"
    
    @State private var opmlImporting = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    @State private var opmlFeeds: [OPMLFeed] = []
    @State private var showOPMLSelector = false
    
    var body: some View {
        NavigationView {
            ZStack {
                // Background
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        // Add URL Section
                        HStack {
                            TextField("RSS Feed URL...", text: $feedUrlInput)
                                .textFieldStyle(PlainTextFieldStyle())
                                .padding(12)
                                .background(Color.white.opacity(0.1))
                                .cornerRadius(8)
                                .keyboardType(.URL)
                                .autocapitalization(.none)
                                .foregroundColor(.white)
                            
                            Button(action: loadFeed) {
                                if isLoading {
                                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                } else {
                                    Text("Add")
                                        .font(.system(.headline, design: .rounded))
                                        .foregroundColor(.black)
                                        .padding(.horizontal, 20)
                                        .padding(.vertical, 12)
                                        .background(feedUrlInput.isEmpty ? Color.gray : Color(red: 0.9, green: 0.7, blue: 0.4))
                                        .cornerRadius(8)
                                }
                            }
                            .disabled(feedUrlInput.isEmpty || isLoading)
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        .padding(.top, 20)
                        
                        // Up Next Queue Section
                        if !audio.queue.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "list.dash")
                                        .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                    Text("Up Next")
                                        .font(.system(.title3, design: .rounded).bold())
                                        .foregroundColor(.white)
                                        
                                    Spacer()
                                    
                                    Button(action: saveCurrentAsPlaylist) {
                                        Text("Save Mix")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color(red: 0.9, green: 0.7, blue: 0.4))
                                            .foregroundColor(.black)
                                            .cornerRadius(6)
                                    }
                                }
                                
                                ForEach(audio.queue) { ep in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(ep.title)
                                                .font(.system(.headline, design: .rounded))
                                                .foregroundColor(ep.id == audio.queue.first?.id ? Color(red: 0.9, green: 0.7, blue: 0.4) : .white)
                                                .lineLimit(1)
                                                .truncationMode(.tail)
                                            if ep.id == audio.queue.first?.id {
                                                Text("Now Playing")
                                                    .font(.caption)
                                                    .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.8))
                                            }
                                        }
                                        Spacer()
                                        Button(action: { audio.queue.removeAll(where: { $0.id == ep.id }) }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.gray)
                                                .font(.title3)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                    Divider().background(Color.white.opacity(0.1))
                                }
                            }
                            .glassPanel()
                            .padding(.horizontal)
                        }
                        
                        // Saved Mixes Section
                        if !audio.savedPlaylists.isEmpty {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Image(systemName: "star.fill")
                                        .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                    Text("Saved Mixes")
                                        .font(.system(.title3, design: .rounded).bold())
                                        .foregroundColor(.white)
                                }
                                
                                ForEach(audio.savedPlaylists, id: \.id) { (mix: SavedMix) in
                                    VStack(spacing: 0) {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(mix.name)
                                                    .font(.system(.headline, design: .rounded))
                                                    .foregroundColor(.white)
                                                Text("\(mix.noiseType.capitalized) + \(mix.binauralPreset.capitalized)")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                            Spacer()
                                            
                                            Button(action: { self.audio.resumeMix(mix) }) {
                                                Text("Load")
                                                    .font(.caption.bold())
                                                    .padding(.horizontal, 12)
                                                    .padding(.vertical, 6)
                                                    .background(Color.white.opacity(0.1))
                                                    .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                                    .cornerRadius(6)
                                            }
                                            
                                            Button(action: { self.deleteMix(mix) }) {
                                                Image(systemName: "trash")
                                                    .foregroundColor(.red.opacity(0.8))
                                            }
                                            .padding(.leading, 8)
                                        }
                                        .padding(.vertical, 4)
                                        Divider().background(Color.white.opacity(0.1))
                                    }
                                }
                            }
                            .glassPanel()
                            .padding(.horizontal)
                        }

                        // Podcast Subscriptions
                        HStack {
                            Text("Your Podcasts")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                            Spacer()
                            Button("Import OPML") {
                                opmlImporting = true
                            }
                            .font(.caption.bold())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.1))
                            .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                            .cornerRadius(6)
                        }
                        
                        VStack(spacing: 12) {
                            ForEach(podcasts) { podcast in
                                HStack(spacing: 8) {
                                    NavigationLink(destination: PodcastDetailView(podcast: podcast, audio: audio, libraryPodcasts: $podcasts)) {
                                        HStack(spacing: 16) {
                                            Image(systemName: "dot.radiowaves.left.and.right")
                                                .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                                .font(.title3)
                                            
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(podcast.name)
                                                    .font(.system(.headline, design: .rounded))
                                                    .foregroundColor(.white)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                                
                                                Text(podcast.episodes.isEmpty ? "Tap to load episodes" : "\(podcast.episodes.count) episodes")
                                                    .font(.caption)
                                                    .foregroundColor(.gray)
                                            }
                                            Spacer()
                                            
                                            Image(systemName: "chevron.right")
                                                .foregroundColor(.gray)
                                                .font(.caption)
                                        }
                                        .padding()
                                        .background(Color.white.opacity(0.05))
                                        .cornerRadius(12)
                                    }
                                    
                                    Button(action: {
                                        podcasts.removeAll(where: { $0.id == podcast.id })
                                        savePodcasts()
                                    }) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.gray)
                                            .padding()
                                            .background(Color.white.opacity(0.05))
                                            .cornerRadius(12)
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                        
                        Spacer().frame(height: 100) // Tab bar clearance
                    }
                }
            }
            .navigationTitle("Podcasts")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                if podcasts.isEmpty { feedUrlInput = defaultFeed }
                loadPersistedPodcasts()
            }
        }
        .fileImporter(isPresented: $opmlImporting, allowedContentTypes: [.xml, .plainText, .data], allowsMultipleSelection: false) { result in
            do {
                guard let selectedFile: URL = try result.get().first else { return }
                if selectedFile.startAccessingSecurityScopedResource() {
                    let feeds = OPMLParser().parse(url: selectedFile)
                    selectedFile.stopAccessingSecurityScopedResource()
                    
                    self.opmlFeeds = feeds
                    self.showOPMLSelector = true
                }
            } catch {
                print("OPML import failed: \(error)")
            }
        }
        .sheet(isPresented: $showOPMLSelector) {
            OPMLSelectionView(feeds: opmlFeeds) { selectedFeeds in
                var count = 0
                for feed in selectedFeeds {
                    if !self.podcasts.contains(where: { $0.url == feed.url }) {
                        self.podcasts.append(Podcast(id: feed.url, name: feed.name, url: feed.url, episodes: []))
                        count += 1
                    }
                }
                self.savePodcasts()
                self.alertMessage = "Successfully imported \(count) new podcast subscriptions."
                self.showAlert = true
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("OPML Import"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
    
    // MARK: - Feed Loading
    func loadFeed() {
        guard let url = URL(string: feedUrlInput) else { return }
        isLoading = true
        
        Task {
            let parser = PodcastParser()
            do {
                let eps = try await parser.parseFeed(url: url)
                let name = url.host?.replacingOccurrences(of: "www.", with: "") ?? "Podcast"
                let pod = Podcast(id: url.absoluteString, name: name, url: url.absoluteString, episodes: eps)
                
                DispatchQueue.main.async {
                    if !self.podcasts.contains(where: { $0.id == pod.id }) {
                        self.podcasts.insert(pod, at: 0)
                        self.savePodcasts()
                    }
                    self.feedUrlInput = ""
                    self.isLoading = false
                }
            } catch {
                print("Feed parse error: \(error)")
                DispatchQueue.main.async { self.isLoading = false }
            }
        }
    }
    
    func savePodcasts() {
        if let data = try? JSONEncoder().encode(podcasts) {
            UserDefaults.standard.set(data, forKey: "savedPodcasts")
        }
    }
    
    func loadPersistedPodcasts() {
        if let data = UserDefaults.standard.data(forKey: "savedPodcasts"),
           let saved = try? JSONDecoder().decode([Podcast].self, from: data) {
            self.podcasts = saved
        }
    }
    
    func savePlaylistsToDisk() {
        if let data = try? JSONEncoder().encode(audio.savedPlaylists) {
            UserDefaults.standard.set(data, forKey: "savedPlaylists")
        }
    }
    
    func deleteMix(_ mix: SavedMix) {
        audio.savedPlaylists.removeAll(where: { $0.id == mix.id })
        savePlaylistsToDisk()
    }
    
    func saveCurrentAsPlaylist() {
        let mix = SavedMix(
            name: audio.queue.first?.title ?? "Custom Mix",
            noiseOn: audio.noiseOn,
            noiseVolume: audio.noiseVolume,
            noiseType: audio.noiseType,
            binauralOn: audio.binauralOn,
            binVolume: audio.binVolume,
            binauralPreset: audio.binauralPreset,
            podVolume: audio.podVolume,
            podcastUrl: audio.isPodPlaying ? audio.queue.first?.audioUrl : nil
        )
        audio.savedPlaylists.append(mix)
        savePlaylistsToDisk()
    }
}

struct EpisodeRowView: View {
    let ep: Episode
    @Binding var expandedEpisodeId: String?
    @ObservedObject var audio: AudioEngine
    let podcast: Podcast
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Button(action: {
                        if expandedEpisodeId == ep.id {
                            expandedEpisodeId = nil
                        } else {
                            expandedEpisodeId = ep.id
                        }
                    }) {
                        Text(ep.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.leading)
                            .lineLimit(expandedEpisodeId == ep.id ? nil : 2)
                    }
                    
                    if expandedEpisodeId == ep.id {
                        if let description = ep.description {
                            Text(description)
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.gray)
                                .padding(.top, 4)
                        }
                        if let pubDate = ep.pubDate {
                            Text(pubDate, style: .date)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    } else {
                        if let pubDate = ep.pubDate {
                            Text(pubDate, style: .date)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(.gray.opacity(0.7))
                        }
                    }
                }
                Spacer()
                
                HStack(spacing: 12) {
                    Button(action: {
                        Task {
                            if let url = URL(string: ep.audioUrl) {
                                let _ = try? await AudioDownloader.shared.download(url: url) { _ in }
                            }
                        }
                    }) {
                        Image(systemName: "icloud.and.arrow.down")
                            .foregroundColor(.gray)
                            .font(.title3)
                    }
                    
                    Button(action: {
                        audio.queue.append(ep)
                        if audio.queue.count == 1 { audio.loadPodcast(ep.audioUrl) }
                    }) {
                        Image(systemName: "plus.circle")
                            .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                            .font(.title)
                    }
                }
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.vertical, 4)
            
            if ep.id != podcast.episodes.last?.id {
                Divider().background(Color.white.opacity(0.1))
            }
        }
    }
}
