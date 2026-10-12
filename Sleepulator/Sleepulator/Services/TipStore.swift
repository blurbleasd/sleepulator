import Foundation
import Combine
import StoreKit
import os

// The tip jar's store: three consumable tips, nothing unlocked by any of them (guideline 3.1.1).
//
//   SleepulatorApp (@StateObject) ── init ──> listen to Transaction.updates (from launch)
//                                         └─> finish Transaction.unfinished
//                                         └─> load the three products
//   TipRows / the card ── purchase(id) ──> Product.purchase ──> TipFlow.apply (pure) ──> phase
//
// Every StoreKit outcome maps to one phase through `TipFlow`, which the unit tests drive without
// StoreKit; TipStoreTests drives the real flow with StoreKitTest. One tip per transaction id: a
// transaction delivered twice (the iOS 27 sandbox has been reported replaying finished ones)
// finishes again and never thanks twice. "Tipped" is a device-only flag: never in the app's Backup
// file (outside Backup.kinds), so a phone set up from that file forgets it (design D17). A
// device restore from iCloud carries it, as it does any app's preferences.

/// A tip as the views show it.
nonisolated struct TipProduct: Identifiable, Equatable {
    let id: String
    let name: String
    let displayPrice: String
}

/// What the tip rows show.
nonisolated enum TipPhase: Equatable {
    case loading
    /// No products (offline, the Paid Apps agreement not active yet, IDs not set up).
    case unavailable
    case ready
    case purchasing(String)
    /// Ask to Buy: shown for this visit only (design D7); a later approval still thanks.
    case pending
    case thanked
    /// "That didn't go through." with Try again.
    case failed
    /// The App Store finished it but it couldn't be verified: it may have been charged, so no
    /// Try again, and it's never thanked or counted.
    case unconfirmed
}

/// What a purchase came back with, StoreKit-free so the mapping is unit-tested.
nonisolated enum TipOutcome: Equatable {
    case verified(transactionID: UInt64)
    case unverified(transactionID: UInt64)
    case userCancelled
    case pending
    case failed
    /// This phone can't buy (Screen Time, a managed device): the jar hides, nothing to retry.
    case notAllowed
}

/// The pure step: an outcome and the ids already thanked → the next phase, and whether this is
/// a new tip to thank and remember.
nonisolated enum TipFlow {
    static func apply(_ outcome: TipOutcome, handled: Set<UInt64>) -> (phase: TipPhase, newTip: UInt64?) {
        switch outcome {
        case .verified(let id):
            return (.thanked, handled.contains(id) ? nil : id)
        case .unverified:
            return (.unconfirmed, nil)     // never thanked, never counted, never "try again"
        case .userCancelled:
            return (.ready, nil)
        case .pending:
            return (.pending, nil)
        case .failed:
            return (.failed, nil)
        case .notAllowed:
            return (.unavailable, nil)
        }
    }
}

final class TipStore: ObservableObject {
    /// The three tips, smallest first. Created in App Store Connect as consumables; the local
    /// `Tips.storekit` (SleepulatorTests) mirrors them for tests and simulator runs.
    static let productIDs = ["app.sleepulator.Sleepulator.tip.small",
                             "app.sleepulator.Sleepulator.tip.kind",
                             "app.sleepulator.Sleepulator.tip.generous"]
    static let names = ["Small tip", "Kind tip", "Generous tip"]
    static let tippedKey = "tippedOnThisPhone"
    private static let handledKey = "tipTransactionsHandled"

    @Published private(set) var products: [TipProduct] = []
    @Published private(set) var phase: TipPhase = .loading
    /// The tip last tried, for "Try again" after a failure.
    @Published private(set) var lastAttempt: String?
    /// Set by a verified tip on this phone; drives Settings' lasting thank-you (design D17) and
    /// keeps the card from showing. Device-only (outside Backup.kinds).
    @Published private(set) var hasTipped: Bool

    /// False when this phone can't buy (Screen Time's In-app Purchases off, a managed device):
    /// Settings hides the tip rows and the card waits (the plan's rescue map). Re-read on every
    /// load and each time the app comes to the front, since Screen Time can change meanwhile.
    @Published private(set) var purchasesAllowed = true

