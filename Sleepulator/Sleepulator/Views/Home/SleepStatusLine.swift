import SwiftUI

/// The Sleep-mode status line. `base` (the layer/resume/"tap to begin" text) is computed by
/// HomeView and passed in; the live "· Nm" countdown is appended here from the observed timer.
struct SleepStatusLine: View {
    let base: String
    let showMinute: Bool
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette

    var body: some View {
        Text(showMinute && sleepTimer.timerRemaining > 0
             ? "\(base) · \(Int(sleepTimer.timerRemaining / 60))m"
             : base)
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundColor(pal.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
    }
}

/// The half-asleep "+15m" bump, shown only in the last 2 minutes of a fixed-duration timer.
struct BumpTimerButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette

    /// Visible only in the final 2 minutes of a fixed-duration timer. Crosses once at the 120s
    /// mark and once on bump/end, so animating on it can't fire on every 1 Hz tick.
    private var isVisible: Bool {
        sleepTimer.timerRemaining > 0 && sleepTimer.timerRemaining <= 120 && !sleepTimer.isEndOfEpisode
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

