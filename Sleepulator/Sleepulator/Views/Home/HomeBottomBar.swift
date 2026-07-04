import SwiftUI

// Master volume + mute, pinned to the bottom thumb zone (the control you reach for
// half-asleep in bed). Bedtime-aware fill so it doesn't glow on true black.
struct HomeBottomBar: View {
    @ObservedObject var audio: AudioEngine
    let pal: Palette
    @AppStorage("bedtimeMode") private var bedtimeMode = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { audio.toggleMute() }) {
                Image(systemName: audio.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .imageScale(.large)
                    // Muted reads through the struck-speaker glyph; a dimmed tone keeps the night
                    // UI calm (red carried a false "error/danger" charge for a benign state).
                    .foregroundColor(audio.isMuted ? pal.dim : pal.accent)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(audio.isMuted ? "Unmute" : "Mute")

            VolumeBar(value: $audio.masterVolume, accent: pal.accent)
                .accessibilityLabel("Master volume")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background {
            if bedtimeMode {
                Capsule().fill(Color.white.opacity(0.06))
            } else {
                Capsule().fill(.ultraThinMaterial).environment(\.colorScheme, .dark)
            }
        }
        .padding(.horizontal, 16)
    }
}

