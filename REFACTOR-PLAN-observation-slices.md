# Refactor plan — AudioEngine observation slices

**Status: Phases 1, 2 & 3 IMPLEMENTED (unverified — not built here); Phase 4 deliberately skipped.**
The payoff is entirely in SwiftUI re-render behavior, which can only be confirmed on a real device
over a locked all-night run (the `CLAUDE.md` verification gate). Phase 4 (settings) is left
undone per its own recommendation below (large mechanical change, no re-render win).

**Phase 3 implemented (this pass):** dropped the `queueManager` and `mixStore` `objectWillChange`
forwards in `AudioEngine.init`; exposed `mixStore` (was `private`). Repointed every reactive
consumer to observe the child directly:
- Queue: `NowPlayingSheet` gains `@ObservedObject var queue: PodcastQueueManager` (Up Next list);
  `SettingsView` gains the same (the Auto-Play / Shuffle toggles, which bound `$audio.autoPlay`/
  `$audio.shuffleQueue` — plain computed proxies — and now bind `$queue.autoPlay`/`$queue.shuffleQueue`).
  `LibraryView` / `PodcastDetailView` only *act* on the queue in closures (no reactive body read),
  and `EpisodeRowView` already holds the manager as a plain `let` — so those are unchanged.
- Mixes: `HomeView` gains `@ObservedObject var mixStore: MixStore` (the "Resume · …" status reads
  `lastMix`); `MixDrawer` gains the same (`savedPresets` via `modePresets`). `SavedMixesList`
  takes its presets by value, so it re-renders when `MixDrawer` does — no change needed.
- Construction sites updated: `ContentView` (HomeView, SettingsView), `MiniPlayerView`
  (NowPlayingSheet), `HomeView` (MixDrawer). No `#Preview` blocks to update.

**Phases 1 & 2 implemented (earlier session):**
- Phase 1 — `PlaybackProgress` slice: `Services/PlaybackProgress.swift`; `AudioEngine` writes the
  slice and exposes non-published passthroughs; `MiniPlayerView` + `NowPlayingSheet` observe it;
  `ContentView` wires it through.
- Phase 2 — timers no longer forwarded: `AudioEngine.init` drops the `sleepTimer`/`pomodoro`
  forwards; `ContentView` drives night-dim off `sleepTimer.$timerRemaining` with a
  transition-tracked `@State`; HomeView's `SessionButton` / `SleepStatusLine` / `BumpTimerButton`
  leaves observe the timer directly; `AmbientScene` gains a `NightDarken` leaf so the sky-darkening
  keeps updating. The Pomodoro readouts already observed the service directly.

> **Revision — adversarial review (folded in below).** A pre-implementation review caught three
> defects in the first draft of Phase 2, now corrected here:
> 1. **Dim-scheduling blocker.** Driving `scheduleDim()` from `.onReceive($timerRemaining)` would
>    cancel/reschedule the 60 s night-dim work item every second → it would never fire. Phase 2b
>    now uses a transition-tracked `@State` so the side-effect runs only on the 0-crossing.
> 2. **Backdrop-freeze regression.** The sleep sky-darkening overlay reads the computed
>    `nightProgress` in a plain modifier and only updates because HomeView re-renders each second
>    today. Dropping the timer forward freezes it. Phase 2 now extracts it into a leaf that
>    observes the timer (new step 2d).
> 3. **Incomplete HomeView surgery.** The per-second reads are `sessionButton` (`HomeView:60,67,68,71`),
>    `statusText` (`90-91`), and the bump control (`191`) — all enumerated and mandated below.
>
> Confirmed *safe* (no change needed): the Pomodoro UI (`FocusHero`, `FocusSessionReadout`,
> `CycleDots`, `HomeView:340-438`) already holds `@ObservedObject var pomodoro` and observes the
> service directly, so dropping the pomodoro forward doesn't freeze it. Construction sites are
> exactly two (`ContentView:80`, `MiniPlayerView:93`) with no `#Preview` blocks.

---

## The problem

`AudioEngine` is a single coarse `ObservableObject`. *Any* `@Published` change on it — or on any
child whose `objectWillChange` it forwards — invalidates **every** view holding
`@ObservedObject var audio: AudioEngine`. Two sources fire continuously all night:

