# SLEEPULATOR — agent guide

A native SwiftUI iOS app for falling asleep and focusing: generative noise + binaural beats,
optionally a podcast, and a sleep timer that fades everything out. Two modes: **Sleep** (warm
"dusk") and **Focus** (cool, Pomodoro). The case behind most decisions: **installed on iPhone,
screen locked, playing all night.**

**Why each rule exists** (the incident, device run or CI flake behind it) is in
`docs/CLAUDE-BACKGROUND.md`, same section order. Read the matching section before changing the
code a rule protects. If the two disagree, this file wins.

- **No app-owned backend.** Feeds come straight from publishers; the only other endpoints are
  Apple's iTunes Search (`ITunesSearchManager`) and StoreKit (tips). The PWA in `archive_webapp/`
  is archived. The server "Sleep Safe" proxy is replaced by the on-device Night Limiter
  (`AUDIO-LIMITER-SPEC.md`). `AppConfig` holds `nightLimiterEnabled` and `appleMusicEnabled`, off
  for 1.0.
- **1.0 plan:** free with a tip jar, iPhone only, portrait (`TARGETED_DEVICE_FAMILY = 1`). Plan and
  its decisions: `docs/designs/APP-STORE-LAUNCH-1.0.md` (device gate TESTING.md §3A, §3B, §3C, §3E,
  §3P, §3U). Privacy, support, App Review and listing drafts: `docs/launch/STORE-TEXT-1.0.md`. On
  hold since 2026-11: the app is for personal use for now.

