import SwiftUI

// Two-segment Sleep | Focus selector. It only *requests* a switch: Home decides whether the switch
// needs a confirm first (a live sleep session or Pomodoro, see `SessionGuards`) and applies it.
struct ModeSwitcher: View {
    let focusMode: Bool
    let pal: Palette
    let onSelect: (_ focus: Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment(title: "Sleep", icon: "moon.stars.fill", isActive: !focusMode) {
                if focusMode { select(false) }
            }
            segment(title: "Focus", icon: "bolt.fill", isActive: focusMode) {
                if !focusMode { select(true) }
            }
        }
        .padding(4)
        .background(Capsule().fill(pal.text.opacity(0.08)))
        .frame(maxWidth: .infinity)
    }

    private func select(_ focus: Bool) {
        UISelectionFeedbackGenerator().selectionChanged()
        onSelect(focus)
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
            .padding(.vertical, 6)
            // 44pt tall segments: the old 10pt padding left a 37pt hit area at the top of the screen.
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(isActive ? pal.bg : pal.dim)
            .background(Capsule().fill(isActive ? pal.accent : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

