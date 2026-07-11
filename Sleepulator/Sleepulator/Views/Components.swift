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

/// The app's single material choke point — every mixer row, Settings section, and diagnostics
/// card is a GlassPanel, so its treatment defines "how premium the app feels" in one place.
/// Depth comes from *darkness*, never added light (the 2am rule): a top-catches-light /
/// bottom-falls-to-shadow gradient hairline, a true-black drop shadow, and — for warm (Sleep)
/// palettes only — a barely-there warm wash so the cool system material stops fighting the dusk.
/// Pass `pal` from sound-carrying surfaces; the no-arg form stays neutral (Settings, utilities).
/// The bedtime true-OLED path is untouched: flat 4% white, no shadow, pixels stay off.
struct GlassPanel: ViewModifier {
    var pal: Palette? = nil
    @AppStorage("bedtimeMode") private var bedtimeMode = false

    /// The hairline that catches the implied overhead light — palette text for warmth, else white.
    private var edge: Color { pal?.text ?? .white }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, UI.lg)
            .padding(.vertical, UI.md)
            .background {
                if bedtimeMode {
                    Color.white.opacity(0.04)
                } else {
                    ZStack {
                        // ultraThin (vs regular) reads as a lighter, less "boxy" card.
                        Rectangle().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
                        // Warm the glass toward the dusk — Sleep only. `glow` is a near-black warm
                        // tint (not a bright fill), so this deepens rather than lightens. Focus
                        // (warm == false) gets no overlay and stays cool.
                        if let pal, pal.warm {
                            pal.glow.opacity(0.5)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                    .strokeBorder(
                        // Bedtime keeps the original dim white hairline — the warm cream gradient
                        // would emit ~3× more light on the top rim of every panel, defeating the
                        // pixels-off OLED intent of the bedtime path.
                        bedtimeMode
                            ? LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.10)],
                                             startPoint: .top, endPoint: .bottom)
                            : LinearGradient(colors: [edge.opacity(0.16), .white.opacity(0.02)],
                                             startPoint: .top, endPoint: .bottom),
                        lineWidth: bedtimeMode ? 0.5 : 1)
            )
            // Depth by darkness — a soft true-black drop, none on the OLED-off bedtime path.
            .shadow(color: .black.opacity(bedtimeMode ? 0 : 0.4), radius: 14, y: 6)
    }
}

extension View {
    /// `pal` warms the glass for sound-carrying surfaces; omit it for neutral chrome (Settings).
    func glassPanel(_ pal: Palette? = nil) -> some View {
        self.modifier(GlassPanel(pal: pal))
    }
}

// MARK: - Breathing Orb

// MARK: - Warm Custom Slider removed in favor of native Slider

// MARK: - VolumeBar (the instrument fader)

/// Gain-staging vocabulary — one glance tells you what kind of fader you're touching, the quiet
/// structural cue premium audio tools share. `.master` is the big fader (thicker, prouder),
/// `.channel` each per-layer volume, `.parameter` the slimmer Settings config lanes. Each carries
/// its idle + editing (grabbed) sizes; the control springs between them on grab.
enum VolumeBarStyle {
    case master, channel, parameter

    var track: (idle: CGFloat, editing: CGFloat) {
        switch self {
        case .master:    return (9, 12)
        case .channel:   return (6, 9)
        case .parameter: return (5, 7)
        }
    }
    var thumb: (idle: CGFloat, editing: CGFloat) {
        switch self {
        case .master:    return (18, 22)
        case .channel:   return (15, 19)
        case .parameter: return (13, 16)
        }
    }
}

