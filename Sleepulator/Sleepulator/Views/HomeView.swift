import SwiftUI

struct HomeView: View {
    @ObservedObject var audio: AudioEngine
    @State private var showTimerActionSheet = false
    @State private var isPlayPressed = false
    @State private var showBreathing = false
    @AppStorage("bedtimeMode") private var bedtimeMode = false

    var body: some View {
        ZStack {
            if bedtimeMode {
                Color(red: 0.1, green: 0.08, blue: 0.05).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
            
            if !bedtimeMode {
                BreathingOrb()
            }
            
            VStack(spacing: 30) {
                // Header & Bedtime Toggle
                HStack {
                    Text("SLEEPULATOR")
                        .font(.title3.bold())
                        .foregroundColor(bedtimeMode ? Color(red: 0.54, green: 0.47, blue: 0.38) : Color(red: 0.9, green: 0.7, blue: 0.4))
                        .tracking(2)
                    
                    Spacer()
                    
                    Button(action: { bedtimeMode.toggle() }) {
                        HStack(spacing: 4) {
                            Image(systemName: bedtimeMode ? "sun.max.fill" : "moon.stars.fill")
                            Text(bedtimeMode ? "Wake" : "Bedtime")
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(bedtimeMode ? Color.black : Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.1))
                        .foregroundColor(bedtimeMode ? Color(red: 0.54, green: 0.47, blue: 0.38) : Color(red: 0.9, green: 0.7, blue: 0.4))
                        .cornerRadius(20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                
                // Resume Last Night
                if let lastMix = audio.lastMix, !audio.noiseOn, !audio.binauralOn, !audio.isPodPlaying {
                    Button(action: { audio.resumeMix(lastMix) }) {
                        HStack(spacing: 16) {
                            Circle()
                                .fill(Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.2))
                                .frame(width: 46, height: 46)
                                .overlay(Image(systemName: "play.fill").foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4)))
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("RESUME LAST NIGHT")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .tracking(1.5)
                                    .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                
                                Text("\(lastMix.noiseType.capitalized) + \(lastMix.binauralPreset.capitalized)")
                                    .font(.system(.headline, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .glassPanel()
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                    }
                }
                
                Spacer()
                
                // Giant Play/Pause button
                Button(action: {
                    if audio.isPodPlaying || audio.noiseOn || audio.binauralOn {
                        audio.stopAll()
                    } else {
                        audio.noiseOn = true
                        if !audio.podTitle.isEmpty && audio.podTitle != "No episode loaded" {
                            audio.togglePodcast()
                        }
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(Color(white: 0.1).opacity(0.8))
                            .frame(width: 160, height: 160)
                            .shadow(color: Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.3), radius: isPlayPressed ? 10 : 30)
                            .overlay(
                                Circle()
                                    .stroke(Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.5), lineWidth: 2)
                            )
                        
                        if audio.isDownloading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                .scaleEffect(2.0)
                        } else {
                            Image(systemName: (audio.isPodPlaying || audio.noiseOn || audio.binauralOn) ? "pause.fill" : "play.fill")
                                .font(.system(size: 70, weight: .light, design: .rounded))
                                .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                        }
                    }
                }
                .scaleEffect(isPlayPressed ? 0.95 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isPlayPressed)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in isPlayPressed = true }
                        .onEnded { _ in isPlayPressed = false }
                )
                
                HStack(spacing: 16) {
                    // Sleep Timer
                    if audio.timerRemaining > 0 {
                        if audio.timerRemaining <= 60 {
                            Button(action: { audio.bumpTimer() }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Still Awake? (+15m)")
                                        .font(.system(.headline, design: .rounded))
                                }
                                .foregroundColor(bedtimeMode ? Color(red: 0.9, green: 0.86, blue: 0.8) : .black)
                                .padding()
                                .background(bedtimeMode ? Color(red: 0.16, green: 0.13, blue: 0.08) : Color(red: 0.3, green: 0.3, blue: 0.9))
                                .cornerRadius(16)
                            }
                        } else {
                            Button(action: { audio.cancelTimer() }) {
                                HStack {
                                    Image(systemName: "moon.stars.fill")
                                    Text("Cancel (\(Int(audio.timerRemaining / 60))m)")
                                        .font(.system(.headline, design: .rounded))
                                }
                                .foregroundColor(.red.opacity(0.8))
                                .glassPanel()
                            }
                        }
                    } else {
                        Button(action: { showTimerActionSheet = true }) {
                            HStack {
                                Image(systemName: "moon.stars.fill")
                                Text("Sleep Timer")
                                    .font(.system(.headline, design: .rounded))
                            }
                            .foregroundColor(bedtimeMode ? Color(red: 0.54, green: 0.47, blue: 0.38) : Color(red: 0.9, green: 0.7, blue: 0.4))
                            .glassPanel()
                        }
                    }
                }
                
                // Breathing Mode Button
                Button(action: { showBreathing = true }) {
                    HStack {
                        Image(systemName: "wind")
                        Text("Breathing Exercise")
                            .font(.system(.headline, design: .rounded))
                    }
                    .foregroundColor(Color(red: 0.4, green: 0.8, blue: 0.9))
                    .glassPanel()
                }
                
                // Seek Controls (Only if podcast is playing)
                if audio.isPodPlaying {
                    HStack(spacing: 40) {
                        Button(action: { audio.seekPodcast(seconds: -15) }) {
                            Image(systemName: "gobackward.15")
                                .font(.title)
                                .foregroundColor(bedtimeMode ? Color(red: 0.54, green: 0.47, blue: 0.38) : Color(red: 0.9, green: 0.7, blue: 0.4))
                        }
                        Button(action: { audio.seekPodcast(seconds: 15) }) {
                            Image(systemName: "goforward.15")
                                .font(.title)
                                .foregroundColor(bedtimeMode ? Color(red: 0.54, green: 0.47, blue: 0.38) : Color(red: 0.9, green: 0.7, blue: 0.4))
                        }
                    }
                    .padding(.top, 10)
                }
                
                Spacer()
                
                // Mix Controls Panel
                VStack(spacing: 25) {
                    WarmMixerRow(icon: "waveform.path.ecg", title: audio.noiseType.capitalized, isOn: $audio.noiseOn, volume: $audio.noiseVolume)
                    WarmMixerRow(icon: "headphones", title: "Binaural (\(audio.binauralPreset.capitalized))", isOn: $audio.binauralOn, volume: $audio.binVolume)
                    WarmMixerRow(icon: "mic.fill", title: "Podcast", isOn: $audio.isPodPlaying, volume: $audio.podVolume, onToggle: { audio.togglePodcast() })
                }
                .glassPanel()
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
        .fullScreenCover(isPresented: $showBreathing) {
            BreathingView(isPresented: $showBreathing)
        }
        .actionSheet(isPresented: $showTimerActionSheet) {
            ActionSheet(title: Text("Sleep Timer"), message: Text("Fade out smoothly over..."), buttons: [
                .default(Text("15 Minutes")) { audio.startSleepTimer(minutes: 15) },
                .default(Text("30 Minutes")) { audio.startSleepTimer(minutes: 30) },
                .default(Text("60 Minutes")) { audio.startSleepTimer(minutes: 60) },
                .cancel()
            ])
        }
    }
}

struct WarmMixerRow: View {
    let icon: String
    let title: String
    @Binding var isOn: Bool
    @Binding var volume: Double
    var onToggle: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: icon)
                    .frame(width: 30)
                    .foregroundColor(isOn ? Color(red: 0.9, green: 0.7, blue: 0.4) : .gray)
                    .font(.system(size: 20))
                
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(isOn ? .white : .gray)
                
                Spacer()
                
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        if let action = onToggle { action() }
                        else { isOn = newValue }
                    }
                ))
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
            }
            
            WarmSlider(value: $volume, range: 0...1)
                .opacity(isOn ? 1.0 : 0.4)
        }
    }
}
