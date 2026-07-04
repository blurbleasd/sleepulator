# Implementation notes — timer backstop + multi-layer noise (June 2026)

Two Tier-1 items from `AUDIT-RECOMMENDATIONS-2026-06.md`, implemented in order. **All changes are
inside files already in the Xcode target — no new `.swift` files, so no `project.pbxproj` edits are
required.** I could not build (no Xcode/Swift toolchain in this environment), so everything here is
**review-verified, not compiled or device-tested.** Build, run the unit tests, and verify the audio
paths on a real iPhone before trusting them (see checklist at the bottom).

---

## A. Fail-safe sleep-timer backstop

**Goal:** audio can't keep playing past the timer even if iOS suspends the app through the deadline.

**Files**
- `Services/SleepTimerService.swift`
  - New `SleepTimerBackstopScheduling` protocol + `NotificationBackstopScheduler` (a local
    notification using **provisional** authorization — granted silently, no permission prompt,
    delivered quietly). Injectable via `SleepTimerService.backstop` for testing.
  - Schedules on `startSleepTimer` / `startEndOfEpisode`, reschedules on `bumpTimer`, cancels on
    `cancelTimer` (which the terminal stop already calls).
  - New `reconcileIfExpired()` — fires the terminal stop if a duration timer's deadline passed
    while suspended. End-of-episode timers need no equivalent (the playback clock resumes ticking).
- `Views/ContentView.swift` — `@Environment(\.scenePhase)`; on `.active`, calls
  `audio.sleepTimer.reconcileIfExpired()`.

**Design notes**
- The in-process fade + stop remains the primary path; this is pure defense-in-depth.
- Provisional notifications need no Info.plist key and never nag a user whose timer ended normally
  (we cancel the pending notification on the in-process fire).
- Two independent nets now exist: (1) the quiet notification (user-visible + launch hook), and
  (2) the deterministic foreground reconcile.

**Tests** (`SleepulatorTests/AudioStateTests.swift` → `SleepTimerBackstopTests`): scheduled on
start, cancelled on cancel, moved later on bump, reconcile fires exactly once when expired, no-op
while running, ignores end-of-episode timers. Uses a spy scheduler (no `UNUserNotificationCenter`).

---

## B. Multi-layer noise engine

**Goal:** play up to 3 noise generators at once (rain + brown + fan), the category's most-requested
feature — without touching the proven DSP or the lock-free param hand-off.

**Approach:** one `AVAudioSourceNode` **per layer** (`kMaxNoiseLayers = 3`), summed by the main
mixer. The single-noise DSP is reused verbatim per layer; only the state/param source is
parameterized. Inactive layers **early-out** to a cheap zero-fill, so the common single-layer case
costs almost the same as before (important for all-night battery).

**Files**
- `Services/GenerativeAudioEngine.swift` (rewrite)
  - `AudioRenderParams`: replaced `noiseGain`/`noiseType` with per-layer `layerGainN`/`layerTypeN`.
  - New `NoiseLayerState` (per-layer filter memory + its own RNG + frame counter; layer 0 keeps the
    original seeds so a single layer is byte-identical to before, layers 1/2 get distinct seeds so
    stacking decorrelates instead of summing a +6 dB copy). `AudioRenderState` is now binaural-only
    and owns its **own** fade smoothing (it used to read the noise node's).
  - `makeNoiseNode(index:)` factory; `setNoiseLayers(_:on:)` API; `setNoise` kept as a single-layer
    wrapper. The DynamicsProcessor safety limiter doubles as the catch for an over-hot stacked bed.
- `Models/Models.swift`: new `ExtraNoiseLayer`; optional `extraLayers` on `SoundPreset` + `SavedMix`
  (optional → pre-layering data decodes as `nil`, fully back-compatible).
- `Services/AudioEngine.swift`: `@Published var extraLayers` (persisted JSON, capped at
  `maxExtraLayers = 2`); `buildNoiseLayers()`; add/remove/setType/setVolume; round-tripped through
  `savePreset` / `applyPreset` / `saveLastMix` / `resumeMix` / `reloadAfterRestore`;
  `reconcileSoundsToMode` drops cross-mode layers; `defaultPresetName` includes them.
- `Views/HomeView.swift` (`MixPanel`): extra-layer rows + an "Add sound" button, shown only while
  the noise bed is on. Reuses `WarmMixerRow`; toggling a layer's switch off removes it.

**Invariant preserved:** every `setNoiseLayers` call still routes through `updateParams` on main
(the single-writer rule the double-buffer depends on; DEBUG `dispatchPrecondition` still guards it).

**Tests** (`NoiseLayeringTests`): add respects cap + picks an unused palette sound; preset and
last-mix round-trip extra layers; a pre-layering preset JSON decodes to `nil` and applies cleanly;
mode switch drops a Sleep-only layer.

---

## Device-verification checklist (the part I can't do here)

Per the project's own gate, verify on a **real iPhone, installed, screen locked, over a full run:**

Timer backstop
- [ ] Start a short duration timer, lock, let it expire — audio fades and stops; the quiet
      notification appears only if the in-process stop didn't fire.
- [ ] Background the app through a deadline, then foreground — audio stops immediately (reconcile).
- [ ] Bump (+15m) moves both the in-app countdown and the backstop; cancel clears the notification.
- [ ] End-of-episode timer still stops at the true episode end (unchanged path).

Multi-layer noise
- [ ] Single layer sounds identical to the previous build (layer 0 seeds unchanged).
- [ ] Add rain + brown — both audible, decorrelated, no clipping/pumping; limiter holds peaks.
- [ ] Drag a layer to 0 and back — no click (per-sample gain smoothing); removing a layer is clean.
- [ ] CPU/thermals with 1 layer ≈ pre-change (inactive layers early-out); check 3 layers is acceptable.
- [ ] Headphone plug/unplug (config-change rebuild) keeps all active layers playing.
- [ ] Save a 2-layer preset, kill the app, relaunch, apply it — layers restored. Resume Last Night
      restores layers. Switching Sleep↔Focus drops cross-mode layers.
