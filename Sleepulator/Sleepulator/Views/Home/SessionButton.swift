import SwiftUI

/// The mode-aware bottom session control: a Sleep-timer countdown, or the Pomodoro toggle.
struct SessionButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    @ObservedObject var pomodoro: PomodoroService
    let focusMode: Bool
    let pal: Palette
    let onSleepTap: () -> Void

    private var spokenLabel: String {
        if focusMode {
            return pomodoro.isRunning
                ? "Stop focus session, \(Int(pomodoro.remaining / 60)) minutes left"
                : "Start focus session"
        }
        return sleepTimer.timerRemaining > 0
            ? "Sleep timer, \(Int(sleepTimer.timerRemaining / 60)) minutes left"
            : "Sleep timer"
    }

    var body: some View {
        Button(action: {
            if focusMode {
                if pomodoro.isRunning { pomodoro.stop() } else { pomodoro.start() }
            } else {
                onSleepTap()
            }
        }) {
            HStack(spacing: 6) {
                if focusMode {
                    Image(systemName: pomodoro.isRunning ? "stop.fill" : "bolt.fill")
                    Text(pomodoro.isRunning ? "\(Int(pomodoro.remaining / 60))m" : "Focus session")
                } else {
                    Image(systemName: "moon.zzz")
                    Text(sleepTimer.timerRemaining > 0 ? "\(Int(sleepTimer.timerRemaining / 60))m left" : "Sleep timer")
                }
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(pal.dim)
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .frame(minHeight: 44)
        // Spoken in words: "29m" reads as "29 meters".
        .accessibilityLabel(spokenLabel)
    }
}

