import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var audio: AudioEngine
    
    let noiseOptions = ["brown", "pink", "white", "green", "fan", "rain", "ocean", "forest"]
    let binauralOptions = ["delta", "theta", "alpha", "gamma"]
    let speedOptions = [0.8, 1.0, 1.2, 1.5, 2.0]
    
    var body: some View {
        NavigationView {
            ZStack {
                Color.black.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Ambient Generator
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Ambient Generator")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                            
                            HStack {
                                Text("Noise Environment")
                                    .foregroundColor(.gray)
                                Spacer()
                                Picker("Noise Environment", selection: $audio.noiseType) {
                                    ForEach(noiseOptions, id: \.self) { option in
                                        Text(option.capitalized).tag(option)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .accentColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Brainwave Entrainment
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Brainwave Entrainment")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                            
                            HStack {
                                Text("Binaural Preset")
                                    .foregroundColor(.gray)
                                Spacer()
                                Picker("Binaural Preset", selection: $audio.binauralPreset) {
                                    ForEach(binauralOptions, id: \.self) { option in
                                        Text(option.capitalized).tag(option)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .accentColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                            }
                            
                            Text("Delta (Deep Sleep), Theta (Light Sleep), Alpha (Relaxation), Gamma (Focus)")
                                .font(.system(.caption, design: .rounded))
                                .foregroundColor(.gray)
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Podcast Playback & Queue
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Podcast Queue")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                            
                            Toggle("Auto-Play Next Episode", isOn: $audio.autoPlay)
                                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                .foregroundColor(.gray)
                                
                            Toggle("Shuffle Queue", isOn: $audio.shuffleQueue)
                                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                .foregroundColor(.gray)
                            
                            HStack {
                                Text("Playback Speed")
                                    .foregroundColor(.gray)
                                Spacer()
                                Picker("Playback Speed", selection: $audio.playbackSpeed) {
                                    ForEach(speedOptions, id: \.self) { speed in
                                        Text("\(speed, specifier: "%.1f")x").tag(speed)
                                    }
                                }
                                .pickerStyle(MenuPickerStyle())
                                .accentColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Advanced Audio Mixer
                        VStack(alignment: .leading, spacing: 20) {
                            Text("Advanced Audio Mixer")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                            
                            Toggle("Auto-Duck Ambient Noise", isOn: $audio.duckAmbient)
                                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                .foregroundColor(.gray)
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Proxy & Sleep Safe Settings
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Network & Safety")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                                
                            Toggle("Sleep Safe Audio Limiter", isOn: $audio.sleepSafeAudio)
                                .toggleStyle(SwitchToggleStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                .foregroundColor(.gray)
                                
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sleep Safe Proxy URL")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                                TextField("https://proxy.server/...", text: $audio.audioProxyUrl)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Private RSS Feed Proxy URL")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                                TextField("https://rss.proxy/...", text: $audio.feedProxyUrl)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .autocapitalization(.none)
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Data Backup
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Backup & Restore")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                                
                            Text("Export your custom mixes, playlists, and settings to a JSON file.")
                                .font(.caption)
                                .foregroundColor(.gray)
                                
                            HStack {
                                Button("Export Data") {
                                    exportData()
                                }
                                .padding()
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                .cornerRadius(8)
                                
                                Button("Import Data") {
                                    isImporting = true
                                }
                                .padding()
                                .background(Color.white.opacity(0.1))
                                .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                .cornerRadius(8)
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Engine Status
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Audio Engine Status")
                                .font(.system(.title3, design: .rounded).bold())
                                .foregroundColor(.white)
                            
                            HStack {
                                Circle()
                                    .fill((audio.isPodPlaying || audio.noiseOn || audio.binauralOn) ? Color(red: 0.9, green: 0.7, blue: 0.4) : Color.gray)
                                    .frame(width: 8, height: 8)
                                Text("AVAudioEngine Running")
                                    .foregroundColor(.gray)
                                Spacer()
                            }
                            
                            if audio.isDownloading {
                                HStack {
                                    ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color(red: 0.9, green: 0.7, blue: 0.4)))
                                        .scaleEffect(0.8)
                                    Text("Downloading episode...")
                                        .foregroundColor(Color(red: 0.9, green: 0.7, blue: 0.4))
                                }
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        Spacer().frame(height: 100)
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Mixer Settings")
            .navigationBarTitleDisplayMode(.large)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            do {
                guard let selectedFile: URL = try result.get().first else { return }
                if selectedFile.startAccessingSecurityScopedResource() {
                    let data = try Data(contentsOf: selectedFile)
                    if let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        for (key, value) in dict {
                            UserDefaults.standard.set(value, forKey: key)
                        }
                    }
                    selectedFile.stopAccessingSecurityScopedResource()
                }
            } catch {
                print("Import failed: \(error)")
            }
        }
        .sheet(isPresented: $isExporting) {
            if let url = exportedFileURL {
                ShareSheet(activityItems: [url])
            }
        }
    }
    
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportedFileURL: URL?
    
    func exportData() {
        let keys = ["noiseVolume", "noiseType", "noiseOn", "binVolume", "binauralPreset", "binauralOn", "podVolume", "autoPlay", "shuffleQueue", "duckAmbient", "feedProxyUrl", "audioProxyUrl", "sleepSafeAudio", "upNextQueue", "lastMix", "savedPlaylists", "savedPodcasts"]
        var backupDict: [String: Any] = [:]
        
        for key in keys {
            if let val = UserDefaults.standard.object(forKey: key) {
                backupDict[key] = val
            }
        }
        
        if let data = try? JSONSerialization.data(withJSONObject: backupDict, options: .prettyPrinted) {
            let tempUrl = FileManager.default.temporaryDirectory.appendingPathComponent("sleepulator-backup-\(Date().timeIntervalSince1970).json")
            try? data.write(to: tempUrl)
            exportedFileURL = tempUrl
            isExporting = true
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
