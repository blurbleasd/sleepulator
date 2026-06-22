# Audio Palette — Spec

_Date: 2026-06-21 · Build-first, for your own use — no monetization framing. New sounds,
tones, and beats for Sleep and Focus, grounded in `GenerativeAudioEngine` (real-time
`AVAudioSourceNode` render) and the mode-scoped palettes in `AudioEngine`._

Priority key: **P0** must-do · **P1** strong follow-up · **P2** later.

---

## 0. Where things stand

Today's palettes (`AudioEngine`, deliberately non-overlapping):

- **Sleep noise:** brown, rain, ocean · **Focus noise:** pink, fan, white
- **Sleep binaural:** delta ("Deep"), theta ("Drift") · **Focus binaural:** alpha ("Relax"),
  gamma ("Focus")

The engine's noise generator already reserves slots the palettes don't expose yet:
`noiseType` is an Int `0=brown, 1=white, 2=pink, 3=green, 4=fan, 5=rain, 6=ocean, 7=forest`,
but `mapNoiseType` only wires brown/white/pink/fan/rain/ocean. **`green` (3) and `forest` (7)
are scaffolded slots** — likely the cheapest additions on this whole list.

## 1. The headline fix — isochronic tones (P0)

**Binaural beats don't work in the app's own hard case.** A binaural beat needs each ear to
receive a different frequency in isolation — i.e. headphones. In the driving scenario (phone
on the nightstand, screen locked, playing all night through the built-in speaker), the two
tones sum in the air and the beat collapses. So `delta`/`theta` are doing essentially nothing
for the exact user the app is designed around.

**Fix: render the same target beat as an isochronic (single tone pulsed at the beat rate) or
monaural beat, which works on a speaker.** The engine already carries `carrier` + `beat`
(glided via `AudioMath.getBinauralPhaseDeltas`); isochronic reuses those values but amplitude-
modulates one mono tone instead of splitting L/R phase.

**Make it automatic.** `AudioSessionController` already observes route changes — use it: when
headphones/AirPods are connected, render true **binaural**; otherwise render **isochronic**.
Add a manual override ("Auto / Headphones / Speaker") for control. This is the most on-brand
audio change here — it makes the entrainment layer actually function on the nightstand.

## 2. New entrainment bands (cheap — just presets)

A binaural/isochronic preset is only a `carrier` + `beat` pair plus a label, so new bands are
trivial:

- **Beta (~14–18 Hz) → Focus.** The classic *concentration* band, and arguably a more natural
  Focus default than gamma. The current alpha→gamma jump skips it.
- **SMR (~12–15 Hz) → either mode.** "Calm-alert"; a nice bridge between relax and focus.
- (Optional) a **theta/Schumann ~7.83 Hz** variant for Sleep wind-down.

Adding one = append to `focusBinaurals`/`sleepBinaurals`, add a `beat` value, add a label in
the `binLabels` map (HomeView) — done.

## 3. Noise colours (cheap — filter math on white)

Each is a different filter over the same white source already in the render block:

- **Green (3) → Sleep.** Mid-band emphasis, "natural" feel. Slot already reserved.
- **Forest (7) → Sleep.** Reserved slot; a softer broadband "outdoors" bed.
- **Gray → Focus.** Psychoacoustically flat (equal perceived loudness across frequencies) —
  the best pure *masking* noise for concentration.
- **Blue / violet → Focus (optional).** High-frequency, bright and alert; can be harsh, so
  keep its default volume low.
- **Deep brown → Sleep (optional).** An extra-low-passed, warmer brown.

**One palette decision to make:** **pink noise has the strongest sleep evidence** (slow-wave
sleep), yet it currently lives only in Focus. The cleanest options are (a) add a warm pink to
Sleep too, or (b) relax the strict "modes share no sounds" rule for pink specifically. Worth a
deliberate call rather than leaving the best-evidenced sleep colour out of Sleep.

## 4. Nature / texture (mostly cheap; a few need samples)

Generative (filtered/modulated noise + envelopes, like rain/ocean already are):

- **Fireplace crackle → Sleep.** Filtered noise bursts over a low bed. Pairs with the embers
  screensaver scene — a nice cross-feature pairing.
- **Wind → Sleep** (low howl / through-trees), **stream/river → Sleep**, **distant thunder →
  Sleep** layered under rain.
- **Rain variants** — drizzle ↔ downpour, rain-on-roof — via a single "intensity" parameter
  on the existing rain generator rather than separate sounds.

Higher cost (need sampled assets, which cut against the pure-generative engine and add app
size): **crickets / night ambience**, **café / coffee-shop murmur** (a popular focus bed),
**cabin/train hum**. Flag these as "only if you're willing to ship samples."

## 5. Tonal beds — a new layer type (cheap, underused)

You currently offer *noise* + *beats* but no *musical* texture. A third layer many people find
more soothing than noise:

- **Drone / pad** — a few detuned sine/triangle oscillators with a slow LFO; warm for Sleep,
  cool for Focus.
- **Singing-bowl shimmer** — additive synthesis (inharmonic partials, long decay), struck
  occasionally. Generative, no samples.

This reuses the oscillator math the binaural path already has, so it's mostly new mixing, not
new infrastructure.

## 6. Honesty / wellbeing framing

Bake these into how the UI labels things, so the app stays trustworthy:

- The reliable mechanism is **masking** (covering disruptive sound), which is why noise
  colours help more people than beats do. Lead with sound character, not health claims.