1. **Podcast progress, ~1/sec** (3 writes per tick).
   `AudioEngine.swift:127-129` declares `@Published podcastProgress / podcastElapsed /
   podcastDuration`; the player's time observer writes all three every second
   (`AudioEngine.swift:304-307`, driven by `podPlayer.onTimeUpdate`).

2. **Sleep timer, ~1/sec** (throttled to whole seconds).
   `SleepTimerService` publishes `timerRemaining`; `AudioEngine.swift:260` forwards its
   `objectWillChange` into the engine's own.

Every second, both invalidate `ContentView` (holds `@StateObject audio`, reads
`audio.sleepTimer.timerRemaining` at `ContentView.swift:13`), which re-runs the whole `TabView`,
plus `HomeView`, `LibraryView`, `SettingsView`, and `MiniPlayerView` (each `@ObservedObject var
audio`). The big offenders are already mitigated (`rmsPower` is not `@Published`; the timer
republish is throttled to 1 Hz; `EpisodeRowView` observes only `queueManager`) — this finishes
the job by routing each high-frequency value to a narrow slice only the views that show it
observe.

### Current forwards (`AudioEngine.swift:259-262`)
```
queueManager.objectWillChange → self   // user-action frequency
sleepTimer.objectWillChange   → self   // ~1/sec while a timer runs   ← Phase 2
pomodoro.objectWillChange     → self   // ~1/sec while focusing       ← Phase 2
mixStore.objectWillChange     → self   // user-action frequency        ← Phase 3
```

### High-frequency consumer call sites (the map)
| Value | Read by | Needs live 1 Hz? |
|---|---|---|
| `podcastProgress` | `MiniPlayerView:16,20`, `NowPlayingSheet:125` | Yes (only these two) |
| `podcastElapsed`  | `NowPlayingSheet:138,141,144` | Yes |
| `podcastDuration` | `NowPlayingSheet:138,141,144`, `HomeView:1100` (visibility check only) | NowPlaying yes; HomeView no |
| `sleepTimer.timerRemaining` | `ContentView:13,30`, `HomeView:71,90-91,191` | ContentView via side-effect; HomeView only the readout/bump leaves |
| `pomodoro.remaining/isRunning` | `HomeView:60,67-68` | Only the focus-hero leaf |
| `sleepTimer.nightProgress` | `AmbientScene:51` (backdrop) | Yes, but already isolated to the scene |

Low-frequency state stays on `AudioEngine` and keeps working unchanged: `isPodPlaying`,
`podTitle`, `playbackNote`, `hasLoadedEpisode`, `focusMode`, `ambientScreensaver`, all the
persisted settings. They flip a few times a night, not continuously.

---

## Principle

Separate **high-frequency** observable state (progress, timer countdown) from **low-frequency**
state. Put each high-frequency group in its own `ObservableObject` that `AudioEngine` owns but
does **not** forward, and have only the leaf views that render it hold `@ObservedObject` on that
slice. Everything else stays on `AudioEngine`.

---

## Phase 1 — extract `PlaybackProgress` (highest value, smallest blast radius)

Removes the ~3-writes/sec whole-tree invalidation. Touches `AudioEngine`, `MiniPlayerView`,
`NowPlayingSheet`, and the one line in `ContentView` that wires the mini-player. **HomeView is
not touched** (its `podcastDuration` read becomes a non-published passthrough).

### 1a. New file `Services/PlaybackProgress.swift`
(The app folder is a filesystem-synchronized group, so a new file is auto-included in the target.)
```swift
import Foundation
import Combine

/// High-frequency podcast playback position, isolated so the ~1/sec time-observer updates
/// invalidate only the now-playing views — not every view holding the AudioEngine. AudioEngine
/// owns this and writes it from the player's time observer, but deliberately does NOT forward its
/// objectWillChange.
final class PlaybackProgress: ObservableObject {
    @Published var progress: Double = 0.0   // 0…1
    @Published var elapsed: Double = 0.0     // seconds
    @Published var duration: Double = 1.0    // seconds (1.0 sentinel until known)
}
```

