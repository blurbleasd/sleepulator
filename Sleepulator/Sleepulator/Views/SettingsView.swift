import SwiftUI
import UniformTypeIdentifiers
import os

struct SettingsView: View {
    /// Held unobserved (a plain `let`): used only for the Backup restore call. All reactive state is
    /// observed via the narrow children below, so unrelated engine publishes (podTitle, transport,
    /// chrome) no longer re-render SettingsView.
    let audio: AudioEngine
    /// Observed directly so the Auto-Play / Shuffle toggles still refresh after Phase 3 dropped
    /// the queueManager objectWillChange forward into AudioEngine.
    @ObservedObject var queue: PodcastQueueManager
    /// Comfort/playback settings (skip interval, stereo width, limiter, EQ, beat routing).
    @ObservedObject var settings: PlaybackSettings
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @AppStorage("autoNightDim") private var autoNightDim = true

    /// Scalar UserDefaults keys included in Backup/Restore. Single source of truth for both the
    /// export and the restore whitelist: restore writes nothing outside this set plus the
    /// file-backed collections below, so a malformed or hostile backup can't inject arbitrary
    /// defaults. Keep new persisted settings in sync here.
    private static let backupScalarKeys: [String] = [
        "noiseVolume", "noiseType", "binVolume", "binauralPreset", "podVolume", "stereoWidth",
        "masterVolume", "autoPlay", "shuffleQueue", "deleteOnCompletion", "hideFinishedEpisodes",
        "nightLimiterEnabled", "sleepEQEnabled", "sleepEQIntensity", "limiterByMode",
        "beatRouting", "skipInterval", "playbackSpeed", "focusMode", "sceneSleep", "sceneFocus",
        "bedtimeMode", "autoNightDim", "timerMinutes", "pomoWork", "pomoRest", "pomoLongRest",
        "pomoCycles"
    ]

    /// Backup keys that map to StorageManager files (not UserDefaults), with the Codable type each
    /// must decode into before restore will write it.
    private static let backupFileBacked: [String: String] = [
        "savedPlaylists": "mixes.json",
        "savedPodcasts": "library.json",
        "upNextQueue": "queue.json",
        "episodePositions": "positions.json"
    ]
    
    var pal: Palette { Palette(bedtime: bedtimeMode) }

    private var eqAmountLabel: String {
        switch settings.sleepEQIntensity {
        case ..<0.05: return "Off"
        case ..<0.8:  return "Light"
        case ..<1.3:  return "Medium"
        default:      return "Strong"
        }
    }
    

    
    var body: some View {
        NavigationStack {
            ZStack {
                pal.bg.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        
                        // Podcast Playback & Queue
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Podcast Queue")
                                .font(.title3.bold())
                                .foregroundColor(pal.text)
                            
                            Toggle("Auto-Play Next Episode", isOn: $queue.autoPlay)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)

                            Toggle("Shuffle Queue", isOn: $queue.shuffleQueue)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)

                            HStack {
                                Text("Skip Interval")
                                    .foregroundColor(pal.dim)
                                Spacer()
                                Menu {
                                    ForEach([10, 15, 30, 45], id: \.self) { secs in
                                        Button("\(secs) seconds") { settings.skipInterval = Double(secs) }
                                    }
                                } label: {
                                    Text("\(Int(settings.skipInterval))s")
                                        .font(.headline)
                                        .foregroundColor(pal.accent)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .frame(minHeight: 44)
                                        .background(pal.text.opacity(0.1))
                                        .clipShape(Capsule())
                                }
                                .accessibilityLabel("Skip interval")
                                .accessibilityValue("\(Int(settings.skipInterval)) seconds")
                            }
                        }
                        .glassPanel()
                        .padding(.horizontal)
                        
                        // Library & Storage Settings
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Library & Storage")
                                .font(.title3.bold())
                                .foregroundColor(pal.text)
                                .padding(.bottom, 4)
                            
