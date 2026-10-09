import SwiftUI

/// Focus's bottom session control: the Pomodoro toggle. (Sleep's timer lives on the orb's night
/// ring now, so this is Focus-only.)
struct SessionButton: View {
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette

    /// Whole minutes left, rounded up so the last minute reads "1", never "0".
    private var minutesLeft: Int { Int((pomodoro.remaining / 60).rounded(.up)) }

    var body: some View {
        Button(action: {
            if pomodoro.isRunning { pomodoro.stop() } else { pomodoro.start() }
        }) {
            HStack(spacing: 6) {
                Image(systemName: pomodoro.isRunning ? "stop.fill" : "bolt.fill")
                Text(pomodoro.isRunning ? "\(minutesLeft)m" : "Focus session")
            }
            .font(.subheadline.weight(.medium))
            .foregroundColor(pal.dim)
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .frame(minHeight: 44)
        // Spoken in words: "29m" reads as "29 meters".
        .accessibilityLabel(pomodoro.isRunning
                            ? "Stop focus session, \(minutesLeft) minutes left"
                            : "Start focus session")
    }
}