### 1b. `AudioEngine.swift` — replace the stored published trio with the slice
Remove (lines 127-129):
```swift
@Published var podcastProgress: Double = 0.0
@Published var podcastElapsed: Double = 0.0
@Published var podcastDuration: Double = 1.0
```
Add (near the other child stores, e.g. by `queueManager`/`sleepTimer`):
```swift
let playbackProgress = PlaybackProgress()   // NOT forwarded — see init
```
Add non-published passthroughs so existing internal/HomeView readers compile unchanged and read
the current value without subscribing to 1 Hz updates:
```swift
// Read-only passthroughs. Plain computed (not @Published): reading them never subscribes a view
// to the 1 Hz progress stream — only PlaybackProgress observers (the now-playing views) do.
var podcastProgress: Double { playbackProgress.progress }
var podcastElapsed: Double { playbackProgress.elapsed }
var podcastDuration: Double { playbackProgress.duration }
```
Rewrite the time-observer handler (lines 301-316) to write the slice:
```swift
podPlayer.onTimeUpdate = { [weak self] elapsed, duration in
    DispatchQueue.main.async {
        guard let self = self else { return }
        self.playbackProgress.elapsed = elapsed
        self.playbackProgress.duration = duration
        if duration > 0 { self.playbackProgress.progress = elapsed / duration }
        if duration > 0, self.sleepTimer.isEndOfEpisode {
            let speed = max(0.1, self.playbackSpeed)
            self.sleepTimer.externalTick(remaining: max(0, (duration - elapsed) / speed))
        }
    }
}
```
The two internal readers already use the passthroughs by name, so they need no change:
- `startEndOfEpisodeTimer()` (lines 655-657): `podcastDuration` / `podcastElapsed` now resolve to
  the slice via the computed vars. ✓
- `seekPodcast(to:)` (line 666): `progress * podcastDuration` likewise. ✓

**Do not** add a forward for `playbackProgress` in the `init` sink block (lines 259-262). That
omission is the whole point.

### 1c. `MiniPlayerView.swift` — observe the slice
```swift
struct MiniPlayerView: View {
    @ObservedObject var audio: AudioEngine
    @ObservedObject var progress: PlaybackProgress   // NEW
    @Binding var selectedTab: Int
    ...
```
Line 16 & 20: `audio.podcastProgress` → `progress.progress`. Pass it through to the sheet (1d).

### 1d. `NowPlayingSheet.swift` — observe the slice
Add `@ObservedObject var progress: PlaybackProgress`. Replace:
- line 125 `audio.podcastProgress` → `progress.progress`
- line 138 `audio.podcastElapsed` / `audio.podcastDuration` → `progress.elapsed` / `progress.duration`
- line 141 `scrubProgress * audio.podcastDuration : audio.podcastElapsed` → `... progress.duration : progress.elapsed`
- line 144 same substitution

### 1e. Wire the slice through `ContentView` and the mini-player
`ContentView.swift:80`:
```swift
MiniPlayerView(audio: audio, progress: audio.playbackProgress, selectedTab: $selectedTab)
```
`MiniPlayerView.swift:93` (where it presents the sheet):
```swift
NowPlayingSheet(audio: audio, progress: progress, isPresented: $showNowPlaying, pal: pal)
```
`ContentView` reads `audio.playbackProgress` only to pass the reference down — it does not read
`.progress/.elapsed/.duration`, so `ContentView.body` is **not** subscribed to the 1 Hz stream.
`HomeView:1100` keeps reading `audio.podcastDuration` (now a passthrough) — fine for a
visibility check; it just won't re-render at 1 Hz for it.

### Phase 1 result
The per-second progress writes now invalidate only `MiniPlayerView` and (when open)
`NowPlayingSheet`. `HomeView`/`LibraryView`/`SettingsView`/`ContentView` no longer re-render for
podcast progress.

---

## Phase 2 — stop forwarding the timers (corrected)

Removes the remaining ~1/sec whole-tree invalidation while a sleep timer or Pomodoro runs. The
Pomodoro half is mostly done already (its readouts observe the service directly); the work is
giving the **sleep timer** the same leaf treatment, fixing the backdrop overlay, and fixing
ContentView's dim scheduling. **Do these together** — dropping the forward (2a) without 2b–2d
*will* regress the dim and the sky-darkening.

### 2a. Drop the forwards
`AudioEngine.swift:260-261`: delete the `sleepTimer.objectWillChange` and
`pomodoro.objectWillChange` sinks. (`SleepTimerService` and `PomodoroService` are already
`ObservableObject`s, so views can observe them directly.)

