import SwiftUI
import UIKit
import ImageIO

// MARK: - Cached artwork

/// Decoded-thumbnail cache for list artwork. Plain `AsyncImage` re-fetches and re-decodes
/// per row, and a long episode list shares one podcast artwork URL — so the same image was
/// decoded dozens of times on the main actor while scrolling. This caches a downsampled,
/// already-decoded `UIImage` keyed by URL + target size, and decodes off the main actor.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() { cache.countLimit = 256 }
    func image(forKey key: String) -> UIImage? { cache.object(forKey: key as NSString) }
    func insert(_ image: UIImage, forKey key: String) { cache.setObject(image, forKey: key as NSString) }
}

/// Drop-in replacement for the small square `AsyncImage`s in the lists. Same visual (fill +
/// rounded corners, gray placeholder), but cached + downsampled so scrolling a long list
/// doesn't re-decode the same artwork on the main thread.
struct CachedAsyncImage: View {
    let url: URL?
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Color.gray.opacity(0.3)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .cornerRadius(cornerRadius)
        .task(id: url) { await load(url: url, size: size) }
    }

    @MainActor private func load(url: URL?, size: CGFloat) async {
        guard let url else { image = nil; return }
        let key = "\(url.absoluteString)@\(Int(size))"
        if let cached = ThumbnailCache.shared.image(forKey: key) {
            image = cached
            return
        }
        // Cache miss on a (possibly recycled) row: clear first so we never flash the
        // previous episode's artwork while this one decodes.
        image = nil
        let maxPixels = size * UIScreen.main.scale
        let decoded = await Self.fetchAndDownsample(url: url, maxPixels: maxPixels)
        if Task.isCancelled { return }
        if let decoded {
            ThumbnailCache.shared.insert(decoded, forKey: key)
            image = decoded
        }
    }

    /// Fetch (file or network) then downsample, both off the main actor. `nonisolated` so the
    /// file/network read and decode don't run on the main actor (`View` is `@MainActor`, which
    /// would otherwise pin these static helpers to it — blocking the main thread on IO/decode).
    nonisolated private static func fetchAndDownsample(url: URL, maxPixels: CGFloat) async -> UIImage? {
        var data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else if let result = try? await URLSession.shared.data(from: url) {
            data = result.0
        }
        guard let data else { return nil }
        return await Task.detached(priority: .utility) {
            downsample(data: data, maxPixels: maxPixels)
        }.value
    }

    nonisolated private static func downsample(data: Data, maxPixels: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixels)
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Glass Panel Modifier
struct GlassPanel: ViewModifier {
    @AppStorage("bedtimeMode") private var bedtimeMode = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background {
                if bedtimeMode {
                    Color.white.opacity(0.04)
                } else {
                    // ultraThin (vs regular) reads as a lighter, less "boxy" card.
                    Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                }
            }
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassPanel() -> some View {
        self.modifier(GlassPanel())
    }
}

// MARK: - Breathing Orb

// MARK: - Warm Custom Slider removed in favor of native Slider

// MARK: - ChipRow Selector
// A refined volume control — a thin capsule track with an accent fill + a small thumb.
// Replaces the stock Slider, which read as "basic" in the mixer rows.
struct VolumeBar: View {
    @Binding var value: Double
    let accent: Color
    var range: ClosedRange<Double> = 0...1
    var onEditingChanged: ((Bool) -> Void)? = nil
    @State private var editing = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let frac = (value - range.lowerBound) / span
            let fill = max(6, min(w, w * CGFloat(frac)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 6)
                Capsule().fill(accent).frame(width: fill, height: 6)
                Circle().fill(.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .offset(x: fill - 7.5)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !editing { editing = true; onEditingChanged?(true) }
                        let f = Double(min(max(g.location.x / w, 0), 1))
                        value = range.lowerBound + f * span
                    }
                    .onEnded { _ in editing = false; onEditingChanged?(false) }
            )
        }
        .frame(height: 28)
        // Hand VoiceOver a standard adjustable slider for this custom control.
        .accessibilityRepresentation { Slider(value: $value, in: range) }
    }
}

struct ChipRow: View {
    let options: [String]
    let labels: [String: String]?
    @Binding var selection: String
    let palette: Palette

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { key in
                    let isSel = selection == key
                    Button(action: { selection = key }) {
                        Text((labels?[key] ?? key).capitalized)
                            .font(.system(.caption, design: .rounded).bold())
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(isSel ? palette.accent : palette.text.opacity(0.08))
                            .foregroundColor(isSel ? palette.bg : palette.dim)
                            .clipShape(Capsule())
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(Text((labels?[key] ?? key)))
                    .accessibilityAddTraits(isSel ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
