# Sleepulator — UI/UX & Design Review

_Date: 2026-06-21 · Heuristic review from the SwiftUI source (not a pixel/device review — I couldn't run it). Grounded in the actual views, theme, and components._

The visual language is genuinely strong: a coherent two-mood system (warm amber "dusk" for Sleep, cool cyan for Focus), real attention to WCAG contrast (the ratios are noted right in the code), thoughtful Dynamic Type handling, VoiceOver labels everywhere, and a calm "art-first" home. The bones are good. Most of what follows is about (a) reconnecting sleep-specific UX that got dropped in the "ambient-minimal" refactor, and (b) consistency polish.

Priority key: **★★★** signature/high-impact · **★★** worth doing · **★** polish.

---

## A. Sleep-specific UX (the highest-leverage stuff)

### ★★★ 1. Bring back a true "bedtime" dim — it's half-built and disconnected
`Theme.swift` defines a full **bedtime palette** (true OLED black `#000`, dimmed gold, lower-luminance text tuned to ~5:1 contrast), and `GlassPanel`, `MiniPlayerView`, `SettingsView`, `EpisodeRowView` all branch on `@AppStorage("bedtimeMode")`. But the comment in `Theme.swift:42` says the toggle was removed — so `bedtimeMode` is always `false` and **all of that is dead, unreachable code.**

This is the single biggest missed opportunity. A sleep app whose screen may stay on all night should have a near-lightless mode. Reconnect it as an *automatic* behavior, not a manual toggle:
- Auto-engage bedtime palette + dim the screen when a sleep timer is running (or after ~60s of no interaction on the Home screen), and lift it on tap.
- True-black means OLED pixels switch off → real battery savings + zero room glow.
- Pair it with #2 below (kill the all-night animations).

If you don't want to restore it, delete the dead palette and all the `bedtimeMode` branches so the code stops implying a feature that isn't there.

### ★★★ 2. Stop animating the screen once the user is settling
The Home screen runs several `repeatForever` animations simultaneously: the orb glow pulse (`blur 32`, 4.5s), a 52-star twinkling starfield, and in Focus a 640pt blurred angular gradient rotating on a 36s loop (`blur 90`). These are GPU-heavy and never stop. Combined with the `rmsPower` re-render storm (see code audit #5), an always-on bedside screen is doing a lot of work to look alive while someone is trying to sleep.

Recommendation: once playback starts (or the timer is set), fade the decorative motion down to static within ~30–60s. It's both calmer *and* better for battery. Reduce Motion users already get static; make "settling down" do the same for everyone.

### ★★★ 3. The "Still Awake? +15m" timer bump is orphaned
`SleepTimerService.bumpTimer()` (+15 min, and it re-lifts the fade) is a lovely sleep feature — but it's only wired into `HeroTransport`, which is **dead code** (the live Home uses `OrbButton`/`MixDrawer` instead). In the current UI, tapping the "30m left" pill just **reopens the timer sheet, which starts a brand-new timer** rather than extending. So the thoughtful "I'm still awake, don't cut out" affordance is effectively unreachable.

Fix: when a timer is active and near expiry, surface a one-tap "+15m" on the Home screen (and ideally as a Live Activity / lock-screen action, since that's where a half-asleep user actually is).

### ★★ 4. Make starting the nightly ritual one tap, not three
The core nightly action is "start my sounds + set a fade timer." Today that's: tap orb (starts last mix) → tap the small "Sleep timer" text → open sheet → pick duration. Consider:
- Remember the last-used timer duration and **auto-apply it** when the user starts a mix (with the bump from #3 as the safety net), or
- A single "Start sleep" control that resumes the last mix *and* arms the last timer together.

`TimerSelectionSheet` already persists `timerMinutes` via `@AppStorage` — you're one step from "just do what I did last night."

### ★★ 5. Master volume + mute are buried in a sheet
The half-asleep "it's too loud" reach is the most likely night-time interaction, but master volume and mute live inside the "Build mix" drawer (`HomeBottomBar`). Hardware volume keys help, but an in-app, always-visible (large, dim) volume control on the Home screen would serve the bedside use case better than hiding it one sheet deep.

---

## B. Navigation & information architecture

### ★★ 6. The Sleep/Focus mode switch is invisible from the tab bar
Mode is a *big* context change — it swaps the entire palette, the sound palette, and the timer type (sleep-fade vs Pomodoro). But it's a small segmented control inside the Home tab, while the tab itself is permanently labeled "Sleep" with a moon icon. In Focus mode you're looking at a "Sleep" tab rendered in cyan. Either reflect the active mode in the tab label/icon, or rename the tab to something mode-neutral ("Home"/"Now").

### ★★ 7. The mixer is one sheet removed from a sound-mixing app's main job
The "ambient-minimal" Home is beautiful, but *all* layer control (noise on/off, type, binaural, podcast level) lives behind "Build mix." Changing your noise type is tap → sheet → chip. For the app's central activity that may be too minimal. The active-layer pills already render under the orb — consider making them tappable (tap a pill to toggle/cycle that layer) so the most common adjustment doesn't require opening the drawer. Keep the full mixer in the drawer for everything else.

### ★ 8. Dead layout code to remove
`HeaderBar` and `HeroTransport` in `HomeView.swift` are fully built but never instantiated. They duplicate concepts (and, per #3, hold the only copy of the timer-bump UI). Salvage the bump, then delete them so there's one source of truth for the Home layout.

---

## C. Interaction details

### ★★ 9. Two-tap-to-play episodes is surprising
`EpisodeRowView` expands the description on first tap and only plays on the second. Most podcast UIs treat a row tap as "open/play" and put notes behind a disclosure. A user tapping an episode expecting it to play gets a wall of show-notes instead. Add an explicit play affordance on the row (a play glyph on the artwork, or the whole row plays while a chevron expands), so playing is always one deliberate tap.

### ★★ 10. Queue reordering uses chevron buttons instead of drag
`NowPlayingSheet` reorders the "Up Next" queue with per-row up/down chevron buttons in a `ScrollView`. Native `List` + `.onMove` drag-to-reorder is the expected gesture and far faster for moving an item several slots. Keep the chevrons as the accessible fallback, but a draggable list is the headline interaction here. (The commit history mentions a "native reorderable queue List" — it looks like that regressed to manual chevrons.)

### ★ 11. Inconsistent sliders
The mixer rows use a custom `VolumeBar` (capsule track, the comment says the stock `Slider` "read as basic"), but `NowPlayingSheet`'s scrubber and `TimerSelectionSheet` still use the stock `Slider`. Pick one. If `VolumeBar` is the house style, use it (or a shared scrubber variant) for the podcast scrubber too, so the app feels of-a-piece.

### ★ 12. Breathing exercise could pace eyes-closed
`BreathingView` is nice (orb + color-shifting Inhale/Hold/Exhale), but the whole point is to do it with eyes closed, and it's purely visual. Add a gentle haptic on each phase change (a soft tap on inhale/exhale) so users can follow the cadence without looking. Also, the 4-7-8 "Hold" phase has no orb movement — a subtle hold-state cue (e.g. a ring) would make the phase legible.

---

## D. Visual system polish

### ★ 13. Glassmorphism on near-black can read muddy
`.ultraThinMaterial` panels over a `#0E0908` background tend toward a low-contrast grey haze, and they're more GPU-expensive than a flat fill. On a dark sleep UI a flat translucent fill (you already use `Color.white.opacity(0.04)` in the bedtime branch) often looks crisper and costs less. Worth A/B-ing by eye on device.

### ★ 14. Focus mode's rotating blurred gradient can pull focus
A 640pt angular gradient at `blur 90` rotating forever is a lot of ambient motion for a *concentration* mode. Consider slowing it further or reducing opacity — Focus should feel calm-alert, and large drifting glows compete with the work the user is there to do. (Also see #2 re: battery.)

### ★ 15. Empty/loading states are uneven
The Podcasts list has a lovely empty state; the Home first-run is a clean "Tap to begin." But `PodcastDetailView` shows bare red error text and a plain spinner, and search has no "no results" state in `AddPodcastSheet`. Bring those up to the same polish (iconified, on-brand messages) so the rougher screens don't undercut the rest.

---

## Suggested order

1. **Reconnect the sleep story:** #1 (auto bedtime dim), #2 (quiet the animations when settling), #3 (rescue the +15m bump). These are what make it feel like a *sleep* app and they're mostly wiring up things that already exist.
2. **Reduce friction for the nightly ritual:** #4 (one-tap start+timer), #5 (reachable volume), #7 (tappable layer pills).
3. **Interaction correctness:** #9 (episode play), #10 (drag-reorder), #11 (slider consistency).
4. **Polish pass:** #6, #8, #12–#15.

Happy to mock any of these up (a redesigned Home with the bedtime dim + reachable timer/volume is a good candidate) or just implement the quick wins — #3 and #8 in particular are small and recover work that's already written.
