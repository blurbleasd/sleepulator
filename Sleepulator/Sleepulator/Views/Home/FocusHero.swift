import SwiftUI

// Focus hero — the play orb wrapped in a Pomodoro progress ring. The ring is a faint
// idle track until a session is running, then it depletes over the current phase so
// time-left is the focal element of the screen.
struct FocusHero: View {
    @ObservedObject var audio: AudioEngine
    // Observe the Pomodoro directly — a nested ObservableObject reached via `audio`
    // wouldn't re-render the ring each tick.
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette
    let tap: () -> Void

    var body: some View {
        ZStack {
            Circle()
                .stroke(pal.text.opacity(0.10), lineWidth: 6)
                .frame(width: 214, height: 214)

            if pomodoro.isRunning {
                Circle()
                    // remaining fraction = 1 − elapsed; the arc shrinks as the phase runs out.
                    .trim(from: 0, to: CGFloat(1 - pomodoro.progress))
                    .stroke(pal.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .frame(width: 214, height: 214)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: pomodoro.remaining)
            }

            OrbButton(audio: audio, pal: pal, tap: tap)
        }
        .accessibilityElement(children: .contain)
    }
}

// Focus session readout — replaces the generic status line in Focus mode. While a
// session runs it shows the phase, the live countdown, and progress through the set;
// idle, it falls back to the same "what's playing" line as Sleep.
struct FocusSessionReadout: View {
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette
    let idleStatus: String
    let layers: [String]

    private func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        VStack(spacing: 12) {
            if pomodoro.isRunning {
                Text(pomodoro.phase == .work ? "Focus" : (pomodoro.restIsLong ? "Long break" : "Break"))
                    .font(.caption.weight(.semibold))
                    .tracking(1.5)
                    .foregroundColor(pal.accent)

                Text(clock(pomodoro.remaining))
                    .font(.system(size: 40, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(pal.text)
                    .accessibilityLabel("\(clock(pomodoro.remaining)) remaining")

                CycleDots(pomodoro: pomodoro, pal: pal)

                // Skip the rest of the phase — end a break early / bail out of an interval.
                Button(action: {
                    pomodoro.skipPhase()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }) {
                    Label(pomodoro.phase == .work ? "End interval" : "Skip break",
                          systemImage: "forward.end")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(pal.accent)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            } else {
                Text(idleStatus)
                    .font(.system(.callout, design: .rounded).weight(.medium))
                    .foregroundColor(pal.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)

                if !layers.isEmpty {
                    LayerPills(layers: layers, pal: pal)
                }
            }
        }
    }
}

// The set-progress dots under the timer — one per work interval before a long break,
// filled as cycles complete.
struct CycleDots: View {
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette

    var body: some View {
        let n = max(1, pomodoro.cyclesBeforeLongBreak)
        let done = pomodoro.completedCycles % n
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ForEach(Array(0..<n), id: \.self) { i in
                    Circle()
                        .fill(i < done ? pal.accent : pal.text.opacity(0.18))
                        .frame(width: 7, height: 7)
                }
            }
            Text("Cycle \(min(done + 1, n)) of \(n)")
                .font(.caption2)
                .foregroundColor(pal.dim)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Cycle \(min(done + 1, n)) of \(n)")
    }
}

// MARK: - Timer-observing leaves
// These observe the timer services directly (not via `audio`), so their ~1/sec ticks re-render
// only the small leaf — not the whole HomeView. The services are no longer forwarded through
// AudioEngine (see AudioEngine.init), so reading them inline in HomeView.body would otherwise
// show frozen values.

