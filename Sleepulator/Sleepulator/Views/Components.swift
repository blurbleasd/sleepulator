import SwiftUI

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
struct BreathingOrb: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    @State private var timer: Timer?
    var rmsPower: Double = 0.0
    var accent: Color = Theme.gold
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Circle()
                .fill(
                    RadialGradient(gradient: Gradient(colors: [
                        accent.opacity(reduceMotion ? 0.5 : opacity),
                        Color.clear
                    ]), center: .center, startRadius: 10, endRadius: 250)
                )
                // Calm breathing pulse only. No audio-reactive bump — a sleep backdrop
                // shouldn't brighten on loud moments (stimulating, not settling).
                // Reduce Motion: a fully static glow.
                .scaleEffect(reduceMotion ? 1.0 : scale)
                .frame(width: 400, height: 400)
                .blur(radius: 50)
                .onAppear { if !reduceMotion { start478Breathing() } }
                .onDisappear { timer?.invalidate() }
        }
    }
    
    func start478Breathing() {
        runCycle()
        timer = Timer.scheduledTimer(withTimeInterval: 19.0, repeats: true) { _ in
            runCycle()
        }
    }
    
    func runCycle() {
        // 4s Inhale
        withAnimation(.easeInOut(duration: 4.0)) {
            scale = 1.3
            opacity = 0.8
        }
        // 7s Hold
        // 8s Exhale
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            withAnimation(.easeInOut(duration: 8.0)) {
                scale = 1.0
                opacity = 0.5
            }
        }
    }
}

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