                            Toggle("Delete Played Episodes", isOn: $queue.deleteOnCompletion)
                                .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                                .foregroundColor(pal.dim)
                            Text("Automatically delete the downloaded file when an episode finishes playing.")
                                .font(.caption)
                                .foregroundColor(pal.dim)
                                .padding(.bottom, 8)
                            
                            Toggle("Hide Finished Episodes", isOn: $queue.hideFinishedEpisodes)
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
                                Text(settings.stereoWidth < 0.05 ? "Mono" : "\(Int((settings.stereoWidth / 1.5) * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(pal.dim)
                                    .fixedSize()
                            }
                            VolumeBar(value: $settings.stereoWidth, accent: pal.accent, range: 0...1.5)
                                .accessibilityLabel("Stereo width")
                                .accessibilityValue(settings.stereoWidth < 0.05 ? "Mono" : "\(Int((settings.stereoWidth / 1.5) * 100)) percent")
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
                            Toggle(isOn: $settings.nightLimiter) {
                                Text(settings.limiterByMode ? "Night Limiter — following mode" : "Night Limiter — soften loud spikes")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)
                            .disabled(settings.limiterByMode)
                            .opacity(settings.limiterByMode ? 0.45 : 1)

                            Toggle(isOn: $settings.limiterByMode) {
                                Text("Limiter follows mode — on while sleeping, off while focusing")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)

