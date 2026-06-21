# Sleepulator — on-device loudness limiting (replaces Sleep Safe)

> **Status note:** Fully implemented and verified in the native iOS app. All three parts (A, B, C) are complete. The Sleep Safe proxy has been removed, and the on-device limiters (podcast tap and generative dynamics processor) are active.

Scope: move loudness protection from the (now-orphaned) server proxy to a real-time on-device limiter,
and remove the Sleep Safe proxy plumbing. Three parts:
- **A** (primary): a night limiter on the **podcast** via `MTAudioProcessingTap` — the real spike source.
- **B** (secondary, independent): a master limiter + headroom on the **generative** bus, replacing the
  hard `±1` clip.
- **C**: rip out the Sleep Safe proxy (URL field, toggle's proxy half, `AppConfig.audioProxyUrl`).

Why on-device (vs. the proxy): works offline, no cold-start, no transcode loss, no paid-feed privacy hop,
can be **on by default**, and the proxy's only real edge (two-pass LUFS *matching* across episodes) is a
nicety you already disable by default — not the safety feature.

Conventions:
- "PP" = `Sleepulator/Sleepulator/Services/PodcastPlayer.swift`
- "GAE" = `Sleepulator/Sleepulator/Services/GenerativeAudioEngine.swift`
- "AE" = `Sleepulator/Sleepulator/Services/AudioEngine.swift`
- "Settings" = `Sleepulator/Sleepulator/Views/SettingsView.swift`

Hard rules:
- The tap **process callback and the limiter inner loop are real-time threads**: no allocation, no locks,
  no Swift/ObjC runtime calls, no logging. All limiter state lives in a C-style struct allocated in the
  tap's `init` callback and freed in `finalize`.
- **Fail open**: if the tap can't attach (HLS/streamed asset with no accessible audio track, AirPlay, any
  error), playback proceeds **unprocessed** — never block or kill audio for the limiter. Surface a subtle
  `playbackNote` ("Limiter unavailable for this stream") like the existing failure path.
- Guard against denormals/NaN in the DSP (flush tiny values to 0; clamp final output to ±1).
- Build green (`xcodebuild`) + `xcodebuild test` passing.

---

## A — Podcast night limiter (`MTAudioProcessingTap`)

**Problem:** podcast audio is completely unprocessed today (only the generative noise hard-clips). A loud
ad, music sting, or over-mastered laugh passes through at full level and wakes the sleeper. AVPlayer has no
insert-effect API, so we tap its audio mix.

**Why a tap (not routing podcast through AVAudioEngine):** the tap keeps AVPlayer's streaming, seek,
`automaticallyWaitsToMinimizeStalling`, and Now-Playing/lock-screen support intact. Routing the podcast into
`AVAudioEngine` (`AVAudioPlayerNode`) would give a stock Apple limiter but forces download-before-play and a
rewrite of seek/time-observation/Now-Playing — see "Alternative" at the bottom; not recommended now.

**Change (PP):**

1. Add a tap install step in `play(url:id:title:)`, after the `AVPlayerItem` exists and before/at `play()`.
   Build it from the item's asset audio track:
   ```swift
   // async; if it throws or returns no track, skip the tap (fail open)
   if let track = try? await playerItem.asset.loadTracks(withMediaType: .audio).first {
       let params = AVMutableAudioMixInputParameters(track: track)
       params.audioTapProcessor = makeLimiterTap()   // see below
       let mix = AVMutableAudioMix()
       mix.inputParameters = [params]
       playerItem.audioMix = mix
   }
   ```
   Keep a strong reference to the created `MTAudioProcessingTap` for the item's lifetime; release on
   item swap/stop.

2. `makeLimiterTap()` creates the `MTAudioProcessingTap` (flag
   `kMTAudioProcessingTapCreationFlag_PostEffects`) with five callbacks. Allocate a
   `LimiterState` struct in `init` (store in `clientInfo`), read format in `prepare`, free in `finalize`:
   ```c
   struct LimiterState {
       float gain;        // current gain-reduction (1.0 = no reduction)
       float ceiling;     // linear, e.g. 0.71 (~ -3 dBFS)
       float attackCoef;  // fast (attack ~1-3 ms)
       float releaseCoef; // slow (release ~150-300 ms)
       float enabled;     // 1.0 / 0.0  (toggled from the @Published flag, written atomically)
   };
   ```

3. `process` callback — get source audio, apply the limiter per frame across channels in place
   (deinterleaved Float32 is the common tap format; handle interleaved defensively):
   ```
   MTAudioProcessingTapGetSourceAudio(...) -> bufferList
   if state.enabled == 0 { return }            // bypass = passthrough
   for each frame f:
       peak = max(|L[f]|, |R[f]|)
       if peak < 1e-7 { peak = 0 }             // denormal flush
       target = (peak * state.gain > state.ceiling && peak > 0) ? state.ceiling / peak : 1.0
       coef   = (target < state.gain) ? state.attackCoef : state.releaseCoef   // fast down, slow up
       state.gain += (target - state.gain) * coef
       L[f] = clamp(L[f] * state.gain, -1, 1)
       R[f] = clamp(R[f] * state.gain, -1, 1)
   ```
   This is a feedback peak limiter — catches sustained loudness and fast transients without a lookahead
   delay. Good enough for v1.
   - **Optional "night mode" upgrade:** add a gentle compressor stage *before* the ceiling (soft knee,
     threshold ~ -18 dBFS, ratio ~3:1) so moderately-loud sounds are also pulled down, not just peaks —
     this is what keeps quiet dialogue audible while taming loud. Tune by ear.
   - **Optional later:** a few-ms lookahead delay line for true brickwall transient catching.