## Layout (Xcode project at `Sleepulator/Sleepulator.xcodeproj`)
- **App** `Sleepulator/Sleepulator/`: `SleepulatorApp.swift` (entry), `Views/ContentView.swift`
  (the `TabView` root: Home / Podcasts / Settings), `Services/` (below), `Models/Models.swift`
  (`Podcast`, `Episode`, `SavedMix`, `NoiseType`), `PrivacyInfo.xcprivacy`, `Info.plist`.
  - `Views/Home/`: the orb + `NightRing`, `NightEmber` (the veil glance's time-left arc),
    `ModeSwitcher`, `MixDrawer`, `TimerSelectionSheet`, `Backdrops` (`ShootingStarView`,
    `NightSkyMotion`). Night sky: `Views/NightSkyMetalView.swift` + `NightSkyShader.metal`.
  - Pure, unit-tested rules: `SessionGuards`, `HomeScreensaverPolicy`, `MorningReadback`
    (`Views/Home/`); `NowPlayingState`, `PlayerClock`, `NightLineCopy`
    (`Views/NowPlayingState.swift`); `LimiterChoice`, `StereoWidth`, `SettingsOrder`
    (`Views/SettingsRules.swift`); `RateRowRule`, `FeedbackMessage` (`Views/TipJar.swift`);
    `RecentNights` (`Views/RecentNightsView.swift`); `LogRetention` (`Services/LogFile.swift`);
    `Models/PodcastText.swift`, `Models/TonightShelf.swift`.
  - Also: `Views/TonightShelfView.swift` (Podcasts' Tonight shelf), `Views/BackupSupportView.swift`
    (Settings ▸ Backup & support; its `RecentNightsView` lists the night journal's verdicts in plain
    words, read-only), the tip card (`CoachmarkContent.tip` in `FirstRunCoachmark`),
    the scenes (`AmbientScene`), `MiniPlayerClearance`, `SoundNames`, `Theme`, `Components`.
    `BackupController` (`Views/BackupControls.swift`) is owned by `SettingsView`, so a restore
    finishes if its page closes.
- **Widget** `SleepulatorWidget/`: the sleep-timer and Pomodoro Live Activities, the Resume widget.
- **Unit tests** `SleepulatorTests/` (XCTest; `grep -h 'class .*XCTestCase' Sleepulator/SleepulatorTests/*.swift` lists the suites):
  - A new scene's shader goes in `MetalShaders.known` (`MetalShadersTests` checks it against the
    compiled `[[stitchable]]` functions).
  - Tests that write the queue, mixes or places keep their own temp-dir store
    (`PodcastQueueManager(storage:)`, `AudioEngine(storage:)`, `PodcastPlayer(storage:)`), never
    the shared files.
  - Hosted tests await the Task a controller call returns (`BackupControllerTests`); never a short
    poll on the main actor.
  - A test that starts a Pomodoro puts it on fakes first (`PomodoroService.onFakes()`): `start()`
    otherwise posts a real notification and requests a real Live Activity, and `Activity.request`
    can stall about 3 s in the test host.
  - `TipStoreTests` (StoreKitTest, `Tips.storekit`) skip in command-line runs on iOS 26 sims and CI
    skips them outright (`SLEEPULATOR_CI`); run them from Xcode (⌘U).
- **UI tests** `SleepulatorUITests/` (XCUITest, in the shared scheme, run on CI): `HomeLayoutUITests`,
  `NightVeilUITests`. The target is made by `Sleepulator/setup_ui_tests.rb` (idempotent; re-run it
  after adding a file).
  - Every UI test passes `-uiTestIsolated <true/>` (`AppInfo.isUITestRun`): a throwaway night
    journal and no rating prompt.
  - DEBUG-only launch seams, compiled out of release: `-uiTestTipProducts`, `-uiTestTipCardDue`,
    `-veilDelaySeconds` (15 s, `SessionGuards.veilDelay`), `-veilGlanceSeconds` (40 s,
    `SessionGuards.glanceHold(override:)`; a unit test pins the real 6 s + 2 s).
  - Pass settings as launch arguments (plist literals, the argument domain). UI tests run in the
    app the unit tests are hosted in, so leave persisted state (mode, night length) as found.
  - Launch with Moving scenes off (`-ambientMotion <false/>`).
  - A tap that matters checks its effect and goes round again (CI drops synthesized taps). Let an
    overlay finish fading in before tapping it. Never race Sleep's 3 s fade with two taps, nor
    with a look: read the wake off the "Show controls" layer (`lookAfterTheWake`).

## Services (the core)
- `AudioEngine`: the app-facing `ObservableObject` facade; owns UI state + policy, delegates to the
  engines below. It does NOT forward child `objectWillChange`: views that show the timer, queue or
  mixes observe those children directly (see `AudioEngine.init`).
- `GenerativeAudioEngine`: `AVAudioEngine` + `AVAudioSourceNode`, rendering noise/binaural on the
  **real-time render thread**, reading params **lock-free** via an atomic double-buffer.
- `PodcastPlayer`: `AVPlayer` + an `MTAudioProcessingTap` Night Limiter. Owns remote commands, the
  time observer and gapless preload.
- `AudioSessionController`: session activation + interruption / route / background observers.
- `SleepTimerService` (+ `PomodoroService`, `ChimePlayer`): the fade-out sleep timer and the
  Pomodoro. `AudioMath` holds the fade curve.
- `PodcastQueueManager`, `MixStore`, `PersistenceMigrator`, `StorageManager` (JSON file store),
  `AudioDownloader` (offline cache), `PodcastParser` / `OPMLParser` / `ITunesSearchManager`.
- `NightJournal`: one record per Sleep session (a night can hold several), on this phone only:
  per-session `.jsonl` event files (the last 2, in Application Support/Sleepulator/nights,
  excluded from backup) and `night-verdicts.json` (the last 30). Clean nights pace the asks; Send
  feedback attaches the files; the morning read-back reads every session of last night; Settings ▸
  Backup & support ▸ Recent nights lists the verdicts (`RecentNights`, its words pinned by tests:
  a new taint gets a `NightRules` constant and a phrase there).
- `Log` + `LogFile`: the playback log. `Log.<category>` is a `LogChannel` with `Logger`'s calls
  and `privacy:` interpolation (`LogMessage`: unmarked strings read `<private>`). Each line goes to
  the unified log and to `LogFile`, which appends it, scrubbed by `NightRules.scrub`, to
  Application Support/Sleepulator/logs (`playback-<day>.log`, excluded from backup; a new part past
  256 KB, files past 3 days or 1 MB in all dropped, `LogRetention`). `append` only takes a lock
  around an array append; the writes are on a utility queue, best effort, with a bounded backlog.
  "Export the playback log" (`LogExport`) and Send feedback read the files (the unified log only as
  the export's fallback), so a 3 a.m. failure survives a relaunch. `LogFile` never calls `Log` (a
  failure would feed itself). Each launch logs a `[app] launch:` line. Test hosts write a temp
  folder (`AppInfo.isUnitTestHost`/`isUITestRun`, nonisolated for it).
- `TipStore`: StoreKit 2 consumable tips, started at launch (`SleepulatorApp`); listens to
  `Transaction.updates`, finishes every transaction, maps outcomes through the pure `TipFlow`. A
  tip unlocks nothing.
- `Backup`: export and restore. A restore validates first, the person confirms in plain counts
  ("4 mixes, 12 shows"), and a snapshot is kept a week for Undo; if the snapshot can't be saved,
  nothing is replaced.
  - `Backup.kinds` is the restore allowlist, with each setting's type and range: keep new persisted
    settings in sync with it.
  - A restore never changes the mode (`Backup.modeKey`); the other mode's sounds go in its per-mode
    picks.
  - A restore stores what decoded (re-encoded, trimmed to what the engine plays, clamped), never
    the file's own JSON.
  - The engine's queued writes land first (`AudioEngine.flushPendingWrites`, passed to
    `Backup.restore`/`undo` as `settle`), before the Undo copy and again before the writes. A new
    background write in the engine belongs in that flush.
  - An export writes only settings a restore takes back, falls back to a file's `.bak`
    (`StorageManager.rawData`), and stays under the 50 MB a restore reads.
  - Undo trusts its own copy (`undoCopy`): settings as stored, file sections as they were, and
    what it couldn't hold (`undoLeftOutKey`) left alone. Files are written with an error check
    (`writeRawNow`); an Undo that couldn't save one keeps its copy (`UndoResult.incomplete`) and its
    week starts again (`undoKeptAtKey`).
  - Restored episodes, shows and saved places' keys are held to `maxFeedFieldBytes` (16 KB); a
    restore takes at most `maxPlaces` places; what's left out for length is counted and said
    (`Contents.tooLong`).
  - The reload after a restore reads files as launch does and never saves over one it can't decode.

