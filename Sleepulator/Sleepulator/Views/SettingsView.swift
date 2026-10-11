import SwiftUI
import UniformTypeIdentifiers
import os

struct SettingsView: View {
    /// Held unobserved (a plain `let`): used for the restore's reload and the Pomodoro writes. All
    /// reactive state is observed via the narrow children below, so unrelated engine publishes (podTitle, transport,
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

    /// Export, Restore and Undo: state that must outlive the rows (see `BackupController`).
    @StateObject private var backup: BackupController

    init(audio: AudioEngine, queue: PodcastQueueManager, settings: PlaybackSettings) {
        self.audio = audio
        self.queue = queue
        self.settings = settings
        _backup = StateObject(wrappedValue: BackupController(reload: { audio.reloadAfterRestore() }))
    }

    /// Mode-aware like Home: Focus is cool everywhere, not just on Home. Read from the persisted
    /// "focusMode" key (AudioEngine writes it) so this view needn't observe the whole engine.
    @AppStorage("focusMode") private var focusMode = false
    var pal: Palette { Palette(focusMode: focusMode) }

    /// The sleep-aware queue hold, read by AudioEngine when an episode ends (no live plumbing).
    @AppStorage("holdQueueDuringSleepTimer") private var holdQueue = false

    /// "Soften loud moments" as one choice over the two stored flags (`LimiterChoice`).
    private var limiterChoice: Binding<LimiterChoice> {
        Binding(
            get: { LimiterChoice.from(nightLimiter: settings.nightLimiter, byMode: settings.limiterByMode) },
            set: { choice in
                let flags = choice.flags
                // Following the mode sets the limiter itself (onLimiterByMode → applyLimiterForMode).
                settings.limiterByMode = flags.byMode
                if let on = flags.nightLimiter { settings.nightLimiter = on }
            }
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

    /// One settings row's label, with an optional note under it (`SettingLabel`).
    private func label(_ title: String, note: String? = nil) -> SettingLabel {
        SettingLabel(title: title, note: note, pal: pal)
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
                        footer("While Sleep plays on the Sleep screen or the player, or anywhere with a sleep timer running, the screen goes black a minute after your last touch; tap to wake. Breathing leads into your mix, then it starts on its own.")
                    }

                    Section {
                        // What happens to a podcast at night, in one place: how loud it can get,
                        // how it sounds, and whether the next one starts. The hold used to sit in
                        // the daytime Podcasts section, worded like the timer's one-off "Stop
                        // after this episode", which stops everything.
                        Picker(selection: limiterChoice) {
                            ForEach(LimiterChoice.allCases) { Text($0.title).tag($0) }
                        } label: {
                            label("Soften loud moments", note: "Keeps a sudden loud moment from waking you.")
                        }
                        Toggle(isOn: $settings.sleepEQ) {
                            label("Soften harsh highs and boomy lows", note: "Gentler voices at low volume.")
                        }
                        if settings.sleepEQ {
                            VStack(alignment: .leading, spacing: UI.sm) {
                                HStack {
                                    label("How much")
                                    Spacer()
                                    Text(SettingsCopy.softening(settings.sleepEQIntensity)).foregroundStyle(pal.dim)
                                }
                                VolumeBar(value: $settings.sleepEQIntensity, accent: pal.accent,
                                          range: SettingsCopy.eqFloor...2, style: .parameter, tapToSet: true)
                                    // The visible label, so Voice Control's "How much" finds it.
                                    .accessibilityLabel("How much softening")
                                    .accessibilityValue(SettingsCopy.softening(settings.sleepEQIntensity))
                            }
                            .padding(.vertical, UI.xs)
                        }
                        Toggle(isOn: $holdQueue) {
                            label("Don't start the next episode during a sleep timer",
                                  note: queue.autoPlay ? "The one playing finishes; your sounds carry on."
                                                       : "Only applies when the next episode plays automatically.")
                        }
                        // With Auto-Play off the next episode never starts on its own anyway.
                        .disabled(!queue.autoPlay)
                    } header: {
                        header("Podcasts at night")
                    } footer: {
                        footer("Softening is for podcasts only; your sounds are already steady.")
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
                    }

                    Section {
                        BackupRows(backup: backup)
                    } header: {
                        header("Backup")
                    } footer: {
                        footer("Your mixes, podcasts, queue and settings, as one file.")
                    }

                    Section {
                        NavigationLink { DiagnosticsListView(pal: pal) } label: { label("Reports from iOS") }
                        Button {
                            collectingLog = true
                            Task {
                                let text = await LogExport.collect()
                                collectingLog = false
                                logDocument = TextDocument(text: text)
                                isExportingLog = true
                            }
                        } label: {
                            HStack {
                                Label("Export last night's log", systemImage: "doc.text")
                                Spacer()
                                if collectingLog { ProgressView() }
                            }
                        }
                        // Gathering 12 hours of log lines takes a moment; a second tap mustn't
                        // start another.
                        .disabled(collectingLog)
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
        .backupPresentations(backup)
        // The log exporter must live on its OWN node: two .fileExporter modifiers chained on the
        // same view shadow each other (only the last presents — a long-standing SwiftUI defect),
        // which silently broke "Export Data" when this second exporter was added for the
        // overnight log trail. A clear background anchor gives it a separate attachment point.
        .background {
            Color.clear
                .fileExporter(isPresented: $isExportingLog, document: logDocument, contentType: .plainText, defaultFilename: "sleepulator-log") { result in
                    if case .failure(let error) = result {
                        Log.storage.error("Log export failed: \(error.localizedDescription, privacy: .public)")
                        logExportFailed = true
                    }
                }
        }
        .alert("Couldn't save the log", isPresented: $logExportFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Try again, or pick another place to save it.")
        }
    }

    @State private var isExportingLog = false
    @State private var logDocument: TextDocument?
    @State private var collectingLog = false
    @State private var logExportFailed = false
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

/// A settings row's label: the title in the text tone, and an optional short note under it in
/// the dim tone. A disabled row dims its title too: at full cream it read as live, with only the
/// switch's knob greyed.
struct SettingLabel: View {
    let title: String
    var note: String?
    let pal: Palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(isEnabled ? pal.text : pal.dim)
            if let note {
                Text(note).font(.footnote).foregroundStyle(pal.dim)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
