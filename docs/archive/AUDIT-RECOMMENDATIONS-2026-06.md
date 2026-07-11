# Sleepulator — Engineering Audit & Recommendations

_Blind read of the native SwiftUI app (June 2026). Docs intentionally not consulted; findings are from source only._

## Overall assessment

This is high-quality, carefully-engineered code. The hard parts are done right:

- **Real-time audio is correct.** `GenerativeAudioEngine` feeds the render thread via a lock-free atomic double-buffer (`SLPAtomicIndex`, release/acquire ordering), with per-sample gain smoothing and denormal flushes. No locks/allocation in the render block.
- **The Night Limiter is solid.** The `MTAudioProcessingTap` retains the player for its own lifetime and releases in `finalize` (the documented use-after-free fix), handles interleaved/planar layouts, and applies volume post-effects where `AVPlayer.volume` is bypassed.
- **Persistence is crash-resilient.** `StorageManager` writes a `.bak` sibling, self-heals a corrupt primary, and distinguishes missing (benign) from failed. Caps exist everywhere unbounded growth could happen (positions ≤100, finished ≤1000, parser field caps, 2GB LRU cache).
- **SwiftUI re-render discipline is deliberate.** 20Hz RMS and 1Hz progress are kept off `@Published`; child `objectWillChange` is *not* forwarded into `AudioEngine`; leaf views observe the timers directly. Row state is precomputed so the podcast list doesn't re-render on every tick.
- **Network layer is appropriate** for a half-asleep-on-flaky-wifi user: configured sessions, retry with backoff, 4xx-vs-5xx classification.

Recommendations below are about hardening edges and filling gaps, not fixing a broken base.

---

## Tier 1 — highest leverage

### 1. Fail-safe terminal stop for the sleep timer
The app's core promise — fade out and **stop** so audio doesn't play all night — currently rests entirely on in-process timers: a GCD `DispatchSourceTimer` plus a `backgroundTick()` keep-alive from the RMS tap and AVPlayer observer, with the `0.03` fade-floor keeping the engine barely audible so iOS doesn't curtail background execution. Clever, but if iOS **fully suspends** the app, nothing ticks and audio never stops. Add an independent backstop (scheduled local notification / `BGProcessingTask`) at the timer deadline. Your own verification gate flags this path as device-specific and untestable in XCTest, which is exactly why it deserves a redundant stop.

### 2. Reduce Motion is ignored by most ambient scenes
`SceneContext` exposes `reduceMotion`, but only the Focus energy scene and `BreathingBloomView` honor it. Aurora, Embers, RainGlass, StillWater, Sandfall, and Tide animate at full rate regardless. This is an accessibility miss (vestibular sensitivity) *and* a free all-night battery win. Honor it everywhere: static frame or very low frame rate when on.

### 3. Audio-reactive scenes flatline during podcast-only playback
`audioLevel` is driven only by `genEngine.onRMSUpdate`, so with no noise bed the breathing/glow scenes go dead (acknowledged in-code as "a v1 limitation"). The `PodcastPlayer` limiter tap already computes per-buffer peaks — surface that to feed `audioLevel` when the generative bed is silent.

### 4. Sound layering (largest missing feature)
The engine renders exactly one `noiseType` at a time (`AudioRenderParams.noiseType: Int`). Stacking rain + brown + fan is the category's most-requested capability and the most material architectural gap. It plays directly to the generative-synthesis strength (no asset files). See the implementation sketch below.

---

## Tier 2 — strengthen existing features

5. **Gentle wake alarm.** Symmetric to the fade-out timer; `ChimePlayer` already synthesizes audio. Turns the app into a full bedside companion at low marginal cost.
6. **More App Intents + a Home Screen widget.** Only two intents exist today (Start Mix, Set Timer) plus the Live Activity. Add intents for a specific saved preset / scene, and a quick-start widget. The preset and scene infrastructure already exists.
7. **Background feed refresh.** Subscriptions only update on detail-view open. A `BGAppRefreshTask` re-parsing feeds keeps the library alive.
8. **Observability for unverifiable paths.** Add `os_signpost` intervals around timer fire, engine suspend/resume, session reactivation, and limiter attach so the all-night invariants can be confirmed from a real-device sysdiagnose instead of inferred.
9. **Tighten cross-view state sync.** `PodcastDetailView` loads `episodePositions` / downloaded-URL state once in `onAppear`; updates elsewhere don't propagate until re-entry. Drive off a shared observable or refresh on `scenePhase`/tab change.

---

## Tier 3 — polish

