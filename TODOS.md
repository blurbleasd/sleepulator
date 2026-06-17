# TODOS

## AudioContext interruption recovery — MixBus

Both the *suspend→resume* and the *full teardown (closed)* paths are now
implemented and unit-tested. The only genuinely-open item is auto-resume while
backgrounded (Gap 2), which is partly an iOS platform limit rather than a code
gap.

### ✅ Done — in-place reconnect (suspend → resume)
`src/audio/MixBus.js` binds `context.onstatechange` in `_initContext()`. When the
context returns to `running` it calls `reconnectAllSources()`, re-routing each
source's node chain (`MediaElementSourceNode → [eq] → [comp] → [pan] → gain →
duckBus/masterGain`). Raw Web Audio, not Tone.js.

### ✅ Done — full context teardown / rebuild (was "Gap 1")
A `closed` context **is** recovered now, contrary to older notes here:
- `_handleStateChange()` calls `rebuild()` when the context goes `closed`;
  `isDead()` + `resumeContext()` also trigger a rebuild (incl. the
  `InvalidStateError`-on-resume fallback).
- `rebuild()` snapshots each layer's logical settings, stands up a fresh
  `AudioContext` (`_initContext()`), and invokes the `onRebuild(cb)` callback.
- `AppContext.jsx` registers that callback (`mixBus.onRebuild(...)`), recreating
  the hidden `<audio>` elements and re-`addSource`-ing each active layer, then
  re-applying pod effects. A `_rebuilding` guard prevents rebuild storms.
- Covered in `src/audio/MixBus.test.js`: closed→rebuild, per-layer setting
  capture, re-add onto the new context, master-volume re-apply, storm guard,
  `resumeContext` rebuilds-when-dead, `InvalidStateError` fallback.
- Design doc: `docs/audio-rebuild-design.md` (essentially implemented).

Remaining work here is **on-device verification only** (unit tests can't
exercise a real iOS teardown). See TESTING.md §3B.

### ⏳ Open — Gap 2: no automatic resume while backgrounded
On the survivable suspend→resume path, reconnect only helps if the context
actually returns to `running` and the elements get `.play()`d again.
`resumeContext()` / `resumeSoundscapeAudio()` are invoked from explicit user
actions and MediaSession `play` only. After e.g. a phone call ends with the
screen locked and no interaction, nothing re-calls `resume()` + `play()` on its
own, so audio can stay dead until the user taps. Verify TESTING.md §3B's "audio
resumes on its own within a couple of seconds" actually holds on device, or wire
a resume attempt to an interruption-end / visibility event. (Partly an iOS
platform limitation — background JS is heavily throttled.)

## On-device verification backlog (fixes shipped, not yet confirmed on a real iPhone PWA)
- Binaural audibility after the 8 kHz sample-rate bump (was 4 kHz → silent on iOS). Needs headphones.
- Ambient volume-at-zero now pauses the element (muted-but-routed elements could leak on iOS).
- localStorage quota data-loss fix (per-key save + slimmed episode persistence) — confirm queue/subs survive refresh.
- Audio ducking (sidechain) — never verified by ear; confirm it ducks under voice without pumping.
- Headphone-disconnect handler no longer false-pauses on iOS (blank device labels).

## Architectural debt (post-launch, not mid-flight)
- `AppContext.jsx` is a ~1.5k-line god-context (50 `useState`, 30 `useRef`,
  31 `useEffect`). Split into domain hooks (`useAmbient`, `useBinaural`,
  `useSleepTimer`, `usePodcast`, `useAudioEngine`) to shrink the live-state ref
  juggling and make each surface independently testable.
- Infra is three providers (GH Pages app + Cloudflare Worker feed-proxy + Render
  Docker audio-proxy). `render.yaml` hardcodes `ALLOWED_ORIGINS` to a GH-Pages
  username; the audio-proxy needs ffmpeg, so a like-for-like move to a Worker is
  non-trivial (would need ffmpeg.wasm under Worker CPU/memory limits).
