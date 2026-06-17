import SwiftUI

/// Minimal UI for the spike — just enough to drive every engine feature so you
/// can sleep with it and judge the audio. Not the real design (the home IA we
/// agreed on comes later); this is a test harness.
struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    // Paste a direct audio URL (an .mp3 episode enclosure) to test podcast mixing.
    @State private var podURL = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Ambient — Brown noise") {
                    Toggle("Play", isOn: $audio.noiseOn)
                    HStack { Image(systemName: "speaker.wave.1"); Slider(value: $audio.noiseVolume) }
                }

                Section("Binaural (headphones)") {
                    Toggle("Play — Deep Sleep (Delta)", isOn: $audio.binauralOn)
                    HStack { Image(systemName: "speaker.wave.1"); Slider(value: $audio.binVolume) }
                }

                Section("Podcast") {
                    TextField("Direct audio URL (.mp3)…", text: $podURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    Button("Load") { audio.loadPodcast(podURL) }
                        .disabled(podURL.isEmpty)
                    Text(audio.podTitle).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button { audio.skip(-15) } label: { Image(systemName: "gobackward.15") }
                        Spacer()
                        Button { audio.togglePodcast() } label: {
                            Image(systemName: audio.isPodPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.largeTitle)
                        }
                        Spacer()
                        Button { audio.skip(15) } label: { Image(systemName: "goforward.15") }
                    }
                    .buttonStyle(.borderless)
                    HStack { Text("Mix"); Slider(value: $audio.podVolume) }
                }

                Section("Sleep timer") {
                    if audio.timerRemaining > 0 {
                        Text("Fading out — \(Int(audio.timerRemaining))s left")
                        Button("Cancel timer") { audio.cancelTimer() }
                    } else {
                        Button("Start 30-min timer") { audio.startSleepTimer(minutes: 30) }
                        Button("Start 2-min timer (quick test)") { audio.startSleepTimer(minutes: 2) }
                    }
                }

                Section {
                    Button("Stop everything", role: .destructive) { audio.stopAll() }
                }
            }
            .navigationTitle("Sleepulator Spike")
        }
    }
}

#Preview { ContentView() }
