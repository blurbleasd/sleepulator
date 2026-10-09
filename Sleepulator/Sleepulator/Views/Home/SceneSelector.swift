import SwiftUI

/// A minimal backdrop picker for the current mode — chips of the available scenes, the
/// selected one highlighted. Writes the per-mode @AppStorage key, which re-renders the home.
/// The "simple toggle" the screensaver spec calls for until there are enough scenes to want a
/// full grid picker.
struct SceneSelector: View {
    let mood: SceneMood
    @Binding var selectedId: String
    let pal: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backdrop")
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundColor(pal.text)
                .padding(.horizontal, 20)

            // Horizontally scrollable so the row holds any number of backdrops without
            // overflowing on a phone. Edge padding lives on the inner HStack so it bleeds
            // to the screen edges as it scrolls.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SceneRegistry.scenes(for: mood), id: \.id) { scene in
                        let on = scene.id == selectedId
                        Button {
                            selectedId = scene.id
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            // The same ember as every other single-select chip (ChipRow): cream
                            // label on a dim accent tint with a top-lit rim.
                            Text(scene.title)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .foregroundColor(on ? pal.text : pal.dim)
                                .background {
                                    if on {
                                        Capsule().fill(pal.accent.opacity(0.18))
                                            .overlay(Capsule().strokeBorder(
                                                LinearGradient(colors: [pal.accent.opacity(0.7), pal.accent.opacity(0.15)],
                                                               startPoint: .top, endPoint: .bottom),
                                                lineWidth: 1))
                                    } else {
                                        Capsule().fill(pal.text.opacity(0.08))
                                    }
                                }
                                // 44 pt tall to tap (the chip itself stays compact; was 29 pt).
                                .frame(minHeight: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(scene.title) backdrop")
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

