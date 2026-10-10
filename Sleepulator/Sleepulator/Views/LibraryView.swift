import SwiftUI
import UniformTypeIdentifiers
import Combine
import os

struct LibraryView: View {
    /// Held unobserved (a plain `let`): passed to the pushed detail/add views and used for queue
    /// actions, but NOT observed — so unrelated engine publishes (podTitle, transport, settings)
    /// don't re-render the podcast list. Reactive needs come from `queue` + `connectivity`.
    let audio: AudioEngine
    @ObservedObject var queue: PodcastQueueManager
    @ObservedObject var connectivity: Connectivity
    /// The "Last Night" snapshot feeds the Tonight shelf. Low-frequency (written on pause, stop and
    /// backgrounding), so observing it is safe where observing the engine is not.
    @ObservedObject var mixStore: MixStore
    @State private var feedUrlInput = ""
    @State private var podcasts: [Podcast] = []
    /// library.json is read once, then this view's state is the source of truth (the show page
    /// edits it through a binding; a Backup restore posts SleepulatorLibraryReload). Re-reading
    /// on every appear reverted shows that an import or refresh had loaded but not yet saved.
    @State private var didLoadLibrary = false
    @State private var isLoading = false
    /// The in-flight add, cancelled if its sheet closes: a slow feed used to finish later, add
    /// the show you'd cancelled and close the next Add sheet you'd opened.
    @State private var addTask: Task<Void, Never>? = nil
    @State private var errorMessage: String? = nil

    @State private var searchText = ""
    @State private var showAddSheet = false
    /// Set when a pull-to-refresh couldn't reach every show; shown under the list, cleared by the
    /// next refresh that succeeds. Failures used to vanish silently.
    @State private var refreshNote: String? = nil

    @State private var opmlImporting = false
    /// Import was chosen inside the Add sheet: open the file picker once that sheet has gone.
    @State private var importAfterAddSheet = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    /// The import result is raised after the OPML sheet has gone: an alert requested while a
    /// sheet is still up can silently never appear.
    @State private var importAlertPending = false

    /// Feeds parsed from a picked OPML file. The sheet is presented *by item* so it receives
    /// them directly: with an isPresented flag plus a separate array read only inside the sheet
    /// closure, SwiftUI handed the sheet the stale empty array ("0 of 0 shows selected").
    @State private var opmlImport: OPMLImportBatch? = nil

    /// Mode-aware like Home: Focus is cool everywhere, not just on Home. Read from the persisted
    /// "focusMode" key (AudioEngine writes it) so this view needn't observe the whole engine.
    @AppStorage("focusMode") private var focusMode = false
    var pal: Palette { Palette(focusMode: focusMode) }
    /// The night ring's length (0 = All night), for the shelf's "runs past your night" note.
    @AppStorage("nightLengthMinutes") private var nightLength: Double = 0
    /// Saved episode positions (the player's in-memory map): what the shelf resumes from.
    @State private var positions: [String: Double] = [:]

    private var tonight: TonightPlan {
        TonightShelf.plan(library: podcasts,
                          lastEpisodeId: mixStore.lastMix?.podcastId,
                          lastPosition: mixStore.lastMix?.podcastPosition,
                          savedPositions: positions,
                          finished: queue.finishedEpisodes)
    }

