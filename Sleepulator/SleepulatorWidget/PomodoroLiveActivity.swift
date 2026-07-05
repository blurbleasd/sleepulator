import ActivityKit
import WidgetKit
import SwiftUI

// Lock-screen + Dynamic Island presentation for the Focus Pomodoro. Presentation only —
// PomodoroService drives start/update/end, and updates land only at phase boundaries
// (the countdown ticks itself from `endDate`). Gold accent mirrored per the file-local
// convention in SleepTimerLiveActivity.

private let pomoGold = Color(red: 0.91, green: 0.63, blue: 0.30)

struct PomodoroLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomodoroAttributes.self) { context in
            PomodoroLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(pomoGold)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(phaseTitle(context.state), systemImage: context.state.isWork ? "bolt.fill" : "cup.and.saucer.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(pomoGold)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    PomodoroCountdown(state: context.state)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Cycle \(context.state.cycle) of \(context.state.totalCycles)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: context.state.isWork ? "bolt.fill" : "cup.and.saucer.fill")
                    .foregroundStyle(pomoGold)
            } compactTrailing: {
                PomodoroCountdown(state: context.state)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white)
                    .frame(maxWidth: 56)
            } minimal: {
                Image(systemName: context.state.isWork ? "bolt.fill" : "cup.and.saucer.fill")
                    .foregroundStyle(pomoGold)
            }
            .keylineTint(pomoGold)
        }
    }
}

private func phaseTitle(_ state: PomodoroAttributes.ContentState) -> String {
    state.isWork ? "Focus" : (state.isLongBreak ? "Long break" : "Break")
}

private struct PomodoroLockScreenView: View {
    let state: PomodoroAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.isWork ? "bolt.fill" : "cup.and.saucer.fill")
                .font(.title2)
                .foregroundStyle(pomoGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(phaseTitle(state))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Cycle \(state.cycle) of \(state.totalCycles)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            Spacer()
            PomodoroCountdown(state: state)
                .font(.system(.title, design: .rounded).monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding()
    }
}

/// Self-ticking countdown off `endDate`; static 0:00 fallback at the boundary.
private struct PomodoroCountdown: View {
    let state: PomodoroAttributes.ContentState

    var body: some View {
        if let end = state.endDate, end > Date() {
            Text(timerInterval: Date()...end, countsDown: true, showsHours: false)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        } else {
            Text("0:00")
        }
    }
}
