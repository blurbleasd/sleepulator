import SwiftUI

/// The timer sheet's one line of consequence copy. Pure so the tests can pin it to the real fade
/// (AudioMath.getFadeMultiplier: the last 600 s; the ambient tail eases down from there).
enum TimerCopy {
    static func consequence(minutes: Int, tailMinutes: Int) -> String {
        // The whole bed fades with the timer, so in the tail the sounds are already very low:
        // "softly" is the honest word, not "ease out".
        if tailMinutes > 0 {
            return "The podcast stops at \(minutes) min. Your sounds carry on softly for \(tailMinutes) more."
        }
        return minutes > 10 ? "Fades out over the last 10 min, then stops." : "Fades out gently, then stops."
    }
}

/// The Sleep player's one line on how tonight ends for this episode (NowPlayingSheet's night
/// line): whether the timer cuts the story off, or the story ends first. Pure so the tests can pin
/// every case.
nonisolated enum NightLineCopy {
    /// - `timerRemaining`: seconds left on the sleep timer; 0 when none runs.
    /// - `endOfEpisode`: the timer follows this episode.
    /// - `inTail`: the podcast has stopped and the sounds are fading out.
    /// - `episodeRemaining`: wall-clock seconds to the episode's end (speed-scaled); nil when it
    ///   isn't known (a live stream, or before the player reports a length).
    /// - `tailMinutes`: the "keep sounds going" setting.
    static func line(timerRemaining: Double, endOfEpisode: Bool, inTail: Bool,
                     episodeRemaining: Double?, tailMinutes: Int) -> String {
        if inTail { return "Sounds fading · \(span(timerRemaining)) left" }
        guard timerRemaining > 0 else { return "Plays all night" }
        if endOfEpisode {
            let after = tailMinutes > 0 ? " · sounds go on \(tailMinutes) min" : ""
            return "Stops with this episode · in \(span(timerRemaining))" + after
        }
        guard let episode = episodeRemaining else { return "Timer ends in \(span(timerRemaining))" }
        let gap = episode - timerRemaining
        // Within a minute either way, they end together as far as anyone in bed can tell.
        if abs(gap) < 60 { return "Timer ends with this episode · in \(span(timerRemaining))" }
        if gap > 0 { return "Timer ends in \(span(timerRemaining)) · \(span(gap)) before this episode does" }
        return "This episode ends \(span(-gap)) before the timer"
    }

    /// "38 min", "1 hr 12 min", "2 hr". Rounded up: a countdown never claims less than is left.
    static func span(_ seconds: Double) -> String {
        let mins = max(1, Int((max(0, seconds) / 60).rounded(.up)))
        let h = mins / 60, m = mins % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }
}

struct TimerSelectionSheet: View {
    @ObservedObject var audio: AudioEngine
    @Binding var isPresented: Bool
    let pal: Palette
    /// Begins the mix *and* the countdown when nothing is playing. Home owns how a session begins
    /// (last mix, first-run bed, breathing on-ramp), so the sheet hands the minutes back to it.
    let playAndStart: (_ minutes: Int) -> Void
    @AppStorage("timerMinutes") private var timerMinutes = 30.0
    /// Ambient-only span appended after the podcast stops at expiry (0 = off). Read live by
    /// SleepTimerService, so changing it mid-timer still applies.
    @AppStorage("ambientTailMinutes") private var ambientTailMinutes = 0
    /// The Home night ring's length. Starting a timer here sets it; turning the timer off returns
    /// the ring to All night, so the ring and Play keep agreeing with what you last chose.
    @AppStorage("nightLengthMinutes") private var nightLength: Double = 0
    /// Hero number size — @ScaledMetric so it grows with Dynamic Type instead of a fixed 44pt.
    @ScaledMetric private var heroSize: CGFloat = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }
    private var playing: Bool { audio.isAnythingPlaying }

    var body: some View {
        VStack(spacing: UI.xl) {
            Text("Sleep timer")
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

            // What actually happens at the end, said once. The Live Activity already promised
            // "Audio fades out, then stops"; the sheet where you commit said nothing.
            // A tail only runs with a podcast loaded AND a sound bed on (SleepTimerService's
            // tailEligibleFn); say so only when it will.
            Text(TimerCopy.consequence(minutes: Int(timerMinutes),
                                       tailMinutes: audio.hasLoadedEpisode && (audio.noiseOn || audio.binauralOn)
                                           ? ambientTailMinutes : 0))
                .font(.footnote)
                .foregroundColor(pal.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, UI.xxl)
                .padding(.top, -UI.md)

            // Presets *select* a duration (they no longer fire-and-dismiss); nudging the slider
            // after is one coherent flow ending in a single Start button.
            HStack(spacing: UI.md) {
                ForEach([15, 30, 45, 60], id: \.self) { mins in
                    let selected = Int(timerMinutes) == mins
                    Button(action: {
                        withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { timerMinutes = Double(mins) }
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
                    .accessibilityLabel("\(mins) minutes")
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
                    Text("Keep sounds going after the podcast stops")
                        .font(.caption)
                        .foregroundColor(pal.dim)
                    HStack(spacing: UI.sm) {
                        ForEach([0, 15, 30, 60], id: \.self) { mins in
                            let selected = ambientTailMinutes == mins
                            Button(action: {
                                withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { ambientTailMinutes = mins }
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
                            .accessibilityLabel(mins == 0 ? "Stop sounds with the podcast" : "Sounds continue \(mins) minutes after the podcast stops")
                            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }

            // Single commit for the duration timer. With nothing playing it starts the mix too: a
            // countdown over silence did nothing but arm the night veil over a quiet room.
            Button(action: {
                let minutes = Int(timerMinutes)
                nightLength = Double(minutes)
                if playing { audio.sleepTimer.startSleepTimer(minutes: minutes) } else { playAndStart(minutes) }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                isPresented = false
            }) {
                Text(SessionGuards.timerCommitTitle(playing: playing, timerActive: timerActive))
                    .font(.headline.bold())
                    .foregroundColor(pal.bg)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .padding()
                    .background(Capsule().fill(pal.accent))
            }
            .accessibilityHint(playing ? "" : "Starts your mix, then the timer")
            .padding(.horizontal, 40)

            // "End of episode" — only when a podcast with a known, finite length is loaded (so
            // the button can't silently no-op before the duration is known, or on a live stream).
            // A genuinely different timer kind, so it stays its own one-tap action.
            if audio.hasLoadedEpisode, audio.podcastDuration.isFinite, audio.podcastDuration > 5 {
                Button(action: {
                    audio.startEndOfEpisodeTimer()
                    isPresented = false
                }) {
                    // One name for this action wherever it appears (the player's chip says it too).
                    Label("Stop after this episode", systemImage: "text.append")
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
                    nightLength = 0
                    audio.sleepTimer.cancelTimer()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    isPresented = false
                }) {
                    // Says what it does: it stops tonight's countdown AND sets the ring to All night,
                    // which Play then honours on later nights too (the ring is the setting).
                    Label("Play all night", systemImage: "moon.zzz")
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(pal.dim)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Turn off the timer and play all night")
                .accessibilityHint("The ring stays on All night until you set a length again")
            }

            Spacer()
        }
        .padding(.top, UI.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Open on the length the ring shows, when it has one.
        .onAppear { if nightLength >= 5 { timerMinutes = nightLength } }
        // Translucent sheet backdrop (see the presentationBackground at the call site) — the scene
        // drifts behind rather than a flat fill.
    }
}
