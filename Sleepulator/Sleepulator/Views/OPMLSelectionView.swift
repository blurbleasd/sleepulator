import SwiftUI

struct OPMLSelectionView: View {
    let feeds: [OPMLFeed]
    let onImport: ([OPMLFeed]) -> Void
    
    @Environment(\.presentationMode) var presentationMode
    @State private var selectedUrls: Set<String> = []
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button(action: { presentationMode.wrappedValue.dismiss() }) {
                        Text("Cancel")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Text("OPML Import")
                        .font(.system(.title3, design: .rounded).bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)   // shrink before shoving "Import" off the row
                    Spacer()
                    Button(action: {
                        let selected = feeds.filter { selectedUrls.contains($0.url) }
                        onImport(selected)
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        Text("Import")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(selectedUrls.isEmpty ? .gray : Color(red: 0.9, green: 0.7, blue: 0.4))
                    }
                    .disabled(selectedUrls.isEmpty)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                
                // Select All Bar
                HStack {
                    Button(action: {
                        if selectedUrls.count == feeds.count {
                            selectedUrls.removeAll()
                        } else {
                            selectedUrls = Set(feeds.map { $0.url })
                        }
                    }) {
                        Text(selectedUrls.count == feeds.count ? "Deselect All" : "Select All")
                            .font(.system(.subheadline, design: .rounded).bold())
                            .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                    }
                    Spacer()
                    Text("\(selectedUrls.count) / \(feeds.count) Selected")
                        .font(.system(.caption, design: .rounded))
                        .foregroundColor(.gray)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                
                // List
                ScrollView {
                    VStack(spacing: 16) {
                        ForEach(feeds, id: \.url) { feed in
                            Button(action: {
                                if selectedUrls.contains(feed.url) {
                                    selectedUrls.remove(feed.url)
                                } else {
                                    selectedUrls.insert(feed.url)
                                }
                            }) {
                                HStack(spacing: 16) {
                                    Image(systemName: selectedUrls.contains(feed.url) ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundColor(selectedUrls.contains(feed.url) ? Color(red: 0.9, green: 0.7, blue: 0.4) : .gray)
                                        .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(feed.name)
                                            .font(.system(.headline, design: .rounded))
                                            .foregroundColor(.white)
                                            .lineLimit(2)
                                            .minimumScaleFactor(0.75)
                                        Text(feed.url)
                                            .font(.system(.caption2, design: .rounded))
                                            .foregroundColor(.gray)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                    }
                                    Spacer()
                                }
                                .padding()
                                .background(Color.white.opacity(0.05))
                                .cornerRadius(12)
                            }
                            .accessibilityLabel(feed.name)
                            .accessibilityValue(selectedUrls.contains(feed.url) ? "Selected" : "Not selected")
                            .accessibilityAddTraits(selectedUrls.contains(feed.url) ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
        }
        .onAppear {
            selectedUrls = Set(feeds.map { $0.url })
        }
    }
}
