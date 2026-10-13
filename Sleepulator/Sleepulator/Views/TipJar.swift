import SwiftUI
import StoreKit
import MessageUI
import UIKit

// The tip jar's views and the support rows (docs/designs/APP-STORE-LAUNCH-1.0.md; design D4–D9,
// D14, D17; eng run 2 R4, R5):
//
//   Home's tip card ── "Leave a tip" ──> TipSheet (medium detent, Close) ──> TipRows
//   Settings ▸ Backup & support ──> Troubleshooting: Send feedback (first) …
//                                └─> Support Sleepulator (last): the lasting thank-you, TipRows, Rate
//
// TipRows is one view in both places, so the two can't drift. It observes TipStore only, never
// AudioEngine (CLAUDE.md, the coarse-ObservableObject rule).

/// A natural break in the app (a sheet closed, the person left Settings): ContentView may ask
/// for a rating there (design D12). Home's sheets report theirs through this.
struct NaturalBreakKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    var naturalBreak: () -> Void {
        get { self[NaturalBreakKey.self] }
        set { self[NaturalBreakKey.self] = newValue }
    }
}

/// The tip jar's words (design D14).
enum TipCopy {
    static let sheetTitle = "Leave a tip"
    static let footer = "Tips unlock nothing. Everything is already free."
    static let thanks = "Thank you. Sleep well."
    static let lastingThanks = "Thank you for supporting Sleepulator."
    static let unavailable = "Tips aren't available right now."
    static let failed = "That didn't go through."
    static let unconfirmed = "Couldn't confirm this tip."
    static let tryAgain = "Try again"
    static let pending = "Waiting for approval."
    static let loading = "Loading…"
}

/// The three tips and their states (design D5, D7; the Pass 2 state table).
struct TipRows: View {
    @ObservedObject var tips: TipStore
    let pal: Palette

    private var purchasing: String? {
        if case .purchasing(let id) = tips.phase { return id }
        return nil
    }

    var body: some View {
        switch tips.phase {
        case .loading:
            HStack(spacing: UI.md) {
                ProgressView()
                Text(TipCopy.loading).foregroundStyle(pal.dim)
            }
        case .unavailable:
            Text(TipCopy.unavailable).foregroundStyle(pal.dim)
        case .thanked:
            Text(TipCopy.thanks)
                .foregroundStyle(pal.text)
                .accessibilityAddTraits(.isStaticText)
        case .pending:
            Text(TipCopy.pending).foregroundStyle(pal.dim)
        case .unconfirmed:
            Text(TipCopy.unconfirmed).foregroundStyle(pal.dim)
        case .failed:
            Text(TipCopy.failed).foregroundStyle(pal.dim)
            if let id = tips.lastAttempt {
                Button(TipCopy.tryAgain) { Task { await tips.purchase(id) } }
                    .foregroundStyle(pal.text)
            }
        case .ready, .purchasing:
            ForEach(tips.products) { product in
                Button {
                    Task { await tips.purchase(product.id) }
                } label: {
                    HStack {
                        Text(product.name).foregroundStyle(pal.text)
                        Spacer(minLength: UI.md)
                        if purchasing == product.id {
                            ProgressView()
                        } else {
                            Text(product.displayPrice)
                                .monospacedDigit()
                                .foregroundStyle(pal.dim)
                        }
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .disabled(purchasing != nil)
                .accessibilityLabel("\(product.name), \(product.displayPrice)")
            }
        }
    }
}

/// The sheet the tip card opens (design D5). Stays up after a tip until the person closes it.
struct TipSheet: View {
    @ObservedObject var tips: TipStore
    let pal: Palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TipRows(tips: tips, pal: pal)
                } footer: {
                    Text(TipCopy.footer).foregroundStyle(pal.dim)
                }
            }
            .scrollContentBackground(.hidden)
            .background(pal.bg)
            .navigationTitle(TipCopy.sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task { if tips.products.isEmpty { await tips.loadProducts() } }
    }
}

// MARK: - The Rate row (design D8; eng run 2 R4)

/// Whether "Rate Sleepulator" shows: only with an App Store ID, and only on an App Store build
/// (never in Xcode or TestFlight, where the review page doesn't exist yet). Pure, unit-tested.
enum RateRowRule {
    enum StoreEnvironment { case production, other }

