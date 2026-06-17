# SLEEPULATOR — agent guide

A PWA for falling asleep: layer ambient noise + binaural beats, mix in a podcast,
set a sleep timer that fades everything out. Optimized for **installed iPhone PWA,
screen locked, playing all night** — that use case drives most of the hard
decisions below.

## Stack
- React 18 + Vite (`base: './'`), no router. UI is one provider + a layout tree.
- Raw **Web Audio** for the engine (NOT Tone.js — ignore any old notes that say otherwise).
- Vitest + Testing Library (happy-dom) for unit/integration tests.
- Ships to **GitHub Pages** via `.github/workflows/deploy.yml` on push to `main`
  (runs `npm test`, builds, publishes `dist/`). A network-first service worker
  (`public/sw.js`) caches the shell.

## Architecture
- `src/context/AppContext.jsx` — the single provider. Owns ambient, binaural,
  sleep timer, podcast playback, EQ/comp/pan, offline episode caching, MediaSession,
  persistence. **It's a ~1.5k-line god-context** (known debt; see TODOS.md). When
  adding state, follow the existing pattern but prefer extracting a domain hook if
  you're touching a whole subsystem.
- `src/audio/MixBus.js` — the Web Audio engine. One module-level singleton
  (`mixBus`). Per-source chain: `MediaElementSource → [eq] → [comp] → [pan] → gain
  → duckBus (ambient/bin) | masterGain (pod) → destination`.
- `src/utils/core.js` — pure helpers: noise/binaural generators, WAV builders,
  seamless-loop math, feed parsing, URL/proxy helpers. Most unit-testable logic lives here.
- `src/components/*` — presentational; read everything from `useAppContext()`.

## Audio-engine invariants (the hard-won stuff — change with care)
- **iOS uses the native `<audio loop>` path, not gain nodes.** `NATIVE_MEDIA_VOLUME_LOCK`
  (true on iOS) means programmatic `audio.volume` is ignored, so ambient/binaural
  volume is **baked into the generated WAV** and muting uses `audio.muted` / pausing.
  A muted element routed through a `MediaElementSource` can still leak — at true
  zero volume we `pause()` the element (not just mute).
- **Sample-rate floor.** iOS/Safari's decoder is unreliable below ~8 kHz and will
  play a too-low-rate WAV as silence. Ambient = 12 kHz, binaural = 8 kHz. Do not
  drop these. (Binaural also needs **headphones** — the carrier is ~180 Hz.)
- **Seamless loops** use an equal-power (cos/sin) crossfade in `makeSeamlessLoop`,
  not linear — linear dips ~3 dB mid-seam on uncorrelated noise (audible "gap").
- **Context recovery is implemented and tested.** `MixBus` handles both
  suspend→resume (`reconnectAllSources`) and full teardown (`rebuild()` → fresh
  context → `onRebuild` callback recreates elements). `AppContext` registers the
  callback. The remaining open item is auto-resume while backgrounded (iOS limit).
- **Ducking** routes ambient+bin through a shared `duckBus`; an analyser on the pod
  taps loudness and rides the bus gain. Suspended during the sleep-timer fade so the
  two don't fight. Unverified by ear — treat as experimental.
- **Headphone auto-pause**: only on a real present→absent transition with readable
  device labels. On iOS labels are blank, so it must NOT pause then (false pauses
  killed all audio).

## localStorage budget rule
iOS gives localStorage a tight budget. Persistence in `AppContext` saves **each key
independently** (one oversized write must not abort the rest) and **strips the heavy
`description` field** from persisted episodes. If you add persisted state, keep it
small and never put it in a single shared try-block ahead of the queue/subs writes.

## Infra / proxies (3 services — see render.yaml, public/config.js)
- App: GitHub Pages (`https://blurbleasd.github.io`).
- Feed proxy: Cloudflare Worker (CORS-fetches RSS).
- Audio proxy ("Sleep Safe"): Render Docker service running **ffmpeg** loudnorm +
  limiter so volume spikes don't wake you. Free tier sleeps → first play after idle
  is slow. `ALLOWED_ORIGINS` is dashboard-managed (falls back to a default in
  `server.js`); `ALLOWED_AUDIO_HOSTS` gates which podcast hosts may be proxied.
  Note: ffmpeg means this can't trivially move to a Worker.

## Build / deploy notes
- `vite.config.js` injects `__BUILD_ID__` (git short SHA) → shown as "build <id>" at
  the bottom of the home screen, and stamped into `dist/sw.js`'s cache name so each
  deploy auto-busts the shell. To verify a device is on the latest code, compare that
  hash to the latest commit.
- `public/` files are copied verbatim (no Vite `define` substitution) — that's why
  the SW build id needs the `stamp-sw` plugin.

## The verification gate (read before claiming an audio fix works)
**Unit tests cannot catch the iOS audio bugs** (no real AudioContext in happy-dom;
sample-rate, muting, looping, background behavior are device-specific). Any change to
the audio engine, volume path, or looping must be verified on a **real iPhone,
installed as a PWA, screen locked** — see TESTING.md. State clearly in a summary when
something is shipped-but-unverified-on-device.

---

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