    private var storeProducts: [String: Product] = [:]
    /// Transaction ids already thanked, oldest first (the last 20 are kept).
    private var handled: [UInt64]
    private var listener: Task<Void, Never>?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, startStoreKit: Bool = true) {
        self.defaults = defaults
        hasTipped = defaults.bool(forKey: Self.tippedKey)
        handled = (defaults.array(forKey: Self.handledKey) as? [NSNumber] ?? []).map(\.uint64Value)
        #if DEBUG
        // The card's UI test (TS-2, EV-2): three fixed products without StoreKit, which a CLI
        // test run on the iOS 26.5 simulator may never load. Compiled out of release builds.
        if defaults.bool(forKey: "uiTestTipProducts") {
            products = zip(Self.productIDs, Self.names).map { TipProduct(id: $0, name: $1, displayPrice: "$0.99") }
            phase = .ready
            return
        }
        #endif
        refreshPurchasesAllowed()
        guard startStoreKit else { return }
        listener = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in
            for await unfinished in Transaction.unfinished {
                await self?.handle(unfinished)
            }
            await self?.loadProducts()
        }
    }

    // Explicit, so nonisolated (CLAUDE.md "Isolated deinits"): tests create and free the store.
    deinit { listener?.cancel() }

    /// Load (or retry) the three products. An empty answer is "unavailable", never a spinner.
    func loadProducts() async {
        if products.isEmpty { phase = .loading }
        refreshPurchasesAllowed()
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            storeProducts = Dictionary(loaded.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            products = Self.productIDs.enumerated().compactMap { index, id in
                storeProducts[id].map { TipProduct(id: id, name: Self.names[index], displayPrice: $0.displayPrice) }
            }
        } catch {
            Log.storage.error("tip products failed to load: \(error.localizedDescription, privacy: .public)")
            products = []
        }
        if case .purchasing = phase { return }
        phase = products.isEmpty ? .unavailable : .ready
    }

    /// Re-read whether this phone can buy. ContentView calls it on every return to the front.
    func refreshPurchasesAllowed() {
        let allowed = AppStore.canMakePayments
        if allowed != purchasesAllowed { purchasesAllowed = allowed }
    }

    func purchase(_ id: String) async {
        // One purchase at a time: a second tap before the rows re-render would open a second
        // payment sheet for a consumable.
        if case .purchasing = phase { return }
        guard let product = storeProducts[id] else { phase = .unavailable; return }
        lastAttempt = id
        phase = .purchasing(id)
        let outcome: TipOutcome
        do {
            switch try await product.purchase() {
            case .success(let verification):
                outcome = await settle(verification)
            case .userCancelled:
                outcome = .userCancelled
            case .pending:
                outcome = .pending
            @unknown default:
                outcome = .failed
            }
        } catch Product.PurchaseError.purchaseNotAllowed {
            Log.storage.error("tip purchase not allowed on this phone")
            purchasesAllowed = false
            outcome = .notAllowed
        } catch {
            Log.storage.error("tip purchase failed: \(error.localizedDescription, privacy: .public)")
            outcome = .failed
        }
        apply(outcome, fromPurchase: true)
    }

    /// Leaving the tip screen: "Waiting for approval" and a finished thank-you don't outlive
    /// the visit (design D7); a later approval arrives through `Transaction.updates`.
    func screenClosed() {
        switch phase {
        case .pending, .thanked, .failed, .unconfirmed: phase = products.isEmpty ? .unavailable : .ready
        default: break
        }
    }

    // MARK: Internals

    private func handle(_ verification: VerificationResult<Transaction>) async {
        apply(await settle(verification), fromPurchase: false)
    }

    /// Finish the transaction either way (a consumable must be finished), and say whether it
    /// was verified.
    private func settle(_ verification: VerificationResult<Transaction>) async -> TipOutcome {
        switch verification {
        case .verified(let transaction):
            await transaction.finish()
            return .verified(transactionID: transaction.id)
        case .unverified(let transaction, let error):
            Log.storage.error("tip transaction unverified: \(error.localizedDescription, privacy: .public)")
            await transaction.finish()
            return .unverified(transactionID: transaction.id)
        }
    }

    private func apply(_ outcome: TipOutcome, fromPurchase: Bool) {
        let step = TipFlow.apply(outcome, handled: Set(handled))
        // A late update (an Ask to Buy approved while closed) thanks; any other update outside a
        // purchase leaves the rows as they are.
        if fromPurchase || step.newTip != nil { phase = step.phase }
        guard let id = step.newTip else { return }
        handled = Array((handled + [id]).suffix(20))
        defaults.set(handled.map { NSNumber(value: $0) }, forKey: Self.handledKey)
        if !hasTipped {
            hasTipped = true
            defaults.set(true, forKey: Self.tippedKey)
        }
    }
}
