import SwiftUI

struct HomeView: View {
    @ObservedObject var audio: AudioEngine
    @State private var showTimerActionSheet = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Background pulsing gradient for aesthetic
            RadialGradient(gradient: Gradient(colors: [Color(red: 0.9, green: 0.6, blue: 0.3).opacity(0.15), .clear]), center: .top, startRadius: 10, endRadius: 500)
                .ignoresSafeArea()
            
            VStack(spacing: 30) {
                Spacer()
                
                // Giant Play/Pause button
                Button(action: {
                    if audio.isPodPlaying || audio.noiseOn || audio.binauralOn {
                        audio.stopAll()
                    } else {
                        // Play last mix or default
                        audio.noiseOn = true
                        if !audio.podTitle.isEmpty && audio.podTitle != "No episode loaded" {
                            audio.togglePodcast()
                        }
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(red: 0.1, green: 0.08, blue: 0.05))
                            .frame(width: 140, height: 140)
                            .shadow(color: Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.2), radius: 30)
                        
                        Image(systemName: (audio.isPodPlaying || audio.noiseOn || audio.binauralOn) ? "pause.fill" : "play.fill")
                            .font(.system(size: 60))
                            .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                    }
                }
                
                if audio.timerRemaining > 0 {
                    Text("Fading out — \(Int(audio.timerRemaining / 60))m \(Int(audio.timerRemaining) % 60)s left")
                        .font(.subheadline)
                        .foregroundColor(Color(white: 0.6))
                        .onTapGesture {
                            audio.cancelTimer()
                        }
                } else {
                    Button(action: { showTimerActionSheet = true }) {
                        HStack {
                            Image(systemName: "timer")
                            Text("Set Sleep Timer")
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 16)
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(20)
                        .foregroundColor(.white)
                    }
                }
                
                Spacer()
                
                // Mix Controls
                VStack(spacing: 20) {
                    MixerRow(icon: "waveform.path.ecg", title: "Brown Noise", isOn: $audio.noiseOn, volume: $audio.noiseVolume)
                    MixerRow(icon: "headphones", title: "Delta Waves", isOn: $audio.binauralOn, volume: $audio.binVolume)
                    MixerRow(icon: "mic.fill", title: "Podcast", isOn: $audio.isPodPlaying, volume: $audio.podVolume, disableToggle: true)
                }
                .padding()
                .background(Color.white.opacity(0.05))
                .cornerRadius(24)
                .padding(.horizontal)
            }
        }
        .actionSheet(isPresented: $showTimerActionSheet) {
            ActionSheet(title: Text("Sleep Timer"), message: Text("Fade out over..."), buttons: [
                .default(Text("15 Minutes")) { audio.startSleepTimer(minutes: 15) },
                .default(Text("30 Minutes")) { audio.startSleepTimer(minutes: 30) },
                .default(Text("60 Minutes")) { audio.startSleepTimer(minutes: 60) },
                .cancel()
            ])
        }
    }
}

struct MixerRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    @Binding var volume: Double
    var disableToggle: Bool = false
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .frame(width: 30)
                .foregroundColor(isOn ? Color(red: 0.9, green: 0.7, blue: 0.4) : .gray)
            
            Text(title)
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 100, alignment: .leading)
            
            if !disableToggle {
                Toggle("", isOn: $isOn).labelsHidden()
            } else {
                Spacer().frame(width: 50)
            }
            
            Slider(value: $volume, in: 0...1)
                .accentColor(Color(red: 0.9, green: 0.7, blue: 0.4))
        }
    }
}
