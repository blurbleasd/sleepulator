# SLEEPULATOR — agent guide

A native SwiftUI iOS app for falling asleep and focusing: layer generative ambient noise +
binaural beats, optionally mix in a podcast, and set a sleep timer that fades everything out.
Two moods — **Sleep** (warm "dusk") and **Focus** (cool, Pomodoro). Built for the hard case
that drives most decisions: **installed on iPhone, screen locked, playing all night.**

> The original React/Vite **PWA is archived** in `archive_webapp/` (not built or deployed).
> The server-side "Sleep Safe" ffmpeg proxy is **gone**, replaced by an on-device Night
> Limiter (see `AUDIO-LIMITER-SPEC.md`). There is **no longer any app-owned backend**: the
> Cloudflare feed proxy was removed (the `AppConfig.feedProxyUrl` it lived in is gone — `AppConfig`
> now holds `nightLimiterEnabled` and `appleMusicEnabled`, off for 1.0). RSS feeds are fetched
> **directly** from the publisher; the only other endpoints are Apple's: the iTunes podcast
> **search** API (`ITunesSearchManager`) and StoreKit for tips.
>
> **1.0 ships free with a tip jar**, iPhone only, portrait (`TARGETED_DEVICE_FAMILY = 1`; an iPad
> runs it in an iPhone window). The launch plan and every review decision behind it are in
> `docs/designs/APP-STORE-LAUNCH-1.0.md`; its device gate is TESTING.md §3A, §3B, §3C, §3E, §3P, §3U.
> The privacy-policy, support-page and App Review drafts are in `docs/launch/STORE-TEXT-1.0.md`.

