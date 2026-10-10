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

Suites in `SleepulatorTests/` (six files, many suites):

- `AudioMathTests.swift` — fade curve, carrier/beat math, scrub targets.
- `AudioStateTests.swift` — engine state/policy plus `PodcastParserTests` (CDATA, durations,
  dates, caps, enclosures), `OPMLParserTests` (scheme validation, dedupe, corrupt files),
  `StorageManagerTests` (backup recovery), `NetRetryTests`, `CacheEvictionTests`, the
  sleep-timer suites (backstop, cancel, end-of-episode), layering, mode reconciliation, and the
  Podcasts-tab rules (`PodcastTextTests`, `ShowNotesPreviewTests`, `ShowNotesEdgeTests`,
  `TonightShelfTests`, `QueueMoveToHeadTests`), and the player rules (`NowPlayingStateTests`,
  `NightLineCopyTests`, `PlayerQueueActionTests`).
- `PersistenceTests.swift` — legacy `SavedMix` → `SoundPreset` migration, library seeding,
  position-map coercion, `MixStore` reloads.
- `BackupRoundTripTests.swift` — settings Export → Import round-trip and its key allowlist.
- `FocusDriversTests.swift` — the Pomodoro → Focus-scene look mapping.
- `GenerativeAudioEngineTests.swift` — generative-bed rebuild after a media-services reset.

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

### D. Night Limiter (acceptance for enabling by default)
`AppConfig.nightLimiterEnabled` ships `false` until this passes and is logged below.
1. Enable the limiter in Settings. Play a podcast episode with a known loud spot
   (dynamic ad read, intro sting), phone locked, at a low comfortable volume.
   ✅ The spike is audibly tamed; speech stays intelligible; no pumping/distortion.
2. Let it run ≥ 1 hour locked. ✅ No glitches, dropouts, or battery anomalies
   (the tap must never block the real-time thread).
3. Toggle "limiter follows mode": ✅ on in Sleep, off in Focus, mid-playback switch is clean.

### E. All-night soak
1. Full night (or ≥ 4 h): mix + timer, screen locked. ✅ Still behaving at the end —
   timer fired, audio stopped, no crash log in Settings → Privacy → Analytics.

### F. Loop + generator quality
1. Each noise type for several minutes. ✅ No click, gap, or pop; no drift in stereo width.

### G. Offline + storage
1. Download an episode, enable Airplane Mode, relaunch. ✅ Downloaded episode plays.
2. Confirm downloads live in Application Support and are excluded from iCloud backup.

### H. Ambient scenes — settle, freeze, and the phase clock (added 2026-07-05, unverified)
The SceneClock refactor (ShaderBackdrop.swift) moved every scene onto
`TimelineView(.animation(paused:))` + an integrating phase clock. XCTest covers the clock math;
everything below is display-link / render behavior only a device shows.