    static func visible(appStoreID: String?, environment: StoreEnvironment) -> Bool {
        guard let id = appStoreID, !id.isEmpty else { return false }
        return environment == .production
    }

    static func writeReviewURL(appStoreID: String) -> URL? {
        URL(string: "https://apps.apple.com/app/id\(appStoreID)?action=write-review")
    }

    /// This build's store environment. Any failure (offline, no receipt) reads as "other", which
    /// hides the row: conservative, and re-checked next launch.
    static func currentEnvironment() async -> StoreEnvironment {
        guard let result = try? await AppTransaction.shared else { return .other }
        switch result {
        case .verified(let transaction), .unverified(let transaction, _):
            return transaction.environment == .production ? .production : .other
        }
    }
}

// MARK: - Send feedback (FB-1; design D9; eng run 2 R5)

/// The feedback message's words, pure so the tests pin them: what's attached, in plain words,
/// and where it goes (design D9). Never a URL (the attachments are scrubbed at write).
enum FeedbackMessage {
    static let subject = "Sleepulator feedback"

    static func subjectLine(version: String, build: String) -> String {
        "\(subject) (\(version), build \(build))"
    }

    static func body(nightSummary: String, nightFiles: Int, reportsSince: Date?, version: String,
                     build: String, iOS: String, device: String) -> String {
        var attached: [String] = []
        if nightFiles > 0 {
            attached.append("the last \(nightFiles == 1 ? "night's" : "\(nightFiles) nights'") playback events (no web addresses)")
        }
        if let since = reportsSince {
            attached.append("iOS reports since \(since.formatted(date: .abbreviated, time: .omitted))")
        }
        let attachedLine = attached.isEmpty ? "Attached: nothing yet." : "Attached: " + attached.joined(separator: " and ") + "."
        return """


        ———
        \(nightSummary)
        \(attachedLine)
        Sleepulator \(version) (\(build)) · iOS \(iOS) · \(device)
        """
    }

    /// The share sheet's text, when Mail isn't set up: where to send it.
    static func shareText(address: String?, body: String) -> String {
        guard let address else { return body }
        return "Please send this to \(address)" + body
    }
}

/// What "Send feedback" gathers: the kept night files and the newest iOS reports, newest first,
/// within a 2 MB total (eng Section 4 #2), noting anything left out.
struct FeedbackBundle {
    let files: [URL]
    let body: String

    static let byteCap = 2 * 1024 * 1024

    static func gather(journal: NightJournal) -> FeedbackBundle {
        journal.drain()
        let nights = journal.nightFiles()
        let reports = MetricsCollector.shared.payloadFiles()
        var files: [URL] = []
        var total = 0
        var leftOut = 0
        for url in nights + reports {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if total + size > byteCap { leftOut += 1; continue }
            total += size
            files.append(url)
        }
        // "Since" names the oldest report actually attached (reports are newest first), not the
        // oldest on disk, which the cap may have left out.
        let attachedReports = files.filter { reports.contains($0) }
        let since = attachedReports.last.flatMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }
        var body = FeedbackMessage.body(nightSummary: journal.summaryLine(),
                                        nightFiles: files.filter { nights.contains($0) }.count,
                                        reportsSince: attachedReports.isEmpty ? nil : since,
                                        version: AppInfo.version, build: AppInfo.build,
                                        iOS: UIDevice.current.systemVersion, device: UIDevice.current.model)
        if leftOut > 0 {
            body += "\n\(leftOut) older file\(leftOut == 1 ? "" : "s") left out to keep this under \(byteCap / 1_048_576) MB."
        }
        return FeedbackBundle(files: files, body: body)
    }
}

