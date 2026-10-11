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
    /// The Backup & support page is on screen. Its alert lives there, so a result that lands after
    /// the page closed is dropped, not stranded: it surfaced later, out of context, with a one-tap
    /// Undo that skipped the "changes since will be lost" confirm.
    var pageVisible = false

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
        // The picker is animating out now: the alert that follows waits for it like any other.
        lastDismissal = Date()
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
            guard let outcome = await Backup.restore(pending) else {
                busy = false
                refresh()
                await present(.failed(title: "Couldn't restore", message: Backup.noSnapshotMessage))
                return
            }
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
        guard pageVisible else { return }
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
    let pal: Palette

    var body: some View {
        Button { backup.export() } label: {
            SettingActionRow(title: "Export a backup", systemImage: "square.and.arrow.up", pal: pal)
        }
        .disabled(backup.busy)
        Button { backup.isImporting = true } label: {
            SettingActionRow(title: "Restore from a backup", systemImage: "square.and.arrow.down", pal: pal)
        }
        .disabled(backup.busy)
        if let date = backup.undoDate {
            Button { backup.askToUndo() } label: {
                SettingActionRow(title: "Undo the restore from \(date.formatted(.dateTime.weekday(.wide).hour().minute()))",
                                 systemImage: "arrow.uturn.backward", pal: pal)
            }
            .disabled(backup.busy)
        }
    }
}
