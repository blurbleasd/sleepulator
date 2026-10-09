import SwiftUI

/// The half-asleep "+15m" bump, shown only in the last 2 minutes of a fixed-duration timer.
struct BumpTimerButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Visible only in the final 2 minutes of a fixed-duration timer — and never during the
    /// ambient tail, where bumpTimer() deliberately no-ops (the Live Activity hides its "+15m"
    /// for the same reason; a button that haptics-then-does-nothing is worse than none).
    /// Crosses once at the 120s mark and once on bump/tail/end, so animating on it can't fire
    /// on every 1 Hz tick.
    private var isVisible: Bool {
        sleepTimer.timerRemaining > 0 && sleepTimer.timerRemaining <= 120
            && !sleepTimer.isEndOfEpisode && !sleepTimer.inTail
    }

    var body: some View {
        Group {
            if isVisible {
                Button(action: {
                    sleepTimer.bumpTimer()
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill")
                        Text("Still awake? +15m").font(.subheadline.weight(.semibold))
                    }
                    // Ember, not a solid amber slab: it appears in the last two minutes, when the
                    // room is darkest. Cream on the tint still reads at a glance.
                    .foregroundColor(pal.text)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(pal.accent.opacity(0.22)))
                    .overlay(Capsule().strokeBorder(
                        LinearGradient(colors: [pal.accent.opacity(0.75), pal.accent.opacity(0.2)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
                }
                .frame(minHeight: 44)
                .accessibilityLabel("Still awake, add 15 minutes to the sleep timer")
                // Fade + scale in/out instead of popping (matches the episode-notes reveal style).
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isVisible)
    }
}

