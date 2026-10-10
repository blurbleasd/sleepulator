# SLEEPULATOR — agent guide

A native SwiftUI iOS app for falling asleep and focusing: layer generative ambient noise +
binaural beats, optionally mix in a podcast, and set a sleep timer that fades everything out.
Two moods — **Sleep** (warm "dusk") and **Focus** (cool, Pomodoro). Built for the hard case
that drives most decisions: **installed on iPhone, screen locked, playing all night.**

> The original React/Vite **PWA is archived** in `archive_webapp/` (not built or deployed).
> The server-side "Sleep Safe" ffmpeg proxy is **gone**, replaced by an on-device Night
> Limiter (see `AUDIO-LIMITER-SPEC.md`). There is **no longer any app-owned backend**: the
> Cloudflare feed proxy was removed (the `AppConfig.feedProxyUrl` it lived in is gone — `AppConfig`
> now holds only `nightLimiterEnabled`). RSS feeds are fetched **directly** from the publisher, and
> the only external endpoint is Apple's iTunes podcast **search** API (`ITunesSearchManager`).

## Layout (Xcode project at `Sleepulator/Sleepulator.xcodeproj`)
- **App** — `Sleepulator/Sleepulator/`
  - `SleepulatorApp.swift` (entry); `Views/ContentView.swift` — the `TabView` root (Home / Podcasts / Settings).
  - `Views/` — SwiftUI screens + components (HomeView, LibraryView, PodcastDetailView,
    NowPlayingSheet, MiniPlayerView, SettingsView, BreathingView, the `AmbientScene` backdrop
    library, Components, Theme, `MiniPlayerClearance`, `SoundNames`). `Views/Home/` holds Home's
    pieces: the orb + `NightRing`, `ModeSwitcher`, `MixDrawer`, `TimerSelectionSheet`, and the
    pure, unit-tested rules `SessionGuards` and `HomeScreensaverPolicy`. `TonightShelfView` is
    the Podcasts tab's "Tonight" (Focus: "Continue") shelf.
  - `Services/` — the engine + plumbing (below).
  - `Models/Models.swift` — `Podcast`, `Episode`, `SavedMix`, `NoiseType`. `Models/PodcastText.swift`
    (show-notes HTML → plain text, counts, durations, placeholder names) and
    `Models/TonightShelf.swift` (what the Tonight shelf and the show page's Resume offer) are
    pure, unit-tested podcast rules.
  - `PrivacyInfo.xcprivacy`, `Info.plist`.
- **Widget** — `SleepulatorWidget/` (sleep-timer Live Activity).
- **Tests** — `SleepulatorTests/` (XCTest). Three files, many suites: `AudioMathTests.swift`;
  `AudioStateTests.swift` (also holds `PodcastParserTests`, `OPMLParserTests`,
  `StorageManagerTests`, `NetRetryTests`, `CacheEvictionTests`, the sleep-timer suites, Home's
  pure UI rules (`SessionGuardsTests`, `NightRingMathTests`, `MiniPlayerClearanceTests`,
  `HomeScreensaverPolicyTests`), the podcast rules (`PodcastTextTests`, `ShowNotesPreviewTests`,
  `TonightShelfTests`), and more); `PersistenceTests.swift` (`PersistenceMigrator` /
  `MixStore`).

## Services (the core)
- `AudioEngine` — the app-facing `ObservableObject` facade. Owns UI state + policy, delegates
  to the engines below. It does NOT forward child `objectWillChange`: views that show the timer,
  queue or mixes observe those children directly (see the comment in `AudioEngine.init`).
- `GenerativeAudioEngine` — `AVAudioEngine` + `AVAudioSourceNode`. Renders noise/binaural on the
  **real-time render thread**, reading params **lock-free** via an atomic double-buffer.
- `PodcastPlayer` — `AVPlayer` + an `MTAudioProcessingTap` Night Limiter (loudness-bounded so
  spikes don't wake you). Owns remote commands, the time observer, and gapless preload.
- `AudioSessionController` — session activation + interruption / route / background observers.
- `SleepTimerService` (+ `PomodoroService`, `ChimePlayer`) — the fade-out sleep timer and the
  Focus Pomodoro. `AudioMath` holds the fade curve.
- `PodcastQueueManager`, `MixStore`, `PersistenceMigrator`, `StorageManager` (JSON file store),
  `AudioDownloader` (offline cache), `PodcastParser` / `OPMLParser` / `ITunesSearchManager`.

## Audio + state invariants (the hard-won stuff — change with care)
- **Never block the render thread.** It reads params lock-free; hand-offs are atomic. No locks,
  allocation, or `DispatchQueue` work inside the `AVAudioSourceNode` render block.
- **`AudioEngine` is a coarse `ObservableObject`** — *any* `@Published` change invalidates
  *every* observing view. Keep high-frequency values OUT of `@Published` (`rmsPower` is a plain
  property; the sleep-timer republish is throttled to 1Hz in `SleepTimerService.tick`). Don't
  give a view `@ObservedObject var audio` unless it actually displays engine state — that
  re-render storm is what overwhelmed the podcast list (`perf(podcasts)` fix, 2026-06).
- **The Night Limiter (on-device tap) replaced the server proxy.** Loudness-bounded so a loud
  podcast spike can't jolt you awake; it can follow the mode (on for Sleep, off for Focus).
- **The podcast `AVPlayer` is disposable.** Every item carries the limiter tap (volume + the
  sleep fade live there even with the limiter off), and an interruption can kill an AVPlayer +
  tap pipeline for good — only a new AVPlayer recovers. `PodcastPlayer` rebuilds it on item
  failure, media-services reset, or its tap-heartbeat watchdog (clock running, no audio). Never
  reintroduce one AVPlayer for the process. If a podcast is "playing but silent" again, read the
  exported log's `podcast resume:` / `rebuilding the AVPlayer` lines before touching volume code.
- **Downloads live in Application Support**, not Documents (Apple 2.5.x: re-downloadable content
  must not be iCloud-backed). `isExcludedFromBackup`, ~2GB LRU cap (`AudioDownloader`).
- **Persistence is per-key JSON** via `StorageManager`; one oversized write must not abort the
  rest. `PersistenceMigrator` owns the fragile launch-time legacy reads.
- **Sound palettes are mode-scoped** — Sleep and Focus deliberately share no sounds
  (`AudioEngine.reconcileSoundsToMode`).
- **The sleep timer starts from the Home orb's night ring.** `NightRing` sets
  `nightLengthMinutes` (0 = All night, the default, so an update never starts timing anyone out).
  Any Sleep session starting from rest starts the timer at that length: `AudioEngine.noteSessionStart`
  on the idle→playing edge of `noiseOn`/`binauralOn`/`isPodPlaying`, so the orb, mixer switches,
  podcasts, lock screen/AirPods, Siri and the widget all honour it. Nothing in Focus, for All night,
  or while a countdown runs (resume, interruption, stall keep the night). The timer sheet syncs the
  ring; its "Play all night" sets All night (the ring is the setting), and with nothing playing its
  commit is "Play & start timer", so a countdown never runs over silence. The pure rules
  (`timerOnPlay`, the mode-switch confirm over a live session, "the night veil only drops over
  sound") live in `SessionGuards`, unit-tested: change them there, not in view code. Tests that
  start sessions set `engine.nightLengthProvider` rather than relying on the simulator's defaults.
- **Isolated deinits.** Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` a class with no explicit
  `deinit` gets an implicit MainActor-*isolated* one (an explicit `deinit` is nonisolated). On the
  iOS 18.4–26.3 Swift runtimes that path aborts ("pointer being freed was not allocated" in
  `TaskLocal::StopLookupScope`, swiftlang/swift 29245e4) when it runs synchronously on main while
  a task-local is bound outside a Task, and XCTest binds one around every sync test. So any class
  `AudioEngine` owns, or that tests create and free (`SceneClock`, temp-dir `StorageManager`,
  `PodcastParser`), declares `nonisolated deinit {}`. A new engine-owned class without it crashes
  `IsolatedDeinitRuntimeBugTests` on an iOS 26.3 sim; 26.4+ runtimes hide the bug. CI runs the
  suite on both the newest runtime and the newest still-affected one (iOS 26.2 on the runner).

## UI conventions
- **Mode palette everywhere.** Views use `Palette(focusMode:)`, so Focus is cool on every tab, not
  just Home. A view that doesn't otherwise display engine state reads the persisted
  `@AppStorage("focusMode")` (AudioEngine writes it) instead of observing `audio`.
  `Palette(bedtime:)` is legacy and only ever yields Sleep amber.
- **Mini-player clearance is measured, not guessed.** ContentView measures the floating bar's top
  edge and hands each tab `\.miniPlayerTop` (nil on Sleep Home unless a podcast plays). A screen
  that ends at the bottom edge (a tab root, a pushed show page) applies `.miniPlayerClearance()`;
  Home passes `frozen:` under the screensaver. No fixed bottom spacers: the old 112 / 80 / 60 pt
  guesses broke as soon as the bar grew with text size.
- **Dark-only.** `Info.plist` sets `UIUserInterfaceStyle = Dark` and a `UILaunchScreen` filled
  with the `LaunchBackground` color; the generated launch screen is off
  (`INFOPLIST_KEY_UILaunchScreen_Generation = NO`; it followed the system appearance and flashed
  white on every cold launch). ContentView also forces `.dark`.
- **Home's confirms can't present over a sheet.** A `confirmationDialog` raised while the
  Build-mix sheet is up silently does nothing, and the stuck request holds the screensaver off.
  Close the sheet, then ask (`HomeView.requestMode`).
- **One name per sound.** Name sounds through `SoundNames` (binaurals are "Deep", "Drift", …,
  never "Delta" / "Theta").
- **Podcasts is split by depth.** The library and its Tonight shelf follow the 2am rules (artwork
  dimmed to 0.78 in Sleep, `EmberButtonStyle`, no solid accent slabs); a show's page and the Add
  sheet are the brighter browsing surfaces. Swipe actions draw a fixed white label, so tint them
  `pal.actionFill` (the deep accent), never `pal.accent` (2.18:1).
- **Manual podcast starts cancel the ambient tail.** A fresh `play()` never fires
  `podPlayer.onResume`, so a podcast started in the tail would play at its near-zero fade and then
  be stopped. `AudioEngine.cancelTailForManualStart` runs for the queue's user-facing plays
  (`PodcastQueueManager.userStartedPlaybackFn`: rows, swipes, Play All), never its auto-advance,
  and for `AudioEngine.resumeEpisode`, the Podcasts tab's Resume / Back 5 min / Up next / Play
  Latest. `resumeEpisode` also continues an already-loaded, settled (`!isLoadingItem`) episode from
  the live player, starting it over if it's spent, and re-heads the queue in one write
  (`moveToHead`). Resume positions come from the player's in-memory map (`savedEpisodePositions`),
  which beats the Last Night snapshot (stale after a podcast-only pause). LibraryView reads
  library.json once; its state is the source of truth.
- **SwiftUI drops a state update whose new value `==` the old.** `Podcast` hashes by id but its
  `==` also compares what the library row shows; id-only `==` left rows stale after a show page
  loaded more episodes. Keep row-visible fields in `==` (and keep it O(1)).
- **List rows restyle `Label`.** Inside a `List` row, `Label` gets a wide icon column; build
  icon + text pairs in rows from an `HStack`. A sheet's data must reach it through
  `.sheet(item:)`, not a separate `@State` read only inside the sheet closure (the OPML picker
  opened empty that way).

## Build / run
- **Native Xcode build** — open `Sleepulator/Sleepulator.xcodeproj`. NOT Capacitor/CLI; there's
  no `npm` / `cap sync` step (that was the archived PWA).
- Deployment target **iOS 17.0** (uses SwiftUI `Shader`/`.layerEffect`, `.contentMargins`).

## Verification gate (read before claiming an audio fix works)
Unit tests can't catch the iOS audio bugs (no real render thread / session in XCTest):
interruptions, route changes, background keep-alive, looping, the limiter, and the sleep-timer
**fade + terminal stop** are device-specific. Anything touching the engine, session, limiter, or
timer must be verified on a **real iPhone, installed, screen locked, over a full timer run.**
State clearly when something is shipped-but-unverified-on-device. `TESTING.md` holds the
native device-test checklist and a device-pass log — record each pass there. The Night
Limiter ships **off by default** (`AppConfig.nightLimiterEnabled`) until its acceptance
section (TESTING.md §3D) passes on device.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
