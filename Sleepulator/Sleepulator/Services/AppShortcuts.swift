import Foundation
import AppIntents

extension Notification.Name {
    /// Posted by the App Intent / widget deep link; ContentView (which owns the engine)
    /// observes it and calls `AudioEngine.resumeFromShortcut()`.
    static let sleepulatorResumeRequest = Notification.Name("SleepulatorResumeRequest")
}

/// "Start my sleep mix" — resumes the last mix (or starts the default bed) via Siri /
/// Shortcuts / Spotlight. `openAppWhenRun` because the audio engine lives in the UI
/// process and needs an activated audio session; the app opens, the notification below
/// lands, and playback begins with no further taps.
struct StartSleepMixIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Sleep Mix"
    static let description = IntentDescription("Starts your last sleep mix and begins playing.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: .sleepulatorResumeRequest, object: nil)
        return .result()
    }
}

/// Registers the Siri phrases. "Hey Siri, start my sleep mix in Sleepulator" works out of
/// the box; users can re-phrase it in the Shortcuts app.
struct SleepulatorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartSleepMixIntent(),
            phrases: [
                "Start my sleep mix in \(.applicationName)",
                "Start \(.applicationName)",
                "Play my sleep sounds in \(.applicationName)"
            ],
            shortTitle: "Sleep mix",
            systemImageName: "moon.zzz.fill"
        )
    }
}