- **Position-loss window:** resume positions flush every 30s + on background; a hard kill loses up to 30s. Consider a shorter interval or flush-on-significant-seek.
- **Destructive actions** (delete subscription, remove queue item) are immediate — add haptic + undo.
- **Settings copy:** when "limiter follows mode" is on, the disabled Night Limiter toggle still reads as a normal control; clarify it's automatic.
- **`RainGlassDepthView` `t0`** doesn't reset across pause/resume → shader glitch (DEBUG-only today; fix before it ships).
- **Scene duplication:** RNG seeding, night-dimming, and breath-curve math are reimplemented across ~9 scenes. A shared `AnimatedCanvas` wrapper + night-dim/breath helpers would shrink each scene and make the Reduce-Motion rule (#2) trivial to enforce.
- **Test gaps:** strong coverage on pure logic (AudioMath, eviction, parser, retry, queue advance, storage recovery); `MixStore` and `PersistenceMigrator` have none and are pure/Codable — easy wins.

---

## Load-bearing invariant to protect

`GenerativeAudioEngine.updateParams` assumes a **single writer on main** (DEBUG `dispatchPrecondition`). Any new param path — especially layering — must route through main, or the double-buffer corrupts silently in release.

---

# Implementation sketch — the two I'd scope first

## A. Fail-safe sleep-timer backstop

**Goal:** audio is guaranteed to stop at the deadline even if the app is suspended/killed.

**Approach:** keep the existing in-process fade (it gives the graceful ramp), and add an independent hard stop.

1. On `startSleepTimer(minutes:)` / `startEndOfEpisode`, schedule a `UNUserNotificationCenter` request with a `UNTimeIntervalNotificationTrigger` at the deadline (silent/low-key). Cancel it in `cancelTimer`, reschedule on `bumpTimer`.
2. Register a `BGProcessingTaskRequest` (or use the notification's `UNNotificationServiceExtension`/launch handler) whose handler calls `stopAll()` if the app is resumed at/after the deadline and audio is still active.
3. On `applicationDidBecomeActive` / `scenePhase == .active`, reconcile: if `now >= sleepTimerEnd` and `isAnythingPlaying`, force the terminal stop immediately (covers the "iOS suspended us through the deadline, user just unlocked" case).
4. Add a unit test asserting the notification is scheduled with the right fire date and cancelled on `cancelTimer`/`bump` (the scheduling call is mockable even though the audio stop isn't).

**Risk:** low. Purely additive; the in-process path is unchanged. Main subtlety is keeping the scheduled fire date in sync with `bumpTimer` (+15m) and end-of-episode's moving target.

## B. Multi-layer generative noise

**Goal:** play N noise generators simultaneously with independent gains, without breaking the lock-free hand-off or the render-thread budget.

**Param model:** replace the single `noiseType: Int` / `noiseGain: Float` with a small fixed-size array in `AudioRenderParams`:

```swift
struct NoiseLayer { var type: Int32 = 0; var gain: Float = 0 }   // gain 0 = inactive
// fixed cap keeps the struct POD and the double-buffer copy trivial
var layers: (NoiseLayer, NoiseLayer, NoiseLayer)                  // cap = 3 to start
```

**Render thread:** the per-sample `switch type` becomes a loop over active layers (`gain > 0`), each with its **own** filter state (the current `AudioRenderState` fields — `brownL`, `rainBed*`, `green*`, etc. — must be promoted to per-layer arrays). Sum, then the existing stereo-width + softClip stage runs once on the mix. Watch the CPU: 3 brown/ocean layers is cheap; the heavier filtered textures (rain, green, forest) are a few poles each — fine at 3, profile before allowing more.

**State migration:** `AudioRenderState`'s noise filter fields move into `[NoiseLayerState]` indexed to match the param slots. Binaural is untouched.

**API:** `setNoiseLayers([(type, volume)])` replacing `setNoise(on:volume:type:)`; keep a single-layer convenience wrapper so existing call sites and presets keep working.

**Model/persistence:** extend `SoundPreset` and `SavedMix` to store an array of layers; keep the single `noiseType` field decodable for back-compat (decode old → one-element array). `NoiseType.migrate` already gives you the forward-migration hook.

**UI:** the mixer gains a per-layer add/remove + volume; `defaultPresetName()` becomes "Rain + Brown + Delta".

**Tests:** params round-trip, old-preset decode → single layer, and a render-thread smoke test summing two layers stays within `[-1, 1]` after softClip.

**Risk:** medium — it's the render thread and the persistence schema. The single-writer-on-main invariant and the back-compat decode are the two things to get exactly right.
