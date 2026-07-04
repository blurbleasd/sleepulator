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
   ✅ Audio resumes within a couple of seconds.
2. Trigger Siri mid-playback. ✅ Ducks/pauses, then recovers.
3. Plug/unplug headphones (and connect/disconnect Bluetooth). ✅ Correct pause-on-unplug
   behavior, no crash, binaural routing (`beatRouting`) still correct.

### C. Sleep timer — fade + terminal stop (full run)
1. Set a realistic timer (≥ 30 min), lock the phone, let it run to the end **unattended**.
   ✅ Volume fades over the final stretch and playback fully stops — no zombie audio, no
   abrupt cut.
2. Repeat once with a podcast in the mix. ✅ Podcast and generative audio stop together.
3. Extend the timer mid-fade. ✅ Volume restores, timer extends.

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

---

## Quick release checklist

- [ ] ⌘U unit tests pass
- [ ] Simulator smoke test clean (§2)
- [ ] Background audio + lock screen (§3A)
- [ ] Interruptions + route changes (§3B)
- [ ] Timer fade + terminal stop, full run (§3C)
- [ ] Night Limiter acceptance, if enabling by default (§3D)
- [ ] All-night soak (§3E)

## Device-pass log

| Date | Device / iOS | Sections run | Result / notes |
|------|--------------|--------------|----------------|
| —    | —            | —            | No native device pass recorded yet. |