## Audio + state invariants (the hard-won stuff — change with care)
- **Never block the render thread.** No locks, allocation or `DispatchQueue` work inside the
  `AVAudioSourceNode` render block; hand-offs are atomic. No `Log` call there or in the podcast
  tap's callbacks either: a log line allocates and takes `LogFile`'s lock (none does today).
- **`AudioEngine` is a coarse `ObservableObject`**: any `@Published` change invalidates every
  observing view. Keep high-frequency values out of `@Published` (`rmsPower` is a plain property;
  the timer republishes at 1 Hz in `SleepTimerService.tick`). Give a view `@ObservedObject var
  audio` only if it displays engine state.
- **The Night Limiter** is loudness-bounded so a podcast spike can't wake you, and can follow the
  mode (on for Sleep, off for Focus). A tap that can't attach fails open
  (`PodcastPlayer.onLimiterUnavailable` → `AudioEngine.limiterOffForStream`): one dim line in the
  full player, only with the limiter on, never a `playbackNote`.
- **The podcast `AVPlayer` is disposable.** Every item carries the limiter tap (volume and the
  sleep fade live there even with the limiter off). `PodcastPlayer` rebuilds the AVPlayer on item
  failure, media-services reset, or its tap-heartbeat watchdog. Never reintroduce one AVPlayer for
  the process. If a podcast is "playing but silent", read the exported log's `podcast resume:` /
  `rebuilding the AVPlayer` lines before touching volume code.
