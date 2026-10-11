import Foundation

/// Settings' pure rules, unit-tested (`SettingsRulesTests`): how its choices map onto the stored
/// settings, and the words it shows for values.

/// "Soften loud moments", one choice over the two stored flags. It used to be two toggles, one of
/// which ("On while sleeping, off while focusing") disabled the other and left no way to tell
/// which was in charge.
enum LimiterChoice: String, CaseIterable, Identifiable {
    case off, whileSleeping, always

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off:           return "Off"
        case .whileSleeping: return "While sleeping"
        case .always:        return "Always"
        }
    }

    /// The choice the stored flags express. Following the mode wins: it drives `nightLimiter`.
    static func from(nightLimiter: Bool, byMode: Bool) -> LimiterChoice {
        byMode ? .whileSleeping : (nightLimiter ? .always : .off)
    }

    /// The flags to store. `nightLimiter` is nil when following the mode, which sets it itself
    /// (`AudioEngine.applyLimiterForMode`, on for Sleep and off for Focus).
    var flags: (byMode: Bool, nightLimiter: Bool?) {
        switch self {
        case .off:           return (false, false)
        case .whileSleeping: return (true, nil)
        case .always:        return (false, true)
        }
    }
}

enum SettingsCopy {
    /// "1 minute" / "25 minutes", for VoiceOver (it used to read "1 minutes").
    static func minutes(_ n: Int) -> String { n == 1 ? "1 minute" : "\(n) minutes" }

    /// The podcast softening amount in words. The bar starts at `eqFloor`, so it never reads
    /// "Off" while its switch is on.
    static func softening(_ intensity: Double) -> String {
        switch intensity {
        case ..<0.8: return "Light"
        case ..<1.3: return "Medium"
        default:     return "Strong"
        }
    }

    static let eqFloor = 0.2
}

/// Settings' sections, in the order `SettingsOrder` gives them.
enum SettingsSection: String, CaseIterable, Identifiable {
    case sleep, nightPodcasts, focus, podcasts, sound, display
    var id: String { rawValue }
}

/// Which sections lead in each mode. The current mode's own settings come first, then what both
/// modes share; the other mode's are folded under one row at the end. In Sleep the podcast
/// sections sit together (the night first), since a podcast is often what's playing at bedtime.
enum SettingsOrder {
    static func shown(focus: Bool) -> [SettingsSection] {
        focus ? [.focus, .sound, .display, .podcasts]
              : [.sleep, .nightPodcasts, .podcasts, .sound, .display]
    }

    static func folded(focus: Bool) -> [SettingsSection] {
        focus ? [.sleep, .nightPodcasts] : [.focus]
    }
}