1. **Freeze is truly static.** Start a Sleep mix + timer, let the veil engage. In Xcode's Debug
   navigator (or Instruments → Core Animation), FPS ≈ 0 and no CA commits from the app while
   the veil is up. Repeat with each of: Night sky, Aurora, Embers, Still water, Deep space,
   Breathe, Rain on glass. ✅ No redraws, no meteor wakeups (Night sky), gyro off (Aurora /
   Deep space — check with the Energy Log that CoreMotion isn't running).
2. **Freeze-in-place, not reset.** Tap to wake after ≥ 10 min under the veil. ✅ Every scene
   resumes from the pose it froze at — no snap to a birth pose, no burst of catch-up motion.
   Repeat via the lock/unlock path (scenePhase) and the app switcher.
3. **Night slowdown direction.** Run a short timer (10–15 min) on Aurora and Still water and
   watch the last minutes. ✅ Motion eases — curtains/waves slow smoothly, never stall-and-
   reverse (the old `time × factor` bug) and never jump when nightProgress ticks.
4. **Transients sleep.** Same short-timer run on Night sky and Deep space. ✅ Meteors dim as
   the night deepens and stop past ~60%; the comet fades out past ~35% and is gone by ~75%;
   a freeze never leaves a comet/meteor burned on the frozen frame (try pausing repeatedly
   around the 40 s comet cycle).
5. **Focus scenes.** Energy: sweep rotates smoothly (1/10 s cadence through the blur — check
   for stepping) and survives backgrounding (the old repeatForever animation died on the first
   app switch). Current: streams *flow* during a running pomodoro — no per-tick jitter — and
   momentum builds over a work interval, eases on break.
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
   change volume; drifting the finger up/down off the track fine-trims. Then check Settings
   (stereo width, Sleep EQ): a *tap* there DOES jump to that position (tapToSet). VoiceOver
   reports the real value. Gain-staging reads at a glance: the master fader (bottom bar) is
   visibly the thickest, layer faders next, Settings params slimmest.
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

### J. Resume integrity + diagnosability (added 2026-07-05, unverified)
1. **Muted layer survives resume.** Build a mix with an extra layer, mute that layer, stop.
   Reopen and "Resume Last Night". ✅ The layer comes back still muted (it used to un-mute).
2. **Save-on-background durability.** Save a mix, then immediately background the app (within a
   second). Force-quit from the app switcher. Relaunch. ✅ The saved mix is still there (the
   deferred write is flushed synchronously on background). Repeat with audio NOT playing.
3. **Overnight log export.** After a night (or any session with a timer + a call/route change),
   Settings ▸ Advanced ▸ Diagnostics ▸ "Export last night's log". ✅ The share sheet produces a
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
   "hide finished episodes"). During a sleep timer with hold-queue on, a lost stream just leaves
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
   scene, Settings ▸ Advanced ▸ Diagnostics ▸ "Export last night's log". ✅ It carries
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
9. **Ambient-motion toggle (P6a).** Settings ▸ Display ▸ **Ambient motion → OFF**. ✅ The backdrop
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
16. **The ember: time left, no tap** (added 2026-10-10, simulator-checked only). On an OLED
   iPhone in a dark room, at night brightness, start Sleep with a 45-minute night and let the
   controls fade.
   - ✅ A faint amber arc of the night left stays in the ring's place. A dark-adapted eye can
     read it, and it never lights the room (it's ~8% amber).
   - ✅ No arc for "All night", and none in Focus.
   - ✅ Tap the veil once: the ember shows the time left with no controls, then the dark returns.
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
     - ✅ It opens on Sleep, then Podcasts at night, Focus, Sound, Display, Podcasts, Backup and
       Diagnostics, in sentence case.
     - ✅ The Focus steppers change the next Pomodoro phase.
     - ✅ Backup export, restore and "Export last night's log" still work.

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
   off. With Auto-Play on, a failure moves straight on. The failed episode is never marked played.
5. **A live stream keeps a clock.** Play a live or 24/7 stream from a feed. ✅ "Live · 12:34"
   counts up where the scrubber was (not a bar stuck at 0:00, not a spinner); back/forward 15
   work; no "Stop after this episode" chip; the night line reads "Timer ends in …" or "Plays all
   night".
6. **The Night Limiter line, only with the limiter on.** Limiter off (the default): play a stream
   the tap can't attach to (HLS). ✅ No limiter wording anywhere. Turn the limiter on in Settings
   and load it again. ✅ One dim line in the full player, "Night Limiter can't soften this
   stream"; no amber banner on Home, and the mini-player keeps its normal status. A regular MP3
   episode with the limiter on → no line.
7. **Build mix clears the loaded bar on a small phone.** On the smallest supported iPhone (SE /
   mini), Sleep Home with an episode loaded. ✅ Build mix sits fully above the mini-player and
   takes taps; in Focus, so does Focus session. Check with the tab bar showing, after the
   screensaver hides it, and at the largest text size. (The fix was measured on an iPhone 17 Pro
   only.)

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

## Device-pass log

| Date | Device / iOS | Sections run | Result / notes |
|------|--------------|--------------|----------------|
| —    | —            | —            | No native device pass recorded yet. |
