import SwiftUI

// Focus hero — the play orb wrapped in a Pomodoro progress ring. The ring is a faint idle track
// until a session is running, then it depletes over the current phase so time-left is the focal
// element of the screen.
//
// The arc depletes *continuously*, driven off the phase end-date via a `TimelineView` sampling
// `pomodoro.progress(at:)`, instead of the old 1 Hz `.trim` + `.animation(.linear)` that stepped
// once a second. A small lit cap rides the arc's leading edge — the one bright cue, appropriate to
// Focus's calm-*alert* mood (not the 2am sleep surface). The schedule is `paused` when the screen
// is backgrounded / low-luminance so the 30 Hz redraw can't run unseen (the restraint the orb and
// scenes share); when running-but-visible it always reflects true remaining time.
struct FocusHero: View {
    @ObservedObject var audio: AudioEngine
    // Observe the Pomodoro directly — a nested ObservableObject reached via `audio`
    // wouldn't re-render the ring each tick.
    @ObservedObject var pomodoro: PomodoroService
    let pal: Palette
    let tap: () -> Void
    /// True when the hero isn't visibly animating (backgrounded / low-luminance) — stop the ring's
    /// redraw and freeze the inner orb.
    var paused: Bool = false

    private static let ringSize: CGFloat = 214
    private static let lineWidth: CGFloat = 6
    /// The arc eases back in over this span at each phase boundary (grows from empty to full)
    /// instead of snapping in one frame — animated *within* the continuous model so it doesn't
    /// fight the TimelineView (an implicit `.animation` on the per-frame trim would be clobbered).
    private static let refillDuration: TimeInterval = 0.5

    var body: some View {
        ZStack {
            // Idle track — the lit arc dominates it when running, and at idle it's the only cue
            // that this orb carries a timer ring, so keep it perceptible.
            Circle()
                .stroke(pal.text.opacity(0.10), lineWidth: Self.lineWidth)
                .frame(width: Self.ringSize, height: Self.ringSize)

            if pomodoro.isRunning {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
                    ring(progress: pomodoro.progress(at: tl.date),
                         phaseElapsed: pomodoro.phaseElapsed(at: tl.date))
                }
            }

            OrbButton(audio: audio, pal: pal, tap: tap, paused: paused)
        }
        .accessibilityElement(children: .contain)
    }

    /// The depleting arc + its lit leading cap at a given elapsed `progress` (0…1). `phaseElapsed`
    /// drives the boundary refill: for the first `refillDuration` of a phase the arc grows from 0
    /// up to its true length (smoothstep-eased), then tracks depletion normally.
    @ViewBuilder
    private func ring(progress: Double, phaseElapsed: TimeInterval) -> some View {
        let trueFrac = 1 - progress                  // remaining fraction = arc length
        // Refill envelope: 0→1 over the first refillDuration, smoothstep-shaped, then pinned at 1.
        let x = min(1.0, phaseElapsed / Self.refillDuration)
        let refill = x * x * (3 - 2 * x)
        let frac = trueFrac * refill
        let size = Self.ringSize
        let r = (size - Self.lineWidth) / 2          // stroke centerline radius
        // Leading tip: `frac` of the way clockwise from 12 o'clock (the arc's shrinking end).
        let theta = frac * 2 * .pi
        ZStack {
            Circle()
                .trim(from: 0, to: CGFloat(frac))
                .stroke(pal.accent, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // A small lit cap on the leading edge — the Apple-Watch-ring cue. Shows only while
            // there's an arc to cap (hidden as the phase empties, so it doesn't sit alone at top).
            if frac > 0.01 {
                Circle()
                    .fill(pal.accent)
                    .frame(width: Self.lineWidth + 2, height: Self.lineWidth + 2)
                    .shadow(color: pal.accent.opacity(0.6), radius: 4)
                    .offset(x: r * sin(theta), y: -r * cos(theta))
            }
        }
        .frame(width: size, height: size)
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

