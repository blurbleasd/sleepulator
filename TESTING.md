# Testing Sleepulator (native iOS)

> The previous version of this file described the archived React/Vite PWA (now in
> `archive_webapp/`). This version covers the native SwiftUI app.

Two layers: automated unit tests for the pure logic, and a **manual device pass** for the
things only a real phone can exercise. XCTest has no real render thread or audio session, so
interruptions, route changes, background keep-alive, looping, the Night Limiter, and the
sleep-timer fade + terminal stop can only be verified on a **real iPhone, installed, screen
locked, over a full timer run** (CLAUDE.md § Verification gate). Run the device pass before
every release, and record the result in § Device-pass log below.

---

## 1. Automated unit tests

Open `Sleepulator/Sleepulator.xcodeproj` in Xcode → Product → Test (⌘U), or:

```bash
xcodebuild test -project Sleepulator/Sleepulator.xcodeproj \
  -scheme Sleepulator -destination 'platform=iOS Simulator,name=iPhone 16'
```

Suites in `SleepulatorTests/` (seven files, many suites):

- `AudioMathTests.swift` — fade curve, carrier/beat math, scrub targets, the Metal shader
  preflight set (`MetalShadersTests`, also checked against the app's compiled library) and the
  scene registry (`SceneSwipeLoopTests`: the swipe loop, unique scene ids).
- `AudioStateTests.swift` — engine state/policy plus `PodcastParserTests` (CDATA, durations,
  dates, caps, enclosures), `OPMLParserTests` (scheme validation, dedupe, corrupt files),
  `StorageManagerTests` (backup recovery), `NetRetryTests`, `CacheEvictionTests`, the
  sleep-timer suites (backstop, cancel, end-of-episode), the Pomodoro's clock
  (`PomodoroProgressTests`; `PomodoroMissedBoundaryTests`: boundaries a late tick finds start
  the next phase at the boundary, each one counted) and Live Activity
  (`PomodoroLiveActivityTests`: a start ends what was up and keeps its own, Stop ends it),
  layering, mode reconciliation, the
  Night sky meteor's rules (`NightSkyMotionTests`: only while the controls show, faint, rare after
  the first, never popping), and the
  Podcasts-tab rules (`PodcastTextTests`, `ShowNotesPreviewTests`, `ShowNotesEdgeTests`,
  `TonightShelfTests`, `QueueMoveToHeadTests`), the player rules (`NowPlayingStateTests`,
  `NightLineCopyTests`, `PlayerQueueActionTests`, `PodcastFailureStreakTests`), Settings' rules
  (`SettingsRulesTests`: the limiter choice, stereo stops, section order, the hold's spoken
  value), a restore's engine reload (`RestoreReloadTests`: Pomodoro lengths applied, the night's
  timer kept, the queued writes flushed first, an undecodable queue left on disk, the played list
  held to the backup's limits), and three suites
  on a real `AVPlayer` in the simulator: `PodcastPlayerRebuildTests` (dead-pipeline rebuilds),
  `PodcastLoadHoldTests` (a pause, stop or call during a load sticks) and `PodcastItemEndTests`
  (an episode's end is filed under its own item). The night journal and the asks:
  `NightRulesTests`, `NightJournalTests` (pauses, lapsed windows, late news filed by time,
  recovery after a kill, the soft cap, force-quit), `NightJournalWiringTests` (session edges,
  interruptions, the timer's stop, a podcast failure), `AskRulesTests`, `MorningReadbackTests`
  (the read-back's window, wording, re-read times and which sessions are last night; two through
  the real journal), `CoachmarkTipCardTests`, `RateRowRuleTests`, `FeedbackMessageTests`.
- `PersistenceTests.swift` — legacy `SavedMix` → `SoundPreset` migration, library seeding,
  position-map coercion, `MixStore` reloads.
- `BackupRoundTripTests.swift` — the backup's export → restore round-trip, its typed allowlist
  (`Backup.kinds`: a null, wrong type or out-of-range value is skipped), the confirm's counts,
  restore → Undo end to end, refusing when the Undo copy can't be saved, what a restore stores
  (decoded and bounded, never the file's own JSON), Undo putting back its own copy exactly (and
  keeping it when a file can't be saved), an export's `.bak` fallback and 50 MB cap, and a
  restore never switching mode. `BackupControllerTests` covers the Backup page's controller:
  results that land after the page closed, the export letting go of its document, an incomplete
  Undo, and the queued writes landing first.
- `FocusDriversTests.swift` — the Pomodoro → Focus-scene look mapping, `FocusStillFrameTests`
  (with Moving scenes off, a Focus scene's still frame redraws on each Pomodoro publish and reads
  it afresh; one test hosts it in a window), and Contour's light (`ContourLightTests`: the radius
  whose disc covers the interval's share of the screen).
- `GenerativeAudioEngineTests.swift` — generative-bed rebuild after a media-services reset.
- `TipStoreTests.swift` — `TipFlowTests` (every StoreKit outcome to what the tip rows show) and
  `TipStoreTests` (StoreKitTest against `Tips.storekit`). On iOS 26 simulators a command-line run
  hits Apple's SKTestSession bug and loads no products, so those six skip there, and CI skips
  them outright (`SLEEPULATOR_CI`); run them from Xcode (⌘U).

These catch parsing/logic regressions cheaply; they do **not** exercise audio or iOS behavior.

---

## 2. Simulator smoke test (fast gate, do first)

1. Build and run. No warnings-as-errors, no console errors at launch.
2. Play a noise; add an extra layer; toggle binaural. Audio in both modes (Sleep / Focus).
3. Switch modes — active sounds snap into the new mode's palette (no cross-mode leftovers).
4. Load a podcast episode; play/pause; volume slider works alongside noise.
5. Set a **1-minute sleep timer** — volume ramps down smoothly, then everything stops.
6. Save a mix; relaunch; the mix and last state restore.

If anything here fails, fix it before touching the phone.

---

## 3. Device pass — real iPhone, installed (highest value)

Install via Xcode onto the device (not the simulator). Then:

### A. Background audio + lock screen
1. Start a mix (noise + binaural), lock the screen. ✅ Audio keeps playing.
2. Wake the lock screen. ✅ Now Playing controls show; play/pause and skip work for podcasts.
3. Leave it locked for 30+ minutes. ✅ No dropout (AudioSessionController keep-alive).

### B. Interruptions + route changes
1. Playing and locked: call the phone from another device, end the call.
   ✅ Audio resumes within a couple of seconds — **including the podcast** (2026-07-05 fix:
   the resume used to check a flag the pause had already cleared, so a bedtime call
   permanently silenced the podcast; now a `wasPlaying` snapshot restores it).
2. Trigger Siri mid-playback. ✅ Ducks/pauses, then recovers.
3. Plug/unplug headphones (and connect/disconnect Bluetooth). ✅ Correct pause-on-unplug
   behavior, no crash, binaural routing (`beatRouting`) still correct.
4. **Stop-during-call must stick** (2026-07-05, unverified): mid-call, tap Stop on the Live
   Activity (or let the sleep timer expire during the call). End the call.
   ✅ Nothing resumes — the deliberate stop is not overridden by the interruption-ended resume.
5. **Route loss during a call** (unverified): podcast on AirPods, take a call, put the AirPods
   in the case mid-call, end the call. ✅ The podcast does NOT resume on the loudspeaker.
6. **"Plays muted until force-quit"** (2026-10-07, unverified). Reported symptom: the clock moves,
   the noise bed is audible, only the podcast is silent, and it lasts until a force-quit. Seen
   on mornings with NO alarm, and after other apps' audio. The podcast `AVPlayer` always carries
   the limiter tap, and an AVPlayer + MTAudioProcessingTap pipeline can die under it (documented
   for the Clock alarm on iOS 17+). Only a new AVPlayer recovers, and the app used to keep one for
   its whole life. Now it rebuilds on item failure, on media-services reset, and via a heartbeat
   watchdog: the clock advances 4 s with the tap never fed, or 45 s with the tap fed only digital
   silence. Run each with a podcast playing, **without force-quitting between them**:
   a. Overnight timer with earbuds in; let them fall out / disconnect; next morning, play (lock
      screen and in-app). ✅ Audible, or audible within ~4 s after a brief hiccup.
   b. Play a video/voice note in another app, come back, tap play. ✅ Audible.
   c. Set a Clock alarm 1 min out, let it ring, stop it. ✅ Never "playing" in silence.
   d. After any of these, pick a *different* episode. ✅ Audible (it used to inherit the dead
      player).
   If it still happens, **Export logs** and look for: `podcast resume: level=… fed=… signal=…
   route=…` (one per resume), `clock running but no audio`, `rebuilding the AVPlayer`,
   `failed to play to end`, `media services reset`.
7. **Noise bed survives a media-services reset** (2026-10-07, unverified on device). After a
   reset every audio object is invalid. The generative `AVAudioEngine` used to be created once
   for the app's lifetime, so the noise/binaural bed stayed silent until relaunch. Now
   `GenerativeAudioEngine.handleMediaServicesReset` stops the old engine, builds a new one, and
   restarts it only if noise or binaural is on. Unit tests cover the swap and the restart, but
   not the audio. Force the reset with **Settings > Developer > Reset Media Services**:
   a. Noise + binaural playing, screen locked. Reset. ✅ The bed comes back within a few seconds
      (it ramps in, with no pop) and plays at the same mix, volume, and sleep-timer fade level.
   b. Noise off, podcast only. Reset, then turn noise on. ✅ Noise plays.
   c. After (a), plug or unplug headphones. ✅ The bed keeps playing: the configuration-change
      observer follows the new engine.
   Export logs: look for `rebuilding the generative engine`.

### C. Sleep timer — fade + terminal stop (full run)
1. Set a realistic timer (≥ 30 min), lock the phone, let it run to the end **unattended**.
   ✅ Volume fades over the final stretch and playback fully stops — no zombie audio, no
   abrupt cut.
2. Repeat once with a podcast in the mix. ✅ Podcast and generative audio stop together.
3. Extend the timer mid-fade. ✅ Volume restores smoothly, timer extends. (2026-07-05: the
   restore ramp is now buffer-size-independent, ~10 s full-scale — listen for stair-stepping
   on a binaural-only bed with the screen locked, the most zipper-revealing case.)
4. **Ambient tail integrity** (2026-07-05, unverified): podcast + bed + a timer with a tail
   configured. ✅ At expiry the podcast stops and the bed carries on; during the tail neither
   the Live Activity nor the in-app "Still awake?" capsule offers "+15m" (the LA subtitle
   reads "Winding down — ambient only", no truncation on small screens); a bed-only night
   (no podcast loaded) gets NO tail — the timer stops when set.
5. **A deadline missed during a pause** (2026-10-12, unverified): a mix only (no tail), a 5 min
   timer. Pause from the lock screen at 3 minutes, lock, wait 5 minutes, then Play from the lock
   screen. Install and run it without Xcode attached (the debugger keeps the app from
   suspending, so the timer fires on time over the pause). ✅ The sound stops at once (the timer
   is spent) and the playback log reads `terminal stop: duration timer found …s past its
   deadline`, the night file closing `timer … reconciled` at the deadline's time. Or, when iOS
   delivers the timer's tick before the Play: the night closes `person …` at the pause and the
   Play plays on under the ring's timer. Log which you saw; either way the night isn't clean
   (§3U.12).

### D. Night Limiter (acceptance for enabling by default)
`AppConfig.nightLimiterEnabled` ships `false` until this passes and is logged below.
1. Turn the limiter on (Settings ▸ Podcasts at night ▸ Soften loud moments ▸ **Always**). Play a
   podcast episode with a known loud spot (dynamic ad read, intro sting), phone locked, at a low
   comfortable volume.
   ✅ The spike is audibly tamed; speech stays intelligible; no pumping/distortion.
2. Let it run ≥ 1 hour locked. ✅ No glitches, dropouts, or battery anomalies
   (the tap must never block the real-time thread).
3. Settings ▸ Podcasts at night ▸ Soften loud moments ▸ **While sleeping**: ✅ on in Sleep, off in
   Focus, mid-playback switch is clean. **Always** stays on in Focus; **Off** stays off in Sleep.

### E. All-night soak
1. Full night (or ≥ 4 h): mix + timer, screen locked. ✅ Still behaving at the end —
   timer fired, audio stopped, no crash log in Settings → Privacy → Analytics.
2. A full night on the default: **All night** (the ring at its start), a mix plus three or more
   queued episodes, Auto-Play on, screen locked. ✅ In the morning the mix is still playing, the
   episodes played through in order (or the queue ran out and the mix carried on), and nothing
   stopped on its own. Settings ▸ Backup & support ▸ Send feedback: ✅ the summary counts the night
   as clean (3+ hours of sound, no rebuild or failure in it).

### F. Loop + generator quality
1. Each noise type for several minutes. ✅ No click, gap, or pop; no drift in stereo width.

### G. Offline + storage
1. Download an episode, enable Airplane Mode, relaunch. ✅ Downloaded episode plays.
2. Confirm downloads live in Application Support and are excluded from iCloud backup.

### H. Ambient scenes — settle, freeze, and the phase clock (added 2026-07-05, unverified)
The SceneClock refactor (ShaderBackdrop.swift) put every shader scene (and Breathe) on an
integrating phase clock, and (since the 2026-07-11 ProMotion stall) on an
`if paused { still frame } else { TimelineView }` swap rather than
`TimelineView(.animation(paused:))`. Rain on glass never used the clock: its drops run on
absolute time and drop out when held still. XCTest covers the clock math;
everything below is display-link / render behavior only a device shows.

1. **Freeze is truly static.** Start a Sleep mix + timer, let the veil engage. In Xcode's Debug
   navigator (or Instruments → Core Animation), FPS ≈ 0 and no CA commits from the app while
   the veil is up, beyond a 1 Hz commit from the timer's observers on a timed night (NightDarken,
   NightFade, the ring); on All night ≈ 0. Repeat with each of: Night sky, Aurora, Embers, Still water, Deep space,
   Breathe, Rain on glass. ✅ No redraws, no meteor wakeups (Night sky), gyro off (Aurora /
   Deep space — check with the Energy Log that CoreMotion isn't running).
2. **Freeze-in-place, not reset.** Tap to wake after ≥ 10 min under the veil. ✅ Every scene
   resumes from the pose it froze at — no snap to a birth pose, no burst of catch-up motion.
   Repeat via the lock/unlock path (scenePhase) and the app switcher.
3. **Night slowdown direction.** Run a short timer (10–15 min) on Aurora and Still water and
   watch the last minutes. ✅ Motion eases — curtains/waves slow smoothly, never stall-and-
   reverse (the old `time × factor` bug) and never jump when nightProgress ticks.
4. **Transients sleep.** Same short-timer run on Night sky and Deep space. ✅ Meteors dim as
   the night deepens and stop past ~40%; the comet fades out past ~15% and is gone by ~40%;
   a freeze never leaves a comet/meteor burned on the frozen frame (try pausing repeatedly
   around the two-minute comet cycle).
5. **Focus scenes.** Current: streams *flow* during a running pomodoro — no per-tick jitter — and
   momentum builds over a work interval, eases on break.
   **Moving scenes off (added 2026-10-13, simulator-checked only; Contour added 2026-10-21, simulator-checked).** Settings → Moving scenes off,
   Focus, a 5-minute Focus length so the change is quick to see. On each of Current, Tide,
   Sandfall and Contour, start a session and let the controls fade. ✅ The scene holds its pose,
   but its reading follows the interval, creeping with the countdown: Current's front crosses,
   Tide's waterline rises, Sandfall's top bulb drains, Contour's light spreads from the summit
   (`FocusStillFrame`). ✅ A start, a break and a stop show at once. Lock for 30 s and unlock,
   then once more across a phase boundary (the next phase now starts at the boundary itself,
   §I step 6). ✅ The reading is at the true time.
   Out of sight it stops: mid-session, with Instruments' SwiftUI template attached, pull down
   Control Center or Notification Center over Focus Home (the app goes inactive with Home still
   behind it; Always-On and the Lock Screen background the app, which renders nothing and so
   proves nothing). ✅ `FocusStillFrame`'s body stops being evaluated and the GPU shows no
   full-screen fragment pass until it's dismissed, then the reading is at the true time; the
   Focus ring's and readout's own 1 Hz updates are expected. Before the fix the still frame kept
   the look it had when Focus came up (the idle one) all session.
6. **Veil caption.** Veil engages → "Tap to wake" rides the fade in, fades out ~6 s later,
   panel is then true black (check no lit pixels in a dark room). Wake → re-engage: caption
   reliably re-shows.
7. **Battery / burn-in soak.** One full night per §3E on Deep space or Aurora with the veil up.
   ✅ Battery drain comparable to pre-refactor (log % at sleep/wake); no image retention.

### I. Premium controls / mixer (added 2026-07-05, unverified)
Foundation restyle — shared design tokens, GlassPanel/VolumeBar/ChipRow, shape + caption
reductions. All calibrated by eye; only a real dim panel settles it. Do this in a dark room at
the brightness you actually use at night, in **both** Sleep and Focus.

1. **VolumeBar relative drag + fader tiers.** In the Build-mix drawer, grab a layer fader. ✅ It
   moves by the drag *delta* from where you grabbed (not jump-to-touch); a light tap does NOT
   change volume; drifting the finger up/down off the track fine-trims. Then check Settings'
   "How much" softening bar (Podcasts at night, under "Soften harsh highs and boomy lows"; it's
   Settings' only bar, since stereo width is a four-stop menu, §S7): a *tap* there DOES jump to
   that position (tapToSet). VoiceOver reports the real value. Gain-staging reads at a glance: the
   master fader (bottom bar) is visibly the thickest, layer faders next, the "How much" bar slimmest.
1b. **Now-playing rim.** Apply a saved mix. ✅ Its card wears a brighter accent rim + fill and a
   bright (legible) summary line; the rim clears when you swap a sound or toggle a layer; exactly
   one card is lit (a "Brown" and a "Brown + Rain" preset don't both light); an idle/silent
   mixer lights none. Check the active summary text is legible in both Sleep (gold) and Focus.
2. **Selected chip legibility.** Noise/binaural preset chips and the timer duration/tail chips:
   ✅ the selected chip (cream label on a dim accent tint + lit border) is unmistakably readable
   and distinct from unselected at bedtime brightness — both gold (Sleep) and cyan (Focus).
   Unselected chips still read as tappable (hairline), not flat text.
3. **GlassPanel depth, not glare.** Mixer rows / Settings sections: ✅ read as warm lit glass
   (Sleep) / cool glass (Focus) with a soft dark drop — no bright rim, no glow. If Bedtime was
   ever enabled (legacy `bedtimeMode`), panels stay flat on true black — no warm top-rim.
4. **Timer hero number.** ✅ The 44pt count doesn't glare when the sheet opens at 2am; the
   numeric transition on preset taps is smooth; at large Dynamic Type it scales without clipping
   and the Start button is still reachable at the `.medium` detent on a small phone.
5. **The orb breath.** With a mix playing, the play orb swells *gently* with the generative bed
   (noise/binaural) — ✅ a slow drift, not a pulse; on a loud bed its max swell (~1.11×, up from
   the old fixed 1.06×) doesn't catch a drowsy eye. As a timer runs down the swell shrinks to
   nothing (still by fade-out). Instruments (Core Animation): while the orb is visible the 32pt
   blur is cached across the scale-only frames — no per-frame offscreen re-rasterization — and
   under the veil / screensaver the orb's TimelineView is fully stopped (0 fps, no all-night
   composite). On wake it resumes from its frozen pose with no visible pop.
6. **Focus ring (Pomodoro).** Run a Focus session. ✅ The arc depletes *smoothly* (30 fps
   continuous, not 1 Hz steps); the lit leading cap rides the shrinking edge cleanly (no bulge
   against the 6pt arc, no flicker as it empties). At each work↔break boundary the arc eases
   back in over ~0.5 s (refill), not a hard snap — a chime + label change accompany it. Skip
   phase eases in the same way. Background / lock the phone mid-session: Instruments shows the
   ring's 30 fps redraw fully stopped (paused); on return the arc is at the correct remaining
   time with no jump-back. Idle (no session): the faint track ring is still perceptible at low
   brightness.
   **A boundary crossed while locked (added 2026-10-20, unit-tested only).** Install and run it
   without Xcode attached, as in §3C step 5: the debugger keeps the app from suspending, so the
   boundary passes on time and the step can't tell the fix from the old code. Settings: Focus
   length 5 min, short break 1 min. Start a Focus session with no sound (nothing keeps the app
   awake, so it's suspended while locked) and lock at about 4:00 left. Unlock 4.5 min later.
   ✅ The break shows about 0:30 left, not a fresh 1:00, and the ring, readout and Live Activity
   agree. Stop, start again, lock at about 4:00 left, and unlock 7 min later. ✅ The session is
   in its second focus interval with about 3:00 left, one round done in the cycle dots, and no
   run of chimes (one at most). Only the first boundary posts a notification while locked: a
   phase's notification is scheduled when the phase starts, and a suspended app starts none.
   Before the fix the next phase began at unlock and ran its full length.
7. **Focus Live Activity (added 2026-10-20, passed on device 2026-10-20).** Start a Focus session, lock
   the phone: ✅ the Pomodoro's Live Activity is on the Lock Screen and in the Dynamic Island, and
   it stays up past a minute (before the fix it ended as soon as it appeared). Unlock and press
   Stop: ✅ it's gone from both. Start again: ✅ a new one, and it stays up. Force-quit the app
   with it up, reopen, start a session: ✅ just one activity, the new one, still up.

### J. Resume integrity + diagnosability (added 2026-07-05, unverified)
1. **Muted layer survives resume.** Build a mix with an extra layer, mute that layer, stop.
   Reopen and "Resume Last Night". ✅ The layer comes back still muted (it used to un-mute).
2. **Save-on-background durability.** Save a mix, then immediately background the app (within a
   second). Force-quit from the app switcher. Relaunch. ✅ The saved mix is still there (the
   deferred write is flushed synchronously on background). Repeat with audio NOT playing.
3. **Overnight log export.** After a night (or any session with a timer + a call/route change),
   Settings ▸ Backup & support ▸ "Export the playback log". ✅ The share sheet produces a
   readable text timeline — sleep-timer start/bump/tail/terminal-stop, interruption began/ended
   (with the resume decision), route changes, limiter-attach outcome — not a wall of `<private>`
   (verify on a release build) and not slow to generate.

### K. Confirmed 2am bug fixes (added 2026-07-05, unverified)
1. **Breathing on-ramp survives lock (the load-bearing one).** Settings → enable "start with a
   minute of breathing". Start a Sleep session so the wind-down appears, then **lock the phone
   mid-countdown**. ✅ The mix actually starts and plays all night — backgrounding fires
   `begin()` before suspension and the audio session activates in time. (This is a timing race
   only a device settles — the whole point of the fix.) Also confirm a notification banner /
   Control Center pull-down mid-countdown does NOT prematurely start the mix.
2. **Podcast stall doesn't buffer in silence forever.** On a throttled/flaky connection, play a
   streamed episode until it underruns. ✅ A "Buffering…" note shows; a stream that recovers
   within ~30–60s resumes with no skip (ride out a real network dip); a genuinely dead stream is
   dropped after the bounded wait with an honest note, and the generative bed keeps playing. A
   404 / failed episode advances too — and is NOT recorded as "played" (doesn't vanish under
   "Hide played episodes"). During a sleep timer with hold-queue on, a lost stream just leaves
   the bed running (no jarring next episode at 2am).
3. **Queue removes the right episode.** With delete-on-completion on, reorder the queue (or play a
   non-head episode) and let it finish. ✅ The episode that finished is the one removed/deleted —
   never an innocent head.

### L. Depth scenes — the shared `.layerEffect` host: rain-depth + ocean (added 2026-07-05, unverified)
The visual-moat build (commits E1→P6a; `docs/designs/VISUAL-MOAT-REACTIVE-SCENES.md`). `DepthBackdrop`
(ShaderBackdrop.swift) is a new `.layerEffect` host — the depth scenes now ride `SceneClock` +
`sleepTimer.nightProgress` + the built-in `paused:` freeze, same rail as the `.colorEffect` scenes in
§3H. Both depth scenes are **DEBUG-only** A/B siblings, reached by swiping the home backdrop
(`HomeView.cycleScene`): **"Rain (depth)"** next to the shipping "Rain on glass", **"Still water
(depth)"** next to "Still water". The ocean lens was **authored blind** — expect a real tuning round;
this section is where you do it. Do it in a dark room at your real bedtime brightness.

1. **Freeze-in-place (the E1 fix — the load-bearing one).** Swipe to "Rain (depth)". Start a Sleep mix
   + timer, let the veil engage; tap to wake after ≥ 10 min. ✅ The drops resume from the pose they
   froze at — **no snap back to a birth pose** (the `t:0` bug E1 removed; the old DEBUG rain-depth did
   snap). Repeat via lock/unlock (scenePhase) and the app switcher. Repeat for "Still water (depth)".
2. **Reactive settle — rain (P2).** On "Rain (depth)", run a short timer (10–15 min) and watch the last
   minutes. ✅ The rain eases to ~half speed, the mist thins, the dry glass fogs (dimmer + milkier), and
   the lights behind defocus further — all *smoothly*, monotonic, never a jump when `nightProgress`
   ticks. At bedtime (night 0) it looks exactly as it did before (base params).
3. **Reactive settle — ocean (P2/P4).** Same short-timer run on "Still water (depth)". ✅ The swell
   calms, the horizon fogs, the reflection softens as the night deepens; motion eases (never
   stall-and-reverse).
4. **Ocean reads as water (P4 — the blind-authored part).** Prop "Still water (depth)" and just look.
   ✅ It reads as a night pond: the moon + horizon glow appear *reflected and rippling* in the water,
   near foreground swell sharper, the horizon a soft near-mirror. If it reads as a smeared mirror or the
   moon reflection lands wrong, tune `StillWaterLens.metal` (`AMP`, `HORIZON`, `MOONX`, reflectivity) +
   `StillWaterDepthView` (moon glow position/size, `swellBase`) and rebuild. Prove the seam first with
   `refraction = 0` (flat mirror), then dial it up (§10 step 2→3).
5. **A/B vs the flat scenes (P3, retire on a clear win).** Swipe between "Rain (depth)" ↔ "Rain on
   glass", and "Still water (depth)" ↔ "Still water", at the bedside over a full timer. Decide by the
   **clear-win rule:** the depth version ships only if it holds framerate with no measurable battery
   regression vs the flat baseline (read the diagnostics log, item 6) **and** you prefer it blind in ≥ 2
   of 3 sessions. Otherwise iterate, or hit the **kill criteria** — if after two A/B cycles it can't
   clear the power budget without cutting drop count / fps / DoF below where the "whoa" survives, cut
   back to the flat scene.
6. **Measured, not eyeballed — read the F3 diagnostics log (P1 power budget).** After a 30–60 min run per
   scene, Settings ▸ Backup & support ▸ "Export the playback log". ✅ It carries
   `scene=… fps=… thermal=… battery=…` lines (category `scene`). Confirm: fps holds ≈ 30 on the depth
   scenes; `thermal` stays `nominal`/`fair` (never `serious`); per-scene battery drain is ≤ the flat
   baseline (measure the shipping rain / still-water first as the baseline). Confirm an 8 h locked run's
   drain is within budget too (log battery % at sleep and at wake).
7. **Idle-freeze truly stops the loop (P5).** With NO timer running, stop touching the phone; after ~8 s
   the backdrop settles (screensaver). On a depth scene, check Instruments → Core Animation (or that the
   `scene` fps lines stop in the log). ✅ The shader redraw loop is *stopped* (0 fps), not just faded — a
   depth scene left on the nightstand with no timer must not run the `.layerEffect` all night. Both scenes.
8. **Shader guard — no silent black (F2).** ✅ At launch the log carries `Metal shader preflight: all N
   known shaders present`. If a lens ever fails to compile, its backdrop shows the bare far world
   (bokeh / sky), never a black pane, plus a `not in the default library` line. (To exercise on purpose,
   a dev can rename a stitchable function and rebuild — optional.)
9. **Ambient-motion toggle (P6a).** Settings ▸ Display ▸ **Moving scenes → Off**. ✅ The backdrop
   immediately holds a single still frame (try rain-depth, ocean, and a `.colorEffect` scene like Aurora
   — all still), CoreMotion stops (Energy Log: no motion updates), tilt parallax gone. Back ON → the
   scene resumes from its frozen pose, no pop. The toggle survives Backup → Restore.

### M. Night ring + session guards (added 2026-10-09, simulator-checked only)
1. **The ring sets the night.** Sleep Home at rest: drag the ring's handle clockwise from 12 to
   ~45. ✅ Light haptic ticks on the quarter hours, a big "45 min" readout inside the orb while
   dragging, the line reads "Resume · … · 45m". Drag back to 12 → "All night". A drag that starts
   away from the handle (or a left/right scene swipe across the ring) changes nothing.
2. **Play honours it — from every start.** Ring at 45, then start a Sleep session from rest each
   way: ▶, a mixer switch, a podcast (Podcasts tab / mini-player), lock-screen or AirPods play, the
   Siri "Start my mix" shortcut, the resume widget. ✅ Each starts a 45-min timer (Live Activity
   appears); the arc shrinks over the night. Pause and resume → the countdown carries on (not
   restarted). A phone call mid-session → the same countdown resumes. Ring on All night → plays with
   no timer. Focus never starts one. With the breathing on-ramp on, the timer starts when the mix
   does, not during the minute of breathing.
3. **Drag mid-night.** While playing, drag to 20 → timer restarts at 20; drag to 12 → timer off.
   In the last 2 minutes and in the ambient tail the ring is locked (handle dims); "+15m" works.
4. **Mode switch asks first.** With sounds playing or a timer running, tap Focus (also with the
   Build-mix half-sheet open: it closes, then asks). ✅ "Switch to Focus?" pointing at the switch;
   tap outside → nothing changed. Confirm → Focus, timer gone. Focus → Sleep only asks over a
   running Pomodoro. The switch sits at half opacity during a sleep session.
5. **Veil only over sound.** Start a timer, then pause. ✅ The 60 s night veil does not drop over
   silence; resume → it drops a minute later. Waking the veil ramps up over ~1.6 s, not a flash.
6. **Dark launch.** Cold-launch at night. ✅ No white flash before Home (warm near-black launch).
7. **VoiceOver.** The ring is "Night length, 45 minutes", swipe up/down adjusts in 5s; the on-ramp
   close button says "Close without starting your mix" (and doesn't start it).
   *Touch exploration (added 2026-10-10).* On Sleep Home at rest, slide a finger around the
   screen. ✅ The mode switcher, the night line and Build mix are each found by touch, not only by
   swipe. The orb's centre reads "Play", the band around it "Night length", and nothing reads from
   the hidden mini-player's spot above Build mix.
   *The bar's fade-out (added 2026-10-10).* With something queued but nothing loaded, go from
   Podcasts to Sleep (Build mix is already in place there) and tap Build mix where the "Up next"
   bar is still visibly fading; if the bar had already gone, try again. ✅ The mixer opens; never
   Now Playing, Podcasts or a playing queue. With VoiceOver on, focus never lands on the fading
   bar. To widen the window, run it in the Simulator with Debug ▸ Slow Animations (the ~1 s fade
   takes about 9 s): a tap on Build mix through the half-faded bar must still open the mixer.
   *The bar under the veil (added 2026-10-11).* With something queued but nothing loaded, start a
   30-min night from the orb with a podcast-free mix (the bar must read "Up next"), go to Podcasts
   and let the veil drop. ✅ With Voice Control's "Show names" only the veil is labelled,
   and "Tap Play queue" and "Tap Up next: <episode title>" (the bar's full name, as "Show names"
   labels it before the veil) do nothing (no podcast starts, Now Playing stays shut);
   with VoiceOver turned on, swiping finds only the veil. (XCUITest can't tell: it lists the bar
   either way.)
8. **Ring drag keeps the controls awake.** Mid-night (sounds playing): tap to wake, then drag the
   ring slowly for 5+ s. ✅ The controls don't fade under the finger; ~3 s after release they do.
   Inside the last 10 minutes the ring is locked (handle dims); a drag that ends where it began
   doesn't restart the timer (no Live Activity flicker, no volume change).
9. **Timer sheet ↔ ring.** With nothing playing, sheet "Play & start timer" (with and without the
   on-ramp) starts the mix and sets the ring to that length; "Play all night" stops tonight's
   countdown and leaves the ring on All night (tomorrow plays all night too until a length is set);
   the sheet opens on the ring's length. Long-press the orb → "Timer options".
10. **Mini-player on Sleep Home.** At rest with only a queue ("Up next"), no bar on Sleep Home; load an
   episode → the bar appears and Home's controls rise to clear it; pause/play the podcast → nothing
   moves. Focus Home, Podcasts and Settings always show it, and nothing sits under it at the
   largest text size. On Focus Home, check that both Build mix and Focus session show above the
   bar and that Focus session starts the Pomodoro. Check this on the smallest supported phone too
   (iPhone SE) at the largest text size. The whole row once sat hidden under the bar; this was
   fixed 2026-10-09 and simulator-checked, and `HomeLayoutUITests` now covers it.
11. **Focus colours everywhere.** In Focus, the tab bar, mini-player, Now Playing, Podcasts and
   Settings are cyan, not amber.
12. **Veil after a restart.** While playing, restart the timer from the sheet or the ring. ✅ The
   night veil still drops ~60 s later.
13. **Dark launch on upgrade too.** Check M.6 on a fresh install AND on an in-place upgrade (iOS
   caches launch screens; an upgrade can show the old white one once).
14. **"The sleep timer moved" note (upgraders only).** Install over a build from before the ring
   (first run already done). ✅ Sleep Home shows the note once, below the night line, never over
   the ring or the line; "Got it", dragging the ring, or opening timer options retires it for good.
   A fresh install sees only the first-run card, never this note.
15. **A dark night, start to finish** (added 2026-10-09, simulator-checked only). Sleep, a timer
   set, playing:
   - The Sleep screensaver and the veil show no clock, battery or home indicator. Focus's
     screensaver still shows the clock.
   - Adjust the mix for over a minute in small touches. ✅ The veil never drops while you're
     touching. ✅ It drops a minute after the last touch.
   - Leave the mixer (or the timer sheet) open and untouched for 2+ min. ✅ The veil doesn't
     drop under it. ✅ Close it; the veil drops a minute later.
   - Tap Focus mid-session. ✅ A centred alert shows both "Switch to Focus" and "Stay in Sleep",
     and nothing is red.
16. **The ember: time left, on a glance** (added 2026-10-10, changed 2026-10-11, simulator-checked
   only). On an OLED iPhone in a dark room, at night brightness, start Sleep with a 45-minute
   night and let the controls fade.
   - ✅ Nothing is left over the scene: the ring fades with the rest of the controls (the ember
     used to stay in its place; it took from the screensaver).
   - ✅ Tap the veil once: the ember shows the time left with no controls, then the dark returns.
     No arc for "All night", and none in Focus.
   - Check the first session on a fresh install: the first-run card stays up about 15 s before
     the fade. It comes back with the controls on a tap, and it's never held up all night.
17. **First run teaches one thing at a time** (added 2026-10-10, simulator-checked only). On a
   fresh install:
   - ✅ The card's title and line are both about the orb and its ring, on both the full and the
     brief card.
   - Drag the ring first (that retires the card), then Play. ✅ Both noise and binaural start
     (e.g. Brown + Deep), not a bare noise.
   - ✅ The first Build mix shows one line under "Your mix" about turning on several sounds. It
     doesn't show on the next open.
18. **Podcasts empty state and Settings** (added 2026-10-10, simulator-checked only). The add
   sheet and the rest of the tab are §N's.
   - **Podcasts (no shows yet):**
     - ✅ The empty state is centred on the screen, not stuck in its bottom half.
     - ✅ At the largest text size it scrolls instead of clipping.
   - **Settings:**
     - ✅ In Sleep it opens on Sleep, then Podcasts at night, Podcasts, Sound and Display, with the
       Pomodoro folded under "Focus settings" and Backup & support one level down (§S6), in
       sentence case.
     - ✅ The Focus steppers change the next Pomodoro phase.
     - ✅ Backup export, restore and "Export the playback log" still work (§S).

### N. Podcasts tab: Tonight shelf + hardening (added 2026-10-09, simulator-checked only)
1. **Resume where you drifted off.** Play an episode for 20+ min, set the ring to 45, pause, kill
   the app. Podcasts tab: ✅ "Tonight" shows that episode with the right time left and, when it's
   longer than the ring, "Runs past your 45-min night". **Resume** starts at the spot (lock
   screen shows the right title); **Back 5 min** starts 5 minutes earlier; either one starts the
   45-min timer (it's a Sleep start from rest). Focus titles the shelf "Continue", no night note.
2. **Up next.** The row under it plays the newest unplayed episode of that show. Finish the resumed
   episode → the shelf shows only the next one; nothing to offer → no shelf at all.
3. **Show page.** A show you're partway through says **Resume** (with the episode and time left);
   otherwise **Play Latest**. "…" → Play All / Shuffle with a non-empty queue asks "Replace your
   queue?" (Replace Queue / Add to End / Cancel); with an empty queue it just plays.
4. **Show notes** read as plain paragraphs (no `<p>`/`<a href>`), opening paragraphs first, "More"
   for the rest.
5. **Downloads tell the truth.** Airplane mode → Episode options → Download Offline. ✅ An amber
   cloud-warning icon (VoiceOver: "Download failed"), menu offers "Retry Download"; never the
   Downloaded tick. Back online → retry → tick.
6. **Adding shows.** + → search: shows you follow say "In your library"; tapping another shows a
   spinner on that row (others disabled), then the sheet closes with a success haptic and the
   show is first in the list with its real name and count. A bad link / a web page → plain error.
7. **Import from another app.** + → Import Subscriptions → pick an OPML export. ✅ The sheet lists
   the shows (palette colours in both modes; shows you follow marked and not selected); Import →
   sheet closes, then "Shows imported · Added N shows".
8. **Library counts stay current.** Open a show whose feed has new episodes, go back. ✅ Its row
   count updates without a relaunch. Pull to refresh offline → "You're offline…" under the list;
   a show whose feed fails → "Couldn't refresh <show>".
9. **Resume is right after a podcast-only pause, and audible in the tail.** Play an episode,
   lock, listen 10+ min, pause from the lock screen (or AirPods), reopen Podcasts. ✅ Tonight's
   time left matches where you paused (not where you locked). With a timer in its ambient tail
   (podcast stopped, sounds fading), tap Resume. ✅ The timer cancels and the podcast is audible
   and keeps playing. Tap Resume / Back 5 min while that episode is already playing. ✅ No
   dropout (it seeks in place); Back 5 min jumps 5 min from *now*. In the tail, tapping an episode
   row or swiping Play also cancels the timer. After an end-of-episode timer stop, Resume on that
   still-loaded episode starts it over instead of playing its last second and advancing.
10. **Edges.** Paste a link already in your library → "already in your library". Paste a blog's
   RSS (no audio) → "That link has no episodes to play". Search offline / gibberish → the
   unreachable / "No shows found" notes. An OPML file with no shows → "No shows found". A show
   page offline before it ever loaded → "You're offline" with Try Again (not a long spinner);
   a failed refresh with saved episodes → the "Showing saved episodes" line. Search your shows
   for nothing → "No shows match". Swipe a row both ways: white labels on the deep amber / blue.
   Start an add, tap Cancel, open + again → the old add never lands or closes the new sheet.
11. **Large text + VoiceOver.** At an accessibility text size the show page keeps only Resume + "…"
   above the list; rows drop the thumbnail and wrap the title; the Tonight buttons stack.
   VoiceOver reads each episode row as "…, Unplayed / In progress / Played".

### O. Podcast player: the night line, failures + the veil (added 2026-10-10, simulator-checked only)
Sleep unless noted, in a dark room at bedtime brightness. The timer, tail, veil and live-stream
changes are the ones a simulator can't settle.

1. **The veil closes an idle player, not one in use.** Sounds + an episode playing, a timer
   running. Open Now Playing and leave it alone. ✅ When the night veil drops (~60 s) the sheet
   closes and the screen goes black; it never stays lit above the veil. Close it, wait ~50 s,
   open it again → it isn't swept away seconds later (opening restarts the minute). Keep using it
   (scrub, skip, reorder Up Next) for 2+ minutes → it stays. With VoiceOver on, and with Switch
   Control, leave it open → the veil never closes it.
2. **"Stop after this episode" only while playing.** Play an episode of known length, open the
   player. ✅ The hairline chip shows under the night line; pause → it goes (from the timer sheet
   too) and the transport doesn't move. Tap it while playing → the line reads "Stops with this
   episode · in N min". Then take the AirPods out (or pause from the lock screen) and leave the
   phone. ✅ The night still ends on time: at the promised minute the sounds fade and stop (or
   the tail runs), though the podcast stays paused. Export logs: `end-of-episode timer: podcast
   paused, …s left now counted on the wall clock`.
3. **The ambient tail after a stop-with-episode.** Timer sheet → "Keep sounds going after the
   podcast stops" at 10 min. Bed + an episode; scrub to its last ~3 min; tap "Stop after this
   episode" (the line adds "· sounds go on 10 min"); lock. ✅ At the episode's end the podcast
   stops, the next episode does NOT start, and the bed carries on ("Sounds fading · N min left"),
   then everything stops ~10 min later. Repeat with two or three episodes: every run gets the
   tail, never a hard stop at the episode's end. In the tail, tap Next or an Up Next title → the
   timer cancels and that episode is audible.
4. **A failed episode offers a way on.** Airplane mode, play an episode that isn't downloaded (or
   one whose enclosure 404s or won't parse). ✅ The player reads "Couldn't play this episode" with
   **Try again** and, when something's queued after it, **Play next**; the play disc is a retry
   arrow; the mini-player says the same. No raw system error, no spinner over the previous
   episode's audio, and lock-screen Play doesn't resume the previous episode under this one's
   name. Back online → Try again plays it. Play next plays Up Next's first row even with Auto-Play
   off. With Auto-Play on, a failure moves straight on and the failed episode stays queued, right
   behind the one now playing. The failed episode is never marked played (and see §3P.5).
5. **A live stream keeps a clock.** Play a live or 24/7 stream from a feed. ✅ "Live · 12:34"
   counts up where the scrubber was (not a bar stuck at 0:00, not a spinner); back/forward 15
   work; no "Stop after this episode" chip; the night line reads "Timer ends in …" or "Plays all
   night".
6. **The Night Limiter line, only with the limiter on.** Limiter off (the default): play a stream
   the tap can't attach to (HLS). ✅ No limiter wording anywhere. Turn the limiter on in Settings
   (Soften loud moments ▸ Always) and load it again. ✅ One dim line in the full player, "Can't
   soften loud moments on this stream"; no amber banner on Home, and the mini-player keeps its
   normal status. A regular MP3 episode with the limiter on → no line.
7. **Build mix clears the loaded bar on a small phone.** On the smallest supported iPhone (SE /
   mini), Sleep Home with an episode loaded. ✅ Build mix sits fully above the mini-player and
   takes taps; in Focus, so does Focus session. Check with the tab bar showing, after the
   screensaver hides it, and at the largest text size. (The fix was measured on an iPhone 17 Pro
   only.)

### P. Podcast engine: loads that hold, late ends, offline Auto-Play (added 2026-10-10, simulator-checked only)
Three fixes in `PodcastPlayer` / `AudioEngine` / `PodcastQueueManager`. The unit suites drive a
real AVPlayer in the simulator, but the lock screen, AirPods, calls, routes and a real network
dropping out need the phone. Use episodes that are NOT downloaded for 1–4 (a stream's load takes
longest, so the window is widest). Export logs after each.

1. **A pause during an auto-advance sticks.** Auto-Play on, two streamed episodes queued. Scrub
   the first to its last ~10 s, lock the phone. The moment it ends, pause from the lock screen
   (or squeeze an AirPod). ✅ The next episode's title shows on the lock screen, paused, and stays
   paused: nothing starts a second later. Play → it starts from its beginning. Log:
   `podcast load landed after a pause — holding it paused`.
2. **The timer's stop during a load stays stopped.** Start a short sleep timer with only the
   podcast playing, and scrub the episode so it ends a few seconds before the timer does.
   ✅ When the timer stops everything, nothing restarts: the next episode is loaded but paused,
   and no fresh timer appears on the orb. (A hard one to time; the unit test covers it. Worth one attempt.)
3. **A call or Siri during a load.** Tap a streamed episode in the Podcasts tab and immediately
   hold the side button for Siri (or have someone call). ✅ The episode doesn't start under Siri
   or the call. When it ends, the episode starts (if iOS says to resume). Pull the AirPods out
   within a second of tapping an episode. ✅ Nothing plays from the speaker.
4. **Play on a paused first load.** Cold launch, tap Resume Last Night (or an episode), pause
   from the lock screen before it starts, then tap Play in the mini-player. ✅ That same episode
   plays, not the queue's first.
5. **Offline doesn't drain the queue.** Queue five streamed episodes, Auto-Play on, airplane
   mode, play the first. ✅ Within a few seconds Auto-Play stops after three: the player reads
   "Couldn't play this episode" with Try again, the sounds carry on, and all five are still
   queued in the order you queued them (the third, failed, is the one on screen; Up Next lists
   the other four). None marked played, no download deleted. Log:
   `auto-play stopped: 3 failed episodes in a row, all kept queued`. Back online → Try again
   plays. Repeat with one DOWNLOADED episode third in the queue. ✅ It plays after the two streams
   fail, and the failed ones wait right behind it.
6. **A stream lost mid-episode stays queued.** Play a streamed episode for a few minutes, then
   airplane mode. ✅ After about a minute, "Podcast stream lost", and the next one is tried
   (downloaded plays, streams fail as in 5). The lost episode is still in Up Next, and tapping it
   continues near where the stream was lost (unless Auto-Play reached it again overnight, which
   starts it over, as any auto-advance does).
7. **Next right at an episode's end.** Settings ▸ Podcasts ▸ Delete downloads once played ON,
   three downloaded episodes queued. Scrub the first to its last 2 s, tap Next just as it ends
   (try a few times).
   ✅ The second plays from where you left it (or its start), stays unplayed, and keeps its
   download (its row still shows the Downloaded tick); the third is still queued. If the end won the race, the
   log shows `ignoring the end of a podcast item that's since been replaced`, and nothing else
   moved.

### Q. Screensavers: warm scenes, the untimed night, the glance (added 2026-10-10, simulator-checked only)
From the screensaver critique (24/40). The simulator showed every scene, the Focus controls and
both glances, but brightness, colour at 2am, motion on ProMotion and anything over 45 minutes
need the phone. Room dark, phone on the nightstand, brightness where you'd leave it at night.

1. **Every Sleep scene is warm and dim.** Swipe through all seven at bedtime. ✅ No scene throws
   blue light: Night sky's stars and glow are warm, Aurora is red curtains, Still water a small round amber moon (not a tall
   oval) with flat ripples, Rain on glass shows drops that cling and slip with a bright lower
   edge (not meteors), Deep space a faint rust nebula. Embers churns slowly; Breathe's glow sits
   on the ring and swells more than it brightens. ✅ No identical stars repeating down the
   screen in Deep space, Aurora or Still water.
2. **Night sky and Breathe actually move on ProMotion.** Watch each for a minute in the
   screensaver. ✅ The sky turns and its cloud drifts smoothly, Breathe swells and fades
   continuously. (Both
   moved off `TimelineView(paused:)`, which stops driving frames on 120 Hz screens.)
3. **All night gets the veil on the Sleep screen.** Ring set to All night, Play, don't touch.
   ✅ The veil drops about a minute later. (Auto-Lock set to Never so the veil, not iOS, darkens
   it.) Then play All night from the Podcasts tab and read a show page for over a minute. ✅ No
   veil there, but open the full player and leave it: ✅ it closes and the veil drops. With a timer
   running, ✅ it drops on any tab. With VoiceOver on, ✅ it never drops.
   Focus with sound playing, switch to Sleep, don't touch. ✅ The veil arms (and the ring's timer
   starts if one is set).
4. **All night settles.** All night, Deep space or Night sky, Auto-Lock Never, veil off in
   Settings so you can watch: check at 0, 20 and 45 min. ✅ The scene darkens and slows; no comet
   or meteor after ~18 min; by 45 min it holds its darkest, stillest state. Pull the headphones
   for a minute and reconnect. ✅ It doesn't brighten back to bedtime. Then drag the ring to
   30m, and later back to All night. ✅ Nothing brightens either way. With an ambient tail set and
   a podcast in the mix, ✅ the scene holds as the podcast stops. Repeat 4 on Night sky with Settings →
   Moving scenes off: ✅ the still sky still darkens over the 45 minutes. Let a short timer end
   on its own and wake the screen within half an hour. ✅ The scene is still at its darkest.
5. **The glance.** On a 30-min night, let the veil drop, then tap once. ✅ Only the faint ember
   and a dim "Nm left" appear at once (softly), and are gone after ~6 s (faded by ~8 s). A quick
   double-tap still shows the glance. Tap again while it shows or fades. ✅ The scene and the
   controls come back together. A tap on the "Tap to wake" words works too. On All night, ✅ the
   glance says "All night" with no ember. Let the veil drop, then turn VoiceOver on (Accessibility
   Shortcut): ✅ one double-tap wakes. Voice Control: "Tap Wake". ✅ The first shows the glance,
   the second wakes, and nothing else on screen answers "Wake".
6. **Focus scenes step back under the controls.** Focus, each scene, sound playing. ✅ With the
   controls up the scene is dimmed and "Focus session" reads clearly; after 10 s the controls fade
   and the scene rises to full. Tide at rest is a low line at the bottom edge. Sandfall at rest
   has its sand settled dim in the bottom bulb, clear of the mode switcher; Start a session
   and ✅ it flips and drains.

### R. Orb breath + Focus ring on ProMotion (added 2026-10-10, passed on device 2026-10-10)
`OrbButton` and `FocusHero`'s ring moved off `TimelineView(.animation(paused:))`, which stops
driving frames on 120 Hz screens (device 2026-07-11, see `ShaderBackdrop`). They now swap to a
static frame when paused, as the scenes do. The simulator animates either way, so only a
ProMotion iPhone shows the difference. Before the fix the orb likely moved only when something
else redrew Home, and the ring stepped once a second on the Pomodoro's tick. The Focus hero now
also pauses while its controls are faded to the screensaver, as the Sleep orb already did.

1. **The orb breathes.** Sleep, nothing playing (so the controls stay up and nothing else
   redraws Home). Watch the orb for a minute without touching. ✅ The glow swells and settles
   smoothly on a ~4.5 s breath, every breath: no stalls, no once-a-second steps. Repeat in
   Focus, nothing playing, no session.
2. **The Focus ring depletes.** Focus, start a session, and watch the ring for a minute,
   tapping an empty patch of screen every few seconds so the controls don't fade (they go after
   10 s). ✅ The arc shortens continuously and the lit cap glides along it, with no
   once-a-second ticks. Tap End interval. ✅ The new phase's arc eases in over about half a
   second rather than snapping.
3. **Freezes still freeze, and come back true.** Sleep, sound playing: let the controls fade to
   the screensaver, wait a minute, tap to wake. ✅ The orb picks up its breath where it left off,
   no jump. Focus mid-session: let the controls fade, wait a minute, tap to wake. ✅ The ring is
   already at the true time left as it fades in, and carries on smoothly. Settings ▸ Moving
   scenes off, back to Home. ✅ The orb holds still and the ring steps once a second in time
   with the countdown (never stuck, never wrong). Turn it back on. ✅ Smooth again. Lock the
   phone for 30 s mid-session and unlock. ✅ The ring shows the true time left, not where it
   stopped.

### S. Settings: restore with a confirm and Undo, the night section, mode order (added 2026-10-11, simulator-checked only)
1. **Restore asks first.** Settings ▸ Backup & support ▸ Export a backup (✅ the file is named
   `sleepulator-backup-<date>`, in Gregorian years even with Settings ▸ General ▸ Language &
   Region ▸ Calendar set to Japanese). Change a mix and a setting, then Restore from a backup and pick
   that file. ✅ As the picker closes, an alert asks "Replace with the backup from <date>?" and
   names what's in it ("… 4 mixes, 12 shows …"). Cancel. ✅ Nothing changed.
2. **Restore, then Undo.** Restore again and tap Replace. ✅ "Backup restored" names what came back
   and offers Undo. Tap Undo. ✅ "Restore undone"; the mix and setting you changed are back.
   Restore once more and tap OK. ✅ The Backup rows show "Undo the restore from <day, time>", and it
   still works after the app is killed and relaunched. With VoiceOver, ✅ the row reads "Undo the
   restore, <day, time>"; with Voice Control, ✅ "Tap Undo the restore" opens the confirm.
3. **A wrong file.** Pick any other JSON file. ✅ "That isn't a Sleepulator backup." and nothing
   changed. A backup with a section hand-edited to a plain string ("savedPodcasts": "x"). ✅ No
   crash; the rest restores and the result says a few parts weren't recognised.
4. **One limiter choice.** Podcasts at night ▸ Soften loud moments: the whole row opens Off / While
   sleeping / Always. Then §3D step 3.
5. **The hold.** Play the next episode automatically OFF. ✅ "Don't start the next episode during a
   sleep timer" is dim, title and switch, and says it only applies with Auto-Play. With VoiceOver on
   and hints off (VoiceOver ▸ Verbosity ▸ Speak Hints), ✅ it reads "Off. Only applies when the next
   episode plays automatically." Turn Auto-Play on
   and the hold on, start a 15 min timer on a short episode, lock. ✅ The episode ends, the next one
   doesn't start, your sounds carry on.
6. **Mode order.** In Sleep, ✅ the list opens on Sleep and Podcasts at night; the Pomodoro is folded
   under "Focus settings". Switch to Focus. ✅ It opens on Focus; the night is under "Sleep settings".
7. **Stereo width.** Pink, headphones in. Step Mono → Narrow → Natural → Wide. ✅ Each stop sounds
   wider than the last (Wide used to sound the same as most of the slider below it).
8. **A restore never switches mode.** In Sleep with a 45 min timer running, restore a backup
   made in Focus. ✅ Still Sleep, the timer still counts down, the sound is the backup's Sleep
   pick; switch to Focus and ✅ its sound is the backup's Focus sound. Restore a backup with
   different Pomodoro lengths. ✅ The next Focus session uses them (no relaunch).
9. **Undo puts the shows back too.** On a phone with no podcasts, restore a backup with shows,
   open Podcasts, then Undo. ✅ The shows are gone at once (the list re-reads the library as at
   launch) and stay gone after adding one and relaunching.
10. **At 2am.** Sleep, room dark, brightness low. ✅ No amber switch tracks (copper), and the brightest
   things are the switch knobs, not rows of accent text.

### T. Night sky: the sky from a dark field (added 2026-10-11, rebuilt the same day, simulator-checked only)
After the Night sky critique (18/32) a first pass calmed the Canvas starfield. On the phone it still
read flat and static, so the scene was rebuilt as a Metal shader (`NightSkyShader.metal`). The
simulator showed the turning sky, the Milky Way, the cloud and the land; black level and banding on
OLED at 2am, ProMotion and a full night need the phone. Room dark, phone on the nightstand,
brightness where you'd leave it at night, Night sky selected.

1. **It has depth.** At bedtime with the controls faded. ✅ It reads as a sky over land, not dots on
   a screen: a warm glow along the horizon, a hazy far ridge, a black treeline in front of it, stars
   dimmer and warmer low down. Hold the phone and tilt it. ✅ The trees shift more than the ridge,
   the ridge more than the sky.
2. **It's alive but calm.** Watch two minutes. ✅ The sky turns slowly about a point near the top
   (stars there barely move, lower ones wheel), the Milky Way's band and dark rift turn with it, and
   thin cloud drifts across in front, dimming the stars it crosses. ✅ Nothing blinks; only the low
   stars shimmer faintly.
3. **Visible at night brightness.** ✅ The Milky Way, the horizon glow and the treeline are all
   visible to dark-adapted eyes (they sit about 8-25 levels above black; OLED crushes the bottom few),
   and nothing lights the room. ✅ No contour lines in the glow or the band.
4. **Meteors only while you're watching.** Fresh launch, Sleep Home, nothing playing. ✅ One faint
   warm meteor within ~25 s that kindles and burns out rather than popping. Hop to Podcasts and back
   a few times. ✅ No meteor every 15 s; the next ones are minutes apart. Play and let the screensaver
   run 5 minutes. ✅ No meteor under the screensaver. The ring fades with the controls; nothing is
   left over the scene.
5. **The night arc.** A 15 min night, veil off in Settings so you can watch. ✅ By the end the sky,
   the Milky Way and the glow are much dimmer and the turn and drift have slowed. With Moving scenes
   off: ✅ the still sky still dims over the night (it re-reads every 20 s).
6. **ProMotion and battery.** Watch a minute on a 120 Hz phone. ✅ A smooth turn, no stalls. Overnight
   with the veil on: ✅ battery comparable to Deep space (a full-screen shader at 30 fps while the sky
   is in sight; nothing renders under the veil).

### U. Launch 1.0: the night record, Send feedback, tips and the asks (added 2026-10-11, simulator-checked only)
The night journal (`NightJournal`), Send feedback, the tip jar (`TipStore`) and the two asks
(docs/designs/APP-STORE-LAUNCH-1.0.md). Unit tests cover the rules; the phone covers what only a
real night, a real kill and the real App Store do. Before the tip steps: the three tips exist in
App Store Connect (`app.sleepulator.Sleepulator.tip.small` / `.kind` / `.generous`, consumable),
the Paid Apps agreement is active, and the phone is signed in to a Sandbox Apple Account
(Settings ▸ Developer ▸ Sandbox Apple Account). To read a night's file, Send feedback and share it
to Files: each Sleep session is a `.jsonl` file, one event per line (usually one a night; a pause
past 30 minutes or a restart after a kill starts another).

1. **A killed night stays open.** Run from Xcode. Sleep, All night, play a mix, lock, wait 10+
   minutes, then Product ▸ Stop in Xcode (a kill, like iOS ending the app: no notice reaches it).
   Reopen the app. Send feedback. ✅ The summary reads "… 1 left open."; the newest night file
   starts with `opened`, has a `live` line every 5 minutes of sound, and ends with
   `closed` `died …`, timed at the last event before the kill. ✅ No `://` anywhere in either file
   (play a podcast in one of the nights to be sure).
2. **A force-quit while playing is yours.** Play, then swipe the app away in the app switcher
   with the sound still on. Reopen, Send feedback. ✅ That night ends `closed` `person …`, not
   `died`, and isn't counted as left open. (iOS delivers the terminate notice to a running
   background-audio app. If this shows `died`, iOS didn't: log it, the asks will just wait longer.)
3. **An alarm doesn't spoil the night.** A podcast and a mix on All night for 3+ hours, locked,
   with a Clock alarm set to end it. Dismiss the alarm, then stop the sound. Send feedback later
   that morning. ✅ The night's file has `paused` at the alarm, any `pipeline died …` or `player
   rebuilt` as a `note` ending `while paused` (or, within 10 s of the sound coming back,
   `just after the sound started`), and the summary counts the night clean. ✅ Two hours
   after you stopped it (and after 09:00), the night is already counted: you don't have to press
   play again first.
4. **Locked-phone writes.** Run §3E's night (or a 45 min timer) with a passcode set, locked from
   the start. Morning: Send feedback. ✅ The night's file has `live` lines all through the locked
   hours and `closed` `timer …` at the timer's time (not `reconciled`); on All night, a
   `threshold` line after 3 hours. ✅ The exported playback log has no `night journal write failed`.
5. **Feedback after a killed night.** Right after step 1, Send feedback. With Mail set up and a
   support address in the build (`AppInfo.supportEmail`), ✅ Mail opens to that address, subject
   "Sleepulator feedback (1.0, build N)", the body names what's attached ("the last 2 nights'
   playback events (no web addresses)", plus iOS reports when there are any), and the last two
   nights' `.jsonl` files are attached. Without Mail, or with no address in the build, ✅ the share
   sheet opens with the same text and files ("Please send this to …" leads when there's an
   address). With an address, long-press the row: ✅ "Copy address". A night iOS itself ended
   shows up only as exit counts in the next day's report: ✅ once Reports from iOS lists one, the
   next Send feedback attaches it.
6. **A sandbox tip.** Settings ▸ Backup & support ▸ Support Sleepulator. ✅ Small, Kind and
   Generous tip, smallest first, at App Store Connect's prices in the phone's currency. Tap one,
   confirm in the App Store sheet. ✅ "Thank you. Sleep well." replaces the rows. Leave the page
   and come back: ✅ "Thank you for supporting Sleepulator." above the three tips, and the Home tip
   card never shows on this phone again. Cancel on the App Store sheet instead: ✅ the rows are
   back as they were, nothing thanked.
7. **A second tip is a new tip (the iOS 27 sandbox).** Right after step 6, tip again. ✅ The App
   Store sheet asks again, and it thanks again. If it thanks instantly with no App Store sheet, the
   sandbox replayed the last transaction (reported on iOS 27): the app thanks but records nothing
   new. Log which you saw and on which iOS.
8. **No tips to show.** Airplane mode, kill and reopen the app, open Support Sleepulator. ✅ "Tips
   aren't available right now." (never a spinner that stays). Back online, leave and reopen the
   page: ✅ the three tips. Screen Time ▸ Content & Privacy Restrictions ▸ iTunes & App Store
   Purchases ▸ In-app Purchases ▸ Don't Allow, reopen the page: ✅ no tips and no "Support
   Sleepulator" header, just the build line (a tipped phone keeps its thank-you). Allow it again.
9. **The tip card.** It comes after the fifth clean night. To see it now, add `-uiTestTipCardDue YES`
   (and `-tipCardSpent NO`; `-uiTestTipProducts YES` too if the tips aren't in App Store Connect
   yet) to the scheme's Run arguments; Debug builds only. Sleep Home at rest:
   ✅ "Sleeping well?" in the band above Build mix, with No thanks and Leave a tip, clear of the
   night line and the mini-player; the full card (message and "Tips stay in Settings ▸ Backup &
   support.") where there's room, the title and answers where there isn't. ✅ Never in Focus,
   never with sound playing, never under the veil (and, without the argument, only 09:00–20:00,
   2+ hours after a night, never on the day the rating was asked). Leave a tip → the sheet with
   the three tips; Close → the card is gone. No thanks does the same. Under the seam the answer
   lasts this run only (nothing is saved), so a relaunch with the arguments shows the card again;
   that the answer is saved for good is checked on a phone whose card fell due on its own. With VoiceOver: ✅ one stop reads the title and the message, then Leave
   a tip, then No thanks.
10. **The rating ask (dev build only).** Apple shows the review prompt every time in a build run
   from Xcode, and never in TestFlight, so run this from Xcode once the journal has 3 clean nights
   on three different nights, noon to noon (steps 3, 4 and §3E count, each on its own night). Between 09:00 and 20:00, 2+ hours after the last night ended, nothing
   playing, the tip card not on Sleep Home: open Build mix and close it. ✅ The rating prompt, once; the playback log shows
   `asked for a rating (N clean nights)`. Close another sheet, or leave the Settings tab: ✅
   nothing more this version. ✅ Never at launch, never with sound playing, never on the day the tip card showed, never before 09:00 or after 20:00 (those wait;
   the ask still comes at the next suitable break). Clean nights count one a night at most
   (noon to noon, by start): three naps in a day are one.
11. **iPad compatibility.** The app is iPhone only, and an iPad runs it in an iPhone-size window
   (App Review may test it there). Install on an iPad, or run on an iPad simulator. ✅ It opens
   portrait in the iPhone window, plays a mix, the timer and the Now Playing sheet work, nothing is
   clipped. Rotate the iPad: ✅ the app stays portrait.
12. **A missed deadline isn't a clean night.** Run §3C step 5, then Send feedback. ✅ That night's
   file ends `closed` `timer … reconciled`, timed at the deadline (not at the Play), or `closed`
   `person …` at the pause, and the summary counts it under "ended early or spoiled".

### V. Contour: a Focus map lit from the summit (added 2026-10-12; look checked on the phone 2026-10-12, full pass owed)
A new Focus scene (`ContourShader.metal`, `ContourMetalView`): contour lines of a mountain whose
summit sits under the ring, with light spreading down from it as a work interval goes on. The
simulator showed the look and the reading at 7/23/50/80% of a 1-minute interval and a quarter into
a break; motion feel, OLED black, heat and a real 25-minute block need the phone. On the phone
(2026-10-12) the look, the calm drift and working beside it were checked informally (see the log);
the full pass below is owed. Focus, Contour selected (Build mix → Backdrop), a sound playing, the
phone at your desk.

1. **It reads as a map with depth.** Controls up. ✅ A dimmed topographic map, the ring and play
   button sitting on the summit, contour rings around it bent by the terrain. Every fifth line is
   bolder (index contours). It reads as a mountain, not a target. Controls faded: ✅ it reads as a
   layered relief model, not a flat drawing: each band a sheet a step above the one below, higher
   sheets lighter, a soft shadow at the foot of each step on the lower right, and the edges lit on
   the upper left. (The first cut, plain hillshading, read "1-dimensional" on the phone.) The
   summit is fixed at 40% down the screen, where the ring sits on a 6.3"/6.9" Pro: on a smaller
   phone (an SE) or at a large text size, ✅ it still sits under or close beside the ring, not
   clearly apart from it (log how far off it looks).
2. **The light is the interval.** Start a session and let the controls fade. ✅ A quarter in, a disc
   of light about a quarter of the screen sits around the summit, edged by one bright line; halfway,
   about half the screen; near the end, nearly all of it. (The lit share is usually within about 7% of the interval's, rarely more than ~15%: 1 sd is ±0.07. In the first and last ~15% of an interval it runs dark and full on purpose: little is lit 10% in, most of it 90% in.) ✅ No stray bright ring flashes for a frame as an interval or a break starts.
   ✅ The bright edge holds still while the lines drift through it. With a 5-minute Focus length
   and a 1-minute short break (Settings' shortest), ✅ the edge glides between seconds, as the ring
   does, through the work interval and the break; it never jumps (15-20 pt once a second on the
   break, before the fix). On a break: ✅ the map turns teal and the light pulls back up toward
   the summit. Stop the session: ✅ every line goes back to
   one even brightness and the edge is gone.
3. **The motion is a drift, not a churn.** Watch two minutes. ✅ The lines drift steadily outward
   from the summit, and the terrain slowly pans and re-forms. ✅ Flat stretches don't boil, steep
   ones don't shimmer or bead into moiré, and nothing flickers.
4. **You can work beside it.** A full 25-minute block, controls faded. ✅ It stays at the edge of
   your attention: alive without pulling your eye off the work.
5. **ProMotion and heat.** ✅ A smooth drift on a 120 Hz phone (it renders at 30 fps; the lines move
   a fraction of a pixel per frame). After the full block: ✅ the phone is no warmer than after one
   on Current, and the exported log's scene line shows a steady frame rate.
6. **Moving scenes off.** Settings → Moving scenes off, a 5-minute Focus length and a 1-minute
   short break. ✅ A still map: the terrain and lines hold. Start a session and let the controls
   fade: ✅ the light spreads from the summit as the interval goes on (`FocusStillFrame`, as in
   §H step 5), creeping once a second. At the break: ✅ the map turns teal at once and the light
   pulls back up. Stop: ✅ every line goes back to one even brightness and the edge is gone, at
   once, not at the next redraw.

### X. Morning read-back: how last night went (added 2026-10-21, simulator-checked only)
`MorningReadback`: the morning after a night that held, Sleep Home at rest shows one dim line under
the night line. Unit tests pin the window, the wording and which sessions are last night; only a
real night proves the journal records it as one that held. The line is re-read when the app comes
forward, the veil lifts, a sheet closes, Settings is left, play starts or stops, the clock changes,
at 05:00 and 18:00, and when a paused session's 30 minutes run out.

1. **A timed night reads back.** Sleep, a 30-minute night on the ring, play, lock, sleep. In the
   morning (after 05:00), open the app. ✅ Under the night line: "Last night · 30 min, eased out
   at …" with the time the fade ended. ✅ Smaller and dimmer than the night line, one line on the
   phone at default text size.
2. **All night reads back.** All night, play for 3+ hours, then pause in the morning (or let the
   alarm stop it). A pause ends the night 30 minutes later (stopping is the same pause); then lock
   and unlock. ✅ "Last night · 7 hr 12 min, until 6:40 AM" style, the hours matching the sound
   you heard.
3. **It steps aside, and comes back.** ✅ Tap Play: the line goes and the layer pills take its
   place; the orb doesn't jump. Pause: ✅ it's back (a morning session is never last night). Play
   again, then switch to Focus: ✅ no line. Back to Sleep at rest: ✅ it's back. Leave Home on
   screen past 18:00: ✅ the line leaves by itself. Drag the ring at rest: ✅ the line steps aside
   while the orb shows the length.
4. **A broken night says nothing.** A night the app died in (Product ▸ Stop in Xcode mid-night,
   as §U.1), even after you restart the sound and let it run to the morning. ✅ No line the next
   morning.
5. **The mornings people actually have.** (a) The app killed overnight (swipe it away after the
   timer ends): open it in the morning. ✅ The line is there on the first screen. (b) Auto-Lock off,
   the app left on the night veil all night: tap the veil awake after 05:00. ✅ The line is there.
   (c) Settings ▸ Accessibility ▸ Larger Text at the largest size, on the smallest phone you have:
   ✅ the line wraps but never reaches Build mix. (d) All night, Auto-Lock off: pause in the
   morning with Home on screen and leave it. ✅ About 30 minutes later the line appears by itself.
6. **The tip card takes the morning.** On the card's day (5 clean nights, as §U), Sleep Home at
   rest: ✅ the card shows in the band and the line doesn't; ✅ tap No thanks: the card goes and
   the line shows under the night line.
7. **VoiceOver.** ✅ It reads "Last night, 30 minutes, eased out at …", units in words.

---

## Quick release checklist

- [ ] ⌘U unit tests pass
- [ ] Simulator smoke test clean (§2)
- [ ] Background audio + lock screen (§3A)
- [ ] Interruptions + route changes (§3B)
- [ ] Timer fade + terminal stop, full run (§3C)
- [ ] Night Limiter acceptance, if enabling by default (§3D)
- [ ] All-night soak (§3E)
- [ ] Ambient scenes: freeze/resume + phase clock (§3H), after any scene-engine change
- [ ] Depth scenes: freeze-in-place, reactive settle, A/B vs flat, F3 power log (§3L), after depth-scene changes
- [ ] Podcast engine: holds, late ends, offline Auto-Play (§3P), after `PodcastPlayer` / queue changes
- [ ] All-night soak on the default, All night with podcasts (§3E step 2)
- [ ] Launch 1.0: killed and force-quit nights, locked writes, Send feedback, a sandbox tip, the card,
      the rating ask, iPad compatibility (§3U). 1.0's gate: §3A, §3B, §3C, §3E (both runs), §3P and
      §3U on the build to submit (docs/designs/APP-STORE-LAUNCH-1.0.md, LG-1)

## Device-pass log

| Date | Device / iOS | Sections run | Result / notes |
|------|--------------|--------------|----------------|
| 2026-10-10 | iPhone 16 Pro (ProMotion) / iOS 27.0.1 | §3R | ✅ Pass. The orb breathes and the Focus ring depletes smoothly. Debug build of `main` + #29 (`efbdbaa`) + the screensaver branch (`95ee8f0`). |
| 2026-10-12 | iPhone 16 Pro (ProMotion) / iOS not recorded | §V.1, §V.3 (informal); §V.4 partial (under 25 min) | ✅ Look only, not the full §V pass. The first cut read "a mountain map, but 1-dimensional"; after the layered relief (`582be55`): "has depth now". The drift felt calm and it was fine to work beside. Debug build of `claude/screensaver-concepts-23f53c`. Owed: §V.2, §V.4 (a full 25-minute block), §V.5 and §V.6. |
| 2026-10-20 | iPhone 16 Pro (ProMotion) / iOS 27.0.1 | §3I step 7 | ✅ Pass. A Focus session's Live Activity stays up on the Lock Screen and in the Dynamic Island; Stop ends it; a restart, and a start after a force-quit, leave just the new one up. Debug build of `claude/goofy-roentgen-40078e` (`25fe7a5`). |