                            Toggle(isOn: $settings.sleepEQ) {
                                Text("Sleep EQ — soften harsh highs & boomy lows")
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: pal.accent))
                            .foregroundColor(pal.dim)

                            if settings.sleepEQ {
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
                                    VolumeBar(value: $settings.sleepEQIntensity, accent: pal.accent, range: 0...2)
                                        .accessibilityLabel("Sleep EQ softening amount")
                                        .accessibilityValue(eqAmountLabel)
                                }
                                .padding(.top, 4)
                            }
                            Text("Gentle tone shaping for voice clarity at low volume. Podcasts only.")
                                .font(.caption)
                                .foregroundColor(pal.dim)

                            Divider().background(pal.dim.opacity(0.2))

                            // How the entrainment beats render. A true binaural beat needs per-ear
                            // isolation (headphones); on a speaker the two tones sum in the air and
                            // the beat vanishes — so render an isochronic (pulsed mono) tone there.
                            // Auto follows the current output route.
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Beats output")
                                    .font(.subheadline).foregroundColor(pal.text)
                                Picker("Beats output", selection: $settings.beatRouting) {
                                    Text("Auto").tag("auto")
                                    Text("Headphones").tag("headphones")
                                    Text("Speaker").tag("speaker")
                                }
                                .pickerStyle(.segmented)
                                Text(settings.beatRouting == "headphones" ? "Always true binaural (assumes headphones)."
                                   : settings.beatRouting == "speaker" ? "Always isochronic — a speaker-safe pulsed tone."
                                   : "Binaural with headphones, isochronic on the speaker.")
                                    .font(.caption).foregroundColor(pal.dim)
                            }
                            .padding(.top, 4)
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
            let selectedFile: URL
            do {
                guard let file = try result.get().first else { return }
                selectedFile = file
            } catch {
                alertTitle = "Import Failed"
                alertMessage = error.localizedDescription
                showAlert = true
                return
            }
            // Read + parse + validate + write off the main thread; a large backup would
            // otherwise freeze the UI. Return only the user-facing outcome, then apply the
            // in-process reload and surface the alert back on the main actor.
            Task {
                let outcome = await Self.performImport(url: selectedFile)
                if outcome.didRestore { audio.reloadAfterRestore() }
                alertTitle = outcome.title
                alertMessage = outcome.message
                showAlert = true
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .json, defaultFilename: "sleepulator-backup") { result in
            switch result {
            case .success(let url):
                Log.storage.info("Exported backup to \(url.lastPathComponent, privacy: .public)")
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
    
    /// Re-encode a backup section and confirm it decodes into the Codable type the target file
    /// expects. Returns the JSON bytes to write, or nil if the section is malformed/unexpected.
    private static func validatedFileData(key: String, value: Any) -> Data? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: []) else { return nil }
        let decoder = JSONDecoder()
        let valid: Bool
        switch key {
        case "savedPlaylists":   // current schema is [SoundPreset]; older backups are [SavedMix]
            valid = (try? decoder.decode([SoundPreset].self, from: data)) != nil
                 || (try? decoder.decode([SavedMix].self, from: data)) != nil
        case "savedPodcasts":
            valid = (try? decoder.decode([Podcast].self, from: data)) != nil
        case "upNextQueue":
            valid = (try? decoder.decode([Episode].self, from: data)) != nil
        case "episodePositions":
            valid = (try? decoder.decode([String: Double].self, from: data)) != nil
        default:
            valid = false
        }
        return valid ? data : nil
    }

    /// User-facing result of a backup import, produced off the main thread.
    private struct ImportOutcome {
        let title: String
        let message: String
        let didRestore: Bool
    }

    /// Read, parse, validate, and write a backup file on a background executor. Touches only
    /// UserDefaults / StorageManager (both safe off-main); returns the outcome for the caller
    /// to apply on the main actor.
    private static func performImport(url: URL) async -> ImportOutcome {
        await Task.detached(priority: .userInitiated) { () -> ImportOutcome in
            guard url.startAccessingSecurityScopedResource() else {
                return ImportOutcome(title: "Import Failed",
                                     message: "Couldn't access the selected file.",
                                     didRestore: false)
            }
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                guard let dict = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                    return ImportOutcome(title: "Import Failed",
                                         message: "That file isn't a valid Sleepulator backup.",
                                         didRestore: false)
                }

                let allowedScalars = Set(Self.backupScalarKeys)
                var restored = 0
                var skipped = 0

                for (key, value) in dict {
                    if let file = Self.backupFileBacked[key] {
                        // Only write a collection that actually decodes into its expected
                        // type — a malformed section is skipped, never written as garbage.
                        if let validated = Self.validatedFileData(key: key, value: value) {
                            StorageManager.shared.writeRaw(validated, to: file)
                            restored += 1
                        } else { skipped += 1 }
                    } else if key == "lastMix" {
                        if let encoded = try? JSONSerialization.data(withJSONObject: value, options: []),
                           (try? JSONDecoder().decode(SavedMix.self, from: encoded)) != nil {
                            UserDefaults.standard.set(encoded, forKey: key)
                            restored += 1
                        } else { skipped += 1 }
                    } else if allowedScalars.contains(key) {
                        UserDefaults.standard.set(value, forKey: key)
                        restored += 1
                    } else {
                        // Unknown key — never blind-write it into UserDefaults.
                        skipped += 1
                    }
                }

                let message = skipped > 0
                    ? "Imported \(restored) item(s); skipped \(skipped) unrecognized."
                    : "Your data was imported."
                return ImportOutcome(title: "Restore Complete", message: message, didRestore: true)
            } catch {
                return ImportOutcome(title: "Import Failed",
                                     message: error.localizedDescription,
                                     didRestore: false)
            }
        }.value
    }

    func exportData() {
        // Gather + serialize the backup off the main thread; only flip the @State that drives
        // the exporter/alert back on the main actor.
        Task {
            let result = await Self.buildExportDocument()
            switch result {
            case .success(let document):
                exportDocument = document
                isExporting = true
            case .failure(let error):
                alertTitle = "Export Failed"
                alertMessage = error.localizedDescription
                showAlert = true
            }
        }
    }

    private static func buildExportDocument() async -> Result<JSONDocument, Error> {
        await Task.detached(priority: .userInitiated) { () -> Result<JSONDocument, Error> in
            var backupDict: [String: Any] = [:]

            // Scalar settings live in UserDefaults.
            for key in Self.backupScalarKeys {
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
            for (key, file) in Self.backupFileBacked {
                if let data = StorageManager.shared.rawData(for: file),
                   let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                    backupDict[key] = obj
                }
            }

            do {
                let data = try JSONSerialization.data(withJSONObject: backupDict, options: .prettyPrinted)
                return .success(JSONDocument(data: data))
            } catch {
                return .failure(error)
            }
        }.value
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
