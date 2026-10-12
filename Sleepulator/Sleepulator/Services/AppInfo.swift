import Foundation

/// Build identity for the "which build am I actually running?" footer in Settings.
///
/// `version` / `build` come from the bundle (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`). Those
/// are static across manual dev builds (both are `1` today), so on their own they can't tell one
/// build from the next. `builtAt` — the app executable's modification date, i.e. when this build was
/// linked and installed — is what actually distinguishes builds, which is the whole point of the
/// footer: glance at Settings and confirm the phone is running the build you just made.
enum AppInfo {
    /// Running as a unit-test host: services that would write the real stores (the night
    /// journal, the tip store's transaction listener) use throwaway ones. Debug builds only, so
    /// no test path can reach a shipped build.
    static var isUnitTestHost: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    /// Launched by a UI test (`-uiTestIsolated <true/>`): a throwaway night journal and no rating
    /// prompt, so a dev simulator's own nights can't reach the run, nor the run's reach them.
    static var isUITestRun: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "uiTestIsolated")
        #else
        false
        #endif
    }

    /// Where "Send feedback" mails and the support page points. Open input (set before the first
    /// TestFlight build; docs/designs/APP-STORE-LAUNCH-1.0.md, Launch sequence). While nil, Send
    /// feedback opens the share sheet with no address.
    static let supportEmail: String? = nil

    /// The app's numeric App Store ID, from creating its App Store Connect record. Open input;
    /// while nil the "Rate Sleepulator" row stays hidden (design D8).
    static let appStoreID: String? = nil

    /// `CFBundleShortVersionString` (from `MARKETING_VERSION`), e.g. "1.0".
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// `CFBundleVersion` (from `CURRENT_PROJECT_VERSION`), e.g. "1".
    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    /// "1.0 (1)".
    static var versionBuild: String { "\(version) (\(build))" }

    /// When this build was produced: the executable's modification date. On a fresh install this is
    /// effectively "when this build landed on the device," which is exactly the signal for confirming
    /// the running build. `nil` if the attribute can't be read.
    static var builtAt: Date? {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return nil }
        return date
    }

    /// `builtAt` formatted for display (medium date + short time), or `nil` if unavailable.
    static var builtAtLabel: String? {
        guard let d = builtAt else { return nil }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// One-line accessibility summary, e.g. "Version 1.0 (1), built Jul 6, 2026 at 5:32 PM".
    static var accessibilitySummary: String {
        "Version \(versionBuild)" + (builtAtLabel.map { ", built \($0)" } ?? "")
    }
}
