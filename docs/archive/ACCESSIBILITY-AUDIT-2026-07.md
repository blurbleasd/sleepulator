# Accessibility Audit — Sleepulator (native iOS)

**Standard:** WCAG 2.1 AA + Apple HIG · **Date:** 2026-07-04 · **Method:** code-level review of
`Sleepulator/Sleepulator/Views/` (no running app — see "Verify on device" below).

## Summary

The app is in good shape: 109 accessibility annotations across the views, and the patterns that
usually get missed are already handled. One fix was applied in this audit (VoiceOver announcements
for breathing phases); the rest are recommendations, most of them minor.

## Already done well (keep these patterns)

- **Custom volume slider** (`Components.swift`) exposes `.accessibilityRepresentation { Slider(...) }`
  — VoiceOver users get a real adjustable slider despite the custom drag UI.
- **WarmMixerRow** labels the toggle with the layer name and the slider as "\(title) volume";
  decorative icons are `.accessibilityHidden(true)`. At accessibility text sizes the row re-lays-out
  so the fixed-width switch doesn't fight the label.
- **Reduce Motion** is respected where it matters: scene tilt (`HomeView`), backdrops
  (`AmbientScene`, `FocusBackdrop`), mode-switch animation (`ModeSwitcher`), and the breathing
  *text* transition. The breathing pacer's motion is deliberately kept (essential motion —
  WCAG 2.3.3 exemption; it *is* the exercise).
- **Saved-mix cards** use `contextMenu` (whose actions VoiceOver exposes via the Actions rotor),
  with a label ("Apply mix …") and hint.
- **Podcast/Apple Music empty-state rows** (MixPanel) have explicit labels + hints describing
  where the tap leads.
- Timer/mode selection buttons carry `.isSelected` traits (e.g. BreathingView mode pickers).

## Fixed in this audit

| # | Issue | Criterion | Fix |
|---|-------|-----------|-----|
| 1 | Breathing phase changes (Inhale/Hold/Exhale) were visual-only — VoiceOver users couldn't follow the pacer | 4.1.2 / 1.3.1 | `BreathingView` now posts a `UIAccessibility.announcement` on each phase change |

## Recommendations (not yet applied)

| # | Issue | Criterion | Severity | Suggestion |
|---|-------|-----------|----------|------------|
| 2 | OrbButton's idle glow pulse runs under Reduce Motion. The code comments say this is deliberate ("ambient"); it's a slow 4.5 s blur-scale, low risk — but strict HIG reading says gate it | 2.3.3 | Minor | If desired: `@Environment(\.accessibilityReduceMotion)` and skip the `repeatForever` when set. Product call — left as-is because the comment marks it intentional |
| 3 | `minimumScaleFactor` (0.6–0.7) on the breathing instruction and saved-mix names shrinks text for large Dynamic Type users instead of wrapping | 1.4.4 | Minor | Prefer `lineLimit(2)` + layout that tolerates growth; keep scale factor only as last resort |
| 4 | Dim text at `pal.dim.opacity(0.7)` (captions in MixPanel rows, hints) likely lands under 4.5:1 on dark scenes; can't compute exactly from code because scenes are gradients/shaders | 1.4.3 | Minor–Major | Spot-check with Xcode's Accessibility Inspector color-contrast tool on the darkest scene (Bedtime); raise opacity to ~0.85 if it fails |
| 5 | Timer countdown changes aren't announced; a VoiceOver user gets no signal the fade began | 4.1.2 | Minor | Consider one announcement at fade start ("Sleep timer: fading out") — avoid per-second chatter |

## Verify on device (can't be done from code)

VoiceOver focus order in the NowPlaying sheet, actual contrast on shader backdrops, live slider
value announcements during drag, and Dynamic Type at AX5 sizes. Add these to the TESTING.md
device pass if accessibility becomes a release gate.
