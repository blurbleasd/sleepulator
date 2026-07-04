import SwiftUI

// The active-sound pills shown under the hero — shared by Sleep and idle Focus.
struct LayerPills: View {
    let layers: [String]
    let pal: Palette

    var body: some View {
        HStack(spacing: 8) {
            ForEach(layers, id: \.self) { layer in
                Text(layer)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(pal.accent.opacity(0.16)))
                    .foregroundColor(pal.accent)
            }
        }
        // Read the whole row as one phrase ("Active sounds: rain, delta") rather than letting
        // VoiceOver land on each pill separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(layers.isEmpty ? "" : "Active sounds: \(layers.joined(separator: ", "))")
    }
}

