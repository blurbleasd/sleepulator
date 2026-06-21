# Device-test checklist

_As of 2026-06-21 · Covers everything currently unverified on device: the audio-engine
refactor, the Sleep/Focus redesign + fixes, and the scene library. All of it **builds clean**
(`xcodebuild build` → SUCCEEDED); none of it has been seen on a real device or simulator
(the sim test-runner was wedged with a `Device not configured` error → reboot to clear).
Spans the 12 local commits ahead of the pushed `17755f1`. Tick as you go; delete this file
once it's all green._

## 0. Setup
- [ ] Rebooted (clears the CoreSimulator wedge).
- [ ] `xcodebuild test -scheme Sleepulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max'` → **TEST SUCCEEDED** (15 tests). If it still flakes on PTY, the build is fine — it's the runner.
- [ ] App launches + plays on a real iPhone (the all-night use case is the only true test).

## 1. Part B — real-time thread-safety
- [ ] **B1 — param hand-off** (`17755f1`, pushed): drag the **volume** and **stereo-width** sliders and switch **binaural presets** while noise + binaural play → no zipper noise, no wrong-value glitch, no clicks.
- [ ] **B2 — limiter tap retain** (`7d0d553`): let a podcast **auto-advance through several episodes** → no crash, no audio dropout, no growing memory.
- [ ] **B3 — single-writer assert** (`17755f1`): just use it normally in a DEBUG build → no `dispatchPrecondition` trap (would only fire if something wrote params off the main thread).

## 2. Part A — AudioEngine decomposition
- [ ] **A1/A2 — persistence + mixes** (`85e062e`): saved playlists still listed; **save a new mix → relaunch → it's still there**; **delete a mix → relaunch → still gone**; **"Last Night" resume** restores the correct mix; podcast **library + episode positions** intact.
- [ ] **A3 — audio session** (`d12d05a`) — _the scary one, can't be unit-tested:_
  - [ ] **Phone call** mid-playback → audio pauses, then **resumes** when the call ends.
  - [ ] **Headphones unplugged** → podcast pauses, the **noise bed keeps going**, binaural drops.
  - [ ] **Bluetooth** connect / disconnect → playback re-asserts cleanly.
  - [ ] **Backgrounded all-night** (work in another app / screen locked) → the sleep-timer **fade** and **terminal stop** still fire.
- [ ] **A4 — deinit cleanup** (`2b0e3e6`): nothing user-visible; just confirm no leaks/odd behavior over a long session.

## 3. Sleep / Focus redesign + fixes
- [ ] **Sleep night sky** (`8183782`): realistic starfield (varied brightness/colour, Milky Way); the **moon glides down its arc** as the sleep timer runs; the sky **darkens** toward the end.
- [ ] **Reduce Motion** (you run RM on): with the redesign + un-gate, you should now actually **see** the star twinkle, the rare meteor, and the moon's glide. (If it still looks static, that's a bug.)
- [ ] **Moon-snap fix** (`5feca5b`): when the timer **ends**, the moon stays **set at the horizon** — it does **not** pop/glide back up to the top.
- [ ] **Ambient screensaver** (`8183782`): playing in Sleep, leave it ~12s untouched → controls fade to just the sky; **tab bar + mini-player fade too**; **tap** brings them back. Never triggers in **Focus**.
- [ ] **Shooting-star leak fix** (`8183782`): switch **Sleep ↔ Focus several times** → no buildup / no stray meteors firing in the wrong mode.
- [ ] **Focus** (`8183782`): the **Pomodoro ring** depletes over the phase; phase + countdown + **cycle dots** ("Cycle 2 of 4"); a **long break** lands every 4th interval; the first **tab reads "Focus" + bolt** while focusing (not "Sleep"/moon).

## 4. Scene library
- [ ] **Phase 1 seam** (`453406e`): the night sky and focus sweep render **exactly as before** (no-behaviour-change refactor — confirm the nesting didn't shift the full-bleed layout).
- [ ] **Rain on glass** (`588aec5`): **Build mix → Backdrop → "Rain on glass."** Droplets slide down with trails, lights blurred behind, mist on the glass; it **settles** (drops stop) ~60s in. Default stays night sky; selection persists per mode.
  - Tuning knobs if it's close-but-off (all in `RainGlassView.swift`): `drops` count (16) + `speed` range; `opacity` + trail `len`; `bokeh` count/colour; the 60s settle. Tell me which way (busier / faster / brighter) and it's a one-file change.

## 5. Known-open (not bugs — deliberately not built)
- [ ] _Aware:_ Focus idle status can still read a cross-mode "Resume · Brown + Delta" (spec R2, not built).
- [ ] _Aware:_ Pomodoro has **no background notification** — its chime is unreliable when you're in another app (spec R5, not built).
- [ ] _Aware:_ no app-level **"Ambient motion" toggle** yet — Sleep motion currently ignores system Reduce Motion for everyone, not just this device.

## 6. After it's green
- [ ] Switch `gh` to **blurbleasd**, then push the stack (Claude will check the remote for other Codex/cowork commits first).
- [ ] Delete this file.
