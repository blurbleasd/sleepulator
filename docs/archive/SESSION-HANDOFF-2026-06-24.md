# Session handoff — 2026-06-24

Checkpoint for resuming in a fresh session. Pairs with `IMPLEMENTATION-PLAN-2026-06-24.md`
(the Now/Later plan) and the two audits (`CODE-REVIEW-2026-06-22.md`, `AUDIT-2026-06-23.md`).

**Project gate (unchanged, applies to everything below):** anything touching the engine, audio
session, limiter, or sleep timer must be verified on a real iPhone, installed, screen locked, over a
full timer run. The sandbox is Linux, so nothing here was compiled or run by the agent except where
noted; the user built to device and ran the unit suite (61 green).

---

## 1. Shipped this session

All changes are in the tree. Build status: the user built to phone successfully and ran tests
(61 pass). Device-verification status noted per item.

### Robustness tail
1. **Preset-overwrite confirmation** — `AudioEngine.presetWouldOverwrite(named:)` + a "Replace this
   mix?" alert in `MixDrawer` (HomeView). **Device-verified ✅**
2. **Session-activation logging** — `Log.activateAudioSession(_:)` (new helper in `Log.swift`,
   imports AVFoundation) replaces 5 bare `try? setActive(true)` sites (PodcastPlayer,
   GenerativeAudioEngine ×3, AudioEngine). **Not yet device-verified** (needs a real interruption /
   headphone unplug to confirm logging + recovery).
3. **Tiny-write standardization** — `noiseType` / `binauralPreset` didSets persist via `storageQueue`
   like the volume setters. `beatRouting` left as-is (lives on `PlaybackSettings`, no queue). Invisible.
4. **Hygiene comments** — documented softClip-not-on-binaural and the audio-thread-only
   `lastSampleTime` in `GenerativeAudioEngine`.

### Tests
5. **`StorageManager` injectable** — added `init(directory:)`; `init()` is now a `convenience` that
   delegates with Application Support. Production unchanged.
6. **DI into `PersistenceMigrator` + `MixStore`** — both take injected `storage` (+ `defaults` for the
   migrator), defaulting to the real singletons. Existing call sites unchanged.
7. **Pure prune extraction** — `PodcastPlayer.prunedPositions(_:keeping:cap:)`; `flushPositionsToDisk`
   uses it. `testPositionPruneCapsAt100` rewritten hermetic + 2 boundary tests added (in
   `AudioStateTests`). **Tests pass ✅**
8. **`PersistenceTests.swift` (NEW, 10 tests)** — migrator legacy/positions/library cases + MixStore
   legacy reload, hermetic via temp-dir store + throwaway UserDefaults suite.
   **⚠️ NOT IN THE TEST TARGET YET** — it did not run in the user's suite (61 tests, no
   PersistenceTests). See §3-A.

### Features / fixes
9. **Mix-save re-render change** — `HomeView` holds `mixStore` as plain `let` (was `@ObservedObject`)
   to stop preset saves re-rendering the Metal backdrop. *Turned out NOT to be the crackle cause* but
   is a correct re-render reduction; kept.
10. **Shader dither phase wrap** — `fmod(time, 64.0)` before the `hash21(pos + time)` dither in the
    four gradient shaders (Aurora, StillWater, DeepSpace, Embers). RainGlass untouched (no dither
    line, graceful). **Needs multi-hour OLED A/B** to confirm banding stays suppressed late.
11. **Breathing on-ramp** — opt-in `breathingOnRamp` (Settings → Wind-down, off by default). New
    `BreathingOnRampView` (reuses `BreathingBloomView`, 60s countdown, Start now / Skip). `heroTap`
    in HomeView defers the Sleep-start behind it (never in Focus). Added to backup allowlist.
    **Device-verified ✅**
12. **SMR binaural retired** — Focus is now `alpha → beta → gamma`. Removed from `focusBinaurals`,
    the picker options/labels, and `activeLayers` labels; aliased `smr → alpha` in
    `AudioMath.getCarrierAndBeat` as a legacy backstop. (Per evidence review: SMR weakest-supported,
    near-duplicate of beta.)