4. Wire the on/off + intensity: AE exposes `@Published var nightLimiter: Bool` (default **true**). On change,
   write `state.enabled` (a single `float`/`Int32` write is atomic enough for the audio thread; do **not**
   take a lock). Default ceiling/attack/release as above; expose them only if you later add an intensity
   control.

**Acceptance:** with the limiter on (default), play an episode with a known loud spot (ad / music sting) at a
comfortable bedtime volume — the spike is audibly tamed, quiet speech is unchanged, no pumping/clicks. Toggle
off → spike returns. Seek, lock-screen controls, and background playback all still work. A pure-HLS stream
that can't attach the tap plays unprocessed with the subtle note, not silence.

---

## B — Generative master limiter + headroom (independent, small)

**Problem:** the generative noise hard-clips at `max(-1, min(1, …))` (harsh), and nothing bounds the
**sum** of noise + binaural + podcast at the speaker. Each source is limited separately (A limits podcast;
this limits the generative bus), so give each headroom so the sum doesn't reach 0 dBFS.

**Change (GAE):**
1. Insert an Apple `DynamicsProcessor` (or `PeakLimiter`) after the mixer:
   ```swift
   let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                        componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                        componentManufacturer: kAudioUnitManufacturer_Apple,
                                        componentFlags: 0, componentFlagsMask: 0)
   let limiter = AVAudioUnitEffect(audioComponentDescription: desc)
   engine.attach(limiter)
   engine.connect(mainMixer, to: limiter, format: format)   // overrides mixer→output implicit edge
   engine.connect(limiter, to: engine.outputNode, format: format)
   ```
   Set a brickwall-ish ceiling (e.g. master threshold/headroom so output peaks ≈ -3 dBFS) via the AU
   parameters after attach.
2. Replace the per-sample `max(-1, min(1, …))` hard clip in the noise node with a cheap soft clip
   (`x / (1 + |x|)` or `tanh`-free polynomial) **only at the rails** — i.e. keep unity below threshold so the
   tuned timbre is unchanged; round only peaks. (Do **not** apply a global `tanh` — that recolors everything;
   we rejected that earlier.)
3. Trim per-source default gains slightly (a few dB of headroom) so noise@ceiling + binaural@ceiling +
   podcast@ceiling can't sum to a hot 0 dBFS.
4. Keep the existing RMS tap; if you want the meter post-limiter, move the tap to `limiter` bus 0.

**Acceptance:** with noise + binaural + a loud podcast all up, the combined output doesn't clip/distort;
the noise timbre at normal levels is unchanged from today (A/B by ear); the meter still drives the orb.

---

## C — Remove the Sleep Safe proxy

**Problem:** the `audio-proxy/` server is already deleted from the repo, but the app still points at
`sleepulator-audio-proxy.onrender.com` and shows the toggle + URL field. Dead, unreliable plumbing.

**Change:**
- **AE:** delete `AppConfig.audioProxyUrl`, the `@Published var audioProxyUrl`, and the proxy branch in
  `resolveAudioUrl` (keep only the local-cache resolution). Rename the user-facing concept: replace
  `sleepSafeAudio` with `@Published var nightLimiter: Bool` (default **true**) under a **new** key
  `nightLimiterEnabled`. On launch, migrate: if the old `sleepSafeAudio` key exists, ignore its value
  (semantics changed — default the new limiter **on**) and `removeObject` the old `sleepSafeAudio` +
  `audioProxyUrl` keys. Drop the "Sleep Safe on but no proxy" `playbackNote`.
- **Settings:** remove the "Sleep Safe Proxy URL" field + reset button. Replace the "Sleep Safe Audio
  Limiter" toggle with **"Night Limiter — soften loud spikes"** bound to `audio.nightLimiter` (default on).
  (Per the UI spec, the RSS feed-proxy field is a separate thing and moves under "Advanced"; leave it.)

**Acceptance:** no proxy URL or Sleep Safe text remains; Settings shows a single "Night Limiter" toggle
defaulting on; podcasts play directly (local cache still used) with the on-device limiter doing the work;
upgrading users keep working state and the old keys are gone.

---

## Implementation order
1. **C** first (removes the dead proxy, introduces the `nightLimiter` flag + key the rest depends on).
2. **A** (the tap — the actual safety feature). Verify on device before B.
3. **B** (generative limiter + headroom + soft clip) — independent polish; A/B the noise by ear.

## Keep stable
All other `UserDefaults`/`@AppStorage` keys; podcast seek / Now-Playing / queue behavior; the generative
param double-buffer (don't add locks); the RMS-meter pathway.

## Verification gate (on device, not Simulator)
- Loud-spot episode at bedtime volume: spike tamed with limiter on, returns with it off; no pumping/clicks
  on speech.
- Seek, lock-screen play/pause/skip, background + screen-locked playback all intact with the tap attached.
- Noise+binaural+podcast all up: no combined clipping; noise timbre unchanged at normal level.
- Airplane mode / downloaded episode: limiter still applies (it's on-device).
- A streamed/HLS asset that can't take the tap: plays unprocessed with the subtle note, never silent.

## Alternative (not recommended now): route podcast through AVAudioEngine
Play episodes via `AVAudioPlayerNode` inside the existing engine and put one `DynamicsProcessor` on the
master — Apple-tuned DSP, one limiter covers *everything*, and you'd drop the hand-rolled tap. Cost: lose
AVPlayer streaming (must download before play) and re-implement seek, time observation, and Now-Playing
against the engine. Revisit only if you decide to drop streaming playback.
