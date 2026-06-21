import SwiftUI

enum Theme {
    // Warm Dusk (default) — low-blue-light: amber accent on a warm near-black.
    static let gold     = Color(red: 0.91, green: 0.63, blue: 0.30) // amber #E8A04C
    static let bg       = Color(red: 0.07, green: 0.05, blue: 0.035) // warm near-black
    static let glow     = Color(red: 0.075, green: 0.052, blue: 0.032) // barely-there warmth (reduced again)
    static let text     = Color(red: 0.95, green: 0.89, blue: 0.82) // warm cream
    static let textDim  = Color(red: 0.72, green: 0.60, blue: 0.46) // warm muted

    // Bedtime (dimmer) — true OLED black so pixels switch off when the screen is left
    // on overnight (real battery + zero light emission); only the small warm controls stay lit.
    static let bedGold  = Color(red: 0.78, green: 0.50, blue: 0.22)
    static let bedBg    = Color(red: 0.0, green: 0.0, blue: 0.0)
    static let bedGlow  = Color(red: 0.0, green: 0.0, blue: 0.0)
    static let bedText  = Color(red: 0.78, green: 0.70, blue: 0.60)
    static let bedDim   = Color(red: 0.58, green: 0.50, blue: 0.42) // ~5:1 on true black — clears WCAG AA (was 4.15:1)

    // Focus — cool + energizing: a crisp cyan accent on deep cool indigo. The opposite
    // mood from the warm sleepy dusk, so the two modes read as different headspaces.
    static let focusAccent = Color(red: 0.32, green: 0.80, blue: 0.98) // electric cyan-azure
    static let focusBg     = Color(red: 0.04, green: 0.06, blue: 0.11) // deep cool indigo-navy
    static let focusGlow   = Color(red: 0.10, green: 0.24, blue: 0.46) // cool blue glow
    static let focusText   = Color(red: 0.93, green: 0.96, blue: 1.0)  // cool white
    static let focusDim    = Color(red: 0.56, green: 0.66, blue: 0.82) // cool muted
}

struct Palette {
    let accent: Color
    let bg: Color
    let glow: Color
    let text: Color
    let dim: Color

    static let sleep   = Palette(accent: Theme.gold,        bg: Theme.bg,      glow: Theme.glow,      text: Theme.text,      dim: Theme.textDim)
    static let focus   = Palette(accent: Theme.focusAccent, bg: Theme.focusBg, glow: Theme.focusGlow, text: Theme.focusText, dim: Theme.focusDim)
    static let bedtime = Palette(accent: Theme.bedGold,     bg: Theme.bedBg,   glow: Theme.bedGlow,   text: Theme.bedText,   dim: Theme.bedDim)

    init(accent: Color, bg: Color, glow: Color, text: Color, dim: Color) {
        self.accent = accent; self.bg = bg; self.glow = glow; self.text = text; self.dim = dim
    }
    // Legacy initializer — the Bedtime/Wake toggle is gone, so `bedtime` is always false and
    // this yields the warm Sleep palette. Kept so shared utility screens keep compiling.
    init(bedtime: Bool) { self = bedtime ? .bedtime : .sleep }
    // Home drives its palette by mode: warm Sleep vs cool Focus.
    init(focusMode: Bool) { self = focusMode ? .focus : .sleep }
}
