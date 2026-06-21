import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var audio: AudioEngine
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @AppStorage("autoNightDim") private var autoNightDim = true
    
    var pal: Palette { Palette(bedtime: bedtimeMode) }

    private var eqAmountLabel: String {
        switch audio.sleepEQIntensity {
        case ..<0.05: return "Off"
        case ..<0.8:  return "Light"
        case ..<1.3:  return "Medium"
        default:      return "Strong"
        }
    }
    

    
    var body: some View {
        NavigationView {
            ZStack {
                pal.bg.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Podcast Playback & Queue
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Podcast Queue")
                                .font(.title3.bold())
                                .foregroundColor(pal.text)
                            
                            Toggle("Auto-Play Next Episode", isOn: $audio.autoPlay)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)
                                
                            Toggle("Shuffle Queue", isOn: $audio.shuffleQueue)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Library & Storage Settings
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Library & Storage")
                                .font(.title3.bold())
                                .foregroundColor(pal.text)
                                .padding(.bottom, 4)
                            
                            Toggle("Delete Played Episodes", isOn: $audio.deleteOnCompletion)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)
                            Text("Automatically delete the downloaded file when an episode finishes playing.")
                                .font(.caption)
                                .foregroundColor(pal.dim)
                                .padding(.bottom, 8)
                            
                            Toggle("Hide Finished Episodes", isOn: $audio.hideFinishedEpisodes)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Sound
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Stereo Width")
                                    .font(.title3.bold())
                                    .foregroundColor(pal.text)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer()
                                Text(audio.stereoWidth < 0.05 ? "Mono" : "\(Int((audio.stereoWidth / 1.5) * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(pal.dim)
                                    .fixedSize()
                            }
                            VolumeBar(value: $audio.stereoWidth, accent: pal.accent, range: 0...1.5)
                                .accessibilityLabel("Stereo width")
                                .accessibilityValue(audio.stereoWidth < 0.05 ? "Mono" : "\(Int((audio.stereoWidth / 1.5) * 100)) percent")
                            Text("Lower keeps the bass centered on phone and laptop speakers; higher opens the noise up in headphones.")
                                .font(.caption)
                                .foregroundColor(pal.dim)
                        }
                        .glassPanel()
                        .padding(.horizontal)

                        // Sleep Safe Settings
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Playback Safety")
                                .font(.title3.bold())
                                .foregroundColor(pal.text)
                                
                            // Trailing-closure label so the long text wraps at large Dynamic Type
                            // sizes instead of truncating against the fixed-width switch.
                            Toggle(isOn: $audio.nightLimiter) {
                                Text(audio.limiterByMode ? "Night Limiter — following mode" : "Night Limiter — soften loud spikes")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)
                            .disabled(audio.limiterByMode)
                            .opacity(audio.limiterByMode ? 0.45 : 1)

                            Toggle(isOn: $audio.limiterByMode) {
                                Text("Limiter follows mode — on while sleeping, off while focusing")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)

                            Toggle(isOn: $audio.sleepEQ) {
                                Text("Sleep EQ — soften harsh highs & boomy lows")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)

                            if audio.sleepEQ {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Softening amount")
                                            .font(.subheadline)
                                            .foregroundColor(pal.text)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.7)
                                        Spacer()
                                        Text(eqAmountLabel)
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(pal.dim)
                                            .fixedSize()
                                    }
                                    VolumeBar(value: $audio.sleepEQIntensity, accent: pal.accent, range: 0...2)
                                        .accessibilityLabel("Sleep EQ softening amount")
                                        .accessibilityValue(eqAmountLabel)
                                }
                                .padding(.top, 4)
                            }
                            Text("Gentle tone shaping for voice clarity at low volume. Podcasts only.")
                                .font(.caption)
                                .foregroundColor(pal.dim)
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Display
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Display")
                                .font(.title3.bold())
                                .foregroundColor(pal.text)

                            Toggle(isOn: $autoNightDim) {
                                Text("Auto-dim at night")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)

                            Text("Once a sleep timer is running, the screen fades to black after a minute so it doesn't light the room. Tap to wake.")
                                .font(.caption)
                                .foregroundColor(pal.dim)
                        }
                        .glassPanel()
                        .padding(.horizontal)

                        // Advanced
                        DisclosureGroup("Advanced") {
                            VStack(spacing: 24) {
                                // Proxy Settings
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("Network Proxies")
                                        .font(.headline)
                                        .foregroundColor(pal.text)
                                        

                                    
                                    HStack(alignment: .bottom) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("Private RSS Feed Proxy URL")
                                                .foregroundColor(pal.dim)
                                                .font(.caption)
                                            // Palette-aware fill (the system RoundedBorder style glows on true-black bedtime).
                                            TextField("https://rss.proxy/...", text: $audio.feedProxyUrl)
                                                .autocapitalization(.none)
                                                .padding(10)
                                                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(bedtimeMode ? 0.06 : 0.1)))
                                                .foregroundColor(pal.text)
                                                .tint(pal.accent)
                                                .accessibilityLabel("Private RSS feed proxy URL")
                                        }
                                        Button(action: { audio.feedProxyUrl = AppConfig.feedProxyUrl }) {
                                            Image(systemName: "arrow.counterclockwise")
                                                .foregroundColor(pal.accent)
                                                .frame(minWidth: 44, minHeight: 44)
                                        }
                                        .accessibilityLabel("Reset proxy URL to default")
                                    }
                                }
                                
                                // Data Backup
                                VStack(alignment: .leading, spacing: 16) {
                                    Text("Backup & Restore")
                                        .font(.headline)
                                        .foregroundColor(pal.text)
                                        
                                    Text("Export your custom mixes, playlists, and settings to a JSON file.")
                                        .font(.caption)
                                        .foregroundColor(pal.dim)
                                        
                                    HStack {
                                        Button("Export Data") {
                                            exportData()
                                        }
                                        .padding()
                                        .background(pal.text.opacity(0.1))
                                        .foregroundColor(pal.accent)
                                        .cornerRadius(8)
                                        .frame(minWidth: 44, minHeight: 44)
                                        
                                        Button("Import Data") {
                                            isImporting = true
                                        }
                                        .padding()
                                        .background(pal.text.opacity(0.1))
                                        .foregroundColor(pal.accent)
                                        .cornerRadius(8)
                                        .frame(minWidth: 44, minHeight: 44)
                                    }
                                }
                            }
                            .padding(.top, 16)
                        }
                        .accentColor(pal.accent)
                        .glassPanel()
                        .padding(.horizontal)
                        
                        Spacer().frame(height: 80) // 80 is the miniPlayerInset
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Settings")
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
                    defer { selectedFile.stopAccessingSecurityScopedResource() }
                    let data = try Data(contentsOf: selectedFile)
                    guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else { return }

                    // These collections are file-backed (StorageManager), not UserDefaults.
                    let fileBacked = ["savedPlaylists": "mixes.json",
                                      "savedPodcasts": "library.json",
                                      "upNextQueue": "queue.json",
                                      "episodePositions": "positions.json"]

                    for (key, value) in dict {
                        if let file = fileBacked[key] {
                            if let encoded = try? JSONSerialization.data(withJSONObject: value, options: []) {
                                StorageManager.shared.writeRaw(encoded, to: file)
                            }
                        } else if key == "lastMix" {
                            // Stored as encoded Data in UserDefaults.
                            if let encoded = try? JSONSerialization.data(withJSONObject: value, options: []) {
                                UserDefaults.standard.set(encoded, forKey: key)
                            }
                        } else {
                            UserDefaults.standard.set(value, forKey: key)
                        }
                    }
                    alertTitle = "Restore Complete"
                    alertMessage = "Your data was imported. Restart Sleepulator to load your restored library and mixes."
                    showAlert = true
                }
            } catch {
                alertTitle = "Import Failed"
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: "sleepulator-backup") { result in
            switch result {
            case .success(let url):
                print("Exported to \(url)")
            case .failure(let error):
                alertTitle = "Export Failed"
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
        .alert(alertTitle, isPresented: $showAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }
    
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: JSONDocument?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    func exportData() {
        var backupDict: [String: Any] = [:]

        // Scalar settings live in UserDefaults.
        let scalarKeys = ["noiseVolume", "noiseType", "binVolume", "binauralPreset", "podVolume", "stereoWidth", "masterVolume", "autoPlay", "shuffleQueue", "deleteOnCompletion", "hideFinishedEpisodes", "feedProxyUrl", "nightLimiterEnabled", "sleepEQEnabled", "sleepEQIntensity", "limiterByMode"]
        for key in scalarKeys {
            if let val = UserDefaults.standard.object(forKey: key) {
                backupDict[key] = val
            }
        }
        // lastMix is stored as encoded Data in UserDefaults.
        if let data = UserDefaults.standard.data(forKey: "lastMix"),
           let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
            backupDict["lastMix"] = obj
        }

        // Mixes, library, queue, and positions were migrated off UserDefaults into
        // StorageManager files — pull their raw JSON so the backup is actually complete.
        let fileBacked = [("savedPlaylists", "mixes.json"),
                          ("savedPodcasts", "library.json"),
                          ("upNextQueue", "queue.json"),
                          ("episodePositions", "positions.json")]
        for (key, file) in fileBacked {
            if let data = StorageManager.shared.rawData(for: file),
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                backupDict[key] = obj
            }
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: backupDict, options: .prettyPrinted)
            exportDocument = JSONDocument(data: data)
            isExporting = true
        } catch {
            alertTitle = "Export Failed"
            alertMessage = error.localizedDescription
            showAlert = true
        }
    }
}

struct JSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.data = data
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: data)
    }
}
