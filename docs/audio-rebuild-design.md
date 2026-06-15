# Design: recover from a `closed` AudioContext (TODOS P0, Gap 1)

## Goal

When iOS tears the AudioContext down to `closed` after an interruption, the
current in-place `reconnectAllSources()` cannot recover (a `MediaElementSourceNode`
can't move contexts, and `createMediaElementSource` throws if called twice on the
same element). Restore audio without an app restart by rebuilding the engine:
a fresh context, fresh `<audio>` elements, re-routed graph, resumed on the next
user gesture.

## The hard constraint that shapes everything

`MixBus` owns the context and nodes, but **AppContext owns the `<audio>`
elements** (`ambientAudio`/`binAudio`/`podAudio` refs) and the only code that
knows each element's `src`, loop metadata, and playback position. So rebuild
can't live entirely in `MixBus` — it's a two-party handshake:

- `MixBus.rebuild()` throws away the dead context and stands up a new one.
- A registered callback asks AppContext to recreate its elements and re-add
  them as sources.

We deliberately do **not** move element ownership into `MixBus`. The existing
`ensureAmbientAudio` / `ensureBinAudio` / `ensurePodAudio` builders already
encapsulate element creation + event wiring + `addSource` + volume/src restore;
reusing them is far less risky than a full ownership refactor.

## MixBus changes

### 1. Extract context setup so the constructor and rebuild share it

```js
// MixBus.js
constructor() {
  this._onRebuild = null;     // AppContext registers this
  this._rebuilding = false;
  this._initContext();        // was the constructor body
}

_initContext() {
  const AC = window.AudioContext || window.webkitAudioContext;
  if (!AC) { this.supported = false; return; }
  this.supported = true;
  this.context = new AC();
  this.masterGain = this.context.createGain();
  this.masterGain.connect(this.context.destination);
  this._startPanLFO();        // existing panLFO setup, extracted
  this.sources = new Map();
  this.context.onstatechange = () => this._handleStateChange();
}
```

### 2. State-change handler distinguishes the two failure modes

```js
_handleStateChange() {
  const state = this.context.state;
  console.log(`MixBus: state -> ${state}`);
  if (state === 'running') {
    this.reconnectAllSources();          // suspend -> resume path (unchanged)
  } else if (state === 'closed') {
    this.rebuild();                       // teardown path (new)
  }
}
```

### 3. Dead-context guard, used by every entry point

```js
isDead() {
  return !this.supported || !this.context || this.context.state === 'closed';
}
```

`resumeContext()` calls `rebuild()` first if `isDead()`, and treats a
`resume()` rejection with `InvalidStateError` as a teardown signal (belt and
suspenders — some iOS builds reach `closed` without firing `onstatechange`):

```js
async resumeContext() {
  if (!this.supported) return;
  if (this.isDead()) { await this.rebuild(); return; }
  if (['suspended', 'interrupted'].includes(this.context.state)) {
    try { await this.context.resume(); }
    catch (err) {
      if (err?.name === 'InvalidStateError') await this.rebuild();
    }
  }
}
```

### 4. `rebuild()` — capture descriptors, swap context, hand off to AppContext

`this.sources` already holds each source's logical state
(`volume, eqOn, compOn, panOn`). Capture those *ids+settings* (not the dead
nodes), tear down, re-init, and let AppContext recreate the elements.

```js
async rebuild() {
  if (!this.supported || this._rebuilding) return;
  this._rebuilding = true;
  try {
    // 1. snapshot logical layer settings before discarding nodes
    const layers = [...this.sources.entries()].map(([id, s]) => ({
      id, volume: s.volume, eqOn: s.eqOn, compOn: s.compOn, panOn: s.panOn,
    }));

    // 2. tear down the dead context (ignore errors — it may already be closed)
    try { this.panLFO?.stop(); } catch {}
    try { await this.context.close(); } catch {}

    // 3. stand up a fresh context + master + LFO; clears this.sources
    this._initContext();
    this.setMasterVolume(this._lastMasterVolume ?? 1);

    // 4. ask AppContext to recreate elements and re-addSource each layer.
    //    The callback returns after new elements exist and are re-added.
    if (this._onRebuild) await this._onRebuild(layers);
  } finally {
    this._rebuilding = false;
  }
}

onRebuild(cb) { this._onRebuild = cb; }
```

`setMasterVolume` should stash `this._lastMasterVolume` so the new context comes
up at the right level.

## AppContext changes

### 1. Make the builders able to discard and recreate

Today each builder early-returns the existing ref. Add a `force` flag so
rebuild can replace the orphaned element:

