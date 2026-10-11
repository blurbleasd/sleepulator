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
                        SettingActionRow(title: "Reports from iOS", systemImage: "waveform.path.ecg", pal: pal)
                    }
                    Button { exportLog() } label: {
                        SettingActionRow(title: "Export last night's log", systemImage: "doc.text", pal: pal) {
                            if collectingLog { ProgressView() }
                        }
                    }
                    // Gathering 12 hours of log lines takes a moment; a second tap mustn't start another.
                    .disabled(collectingLog)
                } header: {
                    Text("Diagnostics").foregroundStyle(pal.dim)
                } footer: {
                    // Build identity: the build time is the line that tells manual builds apart.
                    VStack(alignment: .leading, spacing: UI.md) {
                        Text("Battery, hang and crash reports iOS delivers about once a day. Stored on this device only.")
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Sleepulator \(AppInfo.versionBuild)")
                            if let built = AppInfo.builtAtLabel { Text("Built \(built)") }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(AppInfo.accessibilitySummary)
                    }
                    .foregroundStyle(pal.dim)
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
        .backupPresentations(backup)
        // The log exporter must live on its OWN node: two .fileExporter modifiers chained on the
        // same view shadow each other (only the last presents, a long-standing SwiftUI defect),
        // which silently broke the backup export when this second exporter was added. A clear
        // background anchor gives it a separate attachment point.
        .background {
            Color.clear
                .fileExporter(isPresented: $isExportingLog, document: logDocument, contentType: .plainText,
                              defaultFilename: "sleepulator-log") { result in
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
    let pal: Palette
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.isEnabled) private var isEnabled

    init(title: String, systemImage: String, pal: Palette, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.systemImage = systemImage
        self.pal = pal
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: UI.md) {
            Image(systemName: systemImage)
                .foregroundStyle(pal.dim)
                .frame(minWidth: 24)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(isEnabled ? pal.text : pal.dim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            trailing()
        }
        .contentShape(Rectangle())
    }
}

extension SettingActionRow where Trailing == EmptyView {
    init(title: String, systemImage: String, pal: Palette) {
        self.init(title: title, systemImage: systemImage, pal: pal) { EmptyView() }
    }
}
