import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var audio: AudioEngine
    
    var body: some View {
        if audio.queue.first != nil || audio.podTitle != "No episode loaded" {
            HStack(spacing: 12) {
                // Play/Pause
                Button(action: {
                    audio.togglePodcast()
                }) {
                    Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                }
                
                // Title
                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.podTitle)
                        .font(.system(.subheadline, design: .rounded).bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(audio.isPodPlaying ? "Playing" : "Paused")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                
                Spacer()
                
                // Seek Backward
                Button(action: {
                    audio.seekPodcast(seconds: -15)
                }) {
                    Image(systemName: "gobackward.15")
                        .font(.title3)
                        .foregroundColor(.white)
                }
                
                // Seek Forward
                Button(action: {
                    audio.seekPodcast(seconds: 15)
                }) {
                    Image(systemName: "goforward.15")
                        .font(.title3)
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.1, opacity: 0.85))
                    .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: -5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.bottom, 50) // Elevate above tab bar
        }
    }
}
