import SwiftUI

/// The half-asleep "+15m" bump, shown only in the last 2 minutes of a fixed-duration timer.
struct BumpTimerButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette

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
                    .foregroundColor(pal.bg)
                    .padding(.horizontal, 18).padding(.vertical, 11)
                    .background(Capsule().fill(pal.accent))
                }
                .frame(minHeight: 44)
                .accessibilityLabel("Still awake, add 15 minutes to the sleep timer")
                // Fade + scale in/out instead of popping (matches the episode-notes reveal style).
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isVisible)
    }
}

