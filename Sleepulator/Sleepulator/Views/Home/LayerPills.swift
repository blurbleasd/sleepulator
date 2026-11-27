import SwiftUI

// The sounds playing, named under the hero — shared by Sleep and idle Focus.
//
// A quiet line, not pills: amber text on an amber capsule read as chips to tap, and they did
// nothing (critique 2026-11-07). The slot under the night line is news, not a control; the morning
// read-back fills it at rest in the same dim, unboxed style. The night line above keeps its
// chevron, so the one control here is still the one that looks like one.
struct LayerPills: View {
    let layers: [String]
    let pal: Palette

    var body: some View {
        Text(layers.joined(separator: "  ·  "))
            .font(.system(.footnote, design: .rounded).weight(.medium))
            .foregroundColor(pal.dim.opacity(0.85))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 30)
            // Capped like the morning line that shares this slot: past accessibility size 2 the
            // orb's stack outgrew a small phone.
            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
            // Read the row as one phrase ("Active sounds: rain, delta").
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(layers.isEmpty ? "" : "Active sounds: \(layers.joined(separator: ", "))")
    }
}