- **Now playing is `AudioEngine.loadedEpisode`, never the queue head.** All loads go through
  `loadPodcast` (an unqueued episode gets a title-only stand-in). Player views resolve the hero and
  Up Next through `NowPlayingState`, not `queue.first` / `dropFirst()`; the player's queue edits
  pin the loaded episode, not `queue[0]` (`PodcastQueueManager.skipToNext`, `moveInUpNext`,
  `shuffleRemainingQueue(nowPlayingId:)`, `remove`/`restore`). Next is a skip, not a finish: it
  never marks played or deletes the download, and plays on with Auto-Play off. Failures carry their
  episode id; `handlePodcastFailure` ignores one from a replaced item.
- **A pause during a load sticks.** `PodcastPlayer.play()` arms `playWhenLoaded` (it plays only
  after the tap attach, up to 1.5 s, and the resume-seek); `pause()` / `stop()` clear it. Mid-load,
  `resume()` / `toggle()` act on the pending load, never the previous item. Engine pauses that
  aren't a tap on a control showing `isPodPlaying` (a call, headphones out, Pause All, Apple Music)
  read `podcastIsPlayingOrStarting`.
- **Item-level news is filed by item.** The end, stall and failure handlers check
  `item === currentItem` and use `currentItemId`, never `currentId`.
- **A failure is not a finish.** `AudioEngine.episodeDidEnd(didFinish: false)` goes to
  `PodcastQueueManager.advancePastFailure`; the episode stays queued with its download. Auto-Play
  moves on only outside the tail and the hold, never to one that already failed in this run, and
  stops after `failureLimit` (3) in a row with the failed ones back at the head. A finish or a
  person's pick resets the count.
- **Downloads live in Application Support**, not Documents (Apple 2.5.x), `isExcludedFromBackup`,
  ~2 GB LRU cap (`AudioDownloader`).
- **Dead tracking prefixes are unwrapped at playback** (`PodcastText.playableAudioUrl`, in
  `AudioEngine.resolveAudioUrl`, so loads and the gapless preload): Chartable's `chtbl.com/track/…`
  404s since it shut down. Stored episodes keep their original address.
- **Persistence is per-key JSON** via `StorageManager`; one oversized write must not abort the
  rest. `PersistenceMigrator` owns the fragile launch-time legacy reads.
- **Sound palettes are mode-scoped.** Sleep and Focus share only Pink
  (`AudioEngine.reconcileSoundsToMode`). Each mode remembers its last noise and binaural pick
  (`lastPick.*`); a mode switch restores it, launch doesn't. A restore puts the other mode's
  current sounds in that mode's picks (`Backup.restorePlan`).
- **The sleep timer starts from the night ring.** `NightRing` sets `nightLengthMinutes` (0 = All
  night, the default). Any Sleep session starting from rest starts the timer at that length
  (`AudioEngine.noteSessionEdge`, on the idle→playing edge of `noiseOn`/`binauralOn`/`isPodPlaying`),
  however it started: orb, mixer, podcasts, lock screen/AirPods, Siri, widget. Never in Focus, for
  All night, or while a countdown runs. The timer sheet opens on the ring's value, All night
  included (an All night chip), and its commit sets the ring: "Play all night" (no timer, or turns
  one off) or a length, "Play & start timer" with nothing playing (`timerCommitTitle`). The pure rules
  (`timerOnPlay`, the mode-switch confirm over a live session, "the night veil only drops over
  sound") live in `SessionGuards`: change them there, not in view code. Tests that start sessions
  set `engine.nightLengthProvider`.
- **All night gets a night too.** Untimed, `nightProgress` runs on the clock (`UntimedNight`:
  0 → 1 over 45 min from the session's start; a pause under 30 min keeps it, a longer one ends it;
  a switch to Focus ends it). Visual only: the audio fade never reads it. Views that darken with it
  (`NightDarken`, `NightFade`) re-read it every 20 s while in sight (`SceneContext.occluded`),
  since an untimed night publishes nothing. The night never brightens at a timer boundary: a timer
  started mid-night starts from where the night is (`SleepTimerService.timedBase`), the ambient
  tail re-bases, a cancel hands the reached night to the untimed clock (`cancelTimer`), and a
  natural end holds until the resume window passes (`fireTerminalStop` → `recordNightEnd`). Only a
  +15m bump eases it back. Focus → Sleep while playing starts the night like Play
  (`AudioEngine.beginSleepNight`).
- **"Stop after this episode" runs on the playback clock.** Offered and started only while the
  episode plays (`startEndOfEpisodeTimer`). A pause hands it to the wall clock with the same end
  (`SleepTimerService.podcastPaused`). The episode's end goes through `episodeEnded()` (the tail if
  set, else the stop). In the tail an ended episode tidies the queue and never auto-plays the
  next; only a person's pick lifts the tail.
