# Sleepulator — Code Review & Improvement Notes

_Date: 2026-06-22 · Scope: native SwiftUI app under `Sleepulator/` (~7,000 LOC). Static review only — not compiled or run on device._

## Overall

This is a genuinely well-built app. The hard parts — the lock-free render thread, the dual generative-engine + AVPlayer split, interruption/route handling, the MTAudioProcessingTap limiter, the all-night background keep-alive — are handled with real care, and the comments explain the *why* behind the non-obvious choices better than most production codebases.

Notably, the **2026-06-21 audit (`AUDIT-2026-06.md`) has largely been worked through.** Verified as fixed in the current tree: CDATA show-notes parsing, downloads moved to App Support with `isExcludedFromBackup` + LRU cap, `rmsPower` demoted out of `@Published`, split lock-screen play/pause commands, the sleep-timer `didFire` guard, `startEngineSafely` retry + `onEngineError`, the atomic param hand-off (`SLPAtomicIndex` acquire/release), the tap now `passRetained`, `finishedEpisodes` capped at 1000, observer/monitor teardown in `deinit`, search debounce (300 ms + cancel), batched download-state lookup, dead `HeaderBar`/`HeroTransport` removed, deployment target unified to 17.0, ATS scoped + justified, and the privacy manifest extended with `DDA9.1`.

So the notes below are mostly the *remaining* tail of that audit plus new observations — polish, robustness, and where to take it next. Severity: **P1** = real bug / battery cost · **P2** = robustness · **P3** = hygiene.

---

## Remaining correctness / robustness

### P1 — Backup/Restore is unvalidated and restart-gated
`SettingsView` import (lines ~272–313) writes each backup section straight into the backing file or UserDefaults with no schema check, and the `else` branch (`UserDefaults.standard.set(value, forKey: key)`) **blind-writes any unrecognized key** into UserDefaults. A malformed or hostile backup file can therefore write arbitrary keys and undecodable blobs (only saved because `load` returns `nil` on a bad decode). It also tells the user to relaunch instead of reloading in-process.
**Fix:** whitelist keys; validate each section decodes to its expected type *before* committing; reload engine state in-process so no restart is needed.

### P1 — `onChange(of:)` uses the deprecated single-parameter form
`ContentView` (and several views) use `.onChange(of: value) { newValue in … }`, which is deprecated as of iOS 17. It still compiles, but on a 17.0 floor you should move to the zero- or two-parameter form (`{ oldValue, newValue in }`). Cheap to fix and clears the warnings.

### P2 — Silent `try?` on the few remaining session-activation sites
`startEngineSafely` is now solid, but `try? AVAudioSession.sharedInstance().setActive(true)` still appears bare in several resume paths (`AudioEngine.handleInterruption`, `PodcastPlayer.resume`, `GenerativeAudioEngine.resumeIfNeeded`). For a "plays reliably all night" product these are the highest-value places to at least log on failure, since a lost activation race is exactly how the bed goes silent at 3 a.m.

### P2 — Saving a preset overwrites a same-name preset with no confirmation
`AudioEngine.savePreset(named:)` overwrites any existing preset with the same name in the same mode (`mixStore.replacePreset`) silently. Easy data loss if a user reuses a name. Add a "replace existing?" confirmation, or disambiguate the name.

### P2 — Widget target still has no privacy manifest
The app manifest is now in good shape, but `SleepulatorWidget/` has no `.xcprivacy`. The Live Activity widget likely touches no required-reason APIs, so it may pass — but Apple increasingly expects every target to ship one. Add a minimal manifest to be safe.

### P3 — Stray `print()` in audio/network paths
Seven `print()` calls remain (e.g. `PodcastPlayer:314`, `GenerativeAudioEngine:494`, `SettingsView:317`), and there's no `os_log`/`Logger` usage anywhere. Adopt `Logger` (subsystem/category) and strip or gate the debug prints for release.

### P3 — Leftover dev comment in the app entry point
`SleepulatorApp.swift` carries a thinking-out-loud comment ("Wait, SleepulatorApp doesn't hold the engine. Let's post a notification."). Harmless, but worth cleaning.

---

## Architecture & SwiftUI

### `HomeView` is a 1,121-line monolith
It's the single biggest maintainability risk left. It mixes the mode switcher, hero orb, layer pills, mix drawer, scene selector, starfield/shooting-star backdrops, and the save-mix flow in one file. Decompose into a `Views/Home/` folder of focused subviews. Beyond readability, smaller `@ObservedObject`-holding leaves means a state change re-renders less of the tree.

