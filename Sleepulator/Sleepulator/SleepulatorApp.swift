import SwiftUI

@main
struct SleepulatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
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
