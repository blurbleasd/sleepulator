import SwiftUI

struct TimerSelectionSheet: View {
    @ObservedObject var audio: AudioEngine
    @Binding var isPresented: Bool
    let pal: Palette
    @AppStorage("timerMinutes") private var timerMinutes = 30.0
    /// Ambient-only span appended after the podcast stops at expiry (0 = off). Read live by
    /// SleepTimerService, so changing it mid-timer still applies.
    @AppStorage("ambientTailMinutes") private var ambientTailMinutes = 0
    /// Hero number size — @ScaledMetric so it grows with Dynamic Type instead of a fixed 44pt.
    @ScaledMetric private var heroSize: CGFloat = 44

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }

    var body: some View {
        VStack(spacing: UI.xl) {
            Text("Sleep Timer")
                .font(.title2.bold())
                .foregroundColor(pal.text)

            // One confident value — the slider and the presets both drive this number. Replaces a
            // "Fade out smoothly over…" caption *and* a separate "N minutes" line saying it twice.
            HStack(alignment: .firstTextBaseline, spacing: UI.xs) {
                Text("\(Int(timerMinutes))")
                    .font(.system(size: heroSize, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(pal.text)
                    .contentTransition(.numericText())
                Text("min")
                    .font(.system(.title3, design: .rounded))
                    .foregroundColor(pal.dim)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Int(timerMinutes)) minutes")

            // Presets *select* a duration (they no longer fire-and-dismiss); nudging the slider
            // after is one coherent flow ending in a single Start button.
            HStack(spacing: UI.md) {
                ForEach([15, 30, 45, 60], id: \.self) { mins in
                    let selected = Int(timerMinutes) == mins
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { timerMinutes = Double(mins) }
                        UISelectionFeedbackGenerator().selectionChanged()
                    }) {
                        Text("\(mins)m")
                            .font(.headline)
                            .padding(.horizontal, UI.lg)
                            .padding(.vertical, 10)
                            .foregroundColor(selected ? pal.text : pal.dim)
                            .background(Capsule().fill(selected ? pal.accent.opacity(0.18) : pal.text.opacity(0.06)))
                            .overlay {
                                // Selected: lit gradient border. Unselected: a faint hairline so the
                                // chip still reads as a tappable button on a dimmed screen (the 6%
                                // fill alone was near-invisible).
                                Capsule().strokeBorder(
                                    selected
                                        ? LinearGradient(colors: [pal.accent.opacity(0.7), pal.accent.opacity(0.15)],
                                                         startPoint: .top, endPoint: .bottom)
                                        : LinearGradient(colors: [pal.text.opacity(0.12), pal.text.opacity(0.12)],
                                                         startPoint: .top, endPoint: .bottom),
                                    lineWidth: selected ? 1 : 0.5)
                            }
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }

            Slider(value: $timerMinutes, in: 5...120, step: 5)
                .tint(pal.accent)
                .padding(.horizontal, 40)

            // Ambient tail — only meaningful when a podcast is in the mix: at expiry (or the
            // episode's end) the podcast stops and the noise bed keeps fading for this span.
            if audio.hasLoadedEpisode {
                VStack(spacing: 8) {
                    Text("Then ambient only for…")
                        .font(.caption)
                        .foregroundColor(pal.dim)
                    HStack(spacing: UI.sm) {
                        ForEach([0, 15, 30, 60], id: \.self) { mins in
                            let selected = ambientTailMinutes == mins
                            Button(action: {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { ambientTailMinutes = mins }
                                UISelectionFeedbackGenerator().selectionChanged()
                            }) {
                                Text(mins == 0 ? "Off" : "+\(mins)m")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, UI.md)
                                    .padding(.vertical, UI.sm)
                                    .foregroundColor(selected ? pal.text : pal.dim)
                                    .background(Capsule().fill(selected ? pal.accent.opacity(0.18) : pal.text.opacity(0.06)))
                                    .overlay {
                                        Capsule().strokeBorder(
                                            selected
                                                ? LinearGradient(colors: [pal.accent.opacity(0.7), pal.accent.opacity(0.15)],
                                                                 startPoint: .top, endPoint: .bottom)
                                                : LinearGradient(colors: [pal.text.opacity(0.12), pal.text.opacity(0.12)],
                                                                 startPoint: .top, endPoint: .bottom),
                                            lineWidth: selected ? 1 : 0.5)
                                    }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityLabel(mins == 0 ? "No ambient tail" : "Ambient continues \(mins) minutes after the podcast stops")
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }

            // Single commit for the duration timer.
            Button(action: {
                audio.sleepTimer.startSleepTimer(minutes: Int(timerMinutes))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isPresented = false
            }) {
                Text(timerActive ? "Restart Timer" : "Start Timer")
                    .font(.headline.bold())
                    .foregroundColor(pal.bg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding()
                    .background(Capsule().fill(pal.accent))
            }
            .padding(.horizontal, 40)

            // "End of episode" — only when a podcast with a known, finite length is loaded (so
            // the button can't silently no-op before the duration is known, or on a live stream).
            // A genuinely different timer kind, so it stays its own one-tap action.
            if audio.hasLoadedEpisode, audio.podcastDuration.isFinite, audio.podcastDuration > 5 {
                Button(action: {
                    audio.startEndOfEpisodeTimer()
                    isPresented = false
                }) {
                    Label("Stop at end of episode", systemImage: "text.append")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(pal.accent)
                        .padding(.horizontal, UI.xl)
                        .padding(.vertical, UI.md)
                        .frame(minHeight: 44)
                        .overlay(Capsule().strokeBorder(pal.accent.opacity(0.5), lineWidth: 1))
                }
            }

            // Cancel an already-running timer — previously there was no way out except starting a
            // new one. Only shown when a timer is actually counting down.
            if timerActive {
                Button(action: {
                    audio.sleepTimer.cancelTimer()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isPresented = false
                }) {
                    Label("Turn off timer", systemImage: "moon.zzz")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(pal.dim)
                        .frame(minHeight: 44)
                }
            }

            Spacer()
        }
        .padding(.top, UI.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg.ignoresSafeArea())
    }
}
