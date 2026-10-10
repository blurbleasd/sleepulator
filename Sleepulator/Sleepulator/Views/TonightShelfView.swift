import SwiftUI

/// The top of the Podcasts library: pick up the episode you drifted off in, and the next one from
/// that show. Rows meant for a `List` section the caller titles ("Tonight" / "Continue"). A night
/// surface, so it follows the 2am rules: dimmed artwork in Sleep, ember buttons, no solid slabs.
struct TonightShelfView: View {
    let plan: TonightPlan
    let pal: Palette
    let focusMode: Bool
    /// The night ring's length in minutes (0 = All night).
    let nightMinutes: Double
    let onResume: () -> Void
    let onBackUp: () -> Void
    let onPlayNext: () -> Void

    /// Artwork is the brightest pixel block on the row; Sleep dims it the way NowPlayingSheet does.
    private var artOpacity: Double { focusMode ? 1 : 0.78 }

    var body: some View {
        Group {
            if let resume = plan.resume {
                resumeRow(resume)
                    .listRowBackground(pal.text.opacity(0.05))
            }
            if let next = plan.next {
                nextRow(next, afterResume: plan.resume != nil)
                    .listRowBackground(pal.text.opacity(0.05))
            }
        }
    }

    private func resumeRow(_ resume: TonightPlan.Resume) -> some View {
        VStack(alignment: .leading, spacing: UI.md) {
            HStack(alignment: .top, spacing: UI.md) {
                artwork(for: resume.episode, in: resume.podcast, size: 56)
                VStack(alignment: .leading, spacing: UI.xs) {
                    Text(resume.episode.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundColor(pal.text)
                        .lineLimit(2)
                    Text(resume.podcast.name)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(pal.dim)
                        .lineLimit(1)
                    if let left = PodcastText.timeLeft(resume.remaining) {
                        Text(left)
                            .font(.system(.footnote, design: .rounded))
                            .foregroundColor(pal.dim)
                    }
                    if let cue = PodcastText.nightCue(remaining: resume.remaining, nightMinutes: nightMinutes, focusMode: focusMode) {
                        HStack(alignment: .firstTextBaseline, spacing: UI.xs) {
                            Image(systemName: "moon")
                            Text(cue)
                        }
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(pal.accent)
                    }
                }
                .accessibilityElement(children: .combine)
            }

            // Side by side when they fit; stacked at large text sizes rather than clipped.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UI.sm) {
                    resumeButtons
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: UI.sm) {
                    resumeButtons
                }
            }
        }
        .padding(.vertical, UI.xs)
    }

    @ViewBuilder private var resumeButtons: some View {
        Button(action: onResume) {
            iconLabel("Resume", systemImage: "play.fill")
        }
        .buttonStyle(EmberButtonStyle(pal: pal))

        Button(action: onBackUp) {
            iconLabel("Back 5 min", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(EmberButtonStyle(pal: pal, quiet: true))
        .accessibilityLabel("Resume 5 minutes earlier")
    }

    private func iconLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: UI.sm) {
            Image(systemName: systemImage)
            Text(title)
        }
    }

    private func nextRow(_ next: TonightPlan.Next, afterResume: Bool) -> some View {
        // Under the resume card it's the same show, so the name would only repeat.
        let lead = afterResume ? "Up next" : "Next from \(next.podcast.name)"
        let length = PodcastText.duration(next.episode.duration).map { " · \($0)" } ?? ""
        return Button(action: onPlayNext) {
            HStack(spacing: UI.md) {
                artwork(for: next.episode, in: next.podcast, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(next.episode.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .foregroundColor(pal.text)
                        .lineLimit(2)
                    Text("\(lead)\(length)")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(pal.dim)
                        .lineLimit(1)
                }
                Spacer(minLength: UI.sm)
                Image(systemName: "play.circle")
                    .font(.title3)
                    .foregroundColor(pal.accent)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Plays this episode")
    }

    @ViewBuilder private func artwork(for episode: Episode, in podcast: Podcast, size: CGFloat) -> some View {
        Group {
            if let art = episode.artworkUrl ?? podcast.artworkUrl, let url = URL(string: art) {
                CachedAsyncImage(url: url, size: size, cornerRadius: 10)
            } else {
                Image(systemName: "moon.zzz")
                    .foregroundColor(pal.accent)
                    .frame(width: size, height: size)
                    .background(pal.text.opacity(0.1))
                    .cornerRadius(10)
            }
        }
        .opacity(artOpacity)
        .accessibilityHidden(true)
    }
}
