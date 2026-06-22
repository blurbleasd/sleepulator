# Sleepulator UI/UX v3 — IA cleanup + Home restructure

> **Status note:** Fully implemented. All six UI/UX goals, including the recent "Apple Minimalist" visual overhaul (v4 aesthetics) have been successfully integrated.

Scope: six changes to navigation, the Home (tab 1) screen, and Settings. No audio-engine,
persistence, or model changes. Goal: one calm screen with a clear hierarchy instead of a flat
control panel, and no duplicated/over-named controls.

Conventions:
- "Home" = `Sleepulator/Sleepulator/Views/HomeView.swift` (the `WarmMixerRow` + `TimerSelectionSheet` live here too).
- "Settings" = `Sleepulator/Sleepulator/Views/SettingsView.swift`.
- "Content" = `Sleepulator/Sleepulator/Views/ContentView.swift`.
- "Components" = `Sleepulator/Sleepulator/Views/Components.swift` (holds the existing `ChipRow`).

Hard rules:
- **Do not rename or change any `UserDefaults`/`@AppStorage` keys**, the tab `.tag(0/1/2)` values, the
  `lastMix` save path, `NoiseType.migrate`, or the 80pt mini-player bottom inset. These are wired elsewhere.
- Every change keeps the build green (`xcodebuild`) and `xcodebuild test` passing.
- No new raw color literals in views — use the `Palette` (`pal.accent/.text/.dim/.bg`).

---

## 1 — Clarify navigation & naming

**Problem:** "Mixer/mix" names a tab, a settings screen, a panel, a button, and a saved object.
Tab 1 is labeled **Mixer** but is the home screen; Settings is titled **"Mixer Settings."** Users can't
locate anything. The Podcasts tab icon (`play.circle`) reads as "play," not "library."

**Change:**
- In **Content**, relabel the tab items (keep the `.tag()` values exactly):
  - Tab 0 → `Label("Sleep", systemImage: "moon.stars.fill")` (was `"Mixer"` / `slider.vertical.3`)
  - Tab 1 → `Label("Podcasts", systemImage: "music.note.list")` (was `play.circle`)
  - Tab 2 → `Label("Settings", systemImage: "gear")` (unchanged)
- In **Settings**, `navigationTitle("Settings")` (was `"Mixer Settings"`).
- Reserve the word "Mix/Mixer" for the saved-preset feature only ("Save Mix", "Saved Mixes"). Don't
  introduce any new visible "Mixer" titles on Home.

**Acceptance:** tab bar reads **Sleep / Podcasts / Settings**; no screen is titled "Mixer"; deep-link/
tab-selection logic still works (tag values unchanged).

---

## 2 — One hero, one start (merge "Resume Last Night" into the giant button)

**Problem:** when idle, Home shows **both** the "Resume Last Night" glass card **and** the giant Play
button, and they do different things (giant Play cold-starts noise; Resume restores the full mix). Two
competing starts on the one screen whose job is a single tap.

**Change (Home):**
- **Delete** the entire "Resume Last Night" button block (the `if let lastMix = audio.lastMix, !audio.noiseOn …` card).
- Route the giant button through one helper:
  ```swift
  private func heroTap() {
      if audio.isAnythingPlaying {
          audio.toggleMasterTransport()            // pause everything (snapshots layers)
      } else if let mix = audio.lastMix,
                (mix.noiseOn || mix.binauralOn || mix.podcastUrl != nil) {
          audio.resumeMix(mix)                      // resume last night's full mix (types + volumes + pod)
      } else {
          audio.toggleMasterTransport()             // cold start (default noise)
      }
  }
  ```
  Call `heroTap()` inside the existing animation/haptic wrapper that the button already uses.
- Replace the lone `statusText()` under the button with a context-aware subtitle:
  ```swift
  // playing            -> statusText()
  // idle + lastMix      -> "Resume · \(mix.noiseType.capitalized) + \(mix.binauralPreset.capitalized)"
  // idle + no lastMix   -> "Tap to begin"
  ```
- (Optional) long-press the hero = cold start blank (`audio.toggleMasterTransport()` ignoring `lastMix`).
  Note it but it's not required.

**Acceptance:** idle screen has exactly one start affordance (the hero). Idle tap resumes last night's mix
at the right sound types/volumes; a second tap pauses; a cold install (no `lastMix`) starts default noise.

---

## 3 — Remove duplicated controls from Settings

**Problem:** noise type and binaural preset are selectable on Home **and** again in Settings; playback
speed is in Settings **and** the NowPlayingSheet. Two sources of truth per control.

**Change (Settings):**
- **Delete** the "Ambient Generator" section (noise `Picker`).
- **Delete** the "Brainwave Entrainment" section (binaural `Picker`). Preserve its helpful gloss by adding a
  one-line caption under the Home binaural chips (optional): `Deep · Drift · Relax · Focus`.