### 2b. `ContentView` — dim-scheduling by transition, not per-tick  *(fixes blocker #1)*
`ContentView` re-renders every second because `onChange(of: timerActive)` evaluates
`timerActive` (reads `audio.sleepTimer.timerRemaining`) on every body pass, and the forward makes
the body run each tick. After 2a the forward is gone, but we still must drive `scheduleDim()`.
**Do NOT** call `scheduleDim()` on every published value — `scheduleDim` cancels and reschedules
a 60 s `DispatchWorkItem` (`ContentView:26-35`), so calling it ~1/sec means the dim never fires.
Track the active *transition* instead:
```swift
@State private var timerWasActive = false
...
.onReceive(audio.sleepTimer.$timerRemaining) { remaining in
    let active = remaining > 0
    guard active != timerWasActive else { return }   // only act on the 0-crossing
    timerWasActive = active
    if active { scheduleDim() } else { cancelDim() }
}
```
Remove the old `.onChange(of: timerActive)` (lines 103-105). `homeScreensaver` (reads
`ambientScreensaver`, low-frequency) is unchanged. `scheduleDim`'s internal
`timerRemaining > 0` re-check (line 30) is a direct read, not an observation — fine. The
`timerActive` computed (line 13) may stay (used only inside handlers, not body) or be inlined.

### 2c. `HomeView` — move ALL inline per-second reads into leaves  *(fixes incompleteness #3)*
Every one of these reads currently lives in `HomeView.body`'s dependency graph and must move out,
or HomeView keeps re-rendering each second:

