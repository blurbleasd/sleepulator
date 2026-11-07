# Why CLAUDE.md says what it says

CLAUDE.md holds the rules. This file holds what's behind them: the incident, the device or CI run,
the measurement. It was split out of CLAUDE.md on 2026-11-07 so every session doesn't have to load
the history. Read the matching section here before changing the code a rule protects. If the two
disagree, CLAUDE.md wins; fix this file.

Sections follow CLAUDE.md's order.

## Overview

- The Cloudflare feed proxy was removed; `AppConfig.feedProxyUrl`, where it lived, is gone.
- With `TARGETED_DEVICE_FAMILY = 1`, an iPad runs the app in an iPhone window.

## Layout

- `NightEmber` replaced the ring in the veil's glance. Nothing is left over the screensaver: it's
  the scene alone (the user removed the ember from over scenes, 2026-10-11).
- `MorningReadback` draws one dim line in the pills' slot, e.g. "Last night · 1 hr 30 min, eased
  out at 12:41 AM".
- `TonightShelfView` is titled "Tonight" in Sleep and "Continue" in Focus.
- `LimiterChoice` maps Soften loud moments (Off / While sleeping / Always) onto the two stored
  limiter flags. `StereoWidth` has four named stops. `SettingsOrder` puts the current mode's
  sections first and folds the other mode's.
- Settings ▸ Backup & support order: Backup; Troubleshooting (Send feedback, Reports from iOS, the
  playback log); Support Sleepulator last (tips, Rate, the build line).
- `Views/TipJar.swift`'s tip rows are one view shared by Settings and the tip card's sheet.
- `Models/PodcastText.swift` covers show-notes HTML to plain text, counts, durations and
  placeholder names; `Models/TonightShelf.swift` decides what the Tonight shelf and the show page's
  Resume offer.

### UI tests

- `HomeLayoutUITests` checks: Focus's Build mix / Focus session row clears the mini-player and a
  tap starts the Pomodoro; a tap on the shown bar reaches it, and on Podcasts the bar sits above the
  tab bar; on Sleep Home at rest the bar is gone from the accessibility tree and Home's controls
  stay hittable; the tip card sits in the band above Build mix, leaves on No thanks, and Leave a
  tip opens the three tips with Close spending it.
- `-uiTestTipProducts` gives fixed products with no StoreKit; `-uiTestTipCardDue` makes the card
  due now.
- `-uiTestIsolated` exists so a dev simulator's own nights can't reach a run, nor the run's reach
  them.
- `NightVeilUITests` drops the veil on an untimed night, glances, wakes, and checks Focus's
  readout. The veil delay is 15 s there because the real minute made it the slowest test. The
  glance holds 40 s because on CI one slow accessibility query, or XCUITest waiting out a system
  banner inside a tap, pushed the wake tap past the real 8 s, where it counts as a fresh glance.
- Settings go in as launch arguments so the persisted mode and night length stay put.
- Taps that retry after checking their effect: the noise switch, the mode switch, the tab bar (it
  can show a tap dead on target and keep the old tab selected), Focus's Stop, `pauseAudio`, and the
  veil's first tap, whose glance is read off a screenshot since it's hidden from accessibility.
- A tap on the veil as it arrives doesn't reach it, hence waiting for overlays to finish fading in.
- Moving scenes off: an app redrawing every frame never idles, and XCUITest's wait for idle before
  each tap outlasted Home's control fade.
- Racing the 3 s fade with a look: one CI answer took 3.7 s, so NightVeilUITests reads the wake off
  the "Show controls" layer alone and goes round again when no look came inside the fade.

### Unit tests (the suite map, as of 2026-11-07)

- `AudioMathTests.swift`: also `MetalShadersTests` and `SceneSwipeLoopTests` (the swipe loop,
  unique scene ids).
- `AudioStateTests.swift`: `PodcastParserTests`, `OPMLParserTests`, `StorageManagerTests`,
  `NetRetryTests`, `CacheEvictionTests`, the sleep-timer suites, the Pomodoro's clock
  (`PomodoroProgressTests`, `PomodoroMissedBoundaryTests`), Home's pure UI rules
  (`SessionGuardsTests`, `NightRingMathTests`, `MiniPlayerClearanceTests`,
  `HomeScreensaverPolicyTests`, `NightSkyMotionTests`, `FireflyNightTests`, `SnowNightTests`,
  `EasedNightTests`), the podcast rules (`PodcastTextTests`, `ShowNotesPreviewTests`,
  `ShowNotesEdgeTests`, `TonightShelfTests`, `QueueMoveToHeadTests`), the player rules
  (`NowPlayingStateTests`, `NightLineCopyTests`, `PlayerQueueActionTests`,
  `PodcastFailureStreakTests`), Settings' rules (`SettingsRulesTests`), a restore's engine reload
  (`RestoreReloadTests`), the real-AVPlayer suites (`PodcastPlayerRebuildTests`,
  `PodcastLoadHoldTests`, `PodcastItemEndTests`), and the night journal and the asks
  (`NightRulesTests`, `NightJournalTests`, `NightJournalWiringTests`, `AskRulesTests`,
  `MorningReadbackTests`, `CoachmarkTipCardTests`, `RateRowRuleTests`, `FeedbackMessageTests`).