- **Remove** the "Playback Speed" `Picker` from the Podcast section — speed stays in the **NowPlayingSheet**
  only (it's a per-listening control, not a global setting).
- **Keep** Auto-Play, Shuffle, Delete Played Episodes, Hide Finished Episodes.

**Acceptance:** each sound/speed control has exactly one home; Settings no longer changes noise, binaural,
or speed.

---

## 4 — Use the `ChipRow` you already built (replace the Home dropdowns)

**Problem:** `WarmMixerRow` picks the sound via a tiny `Menu { Picker }` dropdown, while the nicer
`ChipRow` in **Components** (capsule chips, 44pt targets, accessibility traits) is unused — and it's the
right control for picking a sound in the dark.

**Change (`WarmMixerRow`):**
- The title becomes a plain label showing the current selection (no `Menu`).
- When the layer is **on** and it has options, render chips under the volume slider:
  ```swift
  if let sel = selection, !options.isEmpty, isOn {
      ChipRow(options: options, labels: optionLabels, selection: sel, palette: pal)
          .padding(.top, 4)
  }
  ```
- Chips appear **only when the layer is on** — declutters the resting screen and removes the
  horizontal-chip-scroll-inside-vertical-page-scroll gesture fight at rest. When off, show just the
  current selection label.
- Leave the **podcast** row's `customMenu` (the queue picker) unchanged.
- `selection` binds to `audio.noiseType` / `audio.binauralPreset`, which already `didSet → syncGenEngine`,
  so chip taps switch the sound live.

**Acceptance:** turning a layer on reveals capsule chips; tapping a chip switches the sound immediately;
resting/off shows just the selection label; no noise/binaural dropdown menus remain on Home.

---

## 5 — Give Home a clear three-zone hierarchy

**Problem:** Home is a flat stack of equal-weight `.glassPanel()`s, and two free `Spacer()`s fight the
`ScrollView` + `minHeight: geo.size.height` centering trick, producing inconsistent gaps. Nothing reads
as primary; "Breathing Exercise" carries the same weight as the sleep timer.

**Change (Home body):**
- Remove the two free `Spacer()`s. Drop the `minHeight: geo.size.height` centering (with this much content
  it always scrolls anyway); top-align and control rhythm with explicit section spacing. Keep the trailing
  80pt mini-player inset spacer.
- Group into three zones, in order, with clear spacing:
  - **Z1 — Header:** title + Bedtime toggle, then `playbackNote` (if any).
  - **Z2 — Now (the only high-emphasis zone):** hero button + subtitle, then the **Sleep Timer** button
    directly beneath it.
  - **Z3 — Mix panel:** master/mute + the three layer rows (keep the glass panel).
  - **Then, low emphasis:** Save Mix, then Saved Mixes.
- Demote the secondaries:
  - **Breathing Exercise:** remove from a full `.glassPanel()` button; make it a small icon+text control —
    either a `wind` icon button in the header, or a compact tinted link under the timer. Not a peer of the hero/timer.
  - **Save Mix:** a small secondary button (not a full glass panel), shown **only when `audio.isAnythingPlaying`**
    (don't offer to save an all-off mix).
- Don't glass-panel everything: reserve the glass treatment for the Mix panel and Saved Mixes so they read
  as grouped surfaces; the hero stays panel-less.
- **Coupled refactor (do as part of this):** extract `HeaderBar`, `HeroTransport`, `MixPanel`,
  `SavedMixesList` subviews so `body` isn't a ~300-line nested `ZStack → GeometryReader → ScrollView →
  VStack`, and so an RMS-driven orb update doesn't invalidate the whole tree.

**Acceptance:** scanning top→bottom reads Header → (hero + timer) → mix panel → saved mixes; the hero and
timer are visibly primary; Breathing and Save Mix are visibly secondary; no empty-Spacer gaps; the orb
pulse no longer re-renders the entire screen.

---

## 6 — Tier Settings (cut debug, bury advanced)

**Problem:** Settings mixes everyday prefs with a developer status panel and intimidating proxy/backup tech
front-and-center.

**Change (Settings):**
- **Delete** the "Audio Engine Status / AVAudioEngine Running" section (developer scaffolding — not for a
  shipping build).
- **Top level keeps:** the Podcast prefs (Auto-Play, Shuffle, Delete Played, Hide Finished) and the
  "Night Limiter" toggle.
- **Move into an "Advanced" `DisclosureGroup` (collapsed by default)** — or a `NavigationLink` to an Advanced
  sub-screen:
  - the two proxy URL fields + their reset buttons,
  - Backup & Restore (Export/Import Data).
- Title is "Settings" (per #1).

**Acceptance:** first glance at Settings shows only everyday prefs + Night Limiter; proxy URLs and backup live
under Advanced (collapsed); the engine-status debug row is gone.

---

## Implementation order (group by file to minimize churn)

1. **#1** — Content tab labels/icons + Settings title. Trivial, do first.
2. **#3 + #6 together** — both edit Settings.
3. **#4** — `WarmMixerRow` → `ChipRow`. Isolated.
4. **#2 + #5 together** — both restructure the Home body. Do last (biggest); the subview extraction in #5
   makes #2 easy to slot in.

## Keep stable (re-confirm before commit)
`UserDefaults`/`@AppStorage` keys, tab `.tag(0/1/2)`, `lastMix` save path (`saveLastMix` in
`pauseAll`/`stopAll`), `NoiseType.migrate`, the 80pt mini-player inset.

## Verification gate
- `xcodebuild` green + `xcodebuild test` passing.
- On device: idle Home shows one start; one tap resumes last night's mix at the right types/volumes; a
  layer's chips appear on enable and switch sound live; Settings opens to everyday prefs with Advanced
  collapsed; Bedtime + Reduce Motion still behave; nothing hides behind the mini-player on any tab.