- **The night journal only observes.** `NightJournal` never changes playback. It takes the
  engine's edges (`noteSessionEdge`, `beginSleepNight`, the Focus switch, an interruption's begin
  and, with the bed back, its end), live-audio ticks (the RMS tap and the podcast clock; gaps over
  2 s don't count) and taints.
  - Clean means sound that really played: to its timer's end while playing, or 3+ hours ended by a
    person, with no player rebuild, pipeline death or podcast failure while it played (a stream the
    stall watchdog gives up on and the noise engine's start errors count too). A timed night needs
    a minute of live audio (`timedNightMinimumLive`).
  - News while paused is a note, not a taint; so is a dead or rebuilt player in the first 10 s after
    sound starts or resumes (`graceAfterResume`, `isPauseAftermath`).
  - A pause over 30 minutes ends the night where it paused, as soon as the asks look or news
    arrives (`closeLapsedPause`). Only a session edge ends a pause, never live ticks: a night whose
    interruption never sends `.ended` undercounts, never fakes.
  - A pause takes the interruption's own time (stamped before the hop to main); a dead or rebuilt
    player stamped up to `newsLead` (2 s) before it is the pause's; `.ended` carries the night on
    only when the bed really restarted (`restartBedAfterInterruption`) or a podcast resumes.
  - A deadline reconciled on the morning foreground never counts (`SleepTimerService.onTerminalStop`
    fires before `stopAllFn`), nor one a tick finds more than `overdueAfter` (5 s) past (reconciled,
    no ambient tail, ended at the deadline). A deadline from before the open night discards it.
  - Late news is filed by when it happened, into the night whose span holds it, else dropped. A
    record found open at launch while playing is `died`.
  - An interruption's pause is marked (`sessionStopped(interruption: true)`, "<live> interruption"
    in the file); a `.person` close over it records `NightVerdict.interrupted` (nil on older
    verdicts and other endings). Only Recent nights reads it.
  - Nothing written may carry a URL (`NightRules.scrub`). Writes are off main and best-effort;
    audio never waits on them.
- **The asks are rare and daytime.** Rating after 3 clean nights, tip card after 5
  (`cleanNightCount`: one per noon-to-noon by start), never at night.
  - Rating: at a natural break (`\.naturalBreak`: a sheet closed, Settings left), 09:00–20:00, 2+ h
    after the night ended, nothing playing, once per version, never on the tip card's day nor
    while Home shows it (`SessionGuards.tipCardShowing`, by `CoachmarkContent.current`).
  - Card: the same window, Sleep Home at rest only, products loaded and purchases allowed, never on
    the rating's day, in the coachmark band; only an answer spends it.
  - The rules live in `SessionGuards` (`mayAskForRating`, `tipCardDue`). The asks' memory
    (`tipCardSpent`, `ratingAskedVersion`, `ratingAskedOn`, `tipCardShownOn`, `tippedOnThisPhone`,
    `tipTransactionsHandled`) is device-only: keep these keys OUT of `Backup.kinds`.
- **The morning read-back speaks only for a night that held.** Sleep Home at rest, 05:00–18:00.
  Last night is every journal session that started 18:00 yesterday to 05:00 today or has at least
  half its span inside, never just the newest. Any session that died, was tainted or ended on an
  untrusted timer (`NightRules.isClean` false) silences it; one that stopped early without a
  failure doesn't (the line says when the sound stopped, not why). Sound is summed (10+ min as the
  line rounds it); a session of last night's still open (paused) holds it back. Rule:
  `MorningReadback`, unit-tested. A card in the coachmark band takes the morning instead
  (HomeView's `currentTip == nil`, device-checked in TESTING.md §X.6). ContentView reads it with the
  asks (`refreshAsks`, rescheduled via `MorningReadback.nextReread` held on `WindowActivity`) and
  hands Home a plain value, never `@Published`.
- **Isolated deinits.** Under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, any class `AudioEngine`
  owns, or that tests create and free (`SceneClock`, temp-dir `StorageManager`, `PodcastParser`),
  declares `nonisolated deinit {}`. Without it, iOS 18.4–26.3 runtimes abort under XCTest;
  `IsolatedDeinitRuntimeBugTests` catches it on an iOS 26.3 sim (26.4+ hide the bug). CI runs the
  suite on the newest runtime and the newest still-affected one.

## UI conventions
- **Mode palette everywhere.** Views use `Palette(focusMode:)`, so Focus is cool on every tab. A
  view that doesn't otherwise show engine state reads `@AppStorage("focusMode")` (AudioEngine
  writes it) instead of observing `audio`. `Palette(bedtime:)` is legacy (Sleep amber only).
