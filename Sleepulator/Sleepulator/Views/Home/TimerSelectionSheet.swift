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

    /// All night is a choice in the sheet, not only a way to cancel: the ring's default, said so.
    static let allNight = "Plays until you stop it."

    /// One name (and glyph) for the end-of-episode timer wherever it's offered: this sheet and the
    /// Sleep player's chip.
    static let stopAfterEpisode = "Stop after this episode"
    static let stopAfterEpisodeSymbol = "text.append"
}

struct TimerSelectionSheet: View {
    @ObservedObject var audio: AudioEngine
    @Binding var isPresented: Bool
    let pal: Palette
    /// Begins the mix *and* the countdown when nothing is playing (`nil`: All night, no countdown).
    /// Home owns how a session begins (last mix, first-run bed, breathing on-ramp), so the sheet
    /// hands the choice back to it.
    let playAndStart: (_ minutes: Int?) -> Void
    @AppStorage("timerMinutes") private var timerMinutes = 30.0
    /// All night is selected. It opens selected when the ring is on All night, so the sheet agrees
    /// with Home's "… · All night" line that opened it. It used to open on its own stored 30 min,
    /// and its commit then set the ring to 30 for later nights too.
    @State private var allNight = false
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
        // Scrolls, top-aligned. At the .medium detent the sheet is often taller than the detent (a
        // podcast's tail row and episode button, a running timer's "Play all night", large text),
        // and the old centred VStack pushed the title up under the drag indicator. Dragging up
        // still grows the sheet to .large before the content scrolls.
        ScrollView {
            VStack(spacing: UI.xl) {
                Text("Sleep timer")
                    .font(.title2.bold())
                    .foregroundColor(pal.text)
                    .multilineTextAlignment(.center)
                    // Swipe-only before. The close every sheet has: it keeps nothing picked here,
                    // which only the commit below does (why it isn't a "Done"). The title keeps
                    // clear of it on both sides, so at large text it wraps, centred, under neither.
                    .padding(.horizontal, 44 + UI.md)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        SheetCloseButton(pal: pal) { isPresented = false }
                            .padding(.trailing, UI.md)
                    }

                // One confident value — the slider and the presets both drive this number. Replaces a
                // "Fade out smoothly over…" caption *and* a separate "N minutes" line saying it twice.
                HStack(alignment: .firstTextBaseline, spacing: UI.xs) {
                    if allNight {
                        Text("All night")
                            .font(.system(size: heroSize, weight: .semibold, design: .rounded))
                            .foregroundColor(pal.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    } else {
                        Text("\(Int(timerMinutes))")
                            .font(.system(size: heroSize, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundColor(pal.text)
                            .contentTransition(.numericText())
                        Text("min")
                            .font(.system(.title3, design: .rounded))
                            .foregroundColor(pal.dim)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(allNight ? "All night" : "\(Int(timerMinutes)) minutes")

                // What actually happens at the end, said once. The Live Activity already promised
                // "Audio fades out, then stops"; the sheet where you commit said nothing.
                // A tail only runs with a podcast loaded AND a sound bed on (SleepTimerService's
                // tailEligibleFn); say so only when it will.
                Text(allNight ? TimerCopy.allNight
                              : TimerCopy.consequence(minutes: Int(timerMinutes),
                                                      tailMinutes: audio.hasLoadedEpisode && (audio.noiseOn || audio.binauralOn)
                                                          ? ambientTailMinutes : 0))
                    .font(.footnote)
                    .foregroundColor(pal.dim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, UI.xxl)
                    .padding(.top, -UI.md)

                // Presets *select* a choice (they no longer fire-and-dismiss); nudging the slider
                // after is one coherent flow ending in a single commit. All night sits on its own
                // above the lengths: it's the other kind of choice, no countdown at all.
                VStack(spacing: UI.md) {
                    chip("All night", selected: allNight, accessibilityLabel: "All night, no timer") {
                        allNight = true
                    }
                    FoldingChipRow(values: [15, 30, 45, 60], spacing: UI.md) { mins in
                        chip("\(mins)m", selected: !allNight && Int(timerMinutes) == mins,
                             accessibilityLabel: "\(mins) minutes") {
                            timerMinutes = Double(mins)
                            allNight = false
                        }
                    }
                }

                // The app's own fader, not the system slider: iOS 26's pure-white thumb was the
                // brightest object on the 2am screen. Tap-to-set suits a settings-style length,
                // and the 5-minute detents tick under the finger. Dimmed under All night; moving
                // it picks a length again.
                VolumeBar(value: $timerMinutes, accent: pal.accent, range: 5...120, thumbColor: pal.text,
                          tapToSet: true, step: 5)
                    .padding(.horizontal, 40)
                    .opacity(allNight ? 0.4 : 1)
                    .accessibilityLabel("Timer length")
                    .accessibilityValue(allNight ? "Off, all night" : "\(Int(timerMinutes)) minutes")

                // Ambient tail — only meaningful when a podcast is in the mix: at expiry (or the
                // episode's end) the podcast stops and the noise bed keeps fading for this span.
                // All night has no expiry, so it isn't offered then.
                if audio.hasLoadedEpisode && !allNight {
                    VStack(spacing: 8) {
                        Text("Keep sounds going after the podcast stops")
                            .font(.caption)
                            .foregroundColor(pal.dim)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, UI.xxl)
                        FoldingChipRow(values: [0, 15, 30, 60], spacing: UI.sm) { mins in
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

                // Single commit. With nothing playing it starts the mix too: a countdown over
                // silence did nothing but arm the night veil over a quiet room. All night sets the
                // ring back to All night (the ring is the setting) and turns a running timer off;
                // it replaces the separate "Play all night" button that showed only mid-timer.
                Button(action: {
                    if allNight {
                        nightLength = 0
                        if timerActive { audio.sleepTimer.cancelTimer() }
                        if !playing { playAndStart(nil) }
                    } else {
                        let minutes = Int(timerMinutes)
                        nightLength = Double(minutes)
                        if playing { audio.sleepTimer.startSleepTimer(minutes: minutes) } else { playAndStart(minutes) }
                    }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    isPresented = false
                }) {
                    Text(SessionGuards.timerCommitTitle(playing: playing, timerActive: timerActive, allNight: allNight))
                        .font(.headline.bold())
                        .multilineTextAlignment(.center)
                        // Ember, like BumpTimerButton, not a solid amber slab (the brightest
                        // surface on the 2am screen). A step stronger than a selected chip's
                        // tint, and the only full-width fill here, so it still reads as the one
                        // commit.
                        .foregroundColor(pal.text)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding()
                        .background(Capsule().fill(pal.accent.opacity(0.22)))
                        .overlay(Capsule().strokeBorder(
                            LinearGradient(colors: [pal.accent.opacity(0.75), pal.accent.opacity(0.2)],
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 1))
                }
                .accessibilityHint(playing ? "" : allNight ? "Starts your mix with no timer" : "Starts your mix, then the timer")
                .padding(.horizontal, 40)

                // "End of episode" — only when a podcast with a known, finite length is loaded (so
                // the button can't silently no-op before the duration is known, or on a live stream).
                // A genuinely different timer kind, so it stays its own one-tap action.
                // Only while it plays: the end-of-episode timer ticks off the playback clock, so set
                // on a paused episode it replaced the night's timer with one that never ran out.
                if audio.hasLoadedEpisode, audio.isPodPlaying,
                   audio.podcastDuration.isFinite, audio.podcastDuration > 5 {
                    Button(action: {
                        audio.startEndOfEpisodeTimer()
                        isPresented = false
                    }) {
                        Label {
                            // Large text wraps it to two lines; centre the second under the first.
                            // Set on the Text itself: the Label's title ignores it from outside.
                            // One name for this action wherever it's offered (the player's chip too).
                            Text(TimerCopy.stopAfterEpisode).multilineTextAlignment(.center)
                        } icon: {
                            Image(systemName: TimerCopy.stopAfterEpisodeSymbol)
                        }
                            .font(.subheadline.weight(.semibold))
                            // Dim, not full accent: amber text read as bright as the cream commit
                            // above it. The accent hairline still marks it as a button.
                            .foregroundColor(pal.dim)
                            .padding(.horizontal, UI.xl)
                            .padding(.vertical, UI.md)
                            .frame(minHeight: 44)
                            .overlay(Capsule().strokeBorder(pal.accent.opacity(0.5), lineWidth: 1))
                    }
                }

            }
            .padding(.top, UI.xxl)
            .padding(.bottom, UI.lg)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // Open on what the ring shows: its length, or All night (0).
        .onAppear {
            if nightLength >= 5 { timerMinutes = nightLength }
            allNight = nightLength < 5
        }
        // Moving the slider picks a length.
        .onChange(of: timerMinutes) { _, _ in allNight = false }
        // Translucent sheet backdrop (see the presentationBackground at the call site) — the scene
        // drifts behind rather than a flat fill.
    }

    /// One chip style for both kinds of choice. Selected: a lit gradient border. Unselected: a
    /// faint hairline so the chip still reads as a button on a dimmed screen (the 6% fill alone
    /// was near-invisible).
    private func chip(_ title: String, selected: Bool, accessibilityLabel: String,
                      action: @escaping () -> Void) -> some View {
        Button(action: {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { action() }
            UISelectionFeedbackGenerator().selectionChanged()
        }) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, UI.lg)
                .padding(.vertical, 10)
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
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Four chips across, folding into two rows of two when they won't fit (large text truncated the
/// single row to "1…", "3…"). ViewThatFits keeps the one-row layout wherever it fits.
private struct FoldingChipRow<Chip: View>: View {
    let values: [Int]
    let spacing: CGFloat
    @ViewBuilder let chip: (Int) -> Chip

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { ForEach(values, id: \.self, content: chip) }
            VStack(spacing: spacing) {
                HStack(spacing: spacing) { ForEach(values.prefix(2), id: \.self, content: chip) }
                HStack(spacing: spacing) { ForEach(values.dropFirst(2), id: \.self, content: chip) }
            }
        }
    }
}
