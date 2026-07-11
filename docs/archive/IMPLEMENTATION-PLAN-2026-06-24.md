# Sleepulator — Implementation Plan (2026-06-24)

Reconciled against the **current source tree**, the 2026-06-22 code review, the 2026-06-23
ground-up audit, and `REFACTOR-PLAN-observation-slices.md`. This supersedes the earlier
auto-generated plan, most of which re-recommended work that has already shipped.

> **Why a rewrite:** the prior plan was built from the 06-22 review without checking the changelog.
> A large share of it is already in the tree (re-render slices, backup hardening, Live Activity,
> parser/session/concurrency fixes), one item was already tried and deliberately declined, and the
> headline "DSP precision" item is a non-issue on the audio side. The accurate remaining work is
> smaller and differently shaped.

> **Scope (2026-06-24 adjustment):** narrowed to a confident **Now** slice — work that's grounded in
> the current code, low-risk, and free of external dependencies or open decisions. Items that need
> iCloud provisioning, a new Watch target, or a product call (full library/mix sync, advanced audio
> panel, Watch haptics) are moved to **Later** so they don't block the near-term work. The one feature
> kept in Now is the breathing on-ramp (pure reuse, on-brand, no new capability).
>
> **Now:** §2A robustness tail · §2C tests · §2B shader phase fix · §2D `HomeView` decompose ·
> §2E.1 breathing on-ramp · §2F polish (opportunistic).
> **Later (separate plan / needs a decision):** §2B idle freeze · §2E.2 session history ·
> §2E.3 iCloud sync · §2E.4 binaural/gray EQ · §2E.5 smarter-timer prompt · §2E.6 Watch ·
> §2D `bedtimeMode` centralization.

---

## 0. Already shipped — do not redo

Verified present in the current tree (06-22 + 06-23 changelogs):

- **Re-render storms** — `PlaybackProgress` slice, sleep-timer/Pomodoro forwards dropped,
  queue/mixStore repointed (observation-slices Phases 1–3). `LibraryView` narrowed via a
  `Connectivity` child; `SettingsView` narrowed via a `PlaybackSettings` child.
- **Backup/Restore** — schema-validated, key-whitelisted, **in-process reload** (no relaunch).
- **Interactive Live Activity** — `+15m` / `Stop` AppIntents on lock screen + Dynamic Island.
- **Concurrency** — audio-session callbacks now hop to main; `Episode`/`Podcast` Hashable/Equatable
  contract fixed; `SleepTimerService.tick` race closed.
- **Parsing/persistence** — RFC-822 named zones + ISO-8601 dates, Latin-1/Win-1252 CDATA, audio-typed
  enclosure preference, OPML scheme/dedupe/stable-id, per-value position coercion, `writeBoth`
  backup-failure logging, `Net.retry` jitter + cancellation.
- **Battery** — scenes freeze on `scenePhase != .active` and `isLuminanceReduced`; CoreMotion stops
  when inactive; BreathingBloom 30→20 fps; BreathingView phase work made cancellable.
- **Hygiene** — `onChange` two-param migration, `os.Logger` (`Log.audio/storage/network`), widget
  privacy manifest.

> **Stale doc flag:** `CLAUDE.md` still calls `AppConfig.feedProxyUrl` "the only live service." The
> 06-23 audit **removed** `feedProxyUrl` (dead config). Update `CLAUDE.md` to match.

---

## 1. Corrections to the earlier plan

1. **"Wrap `globalFrameCount` so `sin()`/`cos()` don't degrade" — drop the audio half.**
   `globalFrameCount` is a `UInt64`; oscillators read `t = Double(globalFrameCount)/Double(sampleRate)`
   (`GenerativeAudioEngine.swift:231–232`). Over 8 h the count is ~1.4e9 — exact in `UInt64`, and the
   `sin()` argument carries ~1e-8 rad error in `Double`, i.e. inaudible. The 06-22 review says the same
   ("inaudible in practice"). The binaural carrier already wraps. **Only the Metal shaders need a
   fix** (32-bit `float time`) — see 2B.

2. **"Refactor `LibraryView` and `PodcastDetailView` off `@ObservedObject var audio`."** `LibraryView`
   is **already** narrowed (holds `audio` as an unobserved `let`). `PodcastDetailView` was **considered
   and deliberately kept** as a full observer (06-23 audit): it's a pushed detail view, not a tab root,
   and now that progress/timer no longer publish through the engine, its `visibleEpisodes` filter no
   longer re-runs on 1 Hz churn. Narrowing it is low value — leave it unless profiling says otherwise.

3. **"CMMotion auto-resets the timer +15m when you shift in bed" — reframe.** Auto-extending on any
   motion is the wrong behavior (a phone in the bed moves all night → timer never fires; defeats the
   sleep timer). The defensible version (and the 06-23 framing) is a **prompt**: in the fade window,
   if motion suggests the user is still awake/reading, pulse a haptic + "Still awake? tap to extend"
   rather than silently resetting. Opt-in, off by default. CoreMotion plumbing already exists. See 2E.

