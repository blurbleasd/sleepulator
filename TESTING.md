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

Suites in `SleepulatorTests/` (three files, many suites):

- `AudioMathTests.swift` — fade curve, carrier/beat math, scrub targets.
- `AudioStateTests.swift` — engine state/policy plus `PodcastParserTests` (CDATA, durations,
  dates, caps, enclosures), `OPMLParserTests` (scheme validation, dedupe, corrupt files),
  `StorageManagerTests` (backup recovery), `NetRetryTests`, `CacheEvictionTests`, the
  sleep-timer suites (backstop, cancel, end-of-episode), layering, and mode reconciliation.
- `PersistenceTests.swift` — legacy `SavedMix` → `SoundPreset` migration, library seeding,
  position-map coercion, `MixStore` reloads.

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

## Device-pass log

| Date | Device / iOS | Sections run | Result / notes |
|------|--------------|--------------|----------------|
| —    | —            | —            | No native device pass recorded yet. |
