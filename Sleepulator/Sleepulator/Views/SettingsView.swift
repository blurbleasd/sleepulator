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
    @AppStorage("autoNightDim") private var autoNightDim = true
    @AppStorage("breathingOnRamp") private var breathingOnRamp = false
    @AppStorage("ambientMotion") private var ambientMotion = true

    /// Scalar UserDefaults keys included in Backup/Restore. Single source of truth for both the
    /// export and the restore whitelist: restore writes nothing outside this set plus the
    /// file-backed collections below, so a malformed or hostile backup can't inject arbitrary
    /// defaults. Keep new persisted settings in sync here.
    // `nonisolated` so the off-main backup export/import (Task.detached) can read these without a
    // cross-actor hop — the View is @MainActor by default (SWIFT_DEFAULT_ACTOR_ISOLATION), which
    // would otherwise make this access an error under Swift 6 mode. Plain Sendable data.
    private nonisolated static let backupScalarKeys: [String] = [
        "noiseVolume", "noiseType", "binVolume", "binauralPreset", "podVolume", "stereoWidth",
        "masterVolume", "autoPlay", "shuffleQueue", "deleteOnCompletion", "hideFinishedEpisodes",
        "nightLimiterEnabled", "sleepEQEnabled", "sleepEQIntensity", "limiterByMode",
        "beatRouting", "skipInterval", "playbackSpeed", "focusMode", "sceneSleep", "sceneFocus",
        "bedtimeMode", "autoNightDim", "breathingOnRamp", "ambientMotion", "timerMinutes",
        "nightLengthMinutes", "ambientTailMinutes",
        "pomoWork", "pomoRest", "pomoLongRest", "pomoCycles"
    ]

    /// Backup keys that map to StorageManager files (not UserDefaults), with the Codable type each
    /// must decode into before restore will write it.
    private nonisolated static let backupFileBacked: [String: String] = [
        "savedPlaylists": "mixes.json",
        "savedPodcasts": "library.json",
        "upNextQueue": "queue.json",
        "episodePositions": "positions.json"
    ]
    
    /// Mode-aware like Home: Focus is cool everywhere, not just on Home. Read from the persisted
    /// "focusMode" key (AudioEngine writes it) so this view needn't observe the whole engine.
    @AppStorage("focusMode") private var focusMode = false
    var pal: Palette { Palette(focusMode: focusMode) }

    private var eqAmountLabel: String {
        switch settings.sleepEQIntensity {
        case ..<0.05: return "Off"
        case ..<0.8:  return "Light"
        case ..<1.3:  return "Medium"
        default:      return "Strong"
        }
    }
    

    
    /// UserDefaults-backed binding for the sleep-aware queue hold (read at advance time by
    /// AudioEngine, so no live plumbing is needed).
    private var holdQueueBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.bool(forKey: "holdQueueDuringSleepTimer") },
            set: { UserDefaults.standard.set($0, forKey: "holdQueueDuringSleepTimer") }
        )
    }

    // Pomodoro lengths: shown from the persisted keys, written through the service (its didSet
    // persists them, and it reads them at the start of each phase).
    @AppStorage("pomoWork") private var pomoWork = 25
    @AppStorage("pomoRest") private var pomoRest = 5
    @AppStorage("pomoLongRest") private var pomoLongRest = 15
    @AppStorage("pomoCycles") private var pomoCycles = 4

    private func pomodoroBinding(_ value: Int, _ write: @escaping (Int) -> Void) -> Binding<Int> {
        Binding(get: { value }, set: { write($0) })
    }

    /// One settings row: the label in the text tone (dim labels read as disabled), the value or
    /// control trailing.
    private func label(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(pal.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func header(_ title: String) -> some View {
        Text(title).foregroundStyle(pal.dim)
    }

    private func footer(_ text: String) -> some View {
        Text(text).foregroundStyle(pal.dim)
    }

    private func minutesStepper(_ title: String, value: Int, range: ClosedRange<Int>, step: Int,
                                write: @escaping (Int) -> Void) -> some View {
        Stepper(value: pomodoroBinding(value, write), in: range, step: step) {
            HStack {
                label(title)
                Spacer()
                Text("\(value) min").foregroundStyle(pal.dim).monospacedDigit()
            }
        }
        .accessibilityValue("\(value) minutes")
    }

    // Order is the app's: Sleep first (the bedside case), then Focus, then what both share, then
    // podcasts, then the rarely touched. It used to open on the podcast queue and storage, with
    // the sleep controls below the fold.
    var body: some View {
        NavigationStack {
            List {
                Group {
                    Section {
                        Toggle(isOn: $autoNightDim) { label("Darken the screen at night") }
                        Toggle(isOn: $breathingOnRamp) { label("Start with a minute of breathing") }
                    } header: {
                        header("Sleep")
                    } footer: {
                        footer("With a sleep timer running, the screen goes black a minute after your last touch; tap to wake. Breathing leads into your mix, then it starts on its own.")
                    }

                    Section {
                        Toggle(isOn: $settings.nightLimiter) {
                            label(settings.limiterByMode ? "Soften loud moments (follows the mode)" : "Soften loud moments")
                        }
                        .disabled(settings.limiterByMode)
                        Toggle(isOn: $settings.limiterByMode) { label("On while sleeping, off while focusing") }
                        Toggle(isOn: $settings.sleepEQ) { label("Soften harsh highs and boomy lows") }
                        if settings.sleepEQ {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    label("How much")
                                    Spacer()
                                    Text(eqAmountLabel).foregroundStyle(pal.dim)
                                }
                                VolumeBar(value: $settings.sleepEQIntensity, accent: pal.accent, range: 0...2, style: .parameter, tapToSet: true)
                                    .accessibilityLabel("Softening amount")
                                    .accessibilityValue(eqAmountLabel)
                            }
                            .padding(.vertical, 4)
                        }
                    } header: {
                        header("Podcasts at night")
                    } footer: {
                        footer("Keeps a sudden loud moment in a podcast from waking you, and gentles voices at low volume. Podcasts only; your sounds are already steady.")
                    }

                    Section {
                        minutesStepper("Focus", value: pomoWork, range: 5...90, step: 5) { audio.pomodoro.workMinutes = $0 }
                        minutesStepper("Short break", value: pomoRest, range: 1...30, step: 1) { audio.pomodoro.restMinutes = $0 }
                        minutesStepper("Long break", value: pomoLongRest, range: 5...60, step: 5) { audio.pomodoro.longRestMinutes = $0 }
                        Stepper(value: pomodoroBinding(pomoCycles) { audio.pomodoro.cyclesBeforeLongBreak = $0 }, in: 2...8) {
                            HStack {
                                label("Rounds before a long break")
                                Spacer()
                                Text("\(pomoCycles)").foregroundStyle(pal.dim).monospacedDigit()
                            }
                        }
                        .accessibilityValue("\(pomoCycles) rounds")
                    } header: {
                        header("Focus")
                    } footer: {
                        footer("Changes apply from the next round.")
                    }

                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                label("Stereo width")
                                Spacer()
                                Text(settings.stereoWidth < 0.05 ? "Mono" : "\(Int((settings.stereoWidth / 1.5) * 100))%")
                                    .foregroundStyle(pal.dim).monospacedDigit()
                            }
                            VolumeBar(value: $settings.stereoWidth, accent: pal.accent, range: 0...1.5, style: .parameter, tapToSet: true)
                                .accessibilityLabel("Stereo width")
                                .accessibilityValue(settings.stereoWidth < 0.05 ? "Mono" : "\(Int((settings.stereoWidth / 1.5) * 100)) percent")
                        }
                        .padding(.vertical, 4)
                        // A true binaural beat needs one tone per ear; on a speaker the two sum in the
                        // air and the beat vanishes, so a speaker gets a pulsed (isochronic) tone.
                        Picker(selection: $settings.beatRouting) {
                            Text("Auto").tag("auto")
                            Text("Headphones").tag("headphones")
                            Text("Speaker").tag("speaker")
                        } label: {
                            label("Beats for")
                        }
                    } header: {
                        header("Sound")
                    } footer: {
                        footer(settings.beatRouting == "headphones" ? "Beats made for headphones, one tone in each ear. Lower width keeps the bass centred on a phone speaker."
                               : settings.beatRouting == "speaker" ? "A gentle pulse that works on a speaker. Lower width keeps the bass centred on a phone speaker."
                               : "Headphone beats with headphones in, a speaker-friendly pulse without. Lower width keeps the bass centred on a phone speaker.")
                    }

                    Section {
                        Toggle(isOn: $ambientMotion) { label("Moving scenes") }
                    } header: {
                        header("Display")
                    } footer: {
                        footer("Off holds the backdrop on one still frame: calmer, and easier on the battery. The system's Reduce Motion already stops the tilt.")
                    }

                    Section {
                        Toggle(isOn: $queue.autoPlay) { label("Play the next episode automatically") }
                        Toggle(isOn: holdQueueBinding) { label("During a sleep timer, stop after this episode") }
                        Toggle(isOn: $queue.shuffleQueue) { label("Shuffle the queue") }
                        Picker(selection: Binding(get: { Int(settings.skipInterval) }, set: { settings.skipInterval = Double($0) })) {
                            ForEach([10, 15, 30, 45], id: \.self) { Text("\($0) seconds").tag($0) }
                        } label: {
                            label("Skip back and forward")
                        }
                        Toggle(isOn: $queue.deleteOnCompletion) { label("Delete downloads once played") }
                        Toggle(isOn: $queue.hideFinishedEpisodes) { label("Hide played episodes") }
                    } header: {
                        header("Podcasts")
                    } footer: {
                        footer("With a sleep timer running, the current episode finishes and only your sounds carry on, so you don't sleep through the next one.")
                    }

                    Section {
                        Button { exportData() } label: {
                            Label("Export a backup", systemImage: "square.and.arrow.up")
                        }
                        Button { isImporting = true } label: {
                            Label("Restore from a backup", systemImage: "square.and.arrow.down")
                        }
                    } header: {
                        header("Backup")
                    } footer: {
                        footer("Your mixes, podcasts, queue and settings, as one file.")
                    }

                    Section {
                        NavigationLink { DiagnosticsListView(pal: pal) } label: { label("Reports from iOS") }
                        Button {
                            Task {
                                let text = await LogExport.collect()
                                logDocument = TextDocument(text: text)
                                isExportingLog = true
                            }
                        } label: {
                            Label("Export last night's log", systemImage: "doc.text")
                        }
                    } header: {
                        header("Diagnostics")
                    } footer: {
                        // Build identity: the build time is the line that tells manual builds apart.
                        VStack(alignment: .leading, spacing: 6) {
                            footer("Battery, hang and crash reports iOS delivers about once a day. Stored on this device only.")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sleepulator \(AppInfo.versionBuild)")
                                if let built = AppInfo.builtAtLabel { Text("Built \(built)") }
                            }
                            .foregroundStyle(pal.dim)
                            .padding(.top, 10)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(AppInfo.accessibilitySummary)
                        }
                    }
                }
                // The same faint row tint as the Podcasts list.
                .listRowBackground(pal.text.opacity(0.05))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(pal.bg.ignoresSafeArea())
            .tint(pal.accent)
            // Room for the floating mini-player, measured.
            .miniPlayerClearance()
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
        // The log exporter must live on its OWN node: two .fileExporter modifiers chained on the
        // same view shadow each other (only the last presents — a long-standing SwiftUI defect),
        // which silently broke "Export Data" when this second exporter was added for the
        // overnight log trail. A clear background anchor gives it a separate attachment point.
        .background {
            Color.clear
                .fileExporter(isPresented: $isExportingLog, document: logDocument, contentType: .plainText, defaultFilename: "sleepulator-log") { result in
                    if case .failure(let error) = result {
                        alertTitle = "Log Export Failed"
                        alertMessage = error.localizedDescription
                        showAlert = true
                    }
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
    @State private var isExportingLog = false
    @State private var logDocument: TextDocument?
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showAlert = false
    
    /// Re-encode a backup section and confirm it decodes into the Codable type the target file
    /// expects. Returns the JSON bytes to write, or nil if the section is malformed/unexpected.
    /// `internal` (not private) so `BackupRoundTripTests` can exercise the validation gate.
    nonisolated static func validatedFileData(key: String, value: Any) -> Data? {
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

    /// Keys whose UserDefaults value is a Data-encoded Codable blob, not a plain scalar. Data can't
    /// go through JSON, so these expand to a nested JSON object on export and are re-encoded on
    /// import. `extraLayers` was in NEITHER backup list until 2026-07 — the user's extra mixer noise
    /// layers were silently dropped from every backup and lost on restore.
    private nonisolated static let backupEncodedKeys: [String] = ["lastMix", "extraLayers"]

    /// The UserDefaults side of an export: scalar settings + the Data-encoded blobs, ready to merge
    /// into the backup dictionary. Pure + parameterized on `defaults` so it's unit-tested (the
    /// shipping export calls this too, so the test covers the real path).
    nonisolated static func backupUserDefaults(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in backupScalarKeys {
            if let v = defaults.object(forKey: key) { out[key] = v }
        }
        for key in backupEncodedKeys {
            if let data = defaults.data(forKey: key),
               let obj = try? JSONSerialization.jsonObject(with: data, options: .allowFragments) {
                out[key] = obj
            }
        }
        return out
    }

    /// The UserDefaults side of a restore: writes allowlisted scalars and re-encodes the Data blobs,
    /// never writing anything outside the allowlist (a malformed or hostile section is skipped, not
    /// written). File-backed keys are handled by the caller against StorageManager, so they're passed
    /// over here without counting. Returns (restored, skipped) for the UserDefaults keys only.
    nonisolated static func restoreUserDefaults(from dict: [String: Any], into defaults: UserDefaults) -> (restored: Int, skipped: Int) {
        let allowed = Set(backupScalarKeys)
        var restored = 0, skipped = 0
        for (key, value) in dict {
            if backupFileBacked[key] != nil {
                continue                                       // handled against StorageManager by the caller
            } else if backupEncodedKeys.contains(key) {
                if let encoded = try? JSONSerialization.data(withJSONObject: value, options: []),
                   decodesForRestore(key: key, data: encoded) {
                    defaults.set(encoded, forKey: key); restored += 1
                } else { skipped += 1 }
            } else if allowed.contains(key) {
                defaults.set(value, forKey: key); restored += 1
            } else {
                skipped += 1                                   // unknown key — never blind-write
            }
        }
        return (restored, skipped)
    }

    /// Validate that a Data-encoded backup blob decodes into its expected type before restore.
    private nonisolated static func decodesForRestore(key: String, data: Data) -> Bool {
        let dec = JSONDecoder()
        switch key {
        case "lastMix":     return (try? dec.decode(SavedMix.self, from: data)) != nil
        case "extraLayers": return (try? dec.decode([ExtraNoiseLayer].self, from: data)) != nil
        default:            return false
        }
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

                var restored = 0
                var skipped = 0

                // File-backed collections → StorageManager, each validated against its expected
                // Codable type (a malformed section is skipped, never written as garbage).
                for (key, file) in Self.backupFileBacked {
                    guard let value = dict[key] else { continue }
                    if let validated = Self.validatedFileData(key: key, value: value) {
                        await StorageManager.shared.writeRaw(validated, to: file)
                        restored += 1
                    } else { skipped += 1 }
                }
                // Scalars + Data-encoded blobs (lastMix, extraLayers) → UserDefaults (allowlisted).
                let ud = Self.restoreUserDefaults(from: dict, into: .standard)
                restored += ud.restored
                skipped += ud.skipped

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
            // Scalar settings + the Data-encoded blobs (lastMix, extraLayers) live in UserDefaults.
            var backupDict = Self.backupUserDefaults(from: .standard)

            // Mixes, library, queue, and positions were migrated off UserDefaults into
            // StorageManager files — pull their raw JSON so the backup is actually complete.
            for (key, file) in Self.backupFileBacked {
                if let data = await StorageManager.shared.rawData(for: file),
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

/// Plain-text wrapper for the "Export logs" share sheet (the overnight LogExport trail).
struct TextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.text = String(decoding: data, as: UTF8.self)
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        return FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Settings ▸ Advanced ▸ Diagnostics: the MetricKit payloads MetricsCollector has stored,
/// newest first, each shareable (AirDrop the JSON to a Mac for analysis). Payloads arrive
/// on iOS's schedule (~daily), so an empty list on a fresh install is expected.
struct DiagnosticsListView: View {
    let pal: Palette
    @State private var files: [URL] = []

    var body: some View {
        ZStack {
            pal.bg.ignoresSafeArea()
            if files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.largeTitle)
                        .foregroundColor(pal.dim)
                    Text("No reports yet")
                        .font(.headline)
                        .foregroundColor(pal.text)
                    Text("iOS delivers battery and stability reports about once a day. Check back after a night's use.")
                        .font(.caption)
                        .foregroundColor(pal.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(files, id: \.self) { url in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent.hasPrefix("diagnostic") ? "Crash / hang report" : "Daily metrics")
                                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                        .foregroundColor(pal.text)
                                    Text(url.lastPathComponent)
                                        .font(.caption2)
                                        .foregroundColor(pal.dim)
                                        .lineLimit(1)
                                }
                                Spacer()
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up")
                                        .foregroundColor(pal.accent)
                                        .frame(width: 44, height: 44)
                                }
                                .accessibilityLabel("Share report")
                            }
                            .glassPanel()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { files = MetricsCollector.shared.payloadFiles() }
    }
}
