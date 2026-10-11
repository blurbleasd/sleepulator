import SwiftUI
import Combine
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
        /// Something to know about what just happened, with only an OK (a backup saved with a
        /// section left out).
        case notice(title: String, message: String)
        case confirmUndo(Date)
        case undone
    }

    @Published var isImporting = false
    @Published var isExporting = false {
        // The document can run to tens of MB. Once the exporter has closed (saved, failed or
        // cancelled: SwiftUI resets this either way) nothing reads it; it was kept all session.
        didSet { if !isExporting { exportDocument = nil } }
    }
    @Published private(set) var exportDocument: JSONDocument?
    @Published private(set) var exportName = "sleepulator-backup"
    /// The sections the backup being saved couldn't include, said once the save lands.
    private var exportLeftOut: [String] = []
    @Published private(set) var prompt: Prompt?
    /// A read, write or undo is running: the rows disable so a second tap can't start another.
    @Published private(set) var busy = false
    /// When the snapshot Undo would put back was taken, while it's still offered.
    @Published private(set) var undoDate: Date?
    /// The Backup & support page is on screen (`pageAppeared` / `pageDisappeared`). Its alert
    /// lives there, so a result that lands after the page closed is dropped, not stranded: it
    /// surfaced later, out of context, with a one-tap Undo that skipped the "changes since will be
    /// lost" confirm. A failure is kept for when the page opens again (`pendingFailure`).
    private(set) var pageVisible = false
    /// A failure that landed while the page was closed. "Couldn't save a copy …, so nothing was
    /// replaced" is the only word that a restore didn't happen; dropped, the person was left
    /// believing it had.
    private var pendingFailure: Prompt?

    private let storage: StorageManager
    private let defaults: UserDefaults
    /// Lands the engine's queued writes before a backup reads the store or a restore writes
    /// over it (`AudioEngine.flushPendingWrites`).
    private let settle: () -> Void
    private let reload: () -> Void
    /// When the last alert went away. SwiftUI drops an alert presented while another (or the file
    /// picker) is still animating out, so the next one waits for it (`alertDelay`).
    private var lastDismissal = Date.distantPast
    /// How long after a dismissal an alert waits. The log exporter's alert waits as long.
    nonisolated static let alertDelay: TimeInterval = 0.5
    private let alertDelay: TimeInterval

    init(storage: StorageManager = .shared, defaults: UserDefaults = .standard, alertDelay: TimeInterval = BackupController.alertDelay,
         settle: @escaping () -> Void = {}, reload: @escaping () -> Void) {
        self.storage = storage
        self.defaults = defaults
        self.alertDelay = alertDelay
        self.settle = settle
        self.reload = reload
    }

    // Explicitly nonisolated (CLAUDE.md, "Isolated deinits"). Only releases stored properties.
    nonisolated deinit {}

    var isPrompting: Binding<Bool> {
        Binding(get: { self.prompt != nil },
                set: { if !$0 { self.prompt = nil; self.lastDismissal = Date() } })
    }

    func refresh() {
        undoDate = Backup.undoDate(storage: storage, defaults: defaults)
    }

    func pageAppeared() {
        pageVisible = true
        refresh()
        guard let failure = pendingFailure else { return }
        pendingFailure = nil
        lastDismissal = Date()                 // the page is still sliding in
        Task { await present(failure) }
    }

    func pageDisappeared() {
        pageVisible = false
    }

    func export() {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let now = Date()
                settle()
                let export = try await Backup.exportData(at: now, storage: storage, defaults: defaults,
                                                         maxBytes: Backup.maxFileBytes)
                // Closed while it was being made: no save sheet popping up later, out of context.
                guard pageVisible else { return }
                exportDocument = JSONDocument(data: export.data)
                exportLeftOut = export.leftOut
                exportName = Backup.filename(for: now)
                isExporting = true
            } catch Backup.ExportFailure.tooLarge {
                await present(.failed(title: "Couldn't make a backup", message: Backup.tooLargeToExportMessage))
            } catch {
                await present(.failed(title: "Couldn't make a backup", message: "Try again in a moment."))
            }
        }
    }

    func exported(_ result: Result<URL, Error>) {
        // The exporter is animating out now: an alert that follows waits for it, as after the picker.
        lastDismissal = Date()
        switch result {
        case .success(let url):
            Log.storage.info("Exported backup to \(url.lastPathComponent, privacy: .public)")
            if let message = Backup.leftOutMessage(exportLeftOut) {
                Task { await present(.notice(title: "Part of the backup is missing", message: message)) }
            }
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
            guard let outcome = await Backup.restore(pending, storage: storage, defaults: defaults, settle: settle) else {
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
            let undone = await Backup.undo(storage: storage, defaults: defaults, settle: settle)
            if undone { reload() }
            busy = false
            refresh()
            await present(undone ? .undone
                          : .failed(title: "Couldn't undo", message: "The copy from before the restore is gone, so there's nothing to put back."))
        }
    }

    private func present(_ next: Prompt) async {
        let wait = alertDelay - Date().timeIntervalSince(lastDismissal)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard pageVisible else {
            if case .failed = next { pendingFailure = next }
            return
        }
        prompt = next
    }

    // MARK: Alert copy

    /// When the restore Undo would reverse was made: "Sunday 9:41 PM".
    static func undoWhen(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).hour().minute())
    }

    var title: String {
        switch prompt {
        case .confirm(let p):         return Backup.confirmTitle(p.contents)
        case .restored:               return "Backup restored"
        case .failed(let title, _), .notice(let title, _): return title
        case .confirmUndo:            return "Undo the restore?"
        case .undone:                 return "Restore undone"
        case nil:                     return ""
        }
    }

    var message: String {
        switch prompt {
        case .confirm(let p):         return Backup.confirmMessage(p.contents)
        case .restored(let o):        return Backup.restoredMessage(o)
        case .failed(_, let message), .notice(_, let message): return message
        case .confirmUndo(let date):
            return "This puts back the mixes, podcasts, queue and settings you had before restoring on "
                + "\(Self.undoWhen(date)). Anything you've changed since will be lost."
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
            let when = BackupController.undoWhen(date)
            Button { backup.askToUndo() } label: {
                SettingActionRow(title: "Undo the restore from \(when)", systemImage: "arrow.uturn.backward", pal: pal)
            }
            // Named without the date, which goes in the value: Voice Control needed "Undo the
            // restore from Sunday 9:41 PM" to tap it, and VoiceOver led with the date.
            .accessibilityLabel("Undo the restore")
            .accessibilityValue(when)
            .disabled(backup.busy)
        }
    }
}