// The most-touched control in the app (mixer rows, master, Settings stereo/EQ), so its feel sets
// the tone. Carved from darkness rather than painted on: an inset channel with a light-from-above
// top hairline, a warm cream thumb (not the old cold hard-white), and — the real prize — RELATIVE
// drag. The old code mapped absolute touch-x → value, so a 2am graze slammed a layer to full
// volume; now the value moves by the drag *delta* from the grab point (what every premium fader
// does), and drifting the finger vertically off the track scales the movement finer for one-handed
// trim in the dark. A pure tap changes nothing on the mixer — deliberate: it can't jolt the mix.
// Settings sliders opt into `tapToSet` (a tap jumps to that position), the expected feel on a
// config screen where the anti-jolt rationale doesn't apply.
struct VolumeBar: View {
    @Binding var value: Double
    let accent: Color
    var range: ClosedRange<Double> = 0...1
    /// Warm cream by default (Theme.text) so every slider loses the one cold hard-white element.
    var thumbColor: Color = Color(red: 0.95, green: 0.89, blue: 0.82)
    /// Gain-staging tier — sets the track/thumb sizes (see `VolumeBarStyle`).
    var style: VolumeBarStyle = .channel
    /// When true a tap (no drag) jumps the value to the tapped position. Off for the mixer (a
    /// graze must not jolt the bed); on for Settings, where tap-to-set is expected.
    var tapToSet: Bool = false
    var onEditingChanged: ((Bool) -> Void)? = nil
    @State private var editing = false
    /// Last drag translation, for incremental (relative) movement — see the gesture.
    @State private var lastX: CGFloat = 0
    /// Whether this gesture has moved past the tap threshold (gates tap-to-set on release).
    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let frac = min(max((value - range.lowerBound) / span, 0), 1)
            let trackH: CGFloat = editing ? style.track.editing : style.track.idle
            let thumbD: CGFloat = editing ? style.thumb.editing : style.thumb.idle
            let fill = max(trackH, min(w, w * CGFloat(frac)))
            ZStack(alignment: .leading) {
                // Carved channel: a dark inset with a darker top hairline (lit from above).
                Capsule().fill(Color.black.opacity(0.25)).frame(height: trackH)
                    .overlay(alignment: .top) {
                        Capsule().fill(Color.black.opacity(0.35)).frame(height: 0.5)
                    }
                Capsule().fill(accent.opacity(0.9)).frame(width: fill, height: trackH)
                // Warm thumb with a subtle top-lit gradient and a hairline accent ring.
                Circle()
                    .fill(RadialGradient(colors: [thumbColor, thumbColor.opacity(0.85)],
                                         center: .init(x: 0.5, y: 0.32),
                                         startRadius: 0, endRadius: thumbD * 0.62))
                    .frame(width: thumbD, height: thumbD)
                    .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: fill - thumbD / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .animation(.spring(response: 0.3, dampingFraction: 0.72), value: editing)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !editing {
                            editing = true
                            lastX = g.translation.width   // establish the grab origin
                            moved = false
                            onEditingChanged?(true)
                            return
                        }
                        if abs(g.translation.width) > 3 { moved = true }
                        let dx = g.translation.width - lastX
                        lastX = g.translation.width
                        guard dx != 0 else { return }   // pure vertical drift: no redundant write
                        // Fine-adjust: the farther the finger drifts above/below the track, the
                        // smaller each point of horizontal travel moves the value (DAW trim).
                        let center = geo.size.height / 2
                        let vDist = max(0, abs(g.location.y - center) - trackH / 2)
                        let fine = 1.0 / (1.0 + Double(vDist) / 30.0)
                        let dv = Double(dx / w) * span * fine
                        value = min(range.upperBound, max(range.lowerBound, value + dv))
                    }
                    .onEnded { g in
                        // Settings-only: a tap (no meaningful drag) jumps to the tapped position.
                        if tapToSet && !moved {
                            let f = Double(min(max(g.location.x / w, 0), 1))
                            value = range.lowerBound + f * span
                        }
                        editing = false
                        onEditingChanged?(false)
                    }
            )
        }
        .frame(height: 28)
        // Hand VoiceOver a standard adjustable slider — the real value stays the source of truth.
        .accessibilityRepresentation { Slider(value: $value, in: range) }
    }
}

/// Segmented chip selector (noise type, binaural preset). The selected chip used to be a solid
/// full-saturation accent fill — literally the brightest surface on the 2am screen. Inverted to an
/// *ember*: a dim accent-tint fill, accent text, and a top-lit gradient hairline — lit from within,
/// dimmer than before yet unmistakably more crafted. Selection slides on a spring (a
/// matchedGeometryEffect pill), honors Reduce Motion, and gives the same selection tick the timer
/// chips already fire.
struct ChipRow: View {
    let options: [String]
    let labels: [String: String]?
    @Binding var selection: String
    let palette: Palette
    @Namespace private var pill
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UI.sm) {
                ForEach(options, id: \.self) { key in
                    let isSel = selection == key
                    Button(action: {
                        if reduceMotion { selection = key }
                        else { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { selection = key } }
                        UISelectionFeedbackGenerator().selectionChanged()
                    }) {
                        Text((labels?[key] ?? key).capitalized)
                            .font(.system(.caption, design: .rounded).bold())
                            .padding(.horizontal, UI.lg).padding(.vertical, 10)
                            // Selected label is bright cream (legible over its own dim tint —
                            // accent-on-accent tint fell below AA); the lit gradient border + tint
                            // carry the ember look, the text just has to be readable at 2am.
                            .foregroundColor(isSel ? palette.text : palette.dim)
                            .background {
                                if isSel {
                                    Capsule().fill(palette.accent.opacity(0.18))
                                        .overlay(
                                            Capsule().strokeBorder(
                                                LinearGradient(colors: [palette.accent.opacity(0.7),
                                                                        palette.accent.opacity(0.15)],
                                                               startPoint: .top, endPoint: .bottom),
                                                lineWidth: 1))
                                        .matchedGeometryEffect(id: "chippill", in: pill)
                                } else {
                                    Capsule().fill(palette.text.opacity(0.08))
                                }
                            }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel(Text((labels?[key] ?? key)))
                    .accessibilityAddTraits(isSel ? .isSelected : [])
                }
            }
            .padding(.horizontal, UI.xs)
        }
    }
}