13. **Podcast crackle on preset save** — confirmed via bisection: only with a *streaming* podcast,
    on save. Cause: the `mixes.json` encode + double write bursting at the tap alongside the alert
    dismiss + re-render + haptic, disturbing the podcast decode/limiter pipeline (the generative bed
    is robust to it). Fix: `MixStore.persistPresets` now coalesces + defers the write ~0.5s off the
    tap; `reloadFromDisk` cancels any pending write so restore can't be clobbered.
    **Preliminary PASS** ("seems ok"); user still observing.
14. **Bulk-add filtered episodes** — `PodcastQueueManager.addAllToQueue([Episode])` (one mutation,
    skips dupes, returns count) + a header button in `PodcastDetailView` that appends `visibleEpisodes`
    (respects Hide Finished + search). **Not yet device-verified.**
15. **Always-present mini-player** — `MiniPlayerView` restructured into 3 states sharing one chrome:
    loaded (full transport), up-next (queue non-empty, play-queue button), idle ("Nothing playing").
    Now observes `queueManager`; `audio.queueManager` wired through `ContentView`.
    **Not yet device-verified.** See open decision §4.

---

## 2. Files touched this session
- Services: `Log.swift`, `AudioEngine.swift`, `GenerativeAudioEngine.swift`, `PodcastPlayer.swift`,
  `StorageManager.swift`, `PersistenceMigrator.swift`, `MixStore.swift`, `AudioMath.swift`,
  `PodcastQueueManager.swift`.
- Views: `HomeView.swift`, `SettingsView.swift`, `MiniPlayerView.swift`, `ContentView.swift`,
  `PodcastDetailView.swift`, `BreathingOnRampView.swift` (new), `AuroraShader.metal`,
  `StillWaterShader.metal`, `DeepSpaceShader.metal`, `EmbersShader.metal`.
- Tests: `AudioStateTests.swift` (prune tests), `PersistenceTests.swift` (new — needs target add).
- Docs: `IMPLEMENTATION-PLAN-2026-06-24.md`, this file.

---

## 3. Remaining work

### A. Add `PersistenceTests.swift` to the test target (quick, do first)
The file exists on disk but isn't compiled into `SleepulatorTests` (the test folder isn't an
Xcode-16 synchronized group). In Xcode: select the file → File Inspector (⌥⌘1) → Target Membership →
check **SleepulatorTests**. If it's not in the navigator, drag it into the `SleepulatorTests` group.
Re-run; expect ~10 more tests (PersistenceTests suite).

