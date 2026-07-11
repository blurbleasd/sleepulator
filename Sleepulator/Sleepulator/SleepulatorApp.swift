import SwiftUI

@main
struct SleepulatorApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // MetricKit only accumulates while a subscriber is registered — register at launch,
        // exactly once. Payloads land ~daily; see MetricsCollector for storage + Settings UI.
        MetricsCollector.shared.start()

        // Preflight the Metal scene shaders: log any that didn't make it into the compiled metallib,
        // so a failed shader is a breadcrumb in the overnight trail, not a silent black backdrop (F2).
        MetalShaders.preflight()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
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
