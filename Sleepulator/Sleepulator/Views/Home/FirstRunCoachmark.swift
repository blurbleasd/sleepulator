import SwiftUI

// One-time first-run nudge: a soft card that tells a new user what makes the app different
// (layering) and points down at the "Build mix" control. Dismissed forever on "Got it" or once
// the user opens the mixer themselves.
struct FirstRunCoachmark: View {
    let pal: Palette
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.fill")
                    .foregroundColor(pal.accent)
                Text("Layer your own soundscape")
                    .font(.system(.subheadline, design: .rounded).weight(.semibold))
                    .foregroundColor(pal.text)
                Spacer(minLength: 0)
            }
            Text("Tap the orb to start, then open Build mix to stack noise, binaural beats, and your own podcasts — with a sleep timer that fades it all out.")
                .font(.caption)
                .foregroundColor(pal.dim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button(action: dismiss) {
                    Text("Got it")
                        .font(.caption.weight(.bold))
                        .foregroundColor(pal.bg)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .background(Capsule().fill(pal.accent))
                }
                .frame(minHeight: 36)
            }

            // A small pointer toward the Build mix control below.
            Image(systemName: "chevron.compact.down")
                .font(.title3)
                .foregroundColor(pal.accent.opacity(0.6))
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(pal.bg.opacity(0.92))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(pal.accent.opacity(0.3), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        )
        .accessibilityElement(children: .combine)
    }
}

