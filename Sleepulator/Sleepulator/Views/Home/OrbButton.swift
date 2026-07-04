import SwiftUI

// The central play orb — the single focal control of the ambient-minimal home. A soft
// breathing glow (ambient, runs even under Reduce Motion) + a clean dark disc.
struct OrbButton: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    let tap: () -> Void
    @State private var pulse = false
    @State private var pressed = false

    var body: some View {
        Button(action: {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            tap()
        }) {
            ZStack {
                Circle().fill(pal.accent.opacity(0.09))
                    .frame(width: 200, height: 200)
                    .blur(radius: 32)
                    .scaleEffect(pulse ? 1.06 : 0.92)
                    .opacity(audio.isAnythingPlaying ? 0.5 : 0.22)
                Circle().fill(Color(white: 0.09).opacity(0.85))
                    .frame(width: 132, height: 132)
                    .overlay(Circle().stroke(pal.accent.opacity(0.35), lineWidth: 1))
                Image(systemName: audio.isAnythingPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 46, weight: .medium, design: .rounded))
                    .foregroundColor(pal.accent)
            }
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.96 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.9), value: pressed)
        .simultaneousGesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in pressed = true }
            .onEnded { _ in pressed = false })
        .onAppear {
            withAnimation(.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(audio.isAnythingPlaying ? "Pause all audio" : "Play")
    }
}

