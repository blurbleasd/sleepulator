import SwiftUI

@main
struct SleepulatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// The tip jar's store, alive for the whole app: it listens for transactions from launch
    /// (an Ask to Buy approved while the app was closed lands here) and finishes any left over.
    /// Not inside a unit-test host: TipStoreTests' StoreKitTest transactions would reach this
    /// listener too and mark the simulator's app as tipped (NightJournal.makeDefault, likewise).
    @StateObject private var tips = TipStore(
        startStoreKit: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil)

    init() {
        // MetricKit only accumulates while a subscriber is registered — register at launch,
        // exactly once. Payloads land ~daily; see MetricsCollector for storage + Settings UI.
        MetricsCollector.shared.start()

        // Preflight the Metal scene shaders: log any that didn't make it into the compiled metallib,
        // so a failed shader is a breadcrumb in the overnight trail, not a silent black backdrop (F2).
        MetalShaders.preflight()

        // Throw away a restore's Undo copy once its week is up. Reading the Undo date discards an
        // expired one, and only Backup & support read it: a library-sized copy sat in Application
        // Support for as long as nobody opened that page.
        _ = Backup.undoDate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(tips)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                // The engine lives in ContentView, not here, so signal it to flush playback
                // positions to disk via a notification it observes (AudioSessionController).
                NotificationCenter.default.post(name: Notification.Name("AppDidEnterBackground"), object: nil)
            }
        }
    }
}
