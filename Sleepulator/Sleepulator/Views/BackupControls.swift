import SwiftUI
import Combine
import UniformTypeIdentifiers
import os

/// The Backup rows' state: export, the restore's read → confirm → write → Undo, and the alerts in
/// between. An ObservableObject owned by the screen rather than @State in a row: a List can tear
/// an off-screen row down mid-restore, and its alert with it.
@MainActor
final class BackupController: ObservableObject {
    enum Prompt {
        case confirm(Backup.Pending)
        case restored(Backup.Outcome)
        case failed(title: String, message: String)
        case confirmUndo(Date)
        case undone
    }

    @Published var isImporting = false
    @Published var isExporting = false
    @Published private(set) var exportDocument: JSONDocument?
    @Published private(set) var exportName = "sleepulator-backup"
    @Published private(set) var prompt: Prompt?
    /// A read, write or undo is running: the rows disable so a second tap can't start another.
    @Published private(set) var busy = false
    /// When the snapshot Undo would put back was taken, while it's still offered.
    @Published private(set) var undoDate: Date?

    private let reload: () -> Void
    /// When the last alert went away. SwiftUI drops an alert presented while another (or the file
    /// picker) is still animating out, so the next one waits for it.
    private var lastDismissal = Date.distantPast

    init(reload: @escaping () -> Void) {
        self.reload = reload
    }

    // Explicitly nonisolated (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}

    var isPrompting: Binding<Bool> {
        Binding(get: { self.prompt != nil },
                set: { if !$0 { self.prompt = nil; self.lastDismissal = Date() } })
    }

    func refresh() {
        undoDate = Backup.undoDate()
    }

    func export() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let now = Date()
                exportDocument = JSONDocument(data: try await Backup.exportData(at: now))
                exportName = Backup.filename(for: now)
                isExporting = true
            } catch {
                await present(.failed(title: "Couldn't make a backup", message: "Try again in a moment."))
            }
        }
    }

    func exported(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            Log.storage.info("Exported backup to \(url.lastPathComponent, privacy: .public)")
        case .failure(let error):
            Log.storage.error("Backup export failed: \(error.localizedDescription, privacy: .public)")
            Task { await present(.failed(title: "Couldn't save the backup", message: "Try again, or pick another place to save it.")) }
        }
    }

    /// The picker's answer: read and validate the file, then ask before replacing anything.
    func picked(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else {
            if case .failure = result {
                Task { await present(.failed(title: "Couldn't restore", message: Backup.failureMessage(.noAccess))) }
            }
            return
        }
        busy = true
        Task {
            let read = await Backup.read(url)
            busy = false
            switch read {
            case .success(let pending): await present(.confirm(pending))
            case .failure(let failure): await present(.failed(title: "Couldn't restore", message: Backup.failureMessage(failure)))
            }
        }
    }

    func restore(_ pending: Backup.Pending) {
        busy = true
        Task {
            let outcome = await Backup.restore(pending)
            reload()
            busy = false
            refresh()
            await present(.restored(outcome))
        }
    }

    func askToUndo() {
        guard let undoDate else { return }
        Task { await present(.confirmUndo(undoDate)) }
    }

    func undo() {
        busy = true
        Task {
            let undone = await Backup.undo()
            if undone { reload() }
            busy = false
            refresh()
            await present(undone ? .undone
                          : .failed(title: "Couldn't undo", message: "The copy from before the restore is gone, so there's nothing to put back."))
        }
    }

    private func present(_ next: Prompt) async {
        let wait = 0.5 - Date().timeIntervalSince(lastDismissal)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        prompt = next
    }

    // MARK: Alert copy

    var title: String {
        switch prompt {
        case .confirm(let p):         return Backup.confirmTitle(p.contents)
        case .restored:               return "Backup restored"
        case .failed(let title, _):   return title
        case .confirmUndo:            return "Undo the restore?"
        case .undone:                 return "Restore undone"
        case nil:                     return ""
        }
    }

    var message: String {
        switch prompt {
        case .confirm(let p):         return Backup.confirmMessage(p.contents)
        case .restored(let o):        return Backup.restoredMessage(o)
        case .failed(_, let message): return message
        case .confirmUndo(let date):
            return "This puts back the mixes, podcasts, queue and settings you had before restoring on "
                + "\(date.formatted(.dateTime.weekday(.wide).hour().minute())). Anything you've changed since will be lost."
        case .undone:                 return "Your mixes, podcasts, queue and settings are back as they were."
        case nil:                     return ""
        }
    }
}

/// The Backup rows: Export, Restore, and Undo while a recent restore can still be undone.
struct BackupRows: View {
    @ObservedObject var backup: BackupController

    var body: some View {
        Button { backup.export() } label: {
            Label("Export a backup", systemImage: "square.and.arrow.up")
        }
        .disabled(backup.busy)
        Button { backup.isImporting = true } label: {
            Label("Restore from a backup", systemImage: "square.and.arrow.down")
        }
        .disabled(backup.busy)
        if let date = backup.undoDate {
            Button { backup.askToUndo() } label: {
                Label("Undo the restore from \(date.formatted(.dateTime.weekday(.wide).hour().minute()))",
                      systemImage: "arrow.uturn.backward")
            }
            .disabled(backup.busy)
        }
    }
}

extension View {
    /// The Backup presentations: the file picker, the exporter and the one alert. Applied once, on
    /// the screen (not a row), so they outlive the rows scrolling away.
    func backupPresentations(_ backup: BackupController) -> some View {
        modifier(BackupPresentations(backup: backup))
    }
}

private struct BackupPresentations: ViewModifier {
    @ObservedObject var backup: BackupController

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $backup.isImporting, allowedContentTypes: [.json],
                          allowsMultipleSelection: false) { backup.picked($0) }
            .fileExporter(isPresented: $backup.isExporting, document: backup.exportDocument,
                          contentType: .json, defaultFilename: backup.exportName) { backup.exported($0) }
            .onAppear { backup.refresh() }
            // Night-time confirms are plain alerts with no destructive role (CLAUDE.md): iOS 26 drew
            // a red button alone on a dark screen.
            .alert(backup.title, isPresented: backup.isPrompting) {
                switch backup.prompt {
                case .confirm(let pending):
                    Button("Cancel", role: .cancel) {}
                    Button("Replace") { backup.restore(pending) }
                case .restored(let outcome) where outcome.undoAvailable:
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
    }
}
