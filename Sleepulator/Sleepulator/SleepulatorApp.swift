import SwiftUI

@main
struct SleepulatorApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                // Post notification to flush, or we can just access it.
                // Wait, SleepulatorApp doesn't hold the engine. Let's post a notification.
                NotificationCenter.default.post(name: Notification.Name("AppDidEnterBackground"), object: nil)
            }
        }
    }
}
