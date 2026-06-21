import Foundation
import AppIntents

@available(iOS 16.0, *)
struct StartSleepulatorMixIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Sleepulator Mix"
    static var description = IntentDescription("Starts your Last Night mix in Sleepulator.")
    static var openAppWhenRun: Bool = true
    
    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("StartSleepulatorMix"), object: nil)
        return .result()
    }
}

@available(iOS 16.0, *)
struct SetSleepTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Set Sleepulator Timer"
    static var description = IntentDescription("Sets a sleep timer in Sleepulator.")
    static var openAppWhenRun: Bool = true
    
    @Parameter(title: "Minutes", default: 30)
    var minutes: Int
    
    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: Notification.Name("SetSleepulatorTimer"), object: nil, userInfo: ["minutes": minutes])
        return .result()
    }
}

@available(iOS 16.0, *)
struct SleepulatorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSleepulatorMixIntent(),
            phrases: [
                "Start my \(.applicationName) mix",
                "Play \(.applicationName)",
                "Start \(.applicationName)"
            ],
            shortTitle: "Start Mix",
            systemImageName: "play.circle.fill"
        )
        
        AppShortcut(
            intent: SetSleepTimerIntent(),
            phrases: [
                "Set a \(.applicationName) timer",
                "Set a sleep timer in \(.applicationName)"
            ],
            shortTitle: "Set Timer",
            systemImageName: "moon.stars.fill"
        )
    }
}
