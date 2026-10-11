import Foundation

/// Settings' pure rules, unit-tested (`SettingsRulesTests`): how its choices map onto the stored
/// settings, and the words it shows for values.

/// "Soften loud moments", one choice over the two stored flags. It used to be two toggles, one of
/// which ("On while sleeping, off while focusing") disabled the other and left no way to tell
/// which was in charge.
enum LimiterChoice: CaseIterable {
    case off, whileSleeping, always

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

    /// The podcast softening amount in words. The bar starts at `eqFloor`, so it can't be set to
    /// "Off" while its switch is on; a lower value saved by the old 0...2 slider (or an old
    /// backup) still reads "Off": the EQ is negligible there (under 1 dB at the floor).
    static func softening(_ intensity: Double) -> String {
        switch intensity {
        case ..<eqFloor: return "Off"
        case ..<0.8: return "Light"
        case ..<1.3: return "Medium"
        default:     return "Strong"
        }
    }

    static let eqFloor = 0.2

    /// The note under "Don't start the next episode during a sleep timer": what it does, or why
    /// it's off while Auto-Play is.
    static func holdNote(autoPlay: Bool) -> String {
        autoPlay ? "The one playing finishes; your sounds carry on."
                 : "Only applies when the next episode plays automatically."
    }

    /// What VoiceOver says as the hold switch's value: nil while it's enabled (the switch says
    /// On or Off itself); while Auto-Play disables it, its state and why. The reason was only in
    /// the hint, which VoiceOver skips with hints off: a dimmed switch, and no word why.
    static func holdSpokenValue(isOn: Bool, autoPlay: Bool) -> String? {
        autoPlay ? nil : "\(isOn ? "On" : "Off"). \(holdNote(autoPlay: false))"
    }

    /// The note under "Binaural beats for", for the chosen routing.
    static func beatsNote(_ routing: String) -> String {
        switch routing {
        case "headphones": return "One tone in each ear. Needs headphones."
        case "speaker":    return "A gentle pulse that works on a speaker."
        default:           return "True binaural beats in headphones, a gentle pulse on the speaker."
        }
    }
}

/// Stereo width as four named stops. It was a slider showing "66%" at its default (width / 1.5),
/// which read as turned down, and for Pink and Rain the engine clamps the width
/// (`min(0.85 * width, 1)`), so the top fifth of the slider did nothing. Every stop sounds
/// different for every noise.
enum StereoWidth: Double, CaseIterable {
    case mono = 0, narrow = 0.5, natural = 1.0, wide = 1.5

    var title: String {
        switch self {
        case .mono:    return "Mono"
        case .narrow:  return "Narrow"
        case .natural: return "Natural"
        case .wide:    return "Wide"
        }
    }

    /// The stop nearest a stored width (the slider could store any value in 0...1.5). Reading
    /// doesn't write: a width between stops stays as it is until a stop is picked.
    static func nearest(_ width: Double) -> StereoWidth {
        allCases.min { abs($0.rawValue - width) < abs($1.rawValue - width) } ?? .natural
    }
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
