import SwiftUI

// Two-segment Sleep | Focus selector. It only *requests* a switch: Home decides whether the switch
// needs a confirm first (a live sleep session or Pomodoro, see `SessionGuards`) and applies it.
struct ModeSwitcher: View {
    let focusMode: Bool
    let pal: Palette
    /// A sleep session is live: the switch steps back (it's the last thing a half-asleep thumb
    /// should find) but stays usable, and a switch still asks first (SessionGuards).
    var quiet: Bool = false
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
        .opacity(quiet ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.6), value: quiet)
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
            // Ember, like the chips: a dim accent tint, cream label, top-lit hairline. The solid
            // amber fill was the brightest surface on the bedside Home, brighter than the orb.
            .foregroundColor(isActive ? pal.text : pal.dim)
            .background {
                if isActive {
                    Capsule().fill(pal.accent.opacity(0.18))
                        .overlay(Capsule().strokeBorder(
                            LinearGradient(colors: [pal.accent.opacity(0.7), pal.accent.opacity(0.15)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

