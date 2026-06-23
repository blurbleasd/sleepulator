import SwiftUI
import UniformTypeIdentifiers
import Combine
import os

struct LibraryView: View {
    @ObservedObject var audio: AudioEngine
    @State private var feedUrlInput = ""
    @State private var podcasts: [Podcast] = []
    @State private var isLoading = false
    @State private var errorMessage: String? = nil
    
    @State private var searchText = ""
    @State private var showAddSheet = false
    
    let defaultFeed = "https://feeds.simplecast.com/tOaZvgCO"
    
    @State private var opmlImporting = false
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    @State private var opmlFeeds: [OPMLFeed] = []
    @State private var showOPMLSelector = false
    
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    var pal: Palette { Palette(bedtime: bedtimeMode) }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                pal.bg.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    if !audio.isOnline {
                        Text("No Internet Connection")
                            .font(.caption.bold())
                            .foregroundColor(.black)   // black on orange = 9.4:1 (white was 2.23:1, fails AA)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Color.orange)
                    }
                    
                    List {
                    Section {
                        ForEach(podcasts.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }) { podcast in
                            NavigationLink(value: podcast.id) {
                                HStack(spacing: 16) {
                                    if let art = podcast.artworkUrl, let url = URL(string: art) {
                                        CachedAsyncImage(url: url, size: 64, cornerRadius: 12)
                                            .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                                    } else {
                                        Image(systemName: "dot.radiowaves.left.and.right")
                                            .foregroundColor(pal.accent)
                                            .frame(width: 64, height: 64)
                                            .background(pal.text.opacity(0.1))
                                            .cornerRadius(12)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(podcast.name)
                                            .font(.system(.headline, design: .rounded).weight(.semibold))
                                            .foregroundColor(pal.text)
                                            .lineLimit(2)
                                        
                                        Text(subtitle(for: podcast))
                                            .font(.system(.subheadline, design: .rounded))
                                            .foregroundColor(pal.dim)
                                    }
                                }
                            }
                            .listRowBackground(pal.text.opacity(0.05))
                            // Quick "play latest" without opening the show, when episodes are loaded.
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if let latest = podcast.episodes.first {
                                    Button {
                                        audio.queueManager.playEpisode(latest)
                                    } label: {
                                        Label("Play latest", systemImage: "play.fill")
                                    }
                                    .tint(.green)
                                }
                            }
                        }
                        .onDelete { indices in
                            let filtered = podcasts.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
                            for index in indices {
                                if let actualIndex = podcasts.firstIndex(where: { $0.id == filtered[index].id }) {
                                    podcasts.remove(at: actualIndex)
                                }
                            }
                            savePodcasts()
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Search subscriptions")
                .refreshable {
                    if !audio.isOnline { return }
                    await withTaskGroup(of: Void.self) { group in
                        for podcast in podcasts {
                            group.addTask {
                                if let url = URL(string: podcast.url), let feed = try? await PodcastParser().parseFeed(url: url) {
                                    await MainActor.run {
                                        if let idx = podcasts.firstIndex(where: { $0.id == podcast.id }) {
                                            podcasts[idx].episodes = feed.episodes
                                            if podcasts[idx].artworkUrl == nil { podcasts[idx].artworkUrl = feed.artworkUrl }
                                            savePodcasts()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // Empty state — the screen was a black void with no subscriptions.
                if podcasts.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 46))
                            .foregroundColor(pal.accent.opacity(0.55))
                        Text("No podcasts yet")
                            .font(.system(.title3, design: .rounded).bold())
                            .foregroundColor(pal.text)
                        Text("Tap + to add a show, or bring your subscriptions over from another app with Import OPML.")
                            .font(.subheadline)
                            .foregroundColor(pal.dim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 44)
                    }
                    .padding(.bottom, 60)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("Podcasts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showAddSheet = true }) {
                        Image(systemName: "plus")
                            .foregroundColor(pal.accent)
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Import OPML") { opmlImporting = true }
                        .font(.caption.bold())
                        .foregroundColor(pal.accent)
                }
            }
            .navigationDestination(for: String.self) { podcastId in
                if let podcast = podcasts.first(where: { $0.id == podcastId }) {
                    PodcastDetailView(podcast: podcast, audio: audio, libraryPodcasts: $podcasts)
                } else {
                    Text("Podcast not found")
                        .foregroundColor(pal.dim)
                }
            }
            .onAppear {
                if podcasts.isEmpty { feedUrlInput = defaultFeed }
                loadPodcasts()
            }
            // Re-read library.json after an in-process Backup restore (the engine posts this).
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SleepulatorLibraryReload"))) { _ in
                loadPodcasts()
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddPodcastSheet(feedUrlInput: $feedUrlInput, isLoading: $isLoading, errorMessage: $errorMessage, pal: pal, onAdd: {
                loadFeed()
            }, audio: audio)
            .presentationDetents([.fraction(0.8), .large])
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
                Log.network.error("OPML import failed: \(error.localizedDescription, privacy: .public)")
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
                self.alertMessage = "Successfully imported \(count) new podcast subscriptions. Downloading episodes in background..."
                self.showAlert = true
                
                Task {
                    await withTaskGroup(of: Void.self) { group in
                        for feed in selectedFeeds {
                            group.addTask {
                                if let url = URL(string: feed.url), let parsed = try? await PodcastParser().parseFeed(url: url) {
                                    await MainActor.run {
                                        if let idx = self.podcasts.firstIndex(where: { $0.url == feed.url }) {
                                            self.podcasts[idx].episodes = parsed.episodes
                                            if self.podcasts[idx].artworkUrl == nil { self.podcasts[idx].artworkUrl = parsed.artworkUrl }
                                            self.savePodcasts()
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .alert(isPresented: $showAlert) {
            Alert(title: Text("OPML Import"), message: Text(alertMessage), dismissButton: .default(Text("OK")))
        }
    }
    }
    
    /// Subscription-row subtitle: surface the unplayed count once episodes are loaded so the
    /// list is scannable ("3 unplayed · 120"), falling back to a prompt or "All caught up".
    private func subtitle(for podcast: Podcast) -> String {
        let total = podcast.episodes.count
        guard total > 0 else { return "Tap to load episodes" }
        let unplayed = podcast.episodes.reduce(0) { $0 + (audio.finishedEpisodes.contains($1.id) ? 0 : 1) }
        return unplayed == 0 ? "All caught up · \(total)" : "\(unplayed) unplayed · \(total)"
    }

    // MARK: - Feed Loading
    func loadFeed() {
        guard let url = URL(string: feedUrlInput) else { return }
        isLoading = true
        errorMessage = nil
        
        Task {
            let parser = PodcastParser()
            do {
                let feed = try await parser.parseFeed(url: url)
                let name = !feed.title.isEmpty ? feed.title : (url.host?.replacingOccurrences(of: "www.", with: "") ?? "Podcast")
                let pod = Podcast(id: url.absoluteString, name: name, url: url.absoluteString, episodes: feed.episodes, artworkUrl: feed.artworkUrl)
                
                DispatchQueue.main.async {
                    if !self.podcasts.contains(where: { $0.id == pod.id }) {
                        self.podcasts.insert(pod, at: 0)
                        self.savePodcasts()
                    }
                    self.feedUrlInput = ""
                    self.isLoading = false
                    self.showAddSheet = false
                }
            } catch {
                Log.network.error("Feed parse error: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    self.isLoading = false
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func savePodcasts() {
        StorageManager.shared.save(podcasts, to: "library.json")
    }
    private func loadPodcasts() {
        if let decoded: [Podcast] = StorageManager.shared.load(from: "library.json") {
            self.podcasts = decoded
        }
    }
}

struct AddPodcastSheet: View {
    @Binding var feedUrlInput: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let pal: Palette
    let onAdd: () -> Void
    @ObservedObject var audio: AudioEngine
    
    @State private var searchResults: [ITunesPodcast] = []
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var searchTask: Task<Void, Never>? = nil
    
    var body: some View {
        ZStack {
            pal.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Podcast")
                    .font(.title2.bold())
                    .foregroundColor(pal.text)
                    .padding(.horizontal, 24)
                
                if !audio.isOnline {
                    Text("Offline: Search is unavailable.")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                        .padding(.horizontal, 24)
                }
                
                TextField("Search iTunes or enter RSS...", text: $searchQuery)
                    .textFieldStyle(PlainTextFieldStyle())
                    .padding(12)
                    .background(pal.text.opacity(0.1))
                    .cornerRadius(8)
                    .autocapitalization(.none)
                    .foregroundColor(pal.text)
                    .padding(.horizontal, 24)
                    .onChange(of: searchQuery) { _, newValue in
                        // Cancel any in-flight search; a per-keystroke fan-out used to race,
                        // and a slow early request could overwrite a newer query's results.
                        searchTask?.cancel()

                        if newValue.lowercased().starts(with: "http") {
                            feedUrlInput = newValue
                            searchResults = []
                            isSearching = false
                            return
                        }
                        guard newValue.count > 2, audio.isOnline else {
                            searchResults = []
                            isSearching = false
                            return
                        }

                        searchTask = Task {
                            // Debounce: wait for typing to settle before hitting the network.
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            if Task.isCancelled { return }
                            await MainActor.run { isSearching = true }
                            let results = (try? await ITunesSearchManager.shared.search(query: newValue)) ?? []
                            if Task.isCancelled { return }
                            await MainActor.run {
                                // Ignore results whose query no longer matches the field.
                                if newValue == searchQuery { searchResults = results }
                                isSearching = false
                            }
                        }
                    }
                    .onDisappear { searchTask?.cancel() }
                
                if let err = errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.horizontal, 24)
                }
                
                if searchQuery.lowercased().starts(with: "http") {
                    Button(action: onAdd) {
                        if isLoading {
                            ProgressView().progressViewStyle(CircularProgressViewStyle(tint: pal.bg))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(pal.accent)
                                .cornerRadius(12)
                        } else {
                            Text("Add Subscription")
                                .font(.headline.bold())
                                .foregroundColor(pal.bg)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(pal.accent)
                                .cornerRadius(12)
                        }
                    }
                    .disabled(!audio.isOnline || isLoading)
                    .padding(.horizontal, 24)
                } else {
                    if isSearching {
                        ProgressView()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding()
                    } else if !searchResults.isEmpty {
                        List(searchResults) { result in
                            Button(action: {
                                if let url = result.feedUrl {
                                    feedUrlInput = url
                                    onAdd()
                                }
                            }) {
                                HStack {
                                    if let urlString = result.artworkUrl600, let url = URL(string: urlString) {
                                        AsyncImage(url: url) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fill)
                                            } else {
                                                Color.gray.opacity(0.3)
                                            }
                                        }
                                        .frame(width: 44, height: 44)
                                        .cornerRadius(8)
                                    }
                                    VStack(alignment: .leading) {
                                        Text(result.collectionName ?? "Unknown")
                                            .font(.headline)
                                            .foregroundColor(pal.text)
                                        Text(result.artistName ?? "")
                                            .font(.subheadline)
                                            .foregroundColor(pal.dim)
                                    }
                                }
                            }
                            .listRowBackground(Color.clear)
                        }
                        .listStyle(.plain)
                    }
                }
                
                Spacer()
            }
            .padding(.top, 24)
        }
    }
}

struct EpisodeRowView: View {
    let ep: Episode
    // Was `@ObservedObject var audio: AudioEngine`. The row displays nothing from the engine,
    // but observing it meant every per-second (AVPlayer) and ~20×/sec (sleep-timer) publish
    // re-rendered every realized row — the podcast-list scroll storm. It only needs the queue
    // manager to act on taps, held as a plain reference (deliberately NOT observed).
    let queueManager: PodcastQueueManager
    let podcast: Podcast
    // Resume progress, computed once by the parent from positions.json (was decoded per row).
    var savedProgress: Double = 0
    // Whether this episode is already downloaded — precomputed once by the parent (was a
    // synchronous per-row disk stat + MD5 hash in onAppear while scrolling).
    var initiallyDownloaded: Bool = false
    // Whether this episode is already marked played — precomputed by the parent from the
    // engine's finishedEpisodes set, so the row needn't observe the engine (scroll-storm fix).
    var initiallyPlayed: Bool = false

    @AppStorage("bedtimeMode") private var bedtimeMode = false
    var pal: Palette { Palette(bedtime: bedtimeMode) }

    @State private var isDownloaded = false
    @State private var downloadProgress: Double? = nil
    @State private var progress: Double = 0
    @State private var isExpanded = false
    @State private var isPlayed = false
    private func formatDuration(_ duration: TimeInterval?) -> String? {
        guard let d = duration else { return nil }
        if d >= 3600 {
            return String(format: "%d hr %d min", Int(d) / 3600, (Int(d) % 3600) / 60)
        } else {
            return String(format: "%d min", Int(d) / 60)
        }
    }

    // Static: allocating a RelativeDateTimeFormatter (ICU/locale-backed) per row body eval
    // showed up as a per-row cost under the re-render storm. Main-thread use only.
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
    private func relativeDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                // Thumbnail
                if let artStr = ep.artworkUrl ?? podcast.artworkUrl, let url = URL(string: artStr) {
                    CachedAsyncImage(url: url, size: 48, cornerRadius: 8)
                } else {
                    Image(systemName: "mic.fill")
                        .foregroundColor(pal.accent)
                        .frame(width: 48, height: 48)
                        .background(pal.text.opacity(0.1))
                        .cornerRadius(8)
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        // Unplayed dot (hidden once played) — the conventional podcast cue.
                        if !isPlayed {
                            Circle().fill(pal.accent).frame(width: 7, height: 7)
                                .accessibilityHidden(true)
                        }
                        Text(ep.title)
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(pal.text.opacity(isPlayed ? 0.5 : 1.0))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        if let pubDate = ep.pubDate {
                            Text(relativeDate(pubDate))
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(pal.dim)
                        }
                        if let durationStr = formatDuration(ep.duration) {
                            Text(durationStr)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(pal.dim)
                        }
                        if progress > 0 {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(pal.text.opacity(0.1))
                                    Capsule().fill(pal.accent)
                                        .frame(width: geo.size.width * CGFloat(progress))
                                }
                            }
                            .frame(width: 40, height: 4)
                            .accessibilityHidden(true)
                        }
                    }
                }
                // Make the title region the VoiceOver button (the bare .onTapGesture below
                // exposed no trait/label/action). Scoped here so the ellipsis Menu stays a
                // separately-focusable control instead of being swallowed by a row-wide combine.
                // .combine composes the label from the title + date + duration Texts.
                // Don't set an explicit .accessibilityLabel here — it would override the
                // merged label and drop the publish date and duration from the announcement.
                // Tap = play (the conventional podcast pattern); show-notes are reached via the
                // explicit chevron below, exposed to VoiceOver as a named action.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Double-tap to play")
                .accessibilityAction { queueManager.playEpisode(ep) }
                .accessibilityAction(named: Text(isExpanded ? "Hide notes" : "Show notes")) {
                    isExpanded.toggle()
                }
                Spacer()

                if let prog = downloadProgress {
                    ProgressView(value: prog)
                        .progressViewStyle(CircularProgressViewStyle())
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Downloading")
                        .accessibilityValue("\(Int(prog * 100)) percent")
                } else if isDownloaded {
                    Image(systemName: "checkmark.icloud.fill")
                        .foregroundColor(pal.accent)
                        .font(.caption)
                        .accessibilityLabel("Downloaded")
                }

                // Visible disclosure for show-notes (only when there are any). Separate from the
                // row's tap-to-play so reading the notes never starts playback by accident.
                if ep.description != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(pal.dim)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .accessibilityLabel(isExpanded ? "Hide notes" : "Show notes")
                }

                Menu {
                    Button(action: {
                        queueManager.playEpisode(ep)
                    }) {
                        Label("Play", systemImage: "play.fill")
                    }

                    Button(action: {
                        if !queueManager.queue.isEmpty {
                            queueManager.queue.insert(ep, at: 1)
                        } else {
                            queueManager.playEpisode(ep)
                        }
                    }) {
                        Label("Play Next", systemImage: "text.insert")
                    }

                    Button(action: {
                        queueManager.addToQueue(ep)
                    }) {
                        Label("Add to Queue", systemImage: "text.append")
                    }

                    Button(action: {
                        if isPlayed {
                            queueManager.markUnfinished(ep.id)
                            isPlayed = false
                        } else {
                            queueManager.markFinished(ep.id)
                            isPlayed = true
                        }
                    }) {
                        Label(isPlayed ? "Mark as Unplayed" : "Mark as Played",
                              systemImage: isPlayed ? "circle" : "checkmark.circle")
                    }

                    if isDownloaded {
                        Button(role: .destructive, action: {
                            if let url = URL(string: ep.audioUrl) {
                                AudioDownloader.shared.deleteCachedEpisode(for: url)
                                isDownloaded = false
                            }
                        }) {
                            Label("Remove Download", systemImage: "trash")
                        }
                    } else {
                        Button(action: {
                            if let url = URL(string: ep.audioUrl) {
                                Task {
                                    downloadProgress = 0.01
                                    _ = try? await AudioDownloader.shared.download(url: url) { prog in
                                        DispatchQueue.main.async { downloadProgress = prog }
                                    }
                                    DispatchQueue.main.async { 
                                        isDownloaded = true
                                        downloadProgress = nil
                                    }
                                }
                            }
                        }) {
                            Label("Download Offline", systemImage: "icloud.and.arrow.down")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(pal.dim)
                        .padding(8)
                        .frame(minWidth: 44, minHeight: 44)
                        .background(pal.text.opacity(0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel("Episode options")
            }
            .contentShape(Rectangle())
            // A single tap plays immediately — no more "tap to expand, tap again to play."
            .onTapGesture {
                queueManager.playEpisode(ep)
            }

            if isExpanded, let desc = ep.description {
                Text(desc)
                    .font(.system(.caption, design: .rounded))
                    .foregroundColor(pal.text.opacity(0.8))
                    .padding(.leading, 60)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
        // Quick, discoverable controls without opening the overflow menu: swipe right to play,
        // swipe left to queue.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { queueManager.playEpisode(ep) } label: {
                Label("Play", systemImage: "play.fill")
            }
            .tint(.green)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { queueManager.addToQueue(ep) } label: {
                Label("Queue", systemImage: "text.append")
            }
            .tint(pal.accent)
        }
        .onAppear {
            // Seeded from the parent's precomputed set — no per-row disk I/O on scroll.
            isDownloaded = initiallyDownloaded
            progress = savedProgress
            isPlayed = initiallyPlayed
        }
    }
}