```js
const ensureAmbientAudio = (force = false) => {
  if (ambientAudio.current && !force) return ambientAudio.current;
  if (ambientAudio.current && force) {
    try { ambientAudio.current.pause(); ambientAudio.current.src = ''; } catch {}
    ambientAudio.current.remove();
    ambientAudio.current = null;            // old MediaElementSource is GC'd with the dead ctx
  }
  const audio = document.createElement('audio');
  configureHiddenAudioElement(audio);
  mixBus.addSource('ambient', audio);
  audio.addEventListener('timeupdate', () => {
    if (NATIVE_MEDIA_VOLUME_LOCK) maybeWrapManualLoop(audio, ambientLoopMeta.current, ambientWrapLock);
  });
  document.body.appendChild(audio);
  ambientAudio.current = audio;
  syncAmbientVolume(1, muted, { preservePosition: false }); // restores src too
  return audio;
};
```

Same pattern for `ensureBinAudio` and `ensurePodAudio`. Note `syncAmbientVolume`
/ `syncBinVolume` already re-set the element `src` via `swapManagedLoopSource`,
so ambient/bin need no extra src handling. For pod, keep the last playback URL
in a ref (`lastPodUrl.current`, set wherever `audio.src = playbackUrl` happens)
and the position from `podProgress`, then on recreate:
`audio.src = lastPodUrl.current; audio.currentTime = savedPos`.

### 2. Register the rebuild callback once

```js
useEffect(() => {
  mixBus.onRebuild(async () => {
    // recreate only the layers that were active; re-apply effects
    if (ambientOnRef.current) { ensureAmbientAudio(true); }
    if (binOnRef.current)     { ensureBinAudio(true); }
    if (podPlayingRef.current || curEpRef.current) { ensurePodAudio(true); }
    mixBus.setEffects('pod', { eqOn: eqOnRef.current, compOn: compOnRef.current, panOn: panOnRef.current });
    // do NOT auto-resume here — see "iOS reality" below
  });
}, []);
```

Use refs (`ambientOnRef`, etc.) inside the callback since it's registered once
and must read live state. Several of these refs already exist
(`podStateRef`); add the few missing ones.

### 3. Resume on the next gesture (already wired)

Every play path and the MediaSession `play` handler already call
`mixBus.resumeContext()`, which now rebuilds-if-dead before resuming. So after a
teardown the **lock-screen Play button recovers audio** — that's the realistic
recovery target.

## iOS reality: what "recovery" can and can't mean

Creating a new `AudioContext` is allowed anytime, but it starts `suspended` and
`resume()` only succeeds inside a user gesture. After a `closed` teardown with
the screen locked and no interaction, there is **no fully-automatic resume** —
that's an iOS platform limit, not a code gap. What this design buys:

- The graph is rebuilt eagerly, so the moment a gesture arrives (tap, or the
  **lock-screen/Now-Playing Play button**, which counts as a gesture) audio
  comes back instantly, instead of requiring an app relaunch.
- The suspend→resume path (the common case) is unchanged and still auto-recovers.

Document this expectation in TESTING.md §3B so a "needs one tap after a long
interruption" result is recorded as *pass*, not *fail*.

## Edge cases

- **Rebuild storms.** `_rebuilding` guard + only triggering on `closed`
  prevents loops; `onstatechange` firing repeatedly is a no-op while rebuilding.
- **Double audio.** Old elements are paused, `src=''`, and removed before new
  ones play, so no two elements ever drive the same layer.
- **Blob URLs.** Ambient/bin URLs come from the shared `LOOP_URL_CACHE` and are
  safe to reuse on a new element — do **not** revoke them on teardown. Only
  per-instance managed/gain-scaled URLs (`ambientManagedUrl`) should be revoked,
  which `swapManagedLoopSource` already handles.
- **Pod position drift.** Restoring `currentTime` after `loadedmetadata` (not
  immediately) avoids a seek-to-0 race on slow element load.
- **Non-iOS / unsupported.** `isDead()` short-circuits when `!supported`; no
  behavior change on desktop.

## Testing additions

- **Unit (CI):** mock an `AudioContext` whose `state` can be forced to
  `closed`; assert `rebuild()` builds a new context, clears/repopulates
  `sources`, and invokes `onRebuild` with the captured layer settings. Assert
  `resumeContext()` calls `rebuild()` when `isDead()`.
- **Device (TESTING.md §3B):** the long-interruption variant already added —
  confirm lock-screen Play restores audio after a `closed` teardown.

## Rollout / risk

Low blast radius: `MixBus` gains methods but keeps the existing suspend→resume
path untouched; AppContext changes are additive (a `force` flag + one effect).
Ship behind the existing manual device pass. Land `_initContext` extraction and
the `force` builders first (pure refactor, unit-testable), then the
`rebuild()` + callback wiring.
