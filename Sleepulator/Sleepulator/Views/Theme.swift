import SwiftUI

/// Shared design tokens (the reduction pass). Premium here is *fewer* decisions repeated
/// consistently: one shape family and one spacing grid instead of the ad-hoc 9/10/11/13/14/22/30
/// values the control surfaces had drifted into. Two radii only — `cardRadius` for panels and
/// cards, `Capsule()` for everything interactive. Spacing is a strict 4-based module.
enum UI {
    /// The one card radius — GlassPanel, saved-mix cards, queue rows. Interactive controls use
    /// `Capsule()`, never a bespoke radius.
    static let cardRadius: CGFloat = 18

    // 4-based spacing grid. Nothing off-grid.
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 32
}

/// The one primitive that makes reactive controls safe for a sleep app. Any audio-reactive or
/// breathing treatment multiplies its designed motion *depth* by this, so the UI is subtly alive
/// while you build the mix and goes progressively still as the sleep timer winds down — reaching
/// zero motion by fade-out. "The instrument understands it's a sleep app." Modulates depth, never
/// brightness (opacity stays clamped at the call site — the 2am rule).
enum NightDamping {
    /// `nightProgress` 0→1 across the timer; 0 when no timer runs (fully alive). Bedtime → 0
    /// immediately (the pixels-off OLED intent).
    ///
    /// Deliberately NOT gated on system Reduce Motion: per SCREENSAVER-LIBRARY-SPEC §5 the app
    /// runs decorative ambient motion (the orb breath, star twinkle) even under Reduce Motion —
    /// it's slow opacity/scale breath, not vestibular motion, and the sky/orb read dead without
    /// it. The proper opt-out is the spec's pending app-level "Ambient motion" toggle, not this.
    static func factor(nightProgress: Double, bedtime: Bool) -> Double {
        if bedtime { return 0 }
        return max(0, min(1, 1 - nightProgress))
    }
}

enum Theme {
    // Warm Dusk (default) — low-blue-light: amber accent on a warm near-black.
    static let gold     = Color(red: 0.91, green: 0.63, blue: 0.30) // amber #E8A04C
    static let bg       = Color(red: 0.07, green: 0.05, blue: 0.035) // warm near-black
    static let glow     = Color(red: 0.075, green: 0.052, blue: 0.032) // barely-there warmth (reduced again)
    static let text     = Color(red: 0.95, green: 0.89, blue: 0.82) // warm cream
    static let textDim  = Color(red: 0.72, green: 0.60, blue: 0.46) // warm muted

    // Focus — cool + energizing: a crisp cyan accent on deep cool indigo. The opposite
    // mood from the warm sleepy dusk, so the two modes read as different headspaces.
    static let focusAccent = Color(red: 0.32, green: 0.80, blue: 0.98) // electric cyan-azure
    static let focusBg     = Color(red: 0.04, green: 0.06, blue: 0.11) // deep cool indigo-navy
    static let focusGlow   = Color(red: 0.10, green: 0.24, blue: 0.46) // cool blue glow
    static let focusText   = Color(red: 0.93, green: 0.96, blue: 1.0)  // cool white
    static let focusDim    = Color(red: 0.56, green: 0.66, blue: 0.82) // cool muted

    // Deep accents: fills for system controls that always draw a white label (swipe actions).
    // White on the accent itself was 2.18:1 (Sleep) / 1.85:1 (Focus); these keep the hue at AA.
    static let emberDeep = Color(red: 0.52, green: 0.32, blue: 0.13) // white label 6.5:1
    static let focusDeep = Color(red: 0.06, green: 0.36, blue: 0.52) // white label 7.2:1
}

struct Palette {
    let accent: Color
    let bg: Color
    let glow: Color
    let text: Color
    let dim: Color
    /// Warm (dusk / bedtime) vs cool (Focus). Material treatments read this so Sleep glass warms
    /// toward the amber dusk while the Focus mixer stays cool and crisp — the two modes must not
    /// share a material tint.
    let warm: Bool

    static let sleep   = Palette(accent: Theme.gold,        bg: Theme.bg,      glow: Theme.glow,      text: Theme.text,      dim: Theme.textDim, warm: true)
    static let focus   = Palette(accent: Theme.focusAccent, bg: Theme.focusBg, glow: Theme.focusGlow, text: Theme.focusText, dim: Theme.focusDim, warm: false)

    init(accent: Color, bg: Color, glow: Color, text: Color, dim: Color, warm: Bool = true) {
        self.accent = accent; self.bg = bg; self.glow = glow; self.text = text; self.dim = dim; self.warm = warm
    }
    // Home drives its palette by mode: warm Sleep vs cool Focus.
    init(focusMode: Bool) { self = focusMode ? .focus : .sleep }

    /// Fill for swipe actions and other system controls with a fixed white label.
    var actionFill: Color { warm ? Theme.emberDeep : Theme.focusDeep }
}
