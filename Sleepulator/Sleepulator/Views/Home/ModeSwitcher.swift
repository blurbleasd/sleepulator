import SwiftUI

// Prominent two-segment Sleep | Focus selector. The active segment fills with the accent.
struct ModeSwitcher: View {
    @Binding var focusMode: Bool
    let pal: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "Sleep", icon: "moon.stars.fill", isActive: !focusMode) {
                if focusMode { setMode(false) }
            }
            segment(title: "Focus", icon: "bolt.fill", isActive: focusMode) {
                if !focusMode { setMode(true) }
            }
        }
        .padding(4)
        .background(Capsule().fill(pal.text.opacity(0.08)))
        .frame(maxWidth: .infinity)
    }

    private func setMode(_ focus: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        if reduceMotion { focusMode = focus }
        else { withAnimation(.easeInOut(duration: 0.2)) { focusMode = focus } }
    }

    private func segment(title: String, icon: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title).fontWeight(.semibold)
            }
            .font(.subheadline)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundColor(isActive ? pal.bg : pal.dim)
            .background(Capsule().fill(isActive ? pal.accent : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

