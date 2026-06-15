# Testing Sleepulator

Two layers: automated unit tests for the pure logic, and a manual device pass for
the things only a real phone can exercise (background audio, lock screen,
interruptions, offline). The device pass is the one that actually protects the
core "fall asleep with audio playing" use case — run it before every release.

---

## 1. Automated unit tests

```bash
npm install        # first time, or after pulling new deps
npm test           # run once
npm run test:watch # re-run on change while developing
```

Covers the pure helpers in `src/utils/core.js`: duration/time formatting, feed-name
derivation, episode de-duplication, URL redaction, Sleep Safe URL building, and a
sanity check that every noise generator produces finite, audible, non-clipping
samples. These catch feed-parsing and formatting regressions cheaply; they do **not**
exercise audio playback or iOS behavior.

---

## 2. Desktop smoke test (fast gate, do first)

In Chrome on the deployed URL, open DevTools:

1. **Application → Service Workers** — confirm the new worker is *activated* and
   *running*; old `sleepulator-*` caches are gone except `sleepulator-episodes`.
2. **Console** — no errors on load.
3. Play a soundscape; toggle ambient + binaural; confirm audio.
4. Set a **1-minute timer** and listen — volume should ramp down smoothly over the
   final stretch rather than cutting out abruptly.
5. Toggle EQ / Compressor / Pan on a playing podcast — no dropouts or errors.

If anything here fails, fix it before touching the phone.

---

## 3. Device pass — iPhone, installed as a PWA (highest value)

Install first: open the deployed URL in **Safari → Share → Add to Home Screen**, then
launch from the home-screen icon (must run standalone, not in the Safari tab).

### A. Background audio + lock screen
1. Tap Play on a soundscape (the first tap satisfies iOS's interaction requirement).
2. Lock the screen. ✅ Audio keeps playing.
3. Wake the lock screen. ✅ Now-Playing controls show; play/pause works; skip works
   for podcasts.

### B. Interruption recovery (the critical one — TODOS P0)
1. Start audio, lock the screen.
2. Call the phone from another device (or trigger Siri), then end the call.
3. ✅ Audio resumes on its own within a couple of seconds.
   - This exercises `MixBus.onstatechange → reconnectAllSources`, which only
     recovers a *suspend → resume*. Watch the console for the state transition.
   - If audio stays dead, distinguish the two failure modes (see TODOS.md):
     - Context went `suspended`/`interrupted` → `running` but stayed silent →
       the elements weren't `.play()`d / `resume()`d (auto-resume gap).
     - Context went to `closed` → the engine rebuilds (new context + fresh
       elements); audio recovers on the **next Play / lock-screen control**, not
       on its own (iOS requires a user gesture to resume). That tap-to-recover
       is a *pass*, not a fail.
4. Repeat with a *long* interruption (let it ring a while, or play audio in
   another app for ~30s before returning) — this is what tends to push iOS to
   `closed` rather than `suspended`.

**Repeatable simulation (no phone call needed).** Tap **Feed Debug** to open the
debug panel, then **Force teardown + rebuild** under "Audio Engine (dev)". This
closes the AudioContext exactly like an iOS interruption and triggers the
rebuild. The status line shows `state / dead / rebuilding / sources`; after the
rebuild it should read `state: running, dead: false` with the active layers
listed. Then tap Play (or the lock-screen control) and confirm audio returns.

### C. Sleep timer
1. Set a short timer, start audio. ✅ Volume fades over the final minutes, then stops.
2. Before it expires, tap **Still Awake? (+15 min)**. ✅ Timer extends, volume restores.

### D. Offline (validates the service-worker shell fix)
1. With the app installed and opened once, enable **Airplane Mode**.
2. Force-quit and relaunch from the home-screen icon.
3. ✅ The app shell loads (not a blank/offline page). Soundscapes still play —
   they're synthesized locally, no network needed.

### E. Upgrade path (run on a device that had the OLD version installed)
1. On a phone with the previous (pre-Vite) version on its home screen, open the app.
2. ✅ Within a reload or two it shows the new Vite build, not the stale monolith.
   - This is the riskiest part of the cutover (cache-first → network-first SW). If it
     stays stale, remove and re-add the home-screen icon as the worst-case reset.

### F. Soundscape loop quality
1. Let a soundscape (e.g. Ocean, Rain) run for several minutes with the screen on.
2. ✅ No audible click, gap, or pop at the loop seam.

---

## Quick release checklist

- [ ] `npm test` passes
- [ ] Desktop smoke test clean (§2)
- [ ] Background audio + lock screen (§3A)
- [ ] Interruption recovery (§3B)
- [ ] Timer fade + extend (§3C)
- [ ] Offline relaunch (§3D)
- [ ] Upgrade from old version (§3E)