## Layout (Xcode project at `Sleepulator/Sleepulator.xcodeproj`)
- **App** — `Sleepulator/Sleepulator/`
  - `SleepulatorApp.swift` (entry); `Views/ContentView.swift` — the `TabView` root (Home / Podcasts / Settings).
  - `Views/` — SwiftUI screens + components (HomeView, LibraryView, PodcastDetailView,
    NowPlayingSheet, MiniPlayerView, SettingsView, BreathingView, the `AmbientScene` backdrop
    library, Components, Theme, `MiniPlayerClearance`, `SoundNames`). `Views/Home/` holds Home's
    pieces: the orb + `NightRing`, `NightEmber` (the faint time-left arc the veil's glance shows
    in the ring's place; nothing is left over the screensaver, which is the scene alone),
    `ModeSwitcher`, `MixDrawer`, `TimerSelectionSheet`, `Backdrops` (Night sky's meteor:
    `ShootingStarView` and its pure, unit-tested `NightSkyMotion` rules; the sky itself is
    `Views/NightSkyMetalView.swift` + `NightSkyShader.metal`), and the pure, unit-tested rules
    `SessionGuards`, `HomeScreensaverPolicy` and `MorningReadback` (the morning after a clean
    night, one dim line in the pills' slot: "Last night · 1 hr 30 min, eased out at 12:41 AM").
    `Views/TonightShelfView.swift`
    is the Podcasts tab's "Tonight" (Focus: "Continue") shelf. `Views/NowPlayingState.swift` holds
    the player views' pure, unit-tested rules: `NowPlayingState` (hero, Up Next, phase),
    `PlayerClock` (times, speeds, lengths, clamped) and `NightLineCopy` (the Sleep player's
    night line). `Views/SettingsRules.swift` holds Settings' pure, unit-tested rules:
    `LimiterChoice` (Soften loud moments: Off / While sleeping / Always, over the two stored limiter
    flags), `StereoWidth` (four named stops) and `SettingsOrder` (the current mode's sections
    first, the other mode's folded). `Views/BackupSupportView.swift` is Settings ▸ Backup & support
    (Backup; Troubleshooting: Send feedback, Reports from iOS, the playback log; Support
    Sleepulator last: tips, Rate, the build line). Its `BackupController`
    (`Views/BackupControls.swift`) is owned by `SettingsView`, so a restore still finishes if that
    page is closed mid-way. `Views/TipJar.swift` holds the tip rows (one view for Settings and the
    card's sheet), Send feedback, and the pure `RateRowRule` and `FeedbackMessage`; the tip card
    itself is `CoachmarkContent.tip` in `FirstRunCoachmark`.
  - `Services/` — the engine + plumbing (below).
  - `Models/Models.swift` — `Podcast`, `Episode`, `SavedMix`, `NoiseType`. `Models/PodcastText.swift`
    (show-notes HTML → plain text, counts, durations, placeholder names) and
    `Models/TonightShelf.swift` (what the Tonight shelf and the show page's Resume offer) are
    pure, unit-tested podcast rules.
  - `PrivacyInfo.xcprivacy`, `Info.plist`.
- **Widget** — `SleepulatorWidget/` (sleep-timer Live Activity).
- **UI tests** — `SleepulatorUITests/` (XCUITest, in the shared scheme so CI runs it).
  `HomeLayoutUITests` checks Focus's Build mix / Focus session row clears the mini-player and
  that a tap starts the Pomodoro; that a tap on the shown bar reaches it, and on Podcasts it sits
  above the tab bar; and that on Sleep Home at rest the bar is gone from the accessibility tree and
  Home's controls stay hittable; and that the tip card sits in the band above Build mix, leaves
  on No thanks, and on Leave a tip opens the three tips with Close spending it (DEBUG-only seams `-uiTestTipProducts` and `-uiTestTipCardDue`: fixed products
  with no StoreKit, and the card due now; compiled out of release). Every UI test also passes
  `-uiTestIsolated <true/>` (`AppInfo.isUITestRun`, DEBUG-only): a throwaway night journal and no
  rating prompt, so a dev simulator's own nights can't reach a run, nor the run's reach them. `NightVeilUITests` drops the
  veil on an untimed night (shortened to 15 s by the Debug-only `-veilDelaySeconds` launch
  argument, `SessionGuards.veilDelay`; the real minute made it the slowest test), glances, wakes,
  and checks Focus's readout. Its glance holds 40 s (Debug-only `-veilGlanceSeconds`,
  `SessionGuards.glanceHold(override:)`; a unit test pins the real 6 s + 2 s): on CI one slow
  accessibility query, or XCUITest waiting out a system banner inside a tap, pushed the wake tap
  past the real 8 s, where it's a fresh glance. It passes settings as launch
  arguments (plist literals, the argument domain) so persisted mode and night length stay put.
  CI's simulators are slow and sometimes drop a synthesized tap, so a tap that matters checks its
  effect and goes round again (the noise switch, the mode switch, the tab bar, which can show a tap dead on target and
  keep the old tab selected, Focus's Stop, `pauseAudio`, the veil's first tap,
  whose glance is read off a screenshot since it's hidden from accessibility), and a test lets an
  overlay finish fading in before tapping it (a tap on the veil as it arrives doesn't reach it).
  They launch with Moving scenes off (`-ambientMotion <false/>`): an app redrawing every frame
  never idles, and XCUITest's wait for idle before each tap outlasted Home's control fade. Never
  race Sleep's 3 s fade with two taps; CI loses it. Nor with a look: one CI answer took 3.7 s, so
  NightVeilUITests reads the wake off the "Show controls" layer alone and goes round again when no
  look came inside the fade (`lookAfterTheWake`). The target is made by `Sleepulator/setup_ui_tests.rb`
  (idempotent; re-run it after adding a file there). It runs in the same app the unit tests are
  hosted in, so a UI test must leave persisted state (mode, night length) as it found it.
- **Tests** — `SleepulatorTests/` (XCTest). Seven files, many suites: `AudioMathTests.swift` (also
  `MetalShadersTests`, which checks `MetalShaders.known` against the app's compiled `[[stitchable]]`
  functions, so a new scene's shader goes in that set, and `SceneSwipeLoopTests`: the swipe loop,
  unique scene ids);
  `AudioStateTests.swift` (also holds `PodcastParserTests`, `OPMLParserTests`,
  `StorageManagerTests`, `NetRetryTests`, `CacheEvictionTests`, the sleep-timer suites, the
  Pomodoro's clock (`PomodoroProgressTests`, `PomodoroMissedBoundaryTests`), Home's
  pure UI rules (`SessionGuardsTests`, `NightRingMathTests`, `MiniPlayerClearanceTests`,
  `HomeScreensaverPolicyTests`, `NightSkyMotionTests`), the podcast rules (`PodcastTextTests`, `ShowNotesPreviewTests`,
  `ShowNotesEdgeTests`, `TonightShelfTests`, `QueueMoveToHeadTests`), the player rules
  (`NowPlayingStateTests`, `NightLineCopyTests`, `PlayerQueueActionTests`,
  `PodcastFailureStreakTests`), Settings' rules (`SettingsRulesTests`) and a restore's engine
  reload (`RestoreReloadTests`; its queue, mixes and places tests keep their own temp-dir stores,
  `PodcastQueueManager(storage:)`, `AudioEngine(storage:)`, `PodcastPlayer(storage:)`: every
  earlier test's objects write the shared files from their own queues, which
  `StorageManager.flush()` doesn't drain, and one queue write landed a test late), the real-AVPlayer suites (`PodcastPlayerRebuildTests`,
  `PodcastLoadHoldTests`, `PodcastItemEndTests`), the night journal and the asks (`NightRulesTests`,
  `NightJournalTests`, `NightJournalWiringTests`, `AskRulesTests`, `MorningReadbackTests`, `CoachmarkTipCardTests`,
  `RateRowRuleTests`, `FeedbackMessageTests`), and more);
  `PersistenceTests.swift` (`PersistenceMigrator` / `MixStore`); `BackupRoundTripTests.swift`
  (export, read, restore and Undo, the `Backup.kinds` checks, a restore never switching mode;
  `BackupControllerTests` for the Backup page's controller, which await the Task each controller
  call returns: the hosted app's first render can hold the main actor 10 s or more mid-test, and
  a 5 s poll ran out under it);
  `FocusDriversTests.swift` (also `FocusStillFrameTests`, one hosted in a window, and
  `ContourLightTests`: the radius whose disc covers the interval's share of the screen);
  `GenerativeAudioEngineTests.swift` (`GenerativeMediaResetTests`);
  `TipStoreTests.swift` (`TipFlowTests`, pure; `TipStoreTests`, StoreKitTest against
  `Tips.storekit`). On iOS 26 simulators a command-line run (xcodebuild, CI) hits an Apple bug,
  "[SKTestSession] Error saving configuration file … Code=3", and loads no products: those six
  tests then SKIP with that reason. CI skips them outright (the workflow sets `SLEEPULATOR_CI`):
  a CI simulator that did load products took minutes per purchase and flaked. They run from
  Xcode (⌘U).

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
- `NightJournal` — one record per Sleep night, on this phone only: per-night `.jsonl` event files
  (the last 2, in Application Support/Sleepulator/nights, excluded from backup) and a verdict list
  (`night-verdicts.json`, the last 30). Clean nights pace the rating ask and the tip card; Send
  feedback attaches the files.
- `TipStore` — StoreKit 2 consumable tips, started at launch (`SleepulatorApp`): listens to
  `Transaction.updates`, finishes every transaction, and maps each outcome through the pure
  `TipFlow`. Nothing is unlocked by a tip.
- `Backup`: the backup file's export and restore. A restore reads and validates first, the person
  confirms in plain counts ("4 mixes, 12 shows"), and a snapshot of what was here is kept for a
  week so Undo can put it back exactly; if that snapshot can't be saved, nothing is replaced.
  `Backup.kinds` is the restore allowlist with each setting's type and range (a JSON null raised
  an uncatchable exception in UserDefaults): keep new persisted settings in sync there. A restore
  never changes the mode (`Backup.modeKey`); a backup from the other mode lands its sounds in the
  per-mode picks instead. A restore stores what decoded (encoded again, trimmed to what the engine
  plays, clamped), never the file's own JSON: the decoder ignores unknown keys, so a hand-edited
  backup could carry megabytes into the preferences plist. The engine's queued writes land first
  (`AudioEngine.flushPendingWrites`, handed to `Backup.restore`/`undo` as `settle`): before the
  Undo copy and again just before the writes. A new background write in the engine belongs in that
  flush. An export writes only settings a restore takes back, reads a file's `.bak` when the
  primary won't parse (`StorageManager.rawData`), and fits under the 50 MB a restore reads.
  Undo trusts its own copy, which is built differently (`undoCopy`): every setting as stored,
  even one the restore's bounds refuse (a played list with a long episode id), file sections
  written back as they were (even ones today's types can't decode), and what it couldn't hold
  (`undoLeftOutKey`) left alone rather than removed or emptied. Files are written with an error
  check (`writeRawNow`); an Undo that couldn't save one keeps its copy (`UndoResult.incomplete`),
  and its week starts again (`undoKeptAtKey`). Restored episodes and shows are held to Backup's
  own 16 KB bound (`maxFeedFieldBytes`, room for the feed parser's 4,000-character guid or
  title): the app copies an episode's id and address into the plist. So are saved places' keys,
  and a restore takes no more places than the player keeps (`maxPlaces`). Anything a restore
  leaves out for a text too long is counted and said, in the confirm and the result
  (`Contents.tooLong`). The reload after a restore reads files as launch does: a queue or library
  today's types can't decode shows empty and stays on disk: the reload doesn't save over it (the
  next edit does, as at launch).

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
  A tap that can't attach fails open (`PodcastPlayer.onLimiterUnavailable` →
  `AudioEngine.limiterOffForStream`): one dim line in the full player, only with the limiter on,
  never a `playbackNote` (that raised an amber banner on Home all night).
- **The podcast `AVPlayer` is disposable.** Every item carries the limiter tap (volume + the
  sleep fade live there even with the limiter off), and an interruption can kill an AVPlayer +
  tap pipeline for good — only a new AVPlayer recovers. `PodcastPlayer` rebuilds it on item
  failure, media-services reset, or its tap-heartbeat watchdog (clock running, no audio). Never
  reintroduce one AVPlayer for the process. If a podcast is "playing but silent" again, read the
  exported log's `podcast resume:` / `rebuilding the AVPlayer` lines before touching volume code.
- **Now playing is `AudioEngine.loadedEpisode`, never the queue head.** Every load sets it (all
  loads go through `loadPodcast`; an unqueued episode gets a title-only stand-in), and it outlives
  the queue moving on (the sleep-aware hold, a removal). The player views resolve the
  hero and Up Next through `NowPlayingState`, not `queue.first` / `dropFirst()`, and the player's
  queue edits pin the loaded episode, not `queue[0]` (`PodcastQueueManager.skipToNext`,
  `moveInUpNext`, `shuffleRemainingQueue(nowPlayingId:)`, `remove`/`restore` for Undo). Next is a
  skip, not a finish: it never marks played or deletes the download, and plays on with Auto-Play
  off. Failures carry their episode id; `handlePodcastFailure` ignores one from a replaced item.
- **A pause during a load sticks.** `PodcastPlayer.play()` only plays after the tap attach (up to
  1.5 s) and the resume-seek, so it arms `playWhenLoaded`; `pause()` / `stop()` clear it and the
  load lands paused. Mid-load, `resume()` / `toggle()` act on that pending load, never on the
  previous item still in the AVPlayer. The engine's pauses that aren't a tap on a control showing
  `isPodPlaying` (a call, headphones out, Pause All, Apple Music) read
  `podcastIsPlayingOrStarting`. Before this, a lock-screen pause, a call or the timer's terminal
  stop during an auto-advance was undone, and the playing edge could arm a fresh night timer.
- **Item-level news is filed by item.** The end, stall and failure handlers check
  `item === currentItem` and use `currentItemId`, never `currentId`.
  `.AVPlayerItemDidPlayToEndTime` can arrive off main after a Next has swapped the next episode
  in; filed under `currentId` it marked the NEW episode played and deleted its download.
- **A failure is not a finish.** `AudioEngine.episodeDidEnd(didFinish: false)` goes to
  `PodcastQueueManager.advancePastFailure`. The episode stays queued with its download. Auto-Play
  moves on only outside the tail and the hold, never to one that already failed in this run, and
  stops after `failureLimit` (3) in a row with the failed ones back at the head. A finish or a
  person's pick resets the count. Offline, every load fails, and advancing on each one emptied
  the queue overnight.
- **Downloads live in Application Support**, not Documents (Apple 2.5.x: re-downloadable content
  must not be iCloud-backed). `isExcludedFromBackup`, ~2GB LRU cap (`AudioDownloader`).
- **Persistence is per-key JSON** via `StorageManager`; one oversized write must not abort the
  rest. `PersistenceMigrator` owns the fragile launch-time legacy reads.
- **Sound palettes are mode-scoped.** Sleep and Focus share no sounds except Pink noise
  (`AudioEngine.reconcileSoundsToMode`). Each mode remembers its own last noise and binaural pick
  (`lastPick.*` keys), and a mode switch restores that pick. Without it, Sleep's Brown came back
  from Focus as Pink: Focus snapped it to Pink, which Sleep also has. Launch doesn't apply the
  memory; there, the current sound is already that mode's latest pick. A restore never switches
  mode: a backup from the other mode puts its current sounds in that mode's picks and takes this
  mode's sounds from its picks (`Backup.restorePlan`).
- **The sleep timer starts from the Home orb's night ring.** `NightRing` sets
  `nightLengthMinutes` (0 = All night, the default, so an update never starts timing anyone out).
  Any Sleep session starting from rest starts the timer at that length: `AudioEngine.noteSessionEdge`
  on the idle→playing edge of `noiseOn`/`binauralOn`/`isPodPlaying`, so the orb, mixer switches,
  podcasts, lock screen/AirPods, Siri and the widget all honour it. Nothing in Focus, for All night,
  or while a countdown runs (resume, interruption, stall keep the night). The timer sheet syncs the
  ring; its "Play all night" sets All night (the ring is the setting), and with nothing playing its
  commit is "Play & start timer", so a countdown never runs over silence. The pure rules
  (`timerOnPlay`, the mode-switch confirm over a live session, "the night veil only drops over
  sound") live in `SessionGuards`, unit-tested: change them there, not in view code. Tests that
  start sessions set `engine.nightLengthProvider` rather than relying on the simulator's defaults.
- **All night gets a night too.** With no timer, `nightProgress` settles on the clock
  (`UntimedNight`: 0 → 1 over 45 min from the Sleep session's start; a pause under 30 min keeps
  the night, a longer one ends it). AudioEngine reports the session's edges
  (`noteSessionEdge`) and a switch to Focus ends it. It's visual only (scenes darken and still,
  comets and meteors retire past 0.4, the orb calms); the audio fade never reads it. Views that
  observe the timer for darkening (`NightDarken`, `NightFade`) also re-read it every 20 s while
  the screen is in sight (`SceneContext.occluded`; with "Moving scenes" off, Night sky and Rain on
  glass still darken),
  since an untimed night publishes nothing. The night never brightens on its own at a timer
  boundary: a timer started mid-night settles on from where the night already is
  (`SleepTimerService.timedBase`), the ambient tail re-bases instead of dropping back, a cancel
  hands the reached night to the untimed clock, and a natural end leaves it settled until the
  resume window passes from the real end (`cancelTimer` carries the reached night; `fireTerminalStop`
  → `recordNightEnd`).
  Only a +15m bump eases it back, by design. Switching Focus → Sleep with the sound playing starts
  the night like Play (`AudioEngine.beginSleepNight`). Before this, All night never darkened.
- **The stop-with-episode timer runs on the playback clock.** "Stop after this episode" (the timer
  sheet and the Sleep player's chip, `startEndOfEpisodeTimer`) is offered and starts only while the
  episode plays. A pause hands it to the wall clock with the same end
  (`SleepTimerService.podcastPaused`); left on the playback clock, the bed played all night. The
  episode's end, from the last tick or the player's end-of-item report, goes through
  `episodeEnded()` (the tail if set, else the stop). In the tail an ended episode tidies the queue
  and never auto-plays the next; only a person's pick lifts the tail.
- **The night journal only observes.** `NightJournal` never changes playback; it takes the
  engine's edges (`noteSessionEdge`, `beginSleepNight`, the Focus switch, an interruption's begin
  and, with the bed back, its end), live-audio ticks (the RMS tap and the podcast clock, gaps over
  2 s not counted) and taints. A night is clean only on sound that really played: to its timer's
  end while playing, or 3+ hours ended by a person, with no player rebuild, pipeline death or
  podcast failure while it played (any failure, by design; a stream the stall watchdog gives up
  on and the noise engine's start error count too). A timed night needs a minute of live audio
  (`timedNightMinimumLive`: a deadline that passed while the app slept, fired by a morning
  lock-screen Play, ends a night that hardly played). News while the night is paused (an alarm
  killing the player, the rebuild when play resumes) is a note, not a taint, and so is a dead or
  rebuilt player in the first 10 s after the sound starts or resumes (`graceAfterResume`,
  `isPauseAftermath`: the watchdog finds a dead player ~4 s in); any other failure then still
  spoils it. A pause over 30 minutes ends the night where it paused, as soon as the asks look or
  news arrives (`closeLapsedPause`), not when play is next pressed. Only a session edge ends a
  pause, never live ticks (they can come from a fading bed or a scrubbed paused podcast), so a
  night whose interruption never sends `.ended` stays paused: it undercounts, never fakes. The
  pause takes the interruption's own time (stamped before the hop to main), a dead or rebuilt
  player stamped up to `newsLead` (2 s) before a pause is the pause's, and `.ended` carries the
  night on only when the bed really restarted (`restartBedAfterInterruption`) or a podcast
  resumes over it.
  A deadline reconciled on the morning foreground never counts, so `SleepTimerService.onTerminalStop`
  fires before `stopAllFn` (the stop would otherwise read as a person's). Nor does one a tick finds
  more than `overdueAfter` (5 s) past, the first tick after a Play over a pause that outlived it:
  reconciled too, with no ambient tail, ended at the deadline. A deadline from before the open
  night (the Play opened a new one) discards that night: it never played. Late news is filed by
  when it happened (an off-main failure carries its time), into the night whose span holds it,
  else dropped. A record found open at launch while playing is `died`. Nothing written may carry a
  URL (`NightRules.scrub`): the files go out with Send feedback, and private feeds keep a
  subscriber's secret in theirs. Writes are off main and best-effort; audio never waits on them.
- **The asks are rare and daytime.** The rating prompt comes after 3 clean nights, the tip card
  after 5 (`cleanNightCount`: one a night at most, noon to noon by start, so naps don't add up),
  in either case never at night. Rating: at a natural break (a sheet closed, Settings
  left; `\.naturalBreak`), 09:00–20:00, 2+ h after the night ended, nothing playing, once per
  version, never on the tip card's day nor while Home shows it (`SessionGuards.tipCardShowing`:
  the Home tab with the card ahead in the coachmark band, by `CoachmarkContent.current`). The card: the same window, Sleep Home at rest only, once
  products loaded and purchases allowed, never on the rating's day, in the coachmark band; only an
  answer spends it. The rules live in
  `SessionGuards` (`mayAskForRating`, `tipCardDue`), unit-tested. The asks' memory
  (`tipCardSpent`, `ratingAskedVersion`, `ratingAskedOn`, `tipCardShownOn`, `tippedOnThisPhone`,
  `tipTransactionsHandled`) is device-only: keep these keys OUT of `Backup.kinds`.
- **The morning read-back speaks only for a clean night.** Sleep Home at rest, 05:00–18:00, for
  the night just gone (started 18:00 to before 05:00, last evening or after midnight), 10+ min of
  live audio, never while a session is open or a card is in the band (`MorningReadback`,
  unit-tested). A night that hiccupped never claims it went well. ContentView reads it with the
  asks (`refreshAsks`, also on appear) and hands Home a plain value, never `@Published`.
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
  edge and hands each tab `\.miniPlayerTop` (nil on Sleep Home unless an episode is loaded). A screen
  that ends at the bottom edge (a tab root, a pushed show page) applies `.miniPlayerClearance()`.
  Home computes its own (`HomeView.homeClearance`) from the screen's bottom edge minus the insets
  anchored while the tab bar shows, so it holds still under the screensaver. No fixed bottom
  spacers: the old 112 / 80 / 60 pt guesses broke as soon as the bar grew with text size.
  To measure a full-bleed view, put `.onGeometryChange` *before* its `.ignoresSafeArea()`.
  Placed after it, you get the un-expanded frame (the tab bar's top edge, not the screen's). That
  bug once hid Focus's whole bottom row under the bar; `HomeLayoutUITests` now guards it.
- **Hidden means not rendered.** On iOS 26 a rendered SwiftUI view stays in the accessibility tree
  XCUITest reads through `opacity(0)`, `.allowsHitTesting(false)` and even
  `.accessibilityHidden(true)`. So ContentView takes the hidden mini-player out of the hierarchy
  (`if !miniPlayerHidden`, an opacity transition), and presents its Now Playing sheet itself so the
  sheet never depends on the bar. The removal fade still renders the bar for 0.9 s, so the
  always-present wrapper also gates `.allowsHitTesting` on `miniPlayerHidden` and
  `.accessibilityHidden` on `miniPlayerHidden || nightDimmed` (the veil's rule below): those stop
  real taps and VoiceOver at once, though XCUITest's tree ignores them. Keep both halves: only
  device steps check that they block (TESTING.md §M7 for the fade, §M7's veil step for
  `nightDimmed`); HomeLayoutUITests checks only that the hit-test gate lets a tap reach the
  shown bar. To
  prove a hidden view is gone, assert `waitForNonExistence(timeout:)` in a UI test: a removal
  transition keeps it in the tree until it finishes.
- **A `.contentShape(.accessibility, …)` can become its container's frame.** NightRing's band shape
  made Home's root accessibility container a 250 pt square around the orb, which clipped every
  other Sleep Home control out of the accessibility hit test. XCUITest called them unhittable,
  while real taps still worked. HomeView's root sets `.contentShape(.accessibility, Rectangle())`
  to keep its own. If a screen's controls turn unhittable in XCUITest, compare each container's
  frame in `app.debugDescription` with the screen.
- **The night veil closes an idle Now Playing sheet.** Any touch anywhere restarts the veil's
  minute (`WindowActivity`), and a presented sheet or dialog makes it wait rather than drop over it
  (`SessionGuards.veilTimeout`). The Now Playing sheet is the exception (`.closeNowPlaying`): left
  untouched for the minute, it's the brightest surface on the night screen, so ContentView closes
  it and the veil drops. Never under VoiceOver or Switch Control, which reach it without touches.
- **Dark-only.** `Info.plist` sets `UIUserInterfaceStyle = Dark` and a `UILaunchScreen` filled
  with the `LaunchBackground` color; the generated launch screen is off
  (`INFOPLIST_KEY_UILaunchScreen_Generation = NO`; it followed the system appearance and flashed
  white on every cold launch). ContentView also forces `.dark`.
- **Home's confirms can't present over a sheet.** A confirm (the mode switch's `.alert`) raised
  while the Build-mix sheet is up silently does nothing, and the stuck request holds the
  screensaver off. Close the sheet, then ask (`HomeView.requestMode`). Night-time confirms are
  `.alert`s with no `.destructive` role. iOS 26 draws a `confirmationDialog` as a popover with no
  cancel button, which left a lone red button on a dark screen.
- **The night veil runs from the last touch.** ContentView drops it 60 s after the last touch
  anywhere in the window (`WindowActivity`: a recognizer that observes every touch, sheets
  included, and claims none), over a playing Sleep session: everywhere while a timer runs, on
  Home or the Now Playing sheet for All night (`SessionGuards.mayNightDim`; on other tabs it would
  black out daytime listening), and never under VoiceOver or Switch Control (`veilTimeout`). If a sheet, dialog or full-screen cover is up when the countdown
  ends, the veil waits another round (`SessionGuards.veilTimeout`). The veil is part of the root
  view, so it can't cover them. The status bar and home indicator hide under the veil and the
  Sleep screensaver (`SessionGuards.hidesSystemOverlays`); Focus keeps its clock. The pending
  countdown lives on `WindowActivity`, not in `@State`: it changes on every touch. The first tap
  on the veil is a glance (`VeilGlance`: the ember and the night line, dim on black, for 6 s);
  a second tap lifts the veil and wakes the controls (`SessionGuards.veilTap`: a tap within
  0.8 s is ignored, and one counts as the wake until the glance has faded; timed on the
  monotonic clock). If VoiceOver or Switch Control turns on while the veil is down, one tap wakes.
  Under the veil the tabs, Home's wake layer and the mini-player are hidden from accessibility, so
  only the veil should answer "Wake". XCUITest still lists SwiftUI elements hidden from
  accessibility (even Home's opacity-0 chrome), so check that with Voice Control on a device
  (TESTING.md §Q.5; for the mini-player, §M7's veil step, since §Q.5 runs where the bar isn't
  rendered).
- **One name per sound.** Name sounds through `SoundNames` (binaurals are "Deep", "Drift", …,
  never "Delta" / "Theta").
- **Podcasts is split by depth.** The library and its Tonight shelf follow the 2am rules (artwork
  dimmed to 0.78 in Sleep, `EmberButtonStyle`, no solid accent slabs); a show's page and the Add
  sheet are the brighter browsing surfaces. Swipe actions draw a fixed white label, so tint them
  `pal.actionFill` (the deep accent), never `pal.accent` (2.18:1). The Sleep Now Playing sheet
  follows the 2am rules too (150 pt desaturated art under a scrim, a `VolumeBar` scrubber, dim
  notes, never amber), and its play button and the mini-player's are the orb's dark
  `PlayerDiscButton`.
- **Manual podcast starts cancel the ambient tail.** A fresh `play()` never fires
  `podPlayer.onResume`, so a podcast started in the tail would play at its near-zero fade and then
  be stopped. `AudioEngine.cancelTailForManualStart` runs for the queue's user-facing plays
  (`PodcastQueueManager.userStartedPlaybackFn`: rows, swipes, Play All, the player's Next and
  Try again), never its auto-advance, and for `AudioEngine.resumeEpisode`, the Podcasts tab's
  Resume / Back 5 min / Up next / Play Latest. `resumeEpisode` also continues an already-loaded,
  settled (`!isLoadingItem`) episode from the live player, starting it over if it's spent, and
  re-heads the queue in one write (`moveToHead`). Resume positions come from the player's
  in-memory map (`savedEpisodePositions`), which beats the Last Night snapshot (stale after a
  podcast-only pause). LibraryView reads library.json once; its state is the source of truth.
- **SwiftUI drops a state update whose new value `==` the old.** `Podcast` hashes by id but its
  `==` also compares what the library row shows; id-only `==` left rows stale after a show page
  loaded more episodes. Keep row-visible fields in `==` (and keep it O(1)).
- **List rows restyle `Label`.** Inside a `List` row, `Label` gets a wide icon column; build
  icon + text pairs in rows from an `HStack`. A sheet's data must reach it through
  `.sheet(item:)`, not a separate `@State` read only inside the sheet closure (the OPML picker
  opened empty that way).
- **Never `TimelineView(.animation(paused:))`.** On ProMotion (120 Hz) phones that schedule stops
  driving frames, so the view moves only when something else redraws it (device 2026-07-11). A
  frame loop that freezes swaps instead: `if paused { staticFrame } else { TimelineView(…) }`,
  with a `@State` `SceneClock` holding the pose (`ShaderBackdrop`, `OrbButton`). A view showing
  real time, like the Focus ring, draws its static frame from the published value instead.
  So do the Focus scenes, whose positions are the Pomodoro: in sight, their still frame observes
  it (`FocusStillFrame`). A bare one, never redrawn, kept the idle look a whole session.

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