- **Entrainment** (binaural/isochronic) evidence is genuinely mixed-to-weak — offer it as a
  pleasant option, not a promised effect.
- "Solfeggio / 432 Hz / healing frequencies" are popular but pseudoscientific — fine to offer
  as *tones people enjoy*, never as claims.
- Loudness is already bounded by the Night Limiter; keep new bright sounds (blue/violet,
  crackle transients) loudness-matched like the existing generators (the render block already
  loudness-matches brown/pink/etc.).

## 7. Implementation notes (where each piece goes)

- **Noise colour:** add a `case` in the render `switch type`, wire the string in
  `mapNoiseType`, add to the mode's palette array, add a label. (Green/forest: the slot ints
  already exist — only the mapping + generator body + palette entry are missing.)
- **New band:** add preset name to the palette array + a `beat` value + a `binLabels` entry.
- **Isochronic:** a render path that amplitude-modulates a single mono tone at `beat`; a
  route-aware selector (binaural when headphones present, else isochronic) driven by
  `AudioSessionController`; a manual override stored in `UserDefaults`.
- **Tonal bed:** likely a third source node (or fold into the binaural node), with its own
  on/off + volume like the existing layers; mode-scoped palette entry.
- **Hard constraint (unchanged):** no locks, allocation, or dispatch inside the render block —
  new generators must read params lock-free via the existing atomic double-buffer, exactly
  like the current ones.

## 8. Requirements & acceptance criteria

### P0

**R1. Isochronic / speaker-safe beats.**
- [ ] A non-binaural render path produces an audible beat at the selected band over a single
      (speaker) output.
- [ ] Output is route-aware: binaural with headphones, isochronic without; with a manual
      Auto/Headphones/Speaker override that persists.
- [ ] No clicks when switching modes/presets (reuse the existing per-sample gain smoothing).

### P1

**R2. Beta (and SMR) bands** added to the binaural/isochronic palettes with labels.
**R3. Green + forest noise** exposed (reserved slots wired) for Sleep; **gray noise** for Focus.
**R4. Fireplace crackle** for Sleep (pairs with the embers scene).
**R5. Pink-for-Sleep decision** made and implemented (warm pink in Sleep, or shared).

### P2

- Wind / stream / distant thunder; a rain **intensity** parameter.
- Tonal beds (drone/pad, singing bowl) as a third layer type.
- Blue/violet noise; deep-brown variant.
- Sampled beds (café murmur, crickets) — only if shipping audio assets is acceptable.

## 9. Phasing

- **Phase 1:** R1 (isochronic + route-aware) — the one that makes the existing beats actually
  work. Highest value.
- **Phase 2:** R2 + R3 + R5 — all cheap palette/preset additions (bands, reserved noise slots,
  pink decision).
- **Phase 3:** R4 and the P2 textures/tonal beds.

## 10. Open questions

- **(design)** Auto-switch binaural↔isochronic silently by route, or always isochronic for
  simplicity (since the nightstand is the main case)?
- **(design)** Keep the strict "modes share no sounds" rule, or carve out pink (and maybe rain)
  as shared since they suit both?
- **(scope)** Are you willing to ship sampled audio (café, crickets), or stay 100% generative?
  That answer decides half the texture list.
- **(product)** Should tonal beds be a third independent layer, or replace the binaural slot
  when someone prefers a pad to beats?

## 11. Review notes (verified against the code, 2026-06-22)

Spot-checked the spec's engine claims against `GenerativeAudioEngine` / `AudioMath` /
`AudioSessionController` / `Models`. Mostly accurate; three corrections:

- **`noiseType` Int — confirmed.** The render engine uses `var noiseType: Int` (`0=brown …
  7=forest`); the `AudioEngine` facade uses a String mapped by `mapNoiseType`. The §0 claim holds.
- **Green (3) / forest (7) are *reserved integers*, not scaffolded slots.** The render `switch`
  implements cases 1/2/4/5/6 only — there is **no `case 3` or `case 7`** (no generator body), and
  `mapNoiseType` has no `green`/`forest` entry (both fall through to brown). So they cost: a
  filter body in the render switch + a `mapNoiseType` case + a palette entry — **plus two edits
  the spec omits:** `NoiseType.migrate` currently folds `green→brown` / `forest→rain`, and
  `NoiseType.valid` excludes them, so a saved "green" silently rewrites to brown until those are
  updated. Still cheap, but it's "write a filter + 4 plumbing edits," not "flip a switch."
- **Latent palette inconsistency to fix alongside.** `focusNoises` offers `"white"`, but
  `NoiseType.migrate` maps `white→pink` and `NoiseType.valid` excludes white — so a persisted
  white can collapse to pink. The String / Int / `migrate` / `valid` layers have drifted;
  reconcile them when touching the palette.
- **P0 isochronic feasibility — confirmed.** `carrier`/`beat` exist and glide (`carrierCur`/
  `beatCur`); `AudioMath.getBinauralPhaseDeltas` + `getCarrierAndBeat(for:)` are present; and
  `AudioSessionController.onRouteChange` already forwards `routeChangeNotification`. An isochronic
  path (amplitude-modulate one mono tone at `beat`) + a route-aware selector is genuinely additive.

---

_Device gate (per CLAUDE.md): anything touching the render thread, the audio session/route
switching, or the limiter must be verified on a real iPhone — installed, screen locked, over a
full timer run, and specifically tested **on the built-in speaker** (the case the isochronic
fix is for) and with headphones connected/disconnected mid-playback._
