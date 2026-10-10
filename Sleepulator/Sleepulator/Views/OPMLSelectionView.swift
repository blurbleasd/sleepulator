import SwiftUI

/// Pick which shows to bring over from another app's OPML export. On the app palette (it was
/// hard-coded black/gray/gold, so Focus got a warm amber sheet), with the system's own toolbar
/// actions, and shows you already follow marked instead of silently skipped.
struct OPMLSelectionView: View {
    let feeds: [OPMLFeed]
    /// Feed links already in the library: shown as "In your library" and left out of the import.
    var subscribedUrls: Set<String> = []
    let onImport: ([OPMLFeed]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedUrls: Set<String> = []

    @AppStorage("focusMode") private var focusMode = false
    private var pal: Palette { Palette(focusMode: focusMode) }

    private var importable: [OPMLFeed] { feeds.filter { !subscribedUrls.contains($0.url) } }
    private var allSelected: Bool { !importable.isEmpty && selectedUrls.count == importable.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(feeds, id: \.url) { feed in
                        row(feed)
                            .listRowBackground(pal.text.opacity(0.05))
                    }
                } header: {
                    HStack {
                        Text("\(selectedUrls.count) of \(PodcastText.showCount(importable.count)) selected")
                            .foregroundColor(pal.dim)
                        Spacer()
                        if !importable.isEmpty {
                            Button(allSelected ? "Deselect All" : "Select All") {
                                selectedUrls = allSelected ? [] : Set(importable.map(\.url))
                            }
                            .foregroundColor(pal.accent)
                            .frame(minHeight: 44)
                        }
                    }
                    .font(.system(.subheadline, design: .rounded))
                    .textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(pal.bg.ignoresSafeArea())
            .navigationTitle("Import Shows")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        onImport(feeds.filter { selectedUrls.contains($0.url) })
                        dismiss()
                    }
                    .disabled(selectedUrls.isEmpty)
                }
            }
        }
        .tint(pal.accent)
        .onAppear {
            selectedUrls = Set(importable.map(\.url))
        }
    }

    private func row(_ feed: OPMLFeed) -> some View {
        let subscribed = subscribedUrls.contains(feed.url)
        let selected = selectedUrls.contains(feed.url)
        return Button {
            if selected { selectedUrls.remove(feed.url) } else { selectedUrls.insert(feed.url) }
        } label: {
            HStack(spacing: UI.md) {
                Image(systemName: subscribed ? "checkmark" : (selected ? "checkmark.circle.fill" : "circle"))
                    .font(.title3)
                    .foregroundColor(subscribed ? pal.dim : (selected ? pal.accent : pal.dim))
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feed.name)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(subscribed ? pal.dim : pal.text)
                        .fixedSize(horizontal: false, vertical: true)
                    // The site, not the raw feed URL: enough to tell two same-named shows apart.
                    Text(subscribed ? "In your library" : (URL(string: feed.url)?.host ?? feed.url))
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(pal.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(subscribed)
        .accessibilityLabel(subscribed ? "\(feed.name), in your library" : feed.name)
        .accessibilityValue(subscribed ? "" : (selected ? "Selected" : "Not selected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
