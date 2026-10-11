import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    /// Held unobserved (a plain `let`): used for the restore's reload and the Pomodoro writes. All
    /// reactive state is observed via the narrow children below, so unrelated engine publishes
    /// (podTitle, transport, chrome) no longer re-render SettingsView.
    let audio: AudioEngine
    /// Observed directly so the Auto-Play / Shuffle toggles still refresh after Phase 3 dropped
    /// the queueManager objectWillChange forward into AudioEngine.
    @ObservedObject var queue: PodcastQueueManager
    /// Comfort/playback settings (skip interval, stereo width, limiter, EQ, beat routing).
    @ObservedObject var settings: PlaybackSettings
    @AppStorage("autoNightDim") private var autoNightDim = true
    @AppStorage("breathingOnRamp") private var breathingOnRamp = false
    @AppStorage("ambientMotion") private var ambientMotion = true

    /// Export, Restore and Undo. Owned here, not by the Backup & support page, so a restore still
    /// finishes and reloads if that page is closed mid-way (see `BackupController`). A
    /// @StateObject, whose autoclosure builds it once: @State's initial value was built on every
    /// init, and ContentView re-inits this view on each engine publish (a mixer drag's every
    /// frame). Its own publishes only fire during a backup action.
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Whether the other mode's settings are unfolded. Folds again when the mode changes.
    @State private var showOtherMode = false

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
    // persists them; the next phase uses them). A restore reloads them (`reloadLengths`).
    @AppStorage("pomoWork") private var pomoWork = PomodoroService.defaultLengths.work
    @AppStorage("pomoRest") private var pomoRest = PomodoroService.defaultLengths.rest
    @AppStorage("pomoLongRest") private var pomoLongRest = PomodoroService.defaultLengths.longRest
    @AppStorage("pomoCycles") private var pomoCycles = PomodoroService.defaultLengths.cycles

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
                // Held on one line: at the largest text sizes "15 min" split into "15 / min".
                Text("\(value) min").foregroundStyle(pal.dim).monospacedDigit().fixedSize()
            }
        }
        // Named once: the label row also holds the value, which VoiceOver read twice.
        .accessibilityLabel(title)
        .accessibilityValue(SettingsCopy.minutes(value))
    }

    /// A row that picks one of a few values: the label (and note) on the left, the value on the
    /// right, and the whole row opens the menu. A Picker with a two-line label dropped its value
    /// onto a line of its own under the note, indented, like a stray control.
    private func choiceRow<T: Hashable>(_ title: String, note: String? = nil, selection: Binding<T>,
                                        options: [T], name: @escaping (T) -> String) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { Text(name($0)).tag($0) }
            }
        } label: {
            // At the accessibility text sizes the value goes under the label: beside it, the
            // label was squeezed into a hyphenated column ("for- / ward").
            let stacked = dynamicTypeSize.isAccessibilitySize
            let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: UI.xs))
                                 : AnyLayout(HStackLayout(spacing: UI.sm))
            layout {
                label(title, note: note)
                if !stacked { Spacer(minLength: UI.sm) }
                HStack(spacing: UI.xs) {
                    Text(name(selection.wrappedValue))
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                }
                .foregroundStyle(pal.dim)
                .fixedSize()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(name(selection.wrappedValue))
        .accessibilityHint(note ?? "")
    }

    /// Stereo width by named stop (`StereoWidth`).
    private var stereoWidth: Binding<StereoWidth> {
        Binding(get: { StereoWidth.nearest(settings.stereoWidth) },
                set: { settings.stereoWidth = $0.rawValue })
    }

    // The current mode's settings lead, then what both modes share, then the other mode's folded
    // under one row, then Backup & support. The list used to run in one order for both modes:
    // Focus opened on Sleep's darkening and podcasts-at-night, Sleep had four Pomodoro steppers
    // mid-list, and it ended on backup, diagnostics and a build timestamp.
    var body: some View {
        NavigationStack {
            List {
                Group {
                    ForEach(SettingsOrder.shown(focus: focusMode)) { section($0) }
                    otherModeRow
                    if showOtherMode {
                        ForEach(SettingsOrder.folded(focus: focusMode)) { section($0) }
                    }
                    Section {
                        NavigationLink {
                            BackupSupportView(backup: backup, pal: pal)
                        } label: {
                            label("Backup & support")
                        }
                    }
                }
                // The same faint row tint as the Podcasts list.
                .listRowBackground(pal.text.opacity(0.05))
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(pal.bg.ignoresSafeArea())
            .tint(pal.controlTint)
            // Room for the floating mini-player, measured.
            .miniPlayerClearance()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .onChange(of: focusMode) { showOtherMode = false }
        }
    }

    /// The fold for the other mode's settings: a row that opens them below it.
    private var otherModeRow: some View {
        Section {
            Button {
                withAnimation(.easeOut(duration: 0.25)) { showOtherMode.toggle() }
            } label: {
                HStack {
                    label(focusMode ? "Sleep settings" : "Focus settings",
                          note: focusMode ? "Darkening, breathing and podcasts at night" : "Session and break lengths")
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(pal.dim)
                        .rotationEffect(.degrees(showOtherMode ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .accessibilityValue(showOtherMode ? "Expanded" : "Collapsed")
        }
    }

    @ViewBuilder
    private func section(_ section: SettingsSection) -> some View {
        switch section {
        case .sleep:         sleepSection
        case .nightPodcasts: nightPodcastsSection
        case .focus:         focusSection
        case .sound:         soundSection
        case .display:       displaySection
        case .podcasts:      podcastsSection
        }
    }

    private var sleepSection: some View {
        Section {
            // A short note per control. One 41-word footer covered both switches, ran to ten
            // lines at large text sizes, and still said "tap to wake" after the veil's glance
            // made it two taps.
            Toggle(isOn: $autoNightDim) {
                label("Darken the screen at night",
                      note: "While Sleep plays, the screen goes black a minute after your last touch. Tap once to glance, twice to wake.")
            }
            Toggle(isOn: $breathingOnRamp) {
                label("Start with a minute of breathing", note: "Then your mix starts on its own.")
            }
        } header: {
            header("Sleep")
        }
    }

    private var nightPodcastsSection: some View {
        Section {
            // What happens to a podcast at night, in one place: how loud it can get, how it
            // sounds, and whether the next one starts. The hold used to sit in the daytime
            // Podcasts section, worded like the timer's one-off "Stop after this episode", which
            // stops everything.
            choiceRow("Soften loud moments", note: "Keeps a sudden loud moment from waking you.",
                      selection: limiterChoice, options: LimiterChoice.allCases) { $0.title }
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
                    // The thumb in the mode's text tone (the default cream sat warm on Focus's
                    // cyan), on a channel that shows against the flat row.
                    VolumeBar(value: $settings.sleepEQIntensity, accent: pal.controlTint,
                              range: SettingsCopy.eqFloor...2, thumbColor: pal.text,
                              trackColor: pal.text.opacity(0.16), style: .parameter, tapToSet: true)
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
    }

    private var focusSection: some View {
        Section {
            minutesStepper("Focus length", value: pomoWork, range: 5...90, step: 5) { audio.pomodoro.workMinutes = $0 }
            minutesStepper("Short break", value: pomoRest, range: 1...30, step: 1) { audio.pomodoro.restMinutes = $0 }
            minutesStepper("Long break", value: pomoLongRest, range: 5...60, step: 5) { audio.pomodoro.longRestMinutes = $0 }
            Stepper(value: pomodoroBinding(pomoCycles) { audio.pomodoro.cyclesBeforeLongBreak = $0 }, in: 2...8) {
                HStack {
                    label("Rounds before a long break")
                    Spacer()
                    Text("\(pomoCycles)").foregroundStyle(pal.dim).monospacedDigit().fixedSize()
                }
            }
            .accessibilityLabel("Rounds before a long break")
            .accessibilityValue("\(pomoCycles) rounds")
        } header: {
            header("Focus")
        } footer: {
            footer("Changes apply from the next round.")
        }
    }

    private var soundSection: some View {
        Section {
            choiceRow("Stereo width", note: "How far the noise spreads, left to right. Narrow suits a phone speaker.",
                      selection: stereoWidth, options: StereoWidth.allCases) { $0.title }
            // A true binaural beat needs one tone per ear; on a speaker the two sum in the
            // air and the beat vanishes, so a speaker gets a pulsed (isochronic) tone.
            choiceRow("Binaural beats for", note: SettingsCopy.beatsNote(settings.beatRouting),
                      selection: $settings.beatRouting, options: ["auto", "headphones", "speaker"]) {
                ["headphones": "Headphones", "speaker": "Speaker"][$0] ?? "Auto"
            }
        } header: {
            header("Sound")
        }
    }

    private var displaySection: some View {
        Section {
            Toggle(isOn: $ambientMotion) {
                label("Moving scenes", note: "Off holds the scene still: calmer, and easier on the battery.")
            }
        } header: {
            header("Display")
        }
    }

    private var podcastsSection: some View {
        Section {
            Toggle(isOn: $queue.autoPlay) { label("Play the next episode automatically") }
            Toggle(isOn: $queue.shuffleQueue) {
                label("Shuffle the queue", note: "The next episode comes from anywhere in Up Next.")
            }
            choiceRow("Skip back and forward",
                      selection: Binding(get: { Int(settings.skipInterval) }, set: { settings.skipInterval = Double($0) }),
                      options: [10, 15, 30, 45]) { "\($0) seconds" }
            Toggle(isOn: $queue.deleteOnCompletion) {
                label("Delete downloads once played", note: "Only finished episodes; a skipped one keeps its download.")
            }
            Toggle(isOn: $queue.hideFinishedEpisodes) { label("Hide played episodes") }
        } header: {
            header("Podcasts")
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

/// Plain-text wrapper for "Export the playback log" (LogExport).
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

/// Settings ▸ Backup & support ▸ Reports from iOS: the MetricKit payloads MetricsCollector has
/// stored, newest first, each shareable (AirDrop the JSON to a Mac for analysis). Payloads
/// arrive on iOS's schedule (~daily), so an empty list on a fresh install is expected.
struct DiagnosticsListView: View {
    let pal: Palette
    @State private var reports: [Report] = []

    /// One stored payload, named for a person: what kind it is and when it came.
    struct Report: Identifiable {
        let url: URL
        let isCrash: Bool
        let date: Date?
        var id: URL { url }
        var kind: String { isCrash ? "Crash or hang report" : "Battery and performance report" }
        var when: String { date?.formatted(date: .abbreviated, time: .shortened) ?? "Date unknown" }
    }

    var body: some View {
        Group {
            if reports.isEmpty {
                VStack(spacing: UI.sm) {
                    Image(systemName: "waveform.path.ecg.rectangle")
                        .font(.largeTitle)
                        .foregroundStyle(pal.dim)
                        .accessibilityHidden(true)
                    Text("No reports yet")
                        .font(.headline)
                        .foregroundStyle(pal.text)
                    Text("iOS sends battery and crash reports about once a day. Check back after a night's use.")
                        .font(.footnote)
                        .foregroundStyle(pal.dim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, UI.xxl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(pal.bg.ignoresSafeArea())
            } else {
                // The list style of the pages around it; it used to be glass cards in a ScrollView
                // with each report named by its raw filename.
                List {
                    ForEach(reports) { report in
                        HStack(spacing: UI.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.kind).foregroundStyle(pal.text)
                                Text(report.when).font(.footnote).foregroundStyle(pal.dim)
                            }
                            .accessibilityElement(children: .combine)
                            Spacer(minLength: 0)
                            ShareLink(item: report.url) {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundStyle(pal.dim)
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Share the \(report.kind.lowercased()) from \(report.when)")
                        }
                    }
                    .listRowBackground(pal.text.opacity(0.05))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(pal.bg.ignoresSafeArea())
            }
        }
        // Room for the floating mini-player, measured (a pushed page ends at the bottom edge).
        .miniPlayerClearance()
        .navigationTitle("Reports from iOS")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            reports = MetricsCollector.shared.payloadFiles().map { url in
                Report(url: url, isCrash: url.lastPathComponent.hasPrefix("diagnostic"),
                       date: (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate)
            }
        }
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
        // Leading even inside a Menu's label, which centres multi-line text.
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
