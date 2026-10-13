import XCTest
import StoreKit
import StoreKitTest
@testable import Sleepulator

/// The pure step from a StoreKit outcome to what the tip rows show.
final class TipFlowTests: XCTestCase {
    func testAVerifiedTipThanksOncePerTransaction() {
        XCTAssertEqual(TipFlow.apply(.verified(transactionID: 7), handled: []).phase, .thanked)
        XCTAssertEqual(TipFlow.apply(.verified(transactionID: 7), handled: []).newTip, 7)
        // A replayed transaction (reported in the iOS 27 sandbox): thanked view, no second tip.
        XCTAssertNil(TipFlow.apply(.verified(transactionID: 7), handled: [7]).newTip)
    }

    /// The App Store may have charged an unverified purchase: never "didn't go through" with Try
    /// again (a second charge), never thanked or counted.
    func testAnUnverifiedTransactionIsNeverATipAndNeverInvitesASecondCharge() {
        let step = TipFlow.apply(.unverified(transactionID: 9), handled: [])
        XCTAssertEqual(step.phase, .unconfirmed)
        XCTAssertNil(step.newTip)
    }

    func testCancelPendingAndFailure() {
        XCTAssertEqual(TipFlow.apply(.userCancelled, handled: []).phase, .ready)
        XCTAssertEqual(TipFlow.apply(.pending, handled: []).phase, .pending)
        XCTAssertEqual(TipFlow.apply(.failed, handled: []).phase, .failed)
    }

    /// An update from outside a purchase (an approval, a replay) thanks only for a new tip and
    /// never over a purchase in flight; the purchase's own outcome always shows.
    func testAnUpdateNeverReplacesAPurchaseInFlight() {
        XCTAssertFalse(TipFlow.showsOutcome(fromPurchase: false, newTip: true, over: .purchasing("t")))
        XCTAssertTrue(TipFlow.showsOutcome(fromPurchase: false, newTip: true, over: .ready))
        XCTAssertFalse(TipFlow.showsOutcome(fromPurchase: false, newTip: false, over: .ready))
        XCTAssertTrue(TipFlow.showsOutcome(fromPurchase: true, newTip: false, over: .purchasing("t")))
    }

    /// A phone that can't buy (Screen Time) gets no Try again and no tip; Settings hides the rows.
    func testAPurchaseNotAllowedIsUnavailableNotATip() {
        let step = TipFlow.apply(.notAllowed, handled: [])
        XCTAssertEqual(step.phase, .unavailable)
        XCTAssertNil(step.newTip)
    }
}

/// The real purchase paths against Tips.storekit (CEO D14, TS-1).
///
/// Known Apple bug: on iOS 26 simulators, a command-line test run (xcodebuild, as CI runs) logs
/// "[SKTestSession] Error saving configuration file: SKInternalErrorDomain Code=3" and loads no
/// products (seen here on 26.3; reported on 26.5, Apple forum 826971). These tests then SKIP with
/// that reason, visibly, instead of failing; they run from Xcode (⌘U). The purchase mapping is
/// covered either way by TipFlowTests, and a real purchase by the TESTING.md §3U sandbox step.
/// The skip stays: the user's decision at the pre-landing review (D1, 2026-10-12).
@MainActor
final class TipStoreTests: XCTestCase {
    private var session: SKTestSession!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        session = try SKTestSession(configurationFileNamed: "Tips")
        session.resetToDefaultState()
        session.disableDialogs = true
        session.clearTransactions()
        suite = "tipstore-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        session.clearTransactions()
        super.tearDown()
    }

    static let storeKitUnavailable = "StoreKitTest loaded no products: SKTestSession couldn't save Tips.storekit "
        + "(Apple bug in command-line runs on iOS 26 simulators). Run TipStoreTests from Xcode."

    private func store(startStoreKit: Bool = false) async throws -> TipStore {
        let s = TipStore(defaults: defaults, startStoreKit: startStoreKit)
        await s.loadProducts()
        try XCTSkipIf(s.products.isEmpty, Self.storeKitUnavailable)
        return s
    }

    func testTheThreeTipsLoadInOrder() async throws {
        let s = try await store()
        XCTAssertEqual(s.products.map(\.id), TipStore.productIDs)
        XCTAssertEqual(s.products.map(\.name), ["Small tip", "Kind tip", "Generous tip"])
        XCTAssertEqual(s.phase, .ready)
    }

    func testATipThanksAndIsRememberedOnThisPhone() async throws {
        let s = try await store()
        await s.purchase(TipStore.productIDs[0])
        XCTAssertEqual(s.phase, .thanked)
        XCTAssertTrue(s.hasTipped)
        XCTAssertTrue(defaults.bool(forKey: TipStore.tippedKey))
        s.screenClosed()
        XCTAssertEqual(s.phase, .ready)
    }

    func testAFailedPaymentShowsTryAgainAndIsNotATip() async throws {
        session.failTransactionsEnabled = true
        let s = try await store()
        await s.purchase(TipStore.productIDs[1])
        XCTAssertEqual(s.phase, .failed)
        XCTAssertFalse(s.hasTipped)
    }

    func testAskToBuyWaitsThenThanksWhenApprovedLater() async throws {
        session.askToBuyEnabled = true
        let s = try await store(startStoreKit: true)
        await s.purchase(TipStore.productIDs[2])
        XCTAssertEqual(s.phase, .pending)
        XCTAssertFalse(s.hasTipped)
        s.screenClosed()                                     // the visit ends: no lingering note
        XCTAssertEqual(s.phase, .ready)
        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        // The approval arrives through Transaction.updates, as it would after the app was closed.
        for _ in 0..<50 where !s.hasTipped { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertTrue(s.hasTipped)
    }

    /// An interrupted purchase (the store needs the person to act first) is never a tip until it
    /// completes. A user cancel needs a real dialog, so TipFlowTests covers that mapping.
    func testAnInterruptedPurchaseIsNotATip() async throws {
        session.interruptedPurchasesEnabled = true
        let s = try await store()
        await s.purchase(TipStore.productIDs[0])
        XCTAssertNotEqual(s.phase, .thanked)
        XCTAssertFalse(s.hasTipped)
    }

    func testAnUnknownProductIsUnavailable() async throws {
        let s = try await store()
        await s.purchase("not.a.tip")
        XCTAssertEqual(s.phase, .unavailable)
    }
}