- **Mini-player clearance is measured, not guessed.** ContentView hands each tab `\.miniPlayerTop`
  (nil on Sleep Home unless an episode is loaded); a screen that ends at the bottom edge (a tab
  root, a pushed show page) applies `.miniPlayerClearance()`; Home computes its own
  (`HomeView.homeClearance`). No fixed bottom spacers. On a full-bleed view, put
  `.onGeometryChange` *before* `.ignoresSafeArea()`. `HomeLayoutUITests` guards it.
- **Hidden means not rendered.** On iOS 26, XCUITest's tree sees through `opacity(0)`,
  `.allowsHitTesting(false)` and `.accessibilityHidden(true)`. ContentView takes the hidden
  mini-player out of the hierarchy (`if !miniPlayerHidden`) and presents the Now Playing sheet
  itself. The always-present wrapper also gates `.allowsHitTesting` on `miniPlayerHidden` and
  `.accessibilityHidden` on `miniPlayerHidden || nightDimmed`: keep both (only device steps check
  them: TESTING.md §M7 and its veil step). Prove a view is gone with `waitForNonExistence(timeout:)`.
- **A `.contentShape(.accessibility, …)` can become its container's frame.** HomeView's root sets
  `.contentShape(.accessibility, Rectangle())`. If a screen's controls turn unhittable in
  XCUITest, compare each container's frame in `app.debugDescription` with the screen.
- **Dark-only.** `Info.plist` sets `UIUserInterfaceStyle = Dark` and a `UILaunchScreen` filled with
  `LaunchBackground`; `INFOPLIST_KEY_UILaunchScreen_Generation = NO`; ContentView forces `.dark`.
- **Home's confirms can't present over a sheet.** Close the sheet, then ask
  (`HomeView.requestMode`). Night-time confirms are `.alert`s with no `.destructive` role, never a
  `confirmationDialog`.