    private var visiblePodcasts: [Podcast] {
        podcasts.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        let plan = tonight
        NavigationStack {
            ZStack {
                // Background
                pal.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    if !connectivity.isOnline {
                        // Palette, not system orange: a saturated orange bar was the loudest thing in
                        // the app at night. Cream on the ember tint keeps AA without the glare.
                        Label("You're offline", systemImage: "wifi.slash")
                            .font(.caption.bold())
                            .foregroundColor(pal.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(pal.accent.opacity(0.18))
                    }

                    List {
                    // Pick up where you drifted off, before the archive. Hidden while searching
                    // your shows, and absent (never an empty card) when there's nothing to resume.
                    if searchText.isEmpty, !plan.isEmpty {
                        Section {
                            TonightShelfView(plan: plan, pal: pal, focusMode: focusMode, nightMinutes: nightLength,
                                             onResume: {
                                                 guard let r = plan.resume else { return }
                                                 UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                 audio.resumeEpisode(r.episode, at: r.position)
                                             },
                                             onBackUp: {
                                                 guard let r = plan.resume else { return }
                                                 UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                 audio.resumeEpisode(r.episode, at: r.position, backUp: TonightShelf.backUpInterval)
                                             },
                                             onPlayNext: {
                                                 guard let n = plan.next else { return }
                                                 UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                 audio.resumeEpisode(n.episode, at: nil)
                                             })
                        } header: {
                            Text(focusMode ? "Continue" : "Tonight")
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundColor(pal.dim)
                                .textCase(nil)
                        }
                    }

                    Section {
                        ForEach(visiblePodcasts) { podcast in
                            NavigationLink(value: podcast.id) {
                                HStack(spacing: 16) {
                                    if let art = podcast.artworkUrl, let url = URL(string: art) {
                                        // Dimmed in Sleep like the Tonight shelf and NowPlayingSheet:
                                        // cover art is the brightest block on a 2am list.
                                        CachedAsyncImage(url: url, size: 64, cornerRadius: 12)
                                            .opacity(pal.artOpacity)
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
                                if let latest = TonightShelf.latestUnplayed(in: podcast, finished: queue.finishedEpisodes, excluding: nil)
                                    ?? podcast.episodes.first {
                                    Button {
                                        queue.playEpisode(latest)
                                    } label: {
                                        Label("Play Latest", systemImage: "play.fill")
                                    }
                                    .tint(pal.actionFill)
                                }
                            }
                        }
                        .onDelete { indices in
                            let filtered = visiblePodcasts
                            for index in indices {
                                if let actualIndex = podcasts.firstIndex(where: { $0.id == filtered[index].id }) {
                                    podcasts.remove(at: actualIndex)
                                }
                            }
                            savePodcasts()
                        }

                        // Searching your shows and matching none used to leave a blank list.
                        if !searchText.isEmpty && visiblePodcasts.isEmpty && !podcasts.isEmpty {
                            Text("No shows match \u{201C}\(searchText)\u{201D}")
                                .font(.subheadline)
                                .foregroundColor(pal.dim)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .listRowBackground(Color.clear)
                        }
                    } footer: {
                        if let note = refreshNote {
                            HStack(alignment: .firstTextBaseline, spacing: UI.xs) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .accessibilityHidden(true)
                                Text(note)
                            }
                            .font(.footnote)
                            .foregroundColor(pal.accent)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .searchable(text: $searchText, prompt: "Search your shows")
                .refreshable { await refreshAll() }

                // Empty state — the screen was a black void with no subscriptions. An overlay on
                // the list, so it has the whole screen: as a sibling below the (empty) list in this
                // VStack it only ever got the bottom half. Centred when it fits; it scrolls when the
                // largest text sizes don't (it used to clip).
                .overlay {
                    if podcasts.isEmpty {
                        GeometryReader { proxy in
                            ScrollView {
                                VStack(spacing: 14) {
                                    Image(systemName: "dot.radiowaves.left.and.right")
                                        .font(.system(size: 46))
                                        .foregroundColor(pal.accent.opacity(0.55))
                                    Text("No podcasts yet")
                                        .font(.system(.title3, design: .rounded).bold())
                                        .foregroundColor(pal.text)
                                    Text("Tap + to find a show by name, or to bring your subscriptions over from another podcast app.")
                                        .font(.subheadline)
                                        .foregroundColor(pal.dim)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 44)
                                }
                                .padding(.vertical, 24)
                                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                            }
                            .scrollBounceBehavior(.basedOnSize)
                        }
                    }
                }
            }
            // Room for the floating mini-player (the empty state used to sit under it).
            .miniPlayerClearance()
            .navigationTitle("Podcasts")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        // A fresh sheet: no stale error or link from the last attempt.
                        errorMessage = nil
                        feedUrlInput = ""
                        showAddSheet = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(pal.accent)
                    }
                    .accessibilityLabel("Add podcast")
                }
            }
            .navigationDestination(for: String.self) { podcastId in
                if let podcast = podcasts.first(where: { $0.id == podcastId }) {
                    PodcastDetailView(podcast: podcast, audio: audio, connectivity: connectivity, libraryPodcasts: $podcasts)
                } else {
                    // Removed (or lost in a restore) while you were away: say so and point home.
                    ContentUnavailableView("Not in your library",
                                           systemImage: "antenna.radiowaves.left.and.right.slash",
                                           description: Text("This show may have been removed. Go back to see your podcasts."))
                        .foregroundStyle(pal.dim)
                }
            }
            .onAppear {
                if !didLoadLibrary {
                    loadPodcasts()
                    didLoadLibrary = true
                }
                loadPositions()
            }
            // A new snapshot (you paused or stopped) can change what the shelf offers.
            .onChange(of: mixStore.lastMix?.podcastId) { _, _ in loadPositions() }
            .onChange(of: mixStore.lastMix?.podcastPosition) { _, _ in loadPositions() }
            // Re-read library.json after an in-process Backup restore (the engine posts this).
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SleepulatorLibraryReload"))) { _ in
                loadPodcasts()
            }
        }
        .sheet(isPresented: $showAddSheet, onDismiss: {
            addTask?.cancel()
            addTask = nil
            isLoading = false
            if importAfterAddSheet {
                importAfterAddSheet = false
                opmlImporting = true
            }
        }) {
            AddPodcastSheet(feedUrlInput: $feedUrlInput, isLoading: $isLoading, errorMessage: $errorMessage, pal: pal,
                            subscribedFeedUrls: Set(podcasts.map(\.url)), onAdd: {
                loadFeed()
            }, onImport: {
                importAfterAddSheet = true
                showAddSheet = false
            }, connectivity: connectivity)
            .presentationDetents([.fraction(0.8), .large])
        }
        .fileImporter(isPresented: $opmlImporting, allowedContentTypes: [.xml, .plainText, .data], allowsMultipleSelection: false) { result in
            let selectedFile: URL
            do {
                guard let file = try result.get().first else { return }
                selectedFile = file
            } catch {
                Log.network.error("OPML import failed: \(error.localizedDescription, privacy: .public)")
                // Logged only, before: the picker closed and nothing said why.
                alertTitle = "Couldn't open that file"
                alertMessage = "Choose the OPML file you exported from your other podcast app and try again."
                showAlert = true
                return
            }
            // Parse off the main thread — a large OPML file would otherwise freeze the UI
            // inside this importer callback. Hop back to the main actor only to publish state.
            Task {
                let feeds = await Task.detached(priority: .userInitiated) { () -> [OPMLFeed] in
                    guard selectedFile.startAccessingSecurityScopedResource() else { return [] }
                    defer { selectedFile.stopAccessingSecurityScopedResource() }
                    return OPMLParser().parse(url: selectedFile)
                }.value
                guard !feeds.isEmpty else {
                    // Don't open an empty selector — tell the user why nothing happened.
                    self.alertTitle = "No shows found"
                    self.alertMessage = "That file has no podcast subscriptions in it. Export an OPML file from your other podcast app and try again."
                    self.showAlert = true
                    return
                }
                self.opmlImport = OPMLImportBatch(feeds: feeds)
            }
        }
        .sheet(item: $opmlImport, onDismiss: {
            if importAlertPending {
                importAlertPending = false
                showAlert = true
            }
        }) { batch in
            OPMLSelectionView(feeds: batch.feeds, subscribedUrls: Set(podcasts.map(\.url))) { selectedFeeds in
                importFeeds(selectedFeeds)
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    }

    /// Subscription-row subtitle: surface the unplayed count once episodes are loaded so the
    /// list is scannable, falling back to a prompt or "All caught up". The wording lives in
    /// `PodcastText.librarySubtitle`.
    private func subtitle(for podcast: Podcast) -> String {
        let total = podcast.episodes.count
        let unplayed = podcast.episodes.reduce(0) { $0 + (queue.finishedEpisodes.contains($1.id) ? 0 : 1) }
        return PodcastText.librarySubtitle(total: total, unplayed: unplayed)
    }

    // MARK: - Feed Loading

    /// Write a freshly parsed feed into the library row with that id (`Podcast.merge`). False when
    /// the feed had no episodes, which keeps the stored ones.
    @discardableResult
    private func apply(_ feed: PodcastParser.ParsedFeed, toPodcastWithId id: String) -> Bool {
        guard let idx = podcasts.firstIndex(where: { $0.id == id }) else { return true }
        return podcasts[idx].merge(title: feed.title, artworkUrl: feed.artworkUrl, episodes: feed.episodes)
    }

    /// Pull-to-refresh: reload every feed, then say which ones failed instead of dropping them.
    private func refreshAll() async {
        guard connectivity.isOnline else {
            refreshNote = "You're offline. Connect to refresh your shows."
            return
        }
        let shows = podcasts
        var failed: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for podcast in shows {
                group.addTask {
                    guard let url = URL(string: podcast.url),
                          let feed = try? await PodcastParser().parseFeed(url: url) else { return podcast.name }
                    let kept = await MainActor.run { apply(feed, toPodcastWithId: podcast.id) }
                    return kept ? nil : podcast.name
                }
            }
            for await name in group {
                if let name { failed.append(name) }
            }
        }
        savePodcasts()
        switch failed.count {
        case 0:  refreshNote = nil
        case 1:  refreshNote = "Couldn't refresh \(failed[0]). Pull down to try again."
        default: refreshNote = "Couldn't refresh \(PodcastText.showCount(failed.count)). Pull down to try again."
        }
    }

    /// Subscribe to the shows picked in the OPML sheet, then load their feeds in the background.
    private func importFeeds(_ selectedFeeds: [OPMLFeed]) {
        let added = selectedFeeds.filter { feed in !podcasts.contains(where: { $0.url == feed.url }) }
        for feed in added {
            podcasts.append(Podcast(id: feed.url, name: feed.name, url: feed.url, episodes: []))
        }
        savePodcasts()
        if added.isEmpty {
            alertTitle = "Nothing new to import"
            alertMessage = "Those shows are already in your library."
        } else {
            alertTitle = "Shows imported"
            alertMessage = "Added \(PodcastText.showCount(added.count)). Their episodes will appear as each one loads."
        }
        importAlertPending = true

        guard !added.isEmpty else { return }
        Task {
            await withTaskGroup(of: Void.self) { group in
                for feed in added {
                    group.addTask {
                        if let url = URL(string: feed.url), let parsed = try? await PodcastParser().parseFeed(url: url) {
                            await MainActor.run { apply(parsed, toPodcastWithId: feed.url) }
                        }
                    }
                }
            }
            savePodcasts()
        }
    }

    func loadFeed() {
        let link = feedUrlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        // A malformed link used to do nothing at all.
        guard let url = URL(string: link),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else {
            errorMessage = "That link doesn't look right. Paste the show's full RSS link, starting with https://."
            return
        }
        guard !podcasts.contains(where: { $0.id == url.absoluteString || $0.url == url.absoluteString }) else {
            errorMessage = "That show is already in your library."
            return
        }
        guard !isLoading else { return }   // a second tap while the first add is still loading
        isLoading = true
        errorMessage = nil

        addTask = Task {
            do {
                let feed = try await PodcastParser().parseFeed(url: url)
                try Task.checkCancellation()
                // A web page, a blog's RSS or an empty feed parses with no playable episodes.
                guard !feed.episodes.isEmpty else { throw NotAPodcastFeed() }
                let name = !feed.title.isEmpty ? feed.title : PodcastText.fallbackName(for: url)
                let pod = Podcast(id: url.absoluteString, name: name, url: url.absoluteString, episodes: feed.episodes, artworkUrl: feed.artworkUrl)
                if !podcasts.contains(where: { $0.id == pod.id }) {
                    podcasts.insert(pod, at: 0)
                    savePodcasts()
                }
                feedUrlInput = ""
                isLoading = false
                showAddSheet = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                // Cancelled because the sheet closed: say nothing, change nothing.
                guard !Task.isCancelled else { return }
                Log.network.error("Feed parse error: \(error.localizedDescription, privacy: .public)")
                isLoading = false
                // Plain recovery copy, not the raw system error (logged above).
                if error is NotAPodcastFeed {
                    errorMessage = "That link has no episodes to play. Check it's the show's podcast feed."
                } else if PodcastText.isOffline(error) {
                    errorMessage = "You're offline. Connect and try again."
                } else {
                    errorMessage = "Couldn't load that feed. Check it's a podcast RSS link and try again."
                }
            }
        }
    }

    private struct NotAPodcastFeed: Error {}

    private func savePodcasts() {
        StorageManager.shared.save(podcasts, to: "library.json")
    }
    private func loadPositions() {
        positions = audio.savedEpisodePositions
    }
    private func loadPodcasts() {
        if let decoded: [Podcast] = StorageManager.shared.load(from: "library.json") {
            self.podcasts = decoded
        }
    }
}

/// One picked OPML file's feeds, presented as a sheet item.
struct OPMLImportBatch: Identifiable {
    let id = UUID()
    let feeds: [OPMLFeed]
}

struct AddPodcastSheet: View {
    @Binding var feedUrlInput: String
    @Binding var isLoading: Bool
    @Binding var errorMessage: String?
    let pal: Palette
    /// Feed links already in the library, so a search result can say so instead of re-adding it.
    let subscribedFeedUrls: Set<String>
    let onAdd: () -> Void
    /// Bring subscriptions over from another app (an OPML file). The library opens the picker.
    let onImport: () -> Void
    @ObservedObject var connectivity: Connectivity

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldFocused: Bool
    @State private var searchResults: [ITunesPodcast] = []
    @State private var searchState: SearchState = .idle
    @State private var searchQuery = ""
    @State private var searchTask: Task<Void, Never>? = nil

