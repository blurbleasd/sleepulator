import Foundation

/// One vocabulary for sound names everywhere a sound is named: Home's status line and pills, the
/// mixer, saved mixes, preset names. Binaural presets are named for what they're for ("Deep"),
/// never their brainwave band ("Delta"): Home's status line used to say "Delta" while the mixer
/// chip said "Deep" for the same sound.
enum SoundNames {
    static let binauralLabels = ["delta": "Deep", "theta": "Drift", "alpha": "Relax",
                                 "beta": "Concentrate", "gamma": "Focus"]

    static func binaural(_ preset: String) -> String { binauralLabels[preset] ?? preset.capitalized }
    static func noise(_ type: String) -> String { type.capitalized }
}