---

## 2. The plan

Ordered by the project's own "quick → robustness → maintainability → features" sequence. Every item
notes whether it needs the **device gate** (real iPhone, installed, screen locked, full timer run).

### A. Robustness tail (open from 06-22, confirmed still open)

| Item | Files | What / why | Device gate |
|---|---|---|---|
| Preset-overwrite confirmation | `AudioEngine.savePreset` (`:718`, overwrites in place at `:731`), `MixStore.replacePreset`, `HomeView` save-mix UI | Saving a preset with an existing name silently overwrites it (data loss). Add a "Replace existing?" confirm, or disambiguate the name. | No |
| Log the 5 bare `try? setActive(true)` | `PodcastPlayer:325`, `GenerativeAudioEngine:351,582,618`, `AudioEngine:896` | A lost activation race is exactly how the bed goes silent at 3 a.m. `Log.audio` already exists — log on failure (don't change control flow). | **Yes** (resume/interruption paths) |
| Standardize tiny-setting writes | `AudioEngine` (`noiseType`, `binauralPreset`, `beatRouting` write UserDefaults sync on main; volumes hop to `storageQueue`) | Route all through one path (`storageQueue` or a thin settings wrapper). Hygiene; removes "why is this one different." | No |
| Hygiene comments | `GenerativeAudioEngine` (`softClip` not on binaural node; RMS-tap `lastSampleTime` audio-thread-only) | One-line `// audio-thread only` / "binaural is gain-capped, intentional" so they don't read as oversights. | No |

### B. Precision & battery (the real DSP item + the deferred freeze)

- **Shader `float time` wrapped phase.** `*Shader.metal` feed a monotonic 32-bit `time` into per-frame
  dither/twinkle hashes (e.g. `AuroraShader.metal:142,149`: `sin(time*1.7…)`, `hash21(pos+time)`).
  After hours the mantissa coarsens and the anti-OLED-banding dither weakens. Convert to a wrapped or
  higher-precision phase passed from Swift (CPU side keeps full precision; only the value crossing into
  Metal wraps). Apply to all five: Aurora, DeepSpace, StillWater, Embers, RainGlass. **Device gate** —
  needs an on-device A/B over a multi-hour run to confirm the dither holds (Simulator won't show OLED
  banding).
- **Idle-based scene freeze (no timer).** Today freeze is gated on `scenePhase`/AOD. Add an idle
  timeout so a **no-timer** session also freezes/slows after N minutes untouched. Guard against
  freezing a scene the user is actively watching pre-sleep (reset on interaction; respect a "keep
  animating" affordance). Pairs with `reduceMotion` fallbacks for the high-framerate scenes
  (Aurora/RainGlass/Embers). **Device gate** (battery + behavior).

### C. Tests (close the persistence gap — needs fixture isolation first)

- **Make `StorageManager` test-injectable.** `PersistenceMigrator.run()` and the prune test both mutate
  the shared singleton + real file store. Inject a storage path/protocol so tests are hermetic and
  instant. This is the prerequisite for the next two.
- **`PersistenceTests.swift` (new).** Cover `PersistenceMigrator` legacy→current migration (incl. the
  legacy `[SavedMix]` `mixes.json` and mixed-type positions map) and `MixStore` round-trips.
- **Hermetic `testPositionPruneCapsAt100`.** Drop the 1 s wall-clock `asyncAfter`; use the injected path.

### D. Maintainability

- **Decompose `HomeView` (1,488 lines).** Pull `ModeSwitcher`, `OrbButton`, `FocusHero`,
  `FocusSessionReadout`, `SleepStatusLine`, `LayerPills`, the mix drawer, and the scene/starfield
  backdrops into `Views/Home/`. **Note the real payoff:** SwiftUI re-renders on *observed state*, not
  file boundaries — the win comes from each extracted leaf observing *less*, continuing the
  observation-slices direction. Pure structural splitting with the same dependencies buys readability
  only.
- **Centralize `bedtimeMode` (optional, low value).** 7 views each `@AppStorage("bedtimeMode")`. A
  shared `@EnvironmentObject` removes the duplicated key string — **but** `@AppStorage` already gives
  per-key invalidation; a single coarse `ObservableObject` risks the same broad-invalidation trap the
  engine work just fixed. Only do it if the shared object exposes narrow, separately-observed values.
  Honestly marginal; defer unless touching these views anyway.

### E. Features (impact-to-effort; Live Activity already done)

1. **Breathing → sleep on-ramp.** Wire optional "start with ~1 min of breathing" into the Sleep play
   flow, auto-transitioning into the default mix. `BreathingBloomView` already exists; this is reuse,
   low risk. (Answers the earlier plan's open question — yes, hook the existing bloom view.)
2. **Sleep session history + light insights.** Persist a small per-session record (mix, duration,
   mode); show a "this week" view (nights, avg length, top soundscape). No HealthKit to start; HealthKit
   "In Bed" is the natural follow-on.
3. **iCloud sync — scope it to `positions.json` first.** Resume-position across iPhone/iPad is the
   high-value, low-risk slice. Use `NSUbiquitousKeyValueStore` for **positions only** — it's small and
   well under the 1 MB/key + 1 MB-total cap. **Do not** push `library.json`/`mixes.json` through KVS:
   they can exceed the cap and KVS is last-writer-wins (a remote `reloadAfterRestore()` can clobber
   local edits with no merge). Full library/mix sync is a CloudKit-shaped problem — separate, later
   decision. Requires the iCloud capability on the App ID + provisioning. **Device gate** (two-device
   propagation + a conflicting-edit case).
4. **Custom binaural blends + real gray-noise EQ.** Advanced panel for custom carrier/beat (currently a
   fixed mode array) and an ISO 226 equal-loudness curve for gray (currently a cheap approximation).
   Carrier writes **must** go through the atomic double-buffer — never touch the render thread directly.
   **Device gate** (engine path).
5. **Smarter timer end — prompt, not auto-extend.** In the fade window, optionally use CoreMotion to
   detect a likely-awake reader and pulse "Still awake? tap to extend" (haptic). Opt-in, off by default.
   Reuses existing CoreMotion plumbing. **Device gate** + a battery measurement before defaulting on.
6. **Apple Watch haptic countdown.** Gentle haptics at the 5-/2-min marks with tap-to-extend; pairs with
   the Live Activity. Larger scope (Watch target) — last.

### F. Polish batch (from 06-22 #8)

Animate the episode expand/collapse and the `+15m` button's appear/disappear (both currently pop);
clear stale search results when the Add-Podcast sheet reopens; add a combined VoiceOver label to the
layer pills ("Active sounds: rain, delta"); extend the Dynamic Type adaptation already in the queue
rows to the `NowPlayingSheet` scrubber and speed menu.

---

## 3. Now scope — order of attack

No upfront decisions required for any of these; they're grounded in the current tree.

1. **Robustness tail (A)** — preset-overwrite confirm, session-activation logging (5 sites), tiny-write
   standardization, hygiene comments. Small, felt, low risk.
2. **Tests (C)** — storage injection → `PersistenceTests` → hermetic prune. Unblocks safe refactoring.
3. **Shader phase fix (B)** — wrapped `float time` across the five shaders. The one real precision bug.
4. **`HomeView` decompose (D)** — extract leaves into `Views/Home/`, narrowing observation as you go.
5. **Breathing on-ramp (E.1)** — reuse `BreathingBloomView` for ~60 s before the default mix.
6. **Polish (F)** — fold in alongside whatever surface you're already touching.

## 4. Later — needs a decision or a new capability (separate plan)

Pulled out of Now so they don't block the above. Each carries a dependency the Now slice doesn't:

- **iCloud sync (E.3)** — needs the iCloud capability on the App ID + a scope call (positions-only via
  KVS now, or full library/mix sync via CloudKit). Two-device + conflict testing.
- **Custom binaural / gray EQ (E.4)** — engine-path work; wants the device gate and a tuning pass.
- **Smarter-timer prompt (E.5)** — confirm the prompt-don't-auto-extend framing + a battery measurement
  before defaulting on.
- **Sleep session history (E.2)** — product call on what to persist/show; HealthKit follow-on later.
- **Idle-based scene freeze (B)** — a deliberate UX change (don't freeze an actively-watched scene);
  worth doing on its own.
- **Apple Watch haptics (E.6)** — new Watch target; largest scope.
- **`bedtimeMode` centralization (D)** — marginal; only if already touching those views.

## 5. Verification gate (non-negotiable for the marked items)

Per `CLAUDE.md`: anything touching the engine, session, limiter, or timer is validated on a **real
iPhone, installed, screen locked, over a full timer run** — XCTest can't exercise the RT thread or
session. Specifically:

- **Session-activation logging (A):** trigger a real interruption (incoming call) and a headphone
  unplug mid-session; confirm logs appear and audio recovers.
- **Shader phase (B):** multi-hour on-device A/B on an OLED iPhone; confirm dither/banding holds late.
- **Idle freeze (B):** confirm a no-timer session freezes after the timeout and resumes on touch; check
  battery delta.
- **Positions sync (E3):** two devices, confirm propagation **and** a conflicting-edit case doesn't
  clobber.
- **Binaural/gray (E4) & smarter-timer (E5):** full locked timer run; confirm carrier changes are
  click-free and the fade + terminal stop still fire.

State clearly in the changelog when something is shipped-but-unverified-on-device.
