# TODOS

## P0 (partial): AudioContext interruption recovery — MixBus

**Status:** The in-place reconnect path is implemented, but it only covers a
*suspend → resume* interruption. A full context teardown and the
auto-resume-while-backgrounded case are still open. See gaps below.

**What's done.** `src/audio/MixBus.js` sets `context.onstatechange` in the
constructor. When the context returns to `running` it calls
`reconnectAllSources()`, which re-routes each source's existing node chain
(`MediaElementSourceNode → [eq] → [comp] → [pan] → gain → masterGain`). All
three sources (ambient noise, binaural, podcast) are `<audio>` elements fed
through `createMediaElementSource`, so this re-establishes the graph after the
*same* context is suspended and resumed. (Note: the engine is raw Web Audio,
not Tone.js — earlier notes here referenced a `Tone.Channel` graph that does
not exist.)

### Gap 1 — full context teardown is unrecoverable
`onstatechange` is bound once, to the original context, and
`reconnectAllSources()` reuses the existing `MediaElementSourceNode`s. If iOS
drives the context to `closed` (rather than `suspended`/`interrupted`), there
is no recovery:
- the closed context's `onstatechange` will never fire `running` again;
- `mixBus` is a module-level singleton constructed once, so no new context is
  created;
- a `MediaElementSourceNode` cannot move to a new context, and
  `createMediaElementSource` throws if called twice on the same element — so
  the existing hidden `<audio>` elements are permanently orphaned.

Recovery requires rebuilding the engine: detect a dead/`closed` context, build
a fresh `AudioContext`, create *new* `<audio>` elements (re-feeding the cached
blob URLs from `getAmbientLoopUrl` / `getBinauralLoopUrl` / the episode src),
and re-`addSource` them. This is the worst-case interruption and is the real
remaining reliability risk for the core "fall asleep with audio playing" use
case.

### Gap 2 — no automatic resume while backgrounded
Even on the survivable suspend→resume path, the reconnect only helps *if* the
context actually returns to `running` and the `<audio>` elements get
`.play()`d again. `resumeContext()` / `resumeSoundscapeAudio()` are only
invoked from explicit user actions and MediaSession `play`. After a phone call
ends with the screen locked and no interaction, nothing re-calls `resume()` +
`play()` on its own, so audio can stay dead until the user taps. TESTING.md
§3B asserts "audio resumes on its own within a couple of seconds" — verify
this actually holds on device, or wire a resume attempt to the
context/interruption-end event.

**Where to verify:** real iPhone, installed as PWA — TESTING.md §3B.
Unit tests cannot exercise either gap.