### `AudioEngine` is a deliberately coarse `ObservableObject` — keep pushing high-frequency state out
The `rmsPower` fix and the 1 Hz sleep-timer throttle were the big wins. The remaining pattern worth enforcing: any view that takes `@ObservedObject var audio` but only *acts on* the engine (doesn't display its state) should take a narrower dependency instead — `EpisodeRowView` already models this correctly by taking `PodcastQueueManager` rather than the whole engine. Audit `PodcastDetailView` and `NowPlayingSheet` against this; `PodcastDetailView`'s `visibleEpisodes` filter re-runs whenever *any* engine `@Published` changes, which can re-filter a long episode list during playback ticks.

### `bedtimeMode` is read via `@AppStorage` in 6+ views
Each is an independent observer of the same key. It works, but there's no single source of truth and the key string is duplicated everywhere. Consider lifting shared display config (`bedtimeMode`, scene IDs) into one small `@StateObject` injected via `@EnvironmentObject`.

### Persistence write paths are slightly inconsistent
Some `@Published` setters in `AudioEngine` write UserDefaults synchronously on the main thread (`noiseType`, `binauralPreset`, `beatRouting`…) while the volume setters hop to `storageQueue`. The values are tiny so it's not a real perf issue, but standardizing on one path (all via `storageQueue`, or a thin settings wrapper) removes a class of "why is this one different" questions.

---

## Audio engine specifics

These are minor — the engine is the strongest part of the codebase.

- **Long-run phase precision.** Time-based oscillators use `t = globalFrameCount / sampleRate` (fan hum, ocean/forest/breeze LFOs). Over an 8-hour run the argument to `sin()` grows large and loses a little precision. Inaudible in practice, but wrapping those phases (as the binaural carrier already does) would make it exact and is cheap.
- **`softClip` is applied to noise but not the binaural node.** Fine today because binaural is gain-capped at 0.15 and the downstream `DynamicsProcessor` catches peaks — just worth a one-line comment so it doesn't read as an oversight.
- **The RMS tap's `lastSampleTime` is a captured `var` mutated on the render thread.** Single-reader/single-writer so it's safe, but a `// audio-thread only` note would match the rigor of the rest of the file.

---

## Testing

The pure-logic coverage added since the audit is good — `PodcastParser` (CDATA / duration / dates), `NoiseType.migrate`, queue advance/shuffle, master-transport snapshot, mode reconciliation. Gaps worth closing:

- `testPositionPruneCapsAt100` writes to the real `StorageManager.shared` singleton with a 1-second wall-clock `asyncAfter` wait — slow and order-dependent. Inject a storage path or protocol so it's hermetic and instant.
- No test for `AudioMath.getFadeMultiplier`'s **0.03 floor** while the timer is still running (the keep-alive invariant) — that's a behavior the all-night path depends on; pin it.
- No coverage of `PodcastQueueManager.advanceQueue` in **shuffle + autoplay** mode (only the autoplay-off path is tested).
- The device-test pass described in `CLAUDE.md`'s verification gate still isn't written down anywhere as a checklist. `TESTING.md` still describes the archived web PWA. A short native "screen-locked, full-timer-run, plug/unplug headphones, take a call mid-session" checklist would close the loop the unit tests can't.

---

## What could take it to the next level

Ordered roughly by impact-to-effort.

1. **Interactive Live Activity / lock-screen controls.** The widget is presentation-only. On iOS 17+ you can add `AppIntent`-backed buttons to the Live Activity and Dynamic Island — "+15 min" and "stop now" without unlocking. This is the single most on-brand addition: it directly serves the half-asleep, screen-locked core use case the whole app is designed around.

2. **A "wind-down" / breathing → sleep on-ramp.** `BreathingView` already exists but is standalone. Wire an optional "start with 1 minute of breathing" step into the Sleep play flow that auto-transitions into the mix. Turns two features into one ritual.

3. **Sleep session history + light insights.** You already track timer length and what was playing. Persist a small per-session record (mix, duration, mode) and show a simple "this week" view: nights, average length, most-used soundscape. No HealthKit needed to start; HealthKit "In Bed"/sleep integration is the natural follow-on.

4. **iCloud / CloudKit sync for episode positions, library, and presets.** These are already clean Codable file stores — `positions.json`, `library.json`, `mixes.json`. Syncing resume-position and saved mixes across iPhone/iPad is a high-value, well-scoped addition given the storage is already abstracted behind `StorageManager`.

5. **Custom binaural blends + a real gray-noise EQ.** The generators note several loudness scalars are "tune by ear" first drafts and gray is "a cheap approximation." A small advanced panel (custom carrier/beat, or blend two bands) plus a proper equal-loudness curve for gray would deepen the differentiated audio story that's already this app's strength.

6. **Apple Watch haptic countdown.** For a fully-asleep, non-visual nudge: gentle haptics at the 5-/2-minute marks with a tap-to-extend. Pairs naturally with #1.

7. **Smarter sleep-timer end.** Instead of (or alongside) the manual "+15m", optionally detect motion via `CMMotionManager` and pulse "still awake? tap to extend" rather than cutting off someone who's reading.

8. **Polish tweaks noticed in passing:** animate the episode expand/collapse and the "+15 min" button's appear/disappear (both currently pop); clear stale search results when the Add-Podcast sheet reopens; add a combined VoiceOver label to the layer pills ("Active sounds: rain, delta"); and extend the Dynamic Type adaptation already in the queue rows to the scrubber and speed menu in `NowPlayingSheet`.

---

## Suggested order of attack

1. **Quick, felt immediately:** deprecated `onChange` migration, `print()`→`Logger`, dev-comment cleanup, the two passing-polish animations.
2. **Robustness:** Backup/Restore validation + in-process reload, preset-overwrite confirmation, logging on the remaining session-activation `try?` sites, widget privacy manifest.
3. **Maintainability:** decompose `HomeView`; narrow the `@ObservedObject audio` dependencies (esp. `PodcastDetailView`); centralize `bedtimeMode`.
4. **Next-level features:** interactive Live Activity (#1) → breathing on-ramp (#2) → session history (#3) → sync (#4).

> Carried-over caveat: the engine's correctness can't be proven by XCTest (no real RT thread / audio session). Anything touching the engine, session, limiter, or timer still needs the on-device, installed, screen-locked, full-timer-run verification.

---

## Changes made in this session (2026-06-22)

All shipped-but-unverified-on-device — see the device checklist at the end.

### Podcast list fixes (reported issues)

1. **"Opens from the middle."** In `PodcastDetailView` the artwork/title/Play-All header was the first *scrolling* row of the `List`; combined with the inline title, the always-on search drawer, and the async feed load, the List anchored partway down. Pulled the header out into a fixed, compact bar (`compactHeader`, 88pt reserved artwork + name + episode count + Play All/Shuffle) above an episodes-only `List` (`.plain`), so the list always starts at its top.

2. **"No easy controls."** In `EpisodeRowView`:
   - A single row tap now **plays immediately** (was tap-to-expand, then tap-again-to-play).
   - Show-notes moved to an explicit **chevron button** (only when notes exist), with an animated reveal — reading notes no longer risks starting playback.
   - **Swipe right = Play, swipe left = Queue** on episodes; **swipe right = Play latest** on subscription rows.
   - Added a **"Play"** item to the top of the overflow menu.
   - VoiceOver updated: tap = play, "Show/Hide notes" exposed as a named action.

### New sleep-fit features

3. **End-of-episode sleep timer.** `SleepTimerService` gained a `TimerKind` (`none`/`duration`/`endOfEpisode`); the episode mode is driven by the playback clock via `externalTick(remaining:)` (tracks pause/seek/speed), fades the ambient bed over the final 90 s, and fires the terminal stop once. `AudioEngine.startEndOfEpisodeTimer()` (no-op without a finite-length loaded episode) feeds it from `onTimeUpdate` and stops everything (rather than advancing the queue) when the episode ends. UI: an "End of episode" button in the timer sheet when a podcast is loaded; the "+15m" bump is hidden for episode-bound timers.

4. **Adaptive rewind on resume.** `PodcastPlayer` records the pause time and, on resume, rewinds proportionally to the gap (0 / 3 / 10 / 20 / 30 s across a blink → next-morning). Pure `static adaptiveRewind(forPause:)` with unit tests (`AdaptiveRewindTests`). Benefits the fell-asleep, phone-call-interruption, and headphone-unplug cases.

5. **Fade-in on play/resume.** A ~0.5 s envelope ramps podcast volume from silence on every play/resume, applied through the limiter-tap state (the PostEffects tap bypasses `AVPlayer.volume`); a tap that attaches mid-fade starts at the enveloped level, and `setVolume` honors an in-progress fade.

**Files touched:** `Views/PodcastDetailView.swift`, `Views/LibraryView.swift`, `Views/HomeView.swift`, `Services/PodcastPlayer.swift`, `Services/SleepTimerService.swift`, `Services/AudioEngine.swift`, `SleepulatorTests/AudioStateTests.swift`.

### Podcast quality-of-life (continued, build verified)

6. **Configurable skip interval.** `AudioEngine.skipInterval` (persisted, default 15s) drives `PodcastPlayer`'s skip-back/forward and the lock-screen `MPRemoteCommandCenter` `preferredIntervals` (glyphs stay in sync). The in-app seek buttons (Now Playing + mini-player) use it with dynamic SF Symbols (`gobackward.N`/`goforward.N`), and a picker (10/15/30/45s) was added to Settings → Podcast Queue.

7. **Mark as played / unplayed + unplayed cues.** `PodcastQueueManager.markUnfinished(_:)` inverts `markFinished`. `EpisodeRowView` gained a "Mark as Played/Unplayed" menu item, an unplayed dot before the title (dimmed once played) — seeded from the engine's `finishedEpisodes` via a precomputed `initiallyPlayed` flag, so the row still doesn't observe the engine. Subscription rows now show an unplayed count ("3 unplayed · 120" / "All caught up · 120").

**Additional files touched:** `Services/PodcastQueueManager.swift`, `Views/NowPlayingSheet.swift`, `Views/MiniPlayerView.swift`, `Views/SettingsView.swift`.

### Device verification for the continued batch
- Changing skip interval updates the in-app glyphs, the actual jump distance, and the lock-screen skip buttons' labels.
- Mark played/unplayed reflects immediately in the row (dot/dim), survives relaunch, and interacts correctly with "Hide Finished Episodes"; subscription unplayed counts update after playing/marking.

### Interactive Live Activity (build verified)

8. **+15m / Stop on the lock screen & Dynamic Island.** Added two `LiveActivityIntent`s (`BumpSleepTimerIntent`, `StopSleepTimerIntent`) in the shared `SleepTimerAttributes.swift` (already a member of both app + widget targets via an Xcode-16 synchronized-group exception, so no project-file change). They run in the app's process and post the `BumpSleepulatorTimer` / `StopSleepulatorTimer` notifications, which `AudioEngine` now observes (→ `sleepTimer.bumpTimer()` / `stopAll()`), keeping the widget decoupled from the engine. `ContentState` gained `isEndOfEpisode` so the "+15m" button is hidden for episode-bound timers (and the subtitle reads "Stops when the episode ends"). Buttons render in both the lock-screen view and the Dynamic Island expanded region, gated to iOS 17+.

**Additional files touched:** `Models/SleepTimerAttributes.swift`, `SleepulatorWidget/SleepTimerLiveActivity.swift`, `Services/AudioEngine.swift`, `Services/SleepTimerService.swift`.

### Robustness & hygiene pass (build verified)

9. **Backup/Restore hardened.** Restore now validates every section decodes into its expected Codable type *before* writing (`validatedFileData`), whitelists keys against a single source-of-truth list (`backupScalarKeys` shared with export), and **no longer blind-writes unknown keys** into UserDefaults — a malformed or hostile backup is skipped, not applied. The completion alert reports how many items were imported vs. skipped, and a non-dictionary file now fails cleanly. Also **completed the export key list** — it was silently missing `skipInterval` (added this session) plus `playbackSpeed`, `focusMode`, scene/scene, `bedtimeMode`, `autoNightDim`, `timerMinutes`, and the Pomodoro keys, so backups are now actually complete. (In-process reload instead of the restart prompt remains a future improvement.)

10. **Deprecated `onChange(of:)` migrated.** All single-parameter closures (ContentView ×4, HomeView ×2, LibraryView, SleepulatorApp) moved to the iOS-17 two-parameter form, clearing the deprecation warnings.

11. **Unified logging.** Added `Services/Log.swift` (`Log.audio` / `Log.storage` / `Log.network` over `os.Logger`) and replaced all 7 stray `print()` calls on the audio/storage/network paths — categorized, queryable in Console, and dropped from release output instead of printing all night.

12. **Widget privacy manifest.** Added `SleepulatorWidget/PrivacyInfo.xcprivacy` (no tracking, no collected data, no required-reason APIs) — closes the last submission gap from the original audit. Plus removed the leftover thinking-out-loud comment in `SleepulatorApp`.

**Files touched:** `Views/SettingsView.swift`, `Views/ContentView.swift`, `Views/HomeView.swift`, `Views/LibraryView.swift`, `SleepulatorApp.swift`, `Services/Log.swift` (new), `Services/StorageManager.swift`, `Services/PodcastPlayer.swift`, `Services/GenerativeAudioEngine.swift`, `Services/SleepTimerService.swift`, `SleepulatorWidget/PrivacyInfo.xcprivacy` (new).

### Device verification — robustness pass
- Export a backup, edit the JSON to corrupt one section + add a junk key, re-import: the good sections restore, the corrupt section and junk key are skipped, and the alert reports the skipped count.
- Round-trip a full backup (including skip interval + Pomodoro settings) and confirm everything returns after relaunch.
- Confirm Console.app shows categorized `app.sleepulator` logs and there's no `print` output.

### Device verification — Live Activity
- Start a sleep timer; confirm the Live Activity shows +15m/Stop and the countdown.
- +15m extends the timer (and the on-screen "Still awake?" state) without opening the app; Stop ends everything from the lock screen.
- Start an end-of-episode timer; confirm +15m is hidden and the subtitle reads "Stops when the episode ends."
- Confirm buttons work with the app backgrounded (audio playing) — i.e. the engine receives the notifications.

### Hardening round 2 — self-review, tests, in-process restore (build verified)

13. **Self-review edge cases.** (a) The "End of episode" timer button now only appears when a podcast with a *known, finite* duration is loaded (`hasLoadedEpisode && podcastDuration.isFinite && > 5`), so it can't silently no-op before the duration is known or on a live stream. (b) Skip-control SF Symbols now fall back to the number-less `gobackward`/`goforward` for any interval outside the set iOS ships glyphs for (`skipBackSymbol`/`skipForwardSymbol` on `AudioEngine`), so a non-standard value (e.g. from a hand-edited backup) can't render a blank button.

14. **Closed test gaps.** Added: fade-multiplier 0.03 floor while running + true-zero at/after expiry + custom fade-duration (`AudioMathTests`); shuffle+autoplay advance promotes a random remaining episode to the head and loads it; `markFinished`/`markUnfinished` round-trip; and end-of-episode timer fires its terminal stop exactly once, ignores `bumpTimer`, and the duration timer ignores `externalTick` (`EndOfEpisodeTimerTests`).

15. **In-process Backup restore (no relaunch).** Restore now applies immediately: `StorageManager.flush()` waits out the async writes, then `AudioEngine.reloadAfterRestore()` re-seeds the persisted settings from UserDefaults and reloads the file-backed stores (`PodcastQueueManager.reloadFromDisk`, `MixStore.reloadFromDisk` — handling the legacy `[SavedMix]` mixes.json too —, `PodcastPlayer.reloadPositions`), and posts a notification that `LibraryView` listens for to re-read `library.json`. The restore alert no longer tells the user to restart.

**Files touched:** `Services/AudioEngine.swift`, `Services/StorageManager.swift`, `Services/PodcastQueueManager.swift`, `Services/MixStore.swift`, `Services/PodcastPlayer.swift`, `Views/SettingsView.swift`, `Views/LibraryView.swift`, `Views/NowPlayingSheet.swift`, `Views/MiniPlayerView.swift`, `Views/HomeView.swift`, `SleepulatorTests/AudioStateTests.swift`, `SleepulatorTests/AudioMathTests.swift`.

### Device verification — hardening round 2
- Restore a backup and confirm library, queue, presets, positions, skip interval, and Pomodoro settings all update **without** relaunching.
- Open the timer sheet right after starting a fresh episode (before the first second ticks) — "End of episode" should appear only once duration is known.
- Set skip interval to each option and confirm the glyph + jump distance match.

### Device verification checklist for these changes
- Podcast detail opens at the top (long feed, cached + freshly-loaded); header doesn't crowd the list on a small phone.
- Episode: single tap plays; chevron expands notes without playing; swipe-to-play and swipe-to-queue don't fight the tap gesture in the `List`.
- End-of-episode timer fires right at the boundary, stops all (does **not** roll into the next episode), and the bed fade lands cleanly; verify it tracks a mid-episode pause and a speed change.
- Adaptive rewind feels right after a real phone-call interruption and after an overnight gap.
- Fade-in doesn't fight the sleep-timer night fade; no click/jump when a stream's limiter tap attaches mid-fade.