- **The night veil runs from the last touch.** ContentView drops it 60 s after the last touch
  anywhere in the window (`WindowActivity`: a recognizer that observes every touch, sheets included,
  and claims none; the pending countdown lives there, not in `@State`), over a playing Sleep
  session: everywhere while a timer runs, only on Home or the Now Playing sheet for All night
  (`SessionGuards.mayNightDim`), never under VoiceOver or Switch Control.
  - A sheet, dialog or full-screen cover makes it wait another round (`SessionGuards.veilTimeout`),
    except an idle Now Playing sheet, which ContentView closes so the veil drops
    (`.closeNowPlaying`; never under VoiceOver or Switch Control).
  - The status bar and home indicator hide under the veil and the Sleep screensaver
    (`SessionGuards.hidesSystemOverlays`); Focus keeps its clock.
  - First tap: a 6 s glance (`VeilGlance`). Second tap wakes the controls (`SessionGuards.veilTap`:
    a tap within 0.8 s is ignored; monotonic clock). With VoiceOver or Switch Control on, one tap
    wakes.
  - Under the veil the tabs, Home's wake layer and the mini-player are hidden from accessibility,
    so only the veil answers "Wake". Check that with Voice Control on a device (TESTING.md §Q.5, and
    §M7's veil step for the mini-player).
- **One name per sound**, through `SoundNames` (binaurals are "Deep", "Drift", …, never "Delta" /
  "Theta").
- **One way to close, one switch tint.** Every sheet closes by a swipe or an xmark at the top right
  (`SheetCloseButton`; `SheetCloseToolbarItem` in a sheet with a nav bar, on the left only where the
  bar's right holds a commit, Import Shows). No Done / Cancel / Close words: a "Done" promised the
  timer sheet kept a pick that only its commit keeps. Every switch tints `pal.controlTint`. A status
  that can't be tapped (the sounds under the orb, `LayerPills`) is a dim line, never a capsule.
  Night menus may keep a red Delete (long-press, swipe); night confirms may not.
- **Podcasts is split by depth.** The library and its Tonight shelf follow the 2am rules (artwork
  dimmed to 0.78 in Sleep, `EmberButtonStyle`, no solid accent slabs); a show's page and the Add
  sheet are the brighter surfaces. Tint swipe actions `pal.actionFill`, never `pal.accent`. The
  Sleep Now Playing sheet: 150 pt desaturated art under a scrim, a `VolumeBar` scrubber, dim notes,
  never amber; its play button and the mini-player's are the orb's dark `PlayerDiscButton`.
- **Manual podcast starts cancel the ambient tail** (`AudioEngine.cancelTailForManualStart`): the
  queue's user-facing plays (`PodcastQueueManager.userStartedPlaybackFn`), never its auto-advance,
  and `AudioEngine.resumeEpisode` (the Podcasts tab's Resume / Back 5 min / Up next / Play Latest).
  `resumeEpisode` also
  continues an already-loaded, settled (`!isLoadingItem`) episode from the live player, starting it
  over if it's spent, and re-heads the queue in one write (`moveToHead`). Resume positions come
  from the player's in-memory map (`savedEpisodePositions`), not the Last Night snapshot; Home's
  Resume (`resumeMix`) too, which also moves past a snapshot episode finished since (no saved
  place + in `finishedEpisodes`). LibraryView reads library.json once; its state is the source of truth.
- **Keep row-visible fields in `Podcast.==`** (it hashes by id; SwiftUI drops a state update whose
  new value `==` the old). Keep `==` O(1).
- **In `List` rows, build icon + text from an `HStack`, not `Label`.** A sheet's data reaches it
  through `.sheet(item:)`, never a separate `@State` read inside the sheet closure.
- **Never `TimelineView(.animation(paused:))`** (it stops driving frames on 120 Hz phones). A frame
  loop that freezes swaps instead: `if paused { staticFrame } else { TimelineView(…) }`, with a
  `@State` `SceneClock` holding the pose (`ShaderBackdrop`, `OrbButton`). A view showing real time
  (the Focus ring, the Focus scenes via `FocusStillFrame`) draws its static frame from the
  published value.

## Build / run
- **Native Xcode build**: open `Sleepulator/Sleepulator.xcodeproj`. No Capacitor, `npm` or
  `cap sync` (that was the archived PWA).
- Deployment target **iOS 17.0** (uses SwiftUI `Shader`/`.layerEffect`, `.contentMargins`).
- Tests: `xcodebuild build-for-testing` once, then `xcodebuild test-without-building
  -only-testing:SleepulatorTests/<Suite> -collect-test-diagnostics never`, on a simulator you
  created, targeted by UDID (`-destination id=<udid>`). Keep the default DerivedData so builds stay
  incremental.

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