/// Mail with the attachments, or the share sheet when Mail isn't set up.
struct FeedbackComposer: UIViewControllerRepresentable {
    let bundle: FeedbackBundle
    let onFinish: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIViewController {
        if MFMailComposeViewController.canSendMail(), let address = AppInfo.supportEmail {
            let mail = MFMailComposeViewController()
            mail.mailComposeDelegate = context.coordinator
            mail.setToRecipients([address])
            mail.setSubject(FeedbackMessage.subjectLine(version: AppInfo.version, build: AppInfo.build))
            mail.setMessageBody(bundle.body, isHTML: false)
            for url in bundle.files {
                if let data = try? Data(contentsOf: url) {
                    mail.addAttachmentData(data, mimeType: url.pathExtension == "json" ? "application/json" : "text/plain",
                                           fileName: url.lastPathComponent)
                }
            }
            return mail
        }
        let text = FeedbackMessage.shareText(address: AppInfo.supportEmail, body: bundle.body)
        let share = UIActivityViewController(activityItems: [text] + bundle.files, applicationActivities: nil)
        share.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return share
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {}

    final class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func mailComposeController(_ controller: MFMailComposeViewController,
                                   didFinishWith result: MFMailComposeResult, error: Error?) {
            onFinish()
        }
    }
}

/// Troubleshooting's first row (design D4, D9). Gathering is a few small local files (2 MB at
/// most), read in the tap.
struct SendFeedbackRow: View {
    let journal: NightJournal
    let pal: Palette
    @State private var bundle: FeedbackBundle?

    // "Playback events", as the mail says: the page's "Export the playback log" is another file.
    private static let note = "Email with the last \(NightRules.keptNightFiles) nights' playback events."

    var body: some View {
        Button {
            bundle = FeedbackBundle.gather(journal: journal)
        } label: {
            SettingActionRow(title: "Send feedback", systemImage: "envelope", note: Self.note, pal: pal)
        }
        .accessibilityLabel("Send feedback")
        .accessibilityHint(Self.note)
        .contextMenu {
            if let address = AppInfo.supportEmail {
                Button("Copy address") { UIPasteboard.general.string = address }
            }
        }
        .sheet(isPresented: Binding(get: { bundle != nil }, set: { if !$0 { bundle = nil } })) {
            if let bundle {
                FeedbackComposer(bundle: bundle) { self.bundle = nil }
                    .ignoresSafeArea()
            }
        }
    }
}

/// Settings ▸ Backup & support's last section: the lasting thank-you, the tips and Rate
/// (design D4, D8, D17).
struct SupportSection: View {
    @ObservedObject var tips: TipStore
    let pal: Palette
    @State private var rateVisible = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            if tips.hasTipped {
                Text(TipCopy.lastingThanks).foregroundStyle(pal.dim)
            }
            // A phone that can't buy shows no tips at all (the plan's rescue map).
            if tips.purchasesAllowed { TipRows(tips: tips, pal: pal) }
            if rateVisible, let id = AppInfo.appStoreID, let url = RateRowRule.writeReviewURL(appStoreID: id) {
                Button { openURL(url) } label: {
                    SettingActionRow(title: "Rate Sleepulator", systemImage: "star",
                                     note: "On the App Store.", pal: pal)
                }
                .accessibilityLabel("Rate Sleepulator")
                .accessibilityHint("On the App Store.")
            }
        } header: {
            if tips.hasTipped || tips.purchasesAllowed || rateVisible {
                Text("Support Sleepulator").foregroundStyle(pal.dim)
            }
        } footer: {
            // Build identity, moved here from Troubleshooting so it still closes the page.
            VStack(alignment: .leading, spacing: 2) {
                Text("Sleepulator \(AppInfo.versionBuild)")
                if let built = AppInfo.builtAtLabel { Text("Built \(built)") }
            }
            .foregroundStyle(pal.dim)
            .padding(.top, UI.sm)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(AppInfo.accessibilitySummary)
            // On the footer, one view: a Section's modifiers land on each of its rows, so a task
            // there ran once per row, and an onDisappear fired whenever the tip rows gave way to
            // "Thank you" (clearing it at once). Leaving the page is BackupSupportView's.
            .task {
                if tips.products.isEmpty, tips.phase != .loading { await tips.loadProducts() }
                // No App ID, no row: don't ask the App Store for this build's environment.
                guard AppInfo.appStoreID != nil else { return }
                rateVisible = RateRowRule.visible(appStoreID: AppInfo.appStoreID,
                                                  environment: await RateRowRule.currentEnvironment())
            }
        }
    }
}
