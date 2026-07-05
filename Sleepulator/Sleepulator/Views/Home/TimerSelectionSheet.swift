import SwiftUI

struct TimerSelectionSheet: View {
    @ObservedObject var audio: AudioEngine
    @Binding var isPresented: Bool
    let pal: Palette
    @AppStorage("timerMinutes") private var timerMinutes = 30.0
    /// Ambient-only span appended after the podcast stops at expiry (0 = off). Read live by
    /// SleepTimerService, so changing it mid-timer still applies.
    @AppStorage("ambientTailMinutes") private var ambientTailMinutes = 0

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }

    var body: some View {
        VStack(spacing: 22) {
            Text("Sleep Timer")
                .font(.title2.bold())
                .foregroundColor(pal.text)

            Text("Fade out smoothly over…")
                .foregroundColor(pal.dim)

            // Presets now *select* a duration (they no longer fire-and-dismiss), so tapping one
            // and then nudging the slider is a single coherent flow ending in one Start button.
            HStack(spacing: 12) {
                ForEach([15, 30, 45, 60], id: \.self) { mins in
                    let selected = Int(timerMinutes) == mins
                    Button(action: {
                        timerMinutes = Double(mins)
                        UISelectionFeedbackGenerator().selectionChanged()
                    }) {
                        Text("\(mins)m")
                            .font(.headline)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(selected ? pal.accent.opacity(0.25) : Color(white: 0.15))
                            .foregroundColor(selected ? pal.accent : pal.text)
                            .cornerRadius(10)
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(selected ? pal.accent.opacity(0.7) : .clear, lineWidth: 1))
                    }
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }

            VStack(spacing: 8) {
                Text("\(Int(timerMinutes)) minutes")
                    .font(.headline)
                    .foregroundColor(pal.text)
                    .monospacedDigit()

                Slider(value: $timerMinutes, in: 5...120, step: 5)
                    .tint(pal.accent)
            }
            .padding(.horizontal, 40)

            // Ambient tail — only meaningful when a podcast is in the mix: at expiry (or the
            // episode's end) the podcast stops and the noise bed keeps fading for this span.
            if audio.hasLoadedEpisode {
                VStack(spacing: 8) {
                    Text("Then ambient only for…")
                        .font(.caption)
                        .foregroundColor(pal.dim)
                    HStack(spacing: 10) {
                        ForEach([0, 15, 30, 60], id: \.self) { mins in
                            let selected = ambientTailMinutes == mins
                            Button(action: {
                                ambientTailMinutes = mins
                                UISelectionFeedbackGenerator().selectionChanged()
                            }) {
                                Text(mins == 0 ? "Off" : "+\(mins)m")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(selected ? pal.accent.opacity(0.25) : Color(white: 0.15))
                                    .foregroundColor(selected ? pal.accent : pal.dim)
                                    .cornerRadius(9)
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
                    .background(pal.accent)
                    .cornerRadius(12)
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
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .frame(minHeight: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(pal.accent.opacity(0.6), lineWidth: 1))
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
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(pal.bg.ignoresSafeArea())
    }
}
