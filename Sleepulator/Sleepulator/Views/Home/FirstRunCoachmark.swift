import SwiftUI

// One-time first-run nudge: a soft card that tells a new user what makes the app different
// (layering) and points down at the "Build mix" control. Dismissed forever on "Got it" or once
// the user opens the mixer themselves.
//
// It must never cover the orb its copy says to tap, nor the Build mix row it points at. HomeView
// measures the room between the two (`CoachmarkLayout`) and proposes exactly that height; the
// card then shows the largest layout that fits — the full card on standard phones, a brief one on
// an SE-class screen or at large text sizes, and nothing at all if even the brief one can't fit.
struct FirstRunCoachmark: View {
    let pal: Palette
    let dismiss: () -> Void

    private static let title = "Layer your own soundscape"
    private static let message = "Tap the orb to start. Drag its ring to set how long it plays before fading out, and open Build mix to stack noise, binaural beats, and your own podcasts."
    /// The brief card's line. VoiceOver still hears `message` in full.
    private static let briefMessage = "Tap the orb to start; drag its ring to set how long."
    /// Text sizes the brief card steps down through, largest first, when it can't fit as-is.
    private static let textSizeCaps: [DynamicTypeSize] = [.xxxLarge, .xxLarge, .xLarge, .large]

    var body: some View {
        ViewThatFits(in: .vertical) {
            full(pointer: true)
            full(pointer: false)
            brief
            // Out of room at a large text size: the tip stops growing at the largest size that
            // still clears the orb, rather than covering it.
            ForEach(Self.textSizeCaps, id: \.self) { cap in
                brief.dynamicTypeSize(...cap)
            }
            // No room at all: show nothing. The orb and Build mix are labelled on their own, and
            // opening the mixer still retires the tip.
            Color.clear.frame(height: 0)
        }
    }

    /// Standard phones: the original card, with its pointer down at Build mix. A little short of
    /// room (e.g. a 6.1" 16e), it drops the pointer first — it still sits right on the row it names.
    private func full(pointer: Bool) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                icon
                titleText
                Spacer(minLength: 0)
            }
            messageText

            HStack {
                Spacer()
                gotIt
            }

            if pointer {
                // A small pointer toward the Build mix control below.
                Image(systemName: "chevron.compact.down")
                    .font(.title3)
                    .foregroundColor(pal.accent.opacity(0.6))
            }
        }
        .padding(UI.lg)
        .modifier(CoachmarkCard(pal: pal))
    }

    /// SE-class room: title and one short line beside "Got it".
    private var brief: some View {
        HStack(spacing: UI.md) {
            VStack(alignment: .leading, spacing: UI.xs) {
                titleText
                Text(Self.briefMessage)
                    .font(.caption)
                    .foregroundColor(pal.dim)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Self.message)
            }
            Spacer(minLength: 0)
            gotIt
        }
        .padding(UI.md)
        .modifier(CoachmarkCard(pal: pal, fill: CoachmarkCard.tightFill))
    }

    private var icon: some View {
        Image(systemName: "square.stack.3d.up.fill")
            .foregroundColor(pal.accent)
    }

    private var titleText: some View {
        Text(Self.title)
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .foregroundColor(pal.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var messageText: some View {
        Text(Self.message)
            .font(.caption)
            .foregroundColor(pal.dim)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var gotIt: some View {
        Button(action: dismiss) {
            Text("Got it")
                .font(.caption.weight(.bold))
                .foregroundColor(pal.bg)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(Capsule().fill(pal.accent))
        }
        .frame(minHeight: 36)
    }
}

/// The card surface every layout shares, so a tighter card still reads as the same tip.
private struct CoachmarkCard: ViewModifier {
    /// The brief card sits squarely over the status line and layer pills, which ghosted through
    /// the full card's 0.92 behind its copy at large text sizes — so it's near-opaque.
    static let tightFill = 0.97

    let pal: Palette
    var fill = 0.92

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                    .fill(pal.bg.opacity(fill))
                    .overlay(RoundedRectangle(cornerRadius: UI.cardRadius, style: .continuous)
                        .stroke(pal.accent.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
            )
            .accessibilityElement(children: .combine)
    }
}

/// Where the first-run coachmark may sit: below the orb's disc and above the Build mix row, with
/// a small gap to each. Pure, so the "never cover the orb or the row" rule is unit-tested.
enum CoachmarkLayout {
    /// Gap kept between the card and the orb's disc above it / the Build mix row below it.
    static let clearance = UI.sm

    /// The band the card may fill, in the coordinate space of `orb` and `mixRowTop`. `orb` is the
    /// OrbButton's frame — its soft glow overhangs the disc, and the card may cover glow but not
    /// disc. Zero height when the two are too close for any card.
    static func room(orb: CGRect, mixRowTop: CGFloat) -> (top: CGFloat, height: CGFloat) {
        let top = orb.midY + OrbButton.discDiameter / 2 + clearance
        return (top, max(0, mixRowTop - clearance - top))
    }
}

/// The two views the coachmark is placed between, collected as anchors up to HomeView's chrome
/// stack — they're siblings, so neither can measure the other directly.
enum CoachmarkAnchor: Hashable { case orb, mixRow }

struct CoachmarkAnchorKey: PreferenceKey {
    static var defaultValue: [CoachmarkAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [CoachmarkAnchor: Anchor<CGRect>],
                       nextValue: () -> [CoachmarkAnchor: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}