    /// A failed search used to look exactly like "no results" (`try?` swallowed it).
    private enum SearchState { case idle, searching, done, failed }

    private var trimmedQuery: String { searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isLink: Bool { Self.isFeedLink(trimmedQuery) }
    private static func isFeedLink(_ text: String) -> Bool { text.lowercased().hasPrefix("http") }

    var body: some View {
        NavigationStack {
            ZStack {
                pal.bg.ignoresSafeArea()
                VStack(alignment: .leading, spacing: UI.lg) {
                    if !connectivity.isOnline {
                        Label("You're offline. Searching and adding shows need a connection.", systemImage: "wifi.slash")
                            .font(.subheadline)
                            .foregroundColor(pal.accent)
                            .padding(.horizontal, UI.xl)
                    }

                    searchField

                    if let err = errorMessage {
                        // Palette amber + a warning glyph (Home's playback note does the same): system
                        // red is the loudest colour in the app at night, and colour alone isn't the message.
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundColor(pal.accent)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, UI.xl)
                    }

                    if isLink {
                        addLinkButton
                    } else {
                        results
                    }

                    Spacer(minLength: 0)
                }
                .padding(.top, UI.sm)
            }
            .navigationTitle("Add Podcast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The sheet could only be swiped away before.
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(pal.accent)
        .onAppear { fieldFocused = true }
        .onDisappear { searchTask?.cancel() }
    }

    private var searchField: some View {
        HStack(spacing: UI.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(pal.dim)
                .accessibilityHidden(true)
            TextField("Search shows or paste a feed link", text: $searchQuery,
                      prompt: Text("Search shows or paste a feed link").foregroundColor(pal.dim))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(isLink ? .go : .search)
                .focused($fieldFocused)
                .foregroundColor(pal.text)
                .onSubmit { if isLink { add(feedURL: trimmedQuery) } }
                .onChange(of: searchQuery) { _, newValue in runSearch(newValue) }
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(pal.dim)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, UI.md)
        .frame(minHeight: 44)
        .background(pal.text.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(pal.text.opacity(0.14), lineWidth: 1))
        .padding(.horizontal, UI.xl)
    }

    private var addLinkButton: some View {
        Button { add(feedURL: trimmedQuery) } label: {
            Group {
                if isLoading {
                    ProgressView().tint(pal.bg)
                } else {
                    Text("Add Show")
                        .font(.headline)
                        .foregroundColor(pal.bg)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(pal.accent, in: Capsule())
        }
        .disabled(!connectivity.isOnline || isLoading)
        .padding(.horizontal, UI.xl)
    }

    @ViewBuilder private var results: some View {
        switch searchState {
        case .searching:
            ProgressView()
                .tint(pal.accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding()
        case .failed:
            note("Search isn't reachable right now. Check your connection, or paste the show's RSS link.",
                 systemImage: "exclamationmark.triangle.fill")
        case .done where searchResults.isEmpty:
            note("No shows found for \u{201C}\(trimmedQuery)\u{201D}. Try another name, or paste the show's RSS link.",
                 systemImage: "magnifyingglass")
        case .done:
            List(searchResults) { result in
                resultRow(result)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        case .idle:
            if trimmedQuery.isEmpty {
                // The sheet opened onto an empty field and nothing else.
                VStack(alignment: .leading, spacing: UI.xxl) {
                    note("Search by show name, or paste a feed link from the show's website.", systemImage: nil)
                    VStack(alignment: .leading, spacing: UI.sm) {
                        Text("Moving from another podcast app?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(pal.text)
                        Text("Export your subscriptions there as an OPML file, then import it here.")
                            .font(.subheadline)
                            .foregroundColor(pal.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(action: onImport) {
                            Label("Import Subscriptions", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(EmberButtonStyle(pal: pal, quiet: true))
                        .padding(.top, UI.xs)
                    }
                    .padding(.horizontal, UI.xl)
                }
            }
        }
    }

    private func note(_ text: String, systemImage: String?) -> some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.subheadline)
        .foregroundColor(pal.dim)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, UI.xl)
    }

    private func resultRow(_ result: ITunesPodcast) -> some View {
        let feed = result.feedUrl ?? ""
        let subscribed = subscribedFeedUrls.contains(feed)
        let adding = isLoading && feedUrlInput == feed
        let name = result.collectionName ?? "Untitled show"
        return Button { add(feedURL: feed) } label: {
            HStack(spacing: UI.md) {
                if let urlString = result.artworkUrl600, let url = URL(string: urlString) {
                    CachedAsyncImage(url: url, size: 44)
                } else {
                    // Rows without artwork used to lose their thumbnail column and misalign.
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(pal.accent)
                        .frame(width: 44, height: 44)
                        .background(pal.text.opacity(0.1))
                        .cornerRadius(8)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.headline)
                        .foregroundColor(pal.text)
                        .lineLimit(2)
                    Text(subscribed ? "In your library" : (result.artistName ?? ""))
                        .font(.subheadline)
                        .foregroundColor(pal.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: UI.sm)
                Group {
                    if adding {
                        ProgressView().tint(pal.accent)
                    } else if subscribed {
                        Image(systemName: "checkmark").foregroundColor(pal.dim)
                    } else {
                        Image(systemName: "plus.circle").foregroundColor(pal.accent)
                    }
                }
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // One add at a time: a tap used to give no feedback, so people tapped again.
        .disabled(subscribed || isLoading || feed.isEmpty)
        .accessibilityLabel(subscribed ? "\(name), in your library" : name)
        .accessibilityHint(subscribed ? "" : "Adds this show to your library")
        .accessibilityValue(adding ? "Adding" : "")
    }

    private func add(feedURL: String) {
        guard !feedURL.isEmpty else { return }
        fieldFocused = false
        feedUrlInput = feedURL
        onAdd()
    }

    private func runSearch(_ newValue: String) {
        // Cancel any in-flight search; a per-keystroke fan-out used to race,
        // and a slow early request could overwrite a newer query's results.
        searchTask?.cancel()
        errorMessage = nil
        let query = newValue.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.isFeedLink(query) {
            searchResults = []
            searchState = .idle
            return
        }
        guard query.count > 2, connectivity.isOnline else {
            searchResults = []
            searchState = .idle
            return
        }

        searchTask = Task {
            // Debounce: wait for typing to settle before hitting the network.
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            searchState = .searching
            do {
                let found = try await ITunesSearchManager.shared.search(query: query)
                // Ignore results whose query no longer matches the field.
                guard !Task.isCancelled, newValue == searchQuery else { return }
                searchResults = found
                searchState = .done
            } catch {
                guard !Task.isCancelled, newValue == searchQuery else { return }
                Log.network.error("Podcast search failed: \(error.localizedDescription, privacy: .public)")
                searchResults = []
                searchState = .failed
            }
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

    /// Mode-aware like Home: Focus is cool everywhere, not just on Home. Read from the persisted
    /// "focusMode" key (AudioEngine writes it) so this view needn't observe the whole engine.
    @AppStorage("focusMode") private var focusMode = false
    var pal: Palette { Palette(focusMode: focusMode) }

    @State private var isDownloaded = false
    @State private var downloadProgress: Double? = nil
    /// The last download attempt failed. A failure used to be marked "Downloaded" anyway, so an
    /// episode you counted on offline played silence.
    @State private var downloadFailed = false
    @State private var progress: Double = 0
    @State private var isExpanded = false
    @State private var isPlayed = false
    /// Plain-text show-notes, flattened when first expanded (cached episodes can predate the
    /// parser's own cleanup). The first few lines show until "More".
    @State private var notesText: String? = nil
    @State private var notesPreview: String? = nil
    @State private var showAllNotes = false
    /// At accessibility sizes the thumbnail goes and the date/length stack, so the title keeps
    /// room beside the notes and options controls instead of truncating to a few words.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Played state for VoiceOver: the unplayed dot and the resume bar are visual only.
    private var playedState: String {
        if isPlayed { return "Played" }
        return progress > 0 ? "In progress" : "Unplayed"
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

    /// Started episodes say what's left ("23 min left"), the rest their full length.
    private var lengthLabel: String? {
        if progress > 0, progress < 0.98, let duration = ep.duration {
            return PodcastText.timeLeft(duration * (1 - progress))
        }
        return PodcastText.duration(ep.duration)
    }

    private func toggleNotes() {
        if notesText == nil, let desc = ep.description {
            let notes = PodcastText.displayShowNotes(desc)
            notesText = notes
            notesPreview = PodcastText.notesPreview(notes)
        }
        withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        if !isExpanded { showAllNotes = false }
    }

    private func startDownload() {
        guard let url = URL(string: ep.audioUrl) else { return }
        Task {
            downloadFailed = false
            downloadProgress = 0.01
            do {
                _ = try await AudioDownloader.shared.download(url: url) { prog in
                    // Progress arrives off the completion's ordering: once the attempt has settled
                    // (progress back to nil), a late update would leave a spinner forever.
                    DispatchQueue.main.async { if downloadProgress != nil { downloadProgress = prog } }
                }
                // Through the main queue so it lands after any progress update already queued.
                DispatchQueue.main.async {
                    isDownloaded = true
                    downloadProgress = nil
                }
            } catch {
                Log.network.error("Episode download failed: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async {
                    downloadFailed = true
                    downloadProgress = nil
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                // Thumbnail
                if !typeSize.isAccessibilitySize {
                    if let artStr = ep.artworkUrl ?? podcast.artworkUrl, let url = URL(string: artStr) {
                        CachedAsyncImage(url: url, size: 48, cornerRadius: 8)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "mic.fill")
                            .foregroundColor(pal.accent)
                            .frame(width: 48, height: 48)
                            .background(pal.text.opacity(0.1))
                            .cornerRadius(8)
                            .accessibilityHidden(true)
                    }
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
                            .lineLimit(typeSize.isAccessibilitySize ? 5 : 2)
                    }

                    let metadata = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 8))
                    metadata {
                        if let pubDate = ep.pubDate {
                            Text(relativeDate(pubDate))
                                .font(.system(.caption2, design: .rounded))
                                .foregroundColor(pal.dim)
                        }
                        if let lengthStr = lengthLabel {
                            Text(lengthStr)
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
                .accessibilityValue(playedState)
                .accessibilityHint("Plays the episode")
                .accessibilityAction { queueManager.playEpisode(ep) }
                .accessibilityAction(named: Text(isExpanded ? "Hide notes" : "Show notes")) {
                    toggleNotes()
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
                } else if downloadFailed {
                    Image(systemName: "exclamationmark.icloud")
                        .foregroundColor(pal.accent)
                        .font(.caption)
                        .accessibilityLabel("Download failed")
                        .accessibilityHint("Try again from Episode options")
                }

                // Visible disclosure for show-notes (only when there are any). Separate from the
                // row's tap-to-play so reading the notes never starts playback by accident.
                if ep.description != nil {
                    Button {
                        toggleNotes()
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
                    } else if downloadProgress == nil {
                        Button(action: startDownload) {
                            Label(downloadFailed ? "Retry Download" : "Download Offline",
                                  systemImage: "icloud.and.arrow.down")
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

            if isExpanded, let notes = notesText, !notes.isEmpty {
                VStack(alignment: .leading, spacing: UI.xs) {
                    let preview = notesPreview ?? notes
                    Text(showAllNotes ? notes : preview)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(pal.text.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                    if !showAllNotes && preview != notes {
                        Button("More") { showAllNotes = true }
                            .font(.system(.footnote, design: .rounded).weight(.semibold))
                            .foregroundColor(pal.accent)
                            .buttonStyle(.plain)
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                }
                .padding(.leading, typeSize.isAccessibilitySize ? 0 : 60)
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
            .tint(pal.actionFill)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button { queueManager.addToQueue(ep) } label: {
                Label("Add to Queue", systemImage: "text.append")
            }
            .tint(pal.actionFill)
        }
        .onAppear {
            // Seeded from the parent's precomputed set — no per-row disk I/O on scroll.
            isDownloaded = initiallyDownloaded
            progress = savedProgress
            isPlayed = initiallyPlayed
        }
    }
}
