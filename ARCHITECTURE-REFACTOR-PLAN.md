# Sleepulator — Architecture Refactor Plan

_Date: 2026-06-21 · Two large items from the audit: (A) decompose the `AudioEngine` god-object, (B) formalize real-time audio thread-safety. Written to be executed **with a compiler in the loop** — each slice below is independently shippable and should be built + smoke-tested before the next._

## Why incremental, not one big rewrite

`AudioEngine` is the spine of an app that plays unattended all night, and it has **no automated coverage on the audio path** (the unit tests deliberately can't exercise the real-time thread — see `TESTING.md`). A single large refactor here is high-blast-radius and unverifiable without a device. The plan therefore moves in slices that each (1) compile, (2) keep the public surface the views depend on identical, and (3) can be verified on a real iPhone, installed, screen-locked, before moving on.

Two Swift gotchas that shape the whole approach:

- **`private` is file-scoped.** The moment you move a method that touches a `private` member into a different file (even an `extension AudioEngine`), it stops compiling. So "split the class across files" forces you to widen a lot of members to `internal`, which leaks the encapsulation you were trying to create. **Prefer extracting owned sub-types over splitting the class across files.**
- **`@Published` stored properties and `init` must stay on the `ObservableObject`.** Only methods and computed vars move. `@objc` notification handlers *can* live in an extension, but they reference private engine state, so they hit the rule above.

---

## Part A — Decompose `AudioEngine`

### Current responsibilities (≈600 lines, one class)

`AudioEngine` currently owns, all at once:
1. **UI-facing @Published state** — volumes, types, mode, toggles, podcast progress, `playbackNote`, `isOnline`, `rmsPower`. (Views bind to these — must stay.)
2. **Persistence** — every `didSet` writing UserDefaults; the big launch-time migration block in `init` (legacy keys → `StorageManager` files).
3. **Mix save/restore** — `saveLastMix`, `resumeMix`, `saveCurrentAsPlaylist`, `deleteMix`, `lastMix`, `savedPlaylists`.
4. **Generative-engine orchestration** — `syncGenEngine`, `updateEnginePower`, the `suspendWorkItem` power-saving, master/fade/width plumbing.
5. **Podcast orchestration** — `loadPodcast`, `resolveAudioUrl`, seek wrappers, queue passthroughs, the `podPlayer` callback wiring.
6. **Audio-session lifecycle** — `setupAudioSession`, `@objc handleInterruption`, `@objc handleRouteChange`, `@objc handleAppBackground`, the `NWPathMonitor`.
7. **Transport logic** — `toggleMasterTransport`, `pauseAll`, `stopAll`, the `lastActiveSnapshot` snapshot/restore, mode reconciliation.

The good news: the codebase **already uses the right pattern** — `AudioEngine` composes `genEngine`, `podPlayer`, `sleepTimer`, `pomodoro`, `queueManager`, `chime` and wires them with closures + `objectWillChange` forwarding. We extend that pattern, pulling cohesive concerns into owned collaborators, leaving `AudioEngine` as a thin **coordinator/facade** that holds the @Published state the views read.

### Target shape

```
AudioEngine (ObservableObject facade)
├─ holds the @Published UI state (unchanged surface for views)
├─ PersistenceMigrator      (NEW) — owns the init-time legacy→file migration
├─ MixStore                 (NEW) — lastMix + savedPlaylists, save/resume/delete
├─ AudioSessionController   (NEW) — session activate, interruption, route, NWPathMonitor
├─ GenerativeAudioEngine    (exists)
├─ PodcastPlayer            (exists)
├─ SleepTimerService / PomodoroService / PodcastQueueManager / ChimePlayer (exist)
```

Each NEW type talks back to the facade through closures (the established idiom), so no `private`-across-files problem and no `@objc`-in-extension churn.

### Slices (each builds + ships on its own)

**Slice A0 — characterization tests first (do this before touching anything).**
Add tests around the behaviors that have no coverage and that the refactor must preserve, using the existing in-target test file:
- `toggleMasterTransport` snapshot/restore (partly covered already) + the `isMasterPauseTransition` guard.
- `reconcileSoundsToMode` / `resumeMix` noise-type migration.
- `saveLastMix` → `resumeMix` round-trip.
These are the regression net. ~1–2 hrs. **Risk: none.**

**Slice A1 — extract `PersistenceMigrator`.**
Move the ~40-line legacy-migration block from `init` into `PersistenceMigrator.run()` returning a small struct of loaded values (mixes, lastMix, positions, library seed). `init` calls it and assigns. No behavior change; shrinks `init` materially and isolates the most fragile, least-touched code. **Risk: low** (pure move; verify launch + that saved mixes/positions survive an upgrade).

**Slice A2 — extract `MixStore`.**
Owns `lastMix` + `savedPlaylists` (with their persistence). `AudioEngine` exposes them via passthrough computed vars so views are unchanged, and builds a `MixSnapshot` (plain struct of the current layer state) to hand to `MixStore.save…`. This removes the mix methods + their `SavedMix(...)` construction from the facade. **Risk: low–medium** (snapshot wiring; verify save/resume/delete and "Last Night" resume).

**Slice A3 — extract `AudioSessionController`.**
Owns `setupAudioSession`, the three `@objc` handlers, and `NWPathMonitor`. It calls back via closures: `onShouldPausePodcast`, `onResumeGenerative`, `onInterruptionEnded`, `onOnlineChanged`. This is the highest-value extraction (it's the gnarliest concern) **and the highest-risk** — interruption/route handling is exactly what the device-verification gate exists for. Ship it alone and test: phone call mid-playback, headphones unplugged, Bluetooth connect/disconnect, backgrounded all-night. **Risk: medium-high — device-gate.**

**Slice A4 — group the remainder with `// MARK:` and tidy.**
What's left (transport, gen-engine sync, podcast orchestration) stays on the facade but gets clear `MARK` sections, the leaked observer tokens get stored + removed in `deinit`, and `monitor.cancel()` moves into `AudioSessionController.deinit`. **Risk: low.**

Net result: `AudioEngine` drops from ~600 lines to a focused coordinator (~250–300), each concern is unit-addressable, and the views never changed.

---

## Part B — Real-time audio thread-safety

Two spots rely on invariants that hold today only because the objects live for the whole app lifetime. Make them correct, not just lucky.

### B1 — Lock-free param hand-off (`GenerativeAudioEngine`)

`updateParams` writes `paramsBuffer[nextIdx]` then publishes `readIdxPtr.pointee = nextIdx`, and the audio render block reads `paramsBuffer[readIdxPtr.pointee]`. The index is a **plain `Int`** with no memory barrier. On ARM64 the aligned word load/store won't tear, but nothing prevents the compiler/CPU from reordering the param-struct write after the index publish — so the audio thread can briefly read the *new* index against the *old* params.

**Fix:** make the index a real atomic with release/acquire ordering.
- **Recommended:** add the **`swift-atomics`** package (`Atomic<Int>`/`ManagedAtomic<Int>`), store the read index in it, publish with `.store(_, ordering: .releasing)`, read with `.load(ordering: .acquiring)`. It's Apple-maintained, RT-safe (lock-free), and works on the 17.0 floor.
- **Alternative (no SPM dep):** a 1-file C shim exposing `atomic_int` + `atomic_load_explicit`/`atomic_store_explicit`, imported via a bridging header. More moving parts in the project file; only choose this to avoid a dependency.
- **Avoid:** the iOS 18 `Synchronization.Atomic` (we just set the floor to 17.0) and any lock (`os_unfair_lock`) — never lock on the render thread.

This is a ~15-line change but it's in the audio hot path: **device-gate** (listen for zipper/wrong-value artifacts when dragging sliders / switching presets).

### B2 — Tap holds `PodcastPlayer` unretained

`makeLimiterTap` stores `Unmanaged.passUnretained(self)` and `finalize` calls back into `player.stateLock`/`activeLimiterStates`. Safe today only because `PodcastPlayer` outlives every tap. If ownership ever changes, `finalize` is a use-after-free.

**Fix (make it robust regardless of ownership):** `passRetained(self)` in the tap's `init` callback and `takeRetainedValue()` (release) in `finalize`. The tap then keeps the player alive exactly as long as it's installed — which is the correct lifetime — and the invariant stops being load-bearing. **Risk: low**, but still touches the audio path → device-gate (verify taps attach/detach across `replaceCurrentItem` and that nothing leaks across many auto-advances).

### B3 — Document the remaining single-writer assumptions

`updateParams` is main-thread-only (all callers are). Add an assertion (`dispatchPrecondition(condition: .onQueue(.main))`) in DEBUG so a future off-main caller is caught immediately rather than corrupting the double-buffer silently. **Risk: none.**

---

## Recommended order & gates

1. **A0** (tests) — no risk, do first; it's the safety net for everything after.
2. **B3** then **B1** — thread-safety while the engine code is fresh in mind; B1 is the single highest-correctness win. Device-gate B1.
3. **A1 → A2** — the low-risk facade slimming. Build + launch-test each.
4. **B2** — tap lifetime. Device-gate.
5. **A3** — session controller. Device-gate hard (interruptions/routes/all-night).
6. **A4** — cleanup.

**Every slice that touches the engine, session, or RT path must pass the `TESTING.md` gate: real iPhone, installed, screen locked, played through a full timer + an interruption.** Unit tests cannot stand in for it.

### Effort (rough)
- Part A: ~1–1.5 days of focused work across the slices, most of it in A2/A3 + device testing.
- Part B: ~0.5 day including the swift-atomics integration and device listening.

I can execute any of these slices on request. Because I can't compile or device-test in this environment, the right cadence is: I make one slice's edits → you build & smoke-test → we proceed. A0 (tests) and B3 (the debug assertion) are the safest to start with and need no device.
