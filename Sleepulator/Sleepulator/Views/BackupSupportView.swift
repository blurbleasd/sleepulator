import SwiftUI
import UniformTypeIdentifiers
import os

/// Settings ▸ Backup & support: the backup file, the reports iOS delivers, the overnight log and
/// the build. Things a person reaches for rarely, and never at 2am, so they live one level down:
/// at the end of the main list they took the only accent-coloured rows and closed the list on a
/// build timestamp.
struct BackupSupportView: View {
    @ObservedObject var backup: BackupController
    let pal: Palette

    @State private var isExportingLog = false
    @State private var logDocument: TextDocument?
    @State private var collectingLog = false
    @State private var logExportFailed = false
    @State private var logName = "sleepulator-log"

    var body: some View {
        List {
            Group {
                Section {
                    BackupRows(backup: backup, pal: pal)
                } header: {
                    Text("Backup").foregroundStyle(pal.dim)
                } footer: {
                    Text("Your mixes, podcasts, queue and settings, as one file.").foregroundStyle(pal.dim)
                }

                Section {
                    NavigationLink { DiagnosticsListView(pal: pal) } label: {
                        SettingActionRow(title: "Reports from iOS", systemImage: "waveform.path.ecg",
                                         note: "Battery and crash reports, about one a day. Kept on this iPhone.", pal: pal)
                    }
                    // The title alone as the name (the note as the hint), as Settings' switches.
                    .accessibilityLabel("Reports from iOS")
                    .accessibilityHint("Battery and crash reports, about one a day. Kept on this iPhone.")
                    Button { exportLog() } label: {
                        // It's the process's own log (OSLogStore, current process): what played
                        // since the app last opened, capped at 12 hours. "Last night's" overpromised.
                        SettingActionRow(title: "Export the playback log", systemImage: "doc.text",
                                         note: "What played and what went wrong since the app opened, up to 12 hours.",
                                         pal: pal) {
                            if collectingLog { ProgressView() }
                        }
                    }
                    .accessibilityLabel("Export the playback log")
                    .accessibilityHint("What played and what went wrong since the app opened, up to 12 hours.")
                    // Gathering the log lines takes a moment; a second tap mustn't start another.
                    .disabled(collectingLog)
                } header: {
                    Text("Troubleshooting").foregroundStyle(pal.dim)
                } footer: {
                    // Build identity: the build time is the line that tells manual builds apart.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sleepulator \(AppInfo.versionBuild)")
                        if let built = AppInfo.builtAtLabel { Text("Built \(built)") }
                    }
                    .foregroundStyle(pal.dim)
                    .padding(.top, UI.sm)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(AppInfo.accessibilitySummary)
                }
            }
            .listRowBackground(pal.text.opacity(0.05))
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(pal.bg.ignoresSafeArea())
        .tint(pal.controlTint)
        .miniPlayerClearance()
        .navigationTitle("Backup & support")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { backup.pageVisible = true; backup.refresh() }
        .onDisappear { backup.pageVisible = false }
        .fileImporter(isPresented: $backup.isImporting, allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { backup.picked($0) }
        .fileExporter(isPresented: $backup.isExporting, document: backup.exportDocument,
                      contentType: .json, defaultFilename: backup.exportName) { backup.exported($0) }
        // Night-time confirms are plain alerts with no destructive role (CLAUDE.md): iOS 26 drew a
        // red button alone on a dark screen.
        .alert(backup.title, isPresented: backup.isPrompting) {
            switch backup.prompt {
            case .confirm(let pending):
                Button("Cancel", role: .cancel) {}
                Button("Replace") { backup.restore(pending) }
            case .restored:
                Button("OK", role: .cancel) {}
                Button("Undo") { backup.undo() }
            case .confirmUndo:
                Button("Cancel", role: .cancel) {}
                Button("Undo restore") { backup.undo() }
            default:
                Button("OK", role: .cancel) {}
            }
        } message: {
            Text(backup.message)
        }
        // The log exporter must live on its OWN node: two .fileExporter modifiers chained on the
        // same view shadow each other (only the last presents, a long-standing SwiftUI defect),
        // which silently broke the backup export when this second exporter was added. A clear
        // background anchor gives it a separate attachment point.
        .background {
            Color.clear
                .fileExporter(isPresented: $isExportingLog, document: logDocument, contentType: .plainText,
                              defaultFilename: logName) { result in
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

    private func exportLog() {
        collectingLog = true
        Task {
            let text = await LogExport.collect()
            collectingLog = false
            logDocument = TextDocument(text: text)
            logName = Backup.filename(for: Date(), prefix: "sleepulator-log")
            isExportingLog = true
        }
    }
}

/// An action row (a button or a link) in the text tone with a dim icon column. Rows in the
/// accent colour shouted from the least-used corner of Settings; a List row also restyles a
/// `Label`, so the pair is built from an HStack (CLAUDE.md, "List rows restyle Label").
struct SettingActionRow<Trailing: View>: View {
    let title: String
    let systemImage: String
    var note: String?
    let pal: Palette
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: UI.md) {
            Image(systemName: systemImage)
                .foregroundStyle(pal.dim)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            SettingLabel(title: title, note: note, pal: pal)
            Spacer(minLength: 0)
            trailing()
        }
        .contentShape(Rectangle())
    }
}

extension SettingActionRow where Trailing == EmptyView {
    init(title: String, systemImage: String, note: String? = nil, pal: Palette) {
        self.init(title: title, systemImage: systemImage, note: note, pal: pal) { EmptyView() }
    }
}