| Read | Location | Fix |
|---|---|---|
| `pomodoro.isRunning`, `pomodoro.remaining` | `sessionButton` `:60,67,68` | make `sessionButton` a leaf taking `@ObservedObject var pomodoro` + `@ObservedObject var sleepTimer` (it switches on `focusMode`, so it needs both) |
| `sleepTimer.timerRemaining` | `sessionButton` `:71` | same leaf |
| `sleepTimer.timerRemaining` (minute) | `statusText()` `:90-91`, called at `:177` | move the countdown into a `SleepTimerStatusText` leaf, OR drop the live minute from the status line (it doesn't need per-second precision) |
| `sleepTimer.timerRemaining` (×2) | bump control `:191` | extract `BumpTimerButton` leaf taking `@ObservedObject var sleepTimer` |

Leaf template (mirrors the existing `FocusHero` pattern at `HomeView:340-344`):
```swift
private struct SessionButton: View {
    @ObservedObject var sleepTimer: SleepTimerService
    @ObservedObject var pomodoro: PomodoroService
    let focusMode: Bool
    let pal: Palette
    let onTapSleep: () -> Void
    var body: some View { /* lines 64-78 verbatim, reading the two @ObservedObjects */ }
}
```
Pass the services in: `SessionButton(sleepTimer: audio.sleepTimer, pomodoro: audio.pomodoro, focusMode: audio.focusMode, …)`.
Note `focusMode` is passed as a plain value, so HomeView (which observes `audio`) still re-renders
on a *mode switch* — that's correct and low-frequency.

### 2d. Fix the sleep-backdrop darkening freeze  *(fixes regression #2)*
`AmbientScene.swift:50-53` (NightSkyScene) applies `Color.black.opacity(ctx.sleepTimer.nightProgress * 0.35)`
as a plain modifier. `nightProgress` is computed from `@Published timerRemaining/timerTotal`
(`SleepTimerService:25-28`), and the overlay only re-evaluates when `makeBackdrop`'s caller
(HomeView) re-renders. Once Phase 2 stops HomeView's per-second renders, this freezes. Wrap it in
a leaf that observes the timer, so it re-renders on its own:
```swift
private struct NightDarken: View {
    @ObservedObject var timer: SleepTimerService
    var body: some View {
        Color.black
            .opacity(timer.nightProgress * 0.35)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}
```
In `NightSkyScene.makeBackdrop`, replace the inline `Color.black…` (lines 50-53) with
`NightDarken(timer: ctx.sleepTimer)`. (The `SceneContext` already carries `sleepTimer`, so no
signature change.) Audit any other `nightProgress`-driven sleep visual (a setting moon, if one is
added) for the same pattern — if it's a plain modifier, it needs the same leaf.

### Phase 2 result
A running sleep timer re-renders only `SessionButton`, the status/bump leaves, and `NightDarken`;
Pomodoro re-renders only its existing leaves. `HomeView.body`, `ContentView.body`, and the other
tabs no longer re-render each second.

---

## Phase 3 — repoint queue / saved-mixes (lower urgency)

`queueManager` and `mixStore` change at user-action frequency, so their forwards
(`AudioEngine.swift:259,262`) are not all-night storms — but removing them tightens the graph.

- Drop the two forwards.
- `LibraryView` and the queue UI in `NowPlayingSheet` already reach
  `audio.queueManager.*` — give those views `@ObservedObject var queue: PodcastQueueManager`
  (passed `audio.queueManager`) and read through it, so queue edits invalidate only those views.
  (`EpisodeRowView` already does exactly this — follow its pattern.)
- The saved-mixes list observes `mixStore`. Since `mixStore` is `private` on `AudioEngine`, expose
  it (or, cleaner, keep the existing `savedPresets`/`lastMix` passthroughs but have the
  saved-mixes view take the `MixStore` directly). This is the only API-surface change in the plan.

Defer Phase 3 until 1–2 are verified; it's polish, not a storm fix.

---

## Phase 4 — settings slice (optional, low value)

The persisted settings (`noiseVolume`, `binVolume`, `masterVolume`, `stereoWidth`, `beatRouting`,
EQ/limiter flags, etc.) change only on user interaction, so grouping them into a `SettingsStore`
buys little re-render benefit and is a large mechanical change (every `audio.x` settings read +
the `didSet`-to-UserDefaults plumbing moves). **Recommend not doing this** unless a future
profiling pass shows settings churn — list it here only for completeness.

---

## Verification (per phase)

1. **Build** the `Sleepulator` scheme (iOS 17+) after each phase; fix any missed call site the
   compiler flags (the passthroughs in 1b are designed to keep readers compiling).
2. **Re-render audit (Simulator, fast):** temporarily add `let _ = Self._printChanges()` at the
   top of `HomeView.body`, `MiniPlayerView.body`, and `ContentView.body`. With a podcast playing
   and a sleep timer running:
   - Before: all three log roughly every second.
   - After Phase 1: `HomeView`/`ContentView` stop logging for progress; `MiniPlayerView` still
     logs ~1/sec (correct — it shows the bar).
   - After Phase 2: `HomeView`/`ContentView` stop logging for the timer too; only the readout
     leaves do. Remove the `_printChanges` lines before shipping.
3. **Instruments (SwiftUI / Core Animation):** confirm the per-second commit count on the Home
   tab drops to ~0 while a timer + podcast run.
4. **Device gate (required before relying on it):** install on a real iPhone, lock the screen,
   run a full sleep-timer fade to terminal stop with a podcast playing. Confirm specifically:
   - countdown readout still ticks (`SessionButton` / status leaf),
   - **the sky gradually darkens** as the timer winds down (the `NightDarken` regression check —
     watch it over a couple of minutes, not just at the ends),
   - the bump (+15m) control still appears in the last 2 minutes and works,
   - fade + terminal stop still fire,
   - mini-player bar still moves and the Now Playing scrubber still tracks,
   - in Focus mode: the Pomodoro ring, countdown, and cycle dots still update each second.
   The refactor must not change any of these — only *which* views re-render to produce them.

---

## Risk & rollback

- **Main risk:** a moved value stops updating because a view observes the wrong object. The
  `_printChanges` audit plus a visual check of each readout catches this immediately.
- **Each phase is independent and revertible** — Phase 1 alone is a complete, shippable win; stop
  there if time-boxed.
- **No audio-thread, session, limiter, or timer-logic changes** — this is purely the SwiftUI
  observation graph. The timer's tick math, fade curve, and terminal-stop path are untouched
  (Phase 2 only changes *who subscribes* to `timerRemaining`, not how it's produced).
- **API surface:** only Phase 3 exposes `mixStore`; Phases 1–2 add one new file and one
  constructor argument to `MiniPlayerView`/`NowPlayingSheet`.

## Suggested order
Phase 1 → verify on device → Phase 2 → verify on device → (optional) Phase 3. Skip Phase 4.
