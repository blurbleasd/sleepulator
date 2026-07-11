import SwiftUI
import MusicKit

/// A lightweight Apple Music catalog browser for the Focus mixer. Search songs / albums /
/// playlists and tap one to start it as a parallel Focus source (see APPLE-MUSIC-FOCUS-SPEC.md).
/// Deliberately minimal in v1 — a search box over the catalog rather than a full library browser.
struct AppleMusicPickerView: View {
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Hold the whole response rather than three `MusicItemCollection`s seeded from `[]`
    /// (those collections aren't ExpressibleByArrayLiteral). nil = no search run yet.
    @State private var response: MusicCatalogSearchResponse?
    @State private var isSearching = false
    @State private var authResolved = false
    @State private var authorized = false

    private var hasResults: Bool {
        guard let r = response else { return false }
        return !r.songs.isEmpty || !r.albums.isEmpty || !r.playlists.isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if authResolved && !authorized {
                    ContentUnavailableView(
                        "Apple Music is off",
                        systemImage: "music.note",
                        description: Text("Enable Apple Music access in Settings ▸ Sleepulator to play it in Focus.")
                    )
                } else if !hasResults && !isSearching {
                    ContentUnavailableView(
                        "Search Apple Music",
                        systemImage: "magnifyingglass",
                        description: Text("Find a song, album, or playlist to play alongside your Focus sounds.")
                    )
                } else {
                    resultsList
                }
            }
            .navigationTitle("Apple Music")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Songs, albums, playlists")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                authorized = await audio.ensureAppleMusicAuthorized()
                authResolved = true
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var resultsList: some View {
        if let r = response {
            List {
                if !r.playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(r.playlists) { p in
                            row(title: p.name, subtitle: p.curatorName, artwork: p.artwork) { audio.startAppleMusic(p); dismiss() }
                        }
                    }
                }
                if !r.albums.isEmpty {
                    Section("Albums") {
                        ForEach(r.albums) { a in
                            row(title: a.title, subtitle: a.artistName, artwork: a.artwork) { audio.startAppleMusic(a); dismiss() }
                        }
                    }
                }
                if !r.songs.isEmpty {
                    Section("Songs") {
                        ForEach(r.songs) { s in
                            row(title: s.title, subtitle: s.artistName, artwork: s.artwork) { audio.startAppleMusic(s); dismiss() }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    @ViewBuilder
    private func row(title: String, subtitle: String?, artwork: Artwork?, play: @escaping () -> Void) -> some View {
        Button(action: play) {
            HStack(spacing: 12) {
                if let artwork {
                    ArtworkImage(artwork, width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.gray.opacity(0.3))
                        .frame(width: 44, height: 44)
                        .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(.body, design: .rounded)).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "play.circle.fill").foregroundStyle(.tint)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func runSearch() async {
        isSearching = true
        defer { isSearching = false }
        response = await audio.searchAppleMusic(query)
    }
}