### B. Outstanding device verification (no code, just testing)
- **Session-activation logging (#2):** real call interruption + headphone unplug mid-playback;
  confirm audio recovers and (optionally, via Console filtered on `app.sleepulator`) failures log.
- **Shader dither (#10):** leave a gradient scene running for hours on the OLED phone; confirm no
  banding creep in dark gradients.
- **Crackle (#13):** keep observing on streaming podcasts under load (warm/busy device). If it
  returns: next levers are (a) pause the ambient backdrop while the mix sheet is open, (b) lower the
  preset write QoS. Note in changelog if it recurs.
- **Bulk-add (#14) + mini-player (#15):** queue episodes via the new header button; confirm the
  mini-player shows "Up next · N", the play button starts the queue, and "Nothing playing" appears
  when empty.

### C. HomeView decompose — the last "Now" item (spec below, §5)
Large, mechanical, and best done WITH a build loop (its failure mode is silent scoping/compile
breakage). Not started.

### D. Later bucket (from `IMPLEMENTATION-PLAN-2026-06-24.md` §4 — each needs a decision/capability)
iCloud sync (positions-only via KVS first), custom binaural blends + ISO-226 gray EQ, smarter
sleep-timer "still awake?" prompt (opt-in, CoreMotion), sleep session history, idle-based scene
freeze (no timer), Apple Watch haptics, `bedtimeMode` centralization.

### E. Loose ends
- **Stale `CLAUDE.md`:** still calls `AppConfig.feedProxyUrl` "the only live service," but the
  06-23 audit removed `feedProxyUrl`. Update the CLAUDE.md overview.
- **Polish batch** (plan §2F): animate episode expand/collapse + the +15m button appear/disappear
  (both pop); clear stale search results when the Add-Podcast sheet reopens; combined VoiceOver label
  on the layer pills; extend Dynamic Type to the NowPlayingSheet scrubber + speed menu.

---

## 4. Open decisions for the user
1. **Mini-player on Home:** it's now always-present globally, so the "Nothing playing" bar also sits
   on the Home/sleep screen when idle (it fades with the screensaver). Decide: keep global, or scope
   "always present" to the Podcasts tab and let Home show it only when something's loaded.
2. **Crackle:** is the deferred-write fix sufficient, or pursue the backdrop-pause / QoS levers?
3. **Later bucket order** when ready (iCloud is the biggest; needs the iCloud capability on the App ID).

---

## 5. Spec — HomeView decompose

**Goal:** break `HomeView.swift` (~1,490 lines; holds `HomeView`, `MixDrawer`, `OrbButton`,
`FocusHero`, `FocusSessionReadout`, `SessionButton`, `SleepStatusLine`, `BumpTimerButton`,
`SceneSelector`, `VolumeBar`, `TimerSelectionSheet`, and the swipe/idle-fade logic) into a
`Views/Home/` folder of focused files.

**The real payoff is narrower observation, not the file split.** SwiftUI re-renders on observed
state, not file boundaries — only extracting leaves that observe *less* reduces re-renders. Several
leaves already observe narrowly (`SessionButton`, `BumpTimerButton`, `SleepStatusLine`,
`FocusHero` observe `sleepTimer`/`pomodoro` directly; `MixDrawer` observes `mixStore`). Preserve
that; don't regress any leaf back to observing the whole `AudioEngine`.

**Suggested file split (one type per file under `Views/Home/`):**
- `HomeView.swift` — the root `ZStack` (backdrop + content + swipe gestures + idle-fade + the
  fullScreenCovers/sheets). Keep `heroTap`, `statusText`, `reconcileMotion`, `scenesFrozen`,
  `cycleScene`, idle-fade here.
- `MixDrawer.swift` — the build-mix sheet (incl. the save alert + overwrite confirm + `SavedMixesList`).
- `OrbButton.swift`, `FocusHero.swift` + `FocusSessionReadout.swift` + `CycleDots`, `SessionButton.swift`,
  `SleepStatusLine.swift` + `BumpTimerButton.swift`, `SceneSelector.swift`, `VolumeBar.swift`,
  `TimerSelectionSheet.swift`.

**Constraints / gotchas:**
- The app target is a synchronized group, so new files auto-compile — but `#Preview`s and any
  `private` helpers shared across the extracted types must move or be made accessible.
- `HomeView` holds `mixStore` as a plain `let` (intentional — see the comment there); keep it.
- Don't change which object each leaf observes. After the split, do a `Self._printChanges()` pass
  (temporary) on `HomeView.body` while a timer + podcast run to confirm the per-second re-render
  count didn't go up.
- **Verification:** build after each extraction (compiler catches missed call sites); then the
  device gate — full locked timer run, confirm countdown/bump/backdrop-darkening/mini-player all
  still update and nothing animates that shouldn't.

**Risk:** purely mechanical but voluminous; do it incrementally (one type per commit) with a build
between each, not as one big move.

---

## 6. Quick-start for the next session
1. Read `IMPLEMENTATION-PLAN-2026-06-24.md` (Now/Later) + this file.
2. Do §3-A (add the test file) and run the suite — should be ~71 green.
3. Pick up §3-C (HomeView decompose, spec in §5) or a Later item per the user's §4 decisions.
4. Honor the device-verification gate for anything touching engine/session/timer.
