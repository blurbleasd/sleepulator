# TODOS

## P0: AudioContext lifecycle handler (Phase 2 — MixBus)

MixBus needs a `context.onstatechange` handler that re-establishes all
`MediaElementSourceNode` connections when iOS recreates the AudioContext
(e.g., after a phone call interrupts audio).

**Why:** Without this, audio goes silently dead after any iOS audio
interruption. Tone.js may close/recreate its context on iOS resume,
breaking all node connections silently.

**Context:** This is the primary reliability risk for the core use case
(falling asleep with audio playing). A 2am phone call would kill the
audio permanently until the user manually restarts the app.

**Where to start:** `src/audio/mix-bus.js` — add a
`Tone.getContext().rawContext.onstatechange` listener that, when state
transitions to 'running' after being 'interrupted' or 'suspended',
calls a `reconnectAllSources()` method that walks all layers and
re-establishes their `MediaElementSourceNode` → `Tone.Channel` connections.

**Depends on:** Phase 2 (MixBus class exists).