- `PersistenceTests.swift`: `PersistenceMigrator` / `MixStore`.
- `BackupRoundTripTests.swift`: export, read, restore and Undo, the `Backup.kinds` checks, a
  restore never switching mode, and `BackupControllerTests`.
- `FocusDriversTests.swift`: also `FocusStillFrameTests` (one hosted in a window),
  `ContourLightTests` (the radius whose disc covers the interval's share of the screen) and
  `ShaderBackdropEasedNightTests` (hosted: the Sleep host hands its shader the scene's eased night,
  and marks leaving the screen, and passes on another tab, as out of sight).
- `GenerativeAudioEngineTests.swift`: `GenerativeMediaResetTests`.
- `TipStoreTests.swift`: `TipFlowTests` (pure) and `TipStoreTests` (StoreKitTest).

Why the rules:
- Temp-dir stores: every earlier test's objects write the shared files from their own queues,
  which `StorageManager.flush()` doesn't drain, and one queue write landed in a later test.
- Awaiting the controller's Task: the hosted app's first render can hold the main actor 10 s or
  more mid-test, and a 5 s poll ran out under it.
- StoreKit on the command line: iOS 26 simulators hit "[SKTestSession] Error saving configuration
  file … Code=3" and load no products, so those six tests skip with that reason. CI skips them
  outright because a CI simulator that did load products took minutes per purchase and flaked.

## Services

- `Backup.kinds` carries types because a JSON null raised an uncatchable exception in UserDefaults.
- A restore re-encodes what decoded because the decoder ignores unknown keys, so a hand-edited
  backup could carry megabytes into the preferences plist.
- Undo's copy keeps every setting as stored, even one the restore's bounds refuse (a played list
  with a long episode id), and file sections as they were, even ones today's types can't decode.
- `maxFeedFieldBytes` (16 KB) leaves room for the feed parser's 4,000-character guid or title; the
  bound matters because the app copies an episode's id and address into the plist.
- After a restore, a queue or library today's types can't decode shows empty and stays on disk; the
  next edit saves over it, as at launch.

## Audio + state invariants

- **Coarse `ObservableObject`:** the re-render storm from views observing `audio` they didn't need
  is what overwhelmed the podcast list (`perf(podcasts)` fix, 2026-06).
- **Limiter fail-open:** a `playbackNote` raised an amber banner on Home all night.
- **Disposable AVPlayer:** an interruption can kill an AVPlayer + tap pipeline for good; only a new
  AVPlayer recovers. The tap-heartbeat watchdog catches "clock running, no audio".
- **Now playing:** `loadedEpisode` outlives the queue moving on (the sleep-aware hold, a removal).
- **A pause during a load:** before `playWhenLoaded`, a lock-screen pause, a call or the timer's
  terminal stop during an auto-advance was undone, and the playing edge could arm a fresh night
  timer.
- **Item-level news:** `.AVPlayerItemDidPlayToEndTime` arrived off main after a Next had swapped
  the next episode in; filed under `currentId`, it marked the NEW episode played and deleted its
  download.
- **A failure is not a finish:** offline, every load fails, and advancing on each one emptied the
  queue overnight.
- **Mode-scoped palettes:** without the per-mode memory, Sleep's Brown came back from Focus as
  Pink: Focus snapped it to Pink, which Sleep also has. Launch doesn't apply the memory because the
  current sound is already that mode's latest pick.
- **The night ring:** All night (0) is the default so an update never starts timing anyone out.
  Resume, interruption and stall keep the running night. "Play & start timer" exists so a
  countdown never runs over silence.
- **All night's night:** scenes darken and still, comets and meteors retire past 0.4, the orb
  calms. With "Moving scenes" off, Night sky, Fireflies, Lamplight and Rain on glass still darken.
  Before `UntimedNight`, All night never darkened.
- **Stop after this episode:** left on the playback clock through a pause, the bed played all
  night.
- **The night journal:**
  - `timedNightMinimumLive` exists for a deadline that passed while the app slept, fired by a
    morning lock-screen Play: that ends a night that hardly played.
  - The 10 s grace: the watchdog finds a dead player about 4 s in after an alarm.
  - Live ticks can come from a fading bed or a scrubbed paused podcast, so they never end a pause.
  - `onTerminalStop` fires before `stopAllFn` because the stop would otherwise read as a person's.
  - The `overdueAfter` case is the first tick after a Play over a pause that outlived the deadline.
  - A deadline from before the open night: the Play opened a new night, so the old one never played.
  - An off-main failure carries its time, so late news can be filed by when it happened.
  - No URLs: the files go out with Send feedback, and private feeds keep a subscriber's secret in
    theirs.
- **The asks:** `cleanNightCount` counts noon to noon by start so naps don't add up.
- **The morning read-back:**
  - Membership took four rounds to get right. Cases it must keep: a 1:00 bedtime that played to
    9:30 and a session the app died in a minute after Play both count (they start inside 18:00 to
    05:00); an early bedtime at 17:50 counts (half its span is inside); an afternoon rest that ran
    past 18:00 doesn't. Never just the newest session: a morning Play isn't last night, and a night
    the app died in stays broken after the sound is restarted.
  - An interruption that never resumed (an alarm, a call) is closed as `.person` where it paused,
    so it doesn't silence the line. The line says when the sound stopped, not why: a 7:00 alarm is
    the common All-night morning.
  - Two of `MorningReadback`'s tests go through the real journal.
  - `refreshAsks` runs on appear, scene activation, play edges, mode and store changes, natural
    breaks, the veil lifting, a clock change, and the next moment the answer can change (the
    window's edge or a paused session lapsing), rescheduled only when that moment moves.
- **Isolated deinits:** a class with no explicit `deinit` gets an implicit MainActor-isolated one
  (an explicit `deinit` is nonisolated). On iOS 18.4 to 26.3 Swift runtimes that path aborts
  ("pointer being freed was not allocated" in `TaskLocal::StopLookupScope`, swiftlang/swift
  29245e4) when it runs synchronously on main while a task-local is bound outside a Task, and
  XCTest binds one around every sync test. iOS 26.2 is the newest still-affected runtime on the CI
  runner.

## UI conventions

- **Mini-player clearance:** the old 112 / 80 / 60 pt bottom spacers broke as soon as the bar grew
  with text size. Measuring after `.ignoresSafeArea()` gives the un-expanded frame (the tab bar's
  top edge, not the screen's); that bug once hid Focus's whole bottom row under the bar. Home's own
  clearance comes from the screen's bottom edge minus the insets anchored while the tab bar shows,
  so it holds still under the screensaver.
- **Hidden means not rendered:** the bar's removal fade still renders it for 0.9 s, which is why
  the wrapper's gates exist. They stop real taps and VoiceOver at once, though XCUITest's tree
  ignores them; HomeLayoutUITests only checks that the hit-test gate lets a tap reach the shown
  bar. A removal transition keeps a view in the tree until it finishes.
- **The accessibility content shape:** NightRing's band shape made Home's root accessibility
  container a 250 pt square around the orb, which clipped every other Sleep Home control out of
  the accessibility hit test. XCUITest called them unhittable, while real taps still worked.
- **Dark-only:** the generated launch screen followed the system appearance and flashed white on
  every cold launch.
- **Confirms over a sheet:** a confirm raised while the Build-mix sheet is up silently does
  nothing, and the stuck request holds the screensaver off. iOS 26 draws a `confirmationDialog` as
  a popover with no cancel button, which left a lone red button on a dark screen.
- **The night veil:** on other tabs with All night it would black out daytime listening. It's part
  of the root view, so it can't cover sheets; that's why it waits for them. The countdown changes
  on every touch, which is why it isn't `@State`. The glance shows the ember and the night line,
  dim on black. A tap counts as the wake until the glance has faded. The idle Now Playing sheet is
  closed because it's the brightest surface on the night screen; never under VoiceOver or Switch
  Control, which reach it without touches. XCUITest still lists SwiftUI elements hidden from
  accessibility (even Home's opacity-0 chrome), hence the Voice Control check; §M7 covers the
  mini-player because §Q.5 runs where the bar isn't rendered.
- **Swipe actions:** they draw a fixed white label, and `pal.accent` under it is 2.18:1.
- **Manual starts and the tail:** a fresh `play()` never fires `podPlayer.onResume`, so a podcast
  started in the tail would play at its near-zero fade and then be stopped. The Last Night
  snapshot goes stale after a podcast-only pause, so resume positions come from the player's map.
  The queue's user-facing plays are rows, swipes, Play All, and the player's Next and Try again;
  `resumeEpisode` covers the Podcasts tab's Resume, Back 5 min, Up next and Play Latest.
- **`Podcast.==`:** an id-only `==` left library rows stale after a show page loaded more episodes.
- **`List` rows:** inside a row, `Label` gets a wide icon column. A sheet's data read from a
  separate `@State` inside the sheet closure is how the OPML picker opened empty.
- **`TimelineView(.animation(paused:))`:** on ProMotion (120 Hz) phones that schedule stops driving
  frames, so the view moves only when something else redraws it (device, 2026-07-11). A Focus
  scene's bare still frame, never redrawn, kept the idle look a whole session.
