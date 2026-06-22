# Rain on Glass — Depth Edition — Spec

**Status: APPROVED** (2026-06-21, via /office-hours · survived 1 round of adversarial review, 7/10)

_Date: 2026-06-21 · From an /office-hours session. The next leap for the screensaver
library: make the backdrop a thing you can **fall into**, starting by evolving the
existing `RainGlassView` from a stylized 2D illusion into a depth-real scene. Personal
project — **no monetization, no tiers, the only test is "do I want to look at it."**
Builds directly on `SCREENSAVER-LIBRARY-SPEC.md`._

---

## 1. The idea

The screensaver library decided the backdrop is something you live with. This spec
decides what makes one worth living with: **depth**. Not "tie it to live weather" (a
clever trick that demos well), but the harder thing — a scene that reads as a real
window with real distance, so the eye relaxes into it the way it does looking out a real
pane at night.

Rain on glass is the flagship because (a) it's already started — `RainGlassView` exists
and ships — so this is an *upgrade*, not a cold start, and (b) the depth recipe it forces
us to invent — **near layer sharp, far layer soft, the near layer bending light from the
far layer** — transfers to every other scene in the catalog (ocean: near swell / hazy
horizon; deep space: near stars sharp / far nebula soft; a window-to-a-place).

## 2. What makes this cool (the "whoa")

The current `RainGlassView` draws each drop as a white ellipse with a small catch-light
(`RainGlassView.swift:139-143`). Real droplets on a window are **transparent lenses**:
each one shows an inverted, magnified pinch of the bright lights behind it. That one
property is the single most convincing depth/realism cue in rain-on-glass photography,
and **no sleep app does it.** It's the "wait, how is that done" moment.

Three depth cues, in priority order:

1. **Droplet refraction (the lens).** Each drop refracts + magnifies the blurred far
   layer behind it. This is the headline. It is cheap in a fragment shader and impossible
   with stacked opaque shapes.
2. **Differential focus (DoF).** Drops and the glass surface are sharp; everything beyond
   the pane is bokeh-soft. The eye reads the focus gradient as distance. (Today the bokeh
   is blurred but the relationship isn't depth-coherent — the drops don't sit "in front.")
3. **Parallax (the garnish).** Tilt the phone and the far layer slides behind the glass.
   A window, not a picture. **Bonus, not load-bearing** — see the bedside caveat in §8.

**EUREKA from the session:** everyone reaches for parallax *layers* to fake depth. For
rain-on-glass the eye reads depth mostly from focus falloff + refraction, not lateral
motion. Build the lens, not just the layers.

## 3. Constraints (the contract every scene signs)

- **Personal-project freedom.** No paywall, no tiers, no launch gate. Ship it when it's
  beautiful, not when it's "marketable."
- **All-night battery / OLED.** Near-black background (OLED pixels off → real battery +
  zero room glow). Must **settle to a single static frame** when `paused` is true (the
  deep-night-dim veil), exactly as `RainGlassView` does today
  (`RainGlassView.swift:14, 108-117`). No redraw loop on an occluded all-night screen.
- **Decoupled.** Renders only from `SceneContext` (`AmbientScene.swift:11-18`); never
  reaches into `AudioEngine`. Keep `sleepTimer` available for the §8 reactive seam.
- **Ambient-motion rule, not system Reduce Motion.** Per `SCREENSAVER-LIBRARY-SPEC.md §5`:
  the rain runs even with system Reduce Motion on (it's not vestibular motion). Follow the
  existing convention; the app-level "Ambient motion" toggle is still unbuilt (§8).
- **iOS 17+.** `IPHONEOS_DEPLOYMENT_TARGET` is **17.0** in every build config (verified in
  `project.pbxproj`; the 2026-06 audit's "17.6" was stale). SwiftUI `Shader`/`.layerEffect`
  needs iOS 17 — satisfied, no OS-version fallback required.
- **No re-render storm.** Drive the shader from one `TimelineView`; do not publish a
  per-frame `@Published` that invalidates `HomeView` (the `rmsPower` mistake, audit P1 #5).
- **Preserve the passive-backdrop modifiers.** A from-scratch rewrite is exactly where
  these get dropped: the new view must keep `.allowsHitTesting(false)`,
  `.accessibilityHidden(true)`, and `.ignoresSafeArea()` (`RainGlassView.swift:119-121`).
  It's decoration, never an interaction target.
- **The device gate.** Refraction, DoF, parallax, settle, and battery are all
  device-specific. Nothing here is "done" until verified on a real iPhone, installed,
  propped at a bedside, over a full timer run, per `CLAUDE.md`'s gate. (Note: `TESTING.md`
  only covers the archived web PWA — there is no written native device-test pass yet, so
  this one is ad-hoc, by eye.)

## 4. Premises (agreed in session)

1. **Depth ≠ parallax layers.** Strongest cue is refraction + differential focus; parallax
   is garnish. _(Agreed — drove the refraction-first design.)_
2. **Rain-on-glass first because the recipe generalizes** to ocean / space / window-to-a-
   place. We're inventing the depth toolkit on the easiest case. _(Agreed.)_
3. **Pure cosmetic, but keep the timer seam.** Don't build reactive-depth now, but leave
   `sleepTimer` in the context so "rain thins / glass fogs / bokeh defocuses as the timer
   winds down" is a one-step sequel. _(Agreed.)_

## 5. Approaches considered

### Approach A — Layered SwiftUI/Canvas + DoF + gyro
The current `RainGlassView` *is* this approach. Push it further: heavier bokeh blur, a
real fog/condensation overlay, CoreMotion gyro offsetting the bokeh layer.
- **Effort: S–M · Risk: Low · Reuses:** the shipped view wholesale.
- Pros: fastest; on-brand; trivially settle-able. Cons: **cannot do droplet refraction**
  (the headline cue) — drops stay opaque blobs; "depth" stays a layered-2D illusion.

### Approach B — Metal shader glass  ← **chosen**
One fragment shader (SwiftUI `.layerEffect`, iOS 17+) renders the pane: procedural drops
that **refract + magnify** a soft far layer, real streak physics, condensation, true DoF.
Gyro feeds in as a uniform.
- **Effort: L · Risk: Med (shader learning curve) · Reuses:** could later seed aurora /
  embers / ocean (all Metal-friendly) — but build the one rain shader first; don't pre-build
  a generic depth toolkit (YAGNI) until a second scene actually asks for it.
- Pros: the actual "whoa"; **near-zero CPU** (the cost moves to GPU — see §7 for the real
  power story). Cons: highest skill jump; shader debugging is its own world; a full-screen
  per-frame `.layerEffect` is **real GPU/power cost, not free** — must be measured, not
  assumed (`SCREENSAVER-LIBRARY-SPEC.md §4.4`'s "visual-per-watt" claim holds only if the
  blur is precomputed, not run per-frame); risk of "tech demo" energy if not kept calm/dim.

### Approach C — Real 3D window (SceneKit/RealityKit)
A true 3D stage: glass plane, geometry at real depths, a camera doing parallax, optionally
TrueDepth face-tracked.
- **Effort: L–XL · Risk: High.**
- Pros: depth is real; head-tracked parallax would be jaw-dropping. Cons: heaviest;
  SceneKit semi-legacy / RealityKit heavy for a 2D-ish look; all-night battery risk;
  overkill for rain. **Someday-experiment, not this build.**

## 6. Recommended approach — B, scaffolded from A

Go for the shader, but **don't cold-start it.** The shipped `RainGlassView` already nails
the layer composition and the `paused` settle. Sequence:

1. **Keep A as the scaffold.** The existing gradient + bokeh + specks + settle stay as the
   fallback render and the composition reference.
2. **Replace the drop layer with the shader.** The 16 hand-drawn drops
   (`RainGlassView.swift:43-55, 125-144`) become shader-generated drops that refract the
   bokeh layer instead of painting over it.
3. **Composite the background into one layer, then attach the shader to it.** `.layerEffect`
   can only sample **the single layer it's attached to**, not an arbitrary second texture —
   so there is no free-floating "far layer" to refract. Render gradient + (brightened)
   bokeh + haze into one SwiftUI view, attach the `.layerEffect` to **that**, and the shader
   distorts that composited content. Drops are generated procedurally inside the shader.
   (See §6.0 — the first draft got this backwards.)

This ships something visibly better within a session or two (DoF + parallax on the
existing drops) and lands the showpiece (refraction) without being blocked on shader
mastery up front.

### 6.0 How `.layerEffect` actually works (the constraint that shapes everything)

A SwiftUI `.layerEffect` shader is handed a `SwiftUI::Layer` — **the rendered content of the
view the effect is applied to** — which it can `sample()` at arbitrary offsets. That
offset-sampling is exactly what refraction needs, and it's idiomatic. The constraint: the
shader **cannot** be handed a separate arbitrary texture as the "far layer"
(`Shader.Argument.image` exists but is constrained/flaky inside layer effects). So the depth
model is not "layer 4 samples an independent layer 1." It is:

- Composite the far world (gradient + bokeh + haze) into the one view the effect is on.
- The shader samples *that* layer: identity outside drops, **offset+scaled+flipped** inside
  each drop (the lens), reading the already-soft far content for DoF.
- **Procedural-in-shader bokeh is the primary plan** (self-contained, animatable, the clean
  fit for the single-layer model). Baking a SwiftUI-rendered bokeh via `ImageRenderer` into
  the composited layer is the fallback if procedural can't match the art.

### 6.1 The depth model (layer stack, far → near)

| # | Layer | Role | Depth cue it carries |
|---|-------|------|----------------------|
| 0 | Sky / glass gradient | Near-black base, OLED-dark | baseline |
| 1 | Far bokeh lights | Defocused warm/cool blobs, **heavy** blur | differential focus = "far" |
| 2 | Atmospheric haze | Faint volumetric fog between 1 and 3 | air has distance |
| 3 | Condensation / mist | Static fine specks on the pane | the glass has a surface |
| 4 | Droplets (shader) | Sharp, **refract the composited far content** through each drop | the lens — the "whoa" |

Gyro offsets the far content relative to the drops. **Settle = stop the loop, not a uniform:**
on `paused`, drop out of the `TimelineView` to a single static render pass (drops frozen),
exactly like today's `if active { TimelineView … }` guard (`RainGlassView.swift:108-117`)
and `StarfieldView`'s instant freeze. Do **not** keep the loop alive with a `settle=1`
uniform — that's a redraw loop on an occluded all-night screen, which §3 forbids.

**The far layer must be bright enough to refract.** Today's bokeh is 5 dim blobs at opacity
~0.20 over near-black (`RainGlassView.swift:66-74, 92`) — most drops would sit over black and
refract *nothing*. The depth version needs more, brighter lights (a soft band of distant
windows, or a denser bokeh field) so the lens has something to bend in the majority of drops.
**This art change is a prerequisite for the "whoa," not a polish step.**

### 6.2 Shader responsibilities (Approach B core)

- Generate drops from a hash grid (stable seeds, like today's deterministic fields) +
  time-driven fall/streak.
- For each drop: sample the layer at a UV **scaled ~1.3–1.8× and flipped** about the drop
  centre → a magnified, inverted pinch of the world behind it (the lens). Start at ~1.5×,
  tune by eye (step 4). A bright catch-light on the upper edge sells the bead; streaks
  refract weakly along their length.
- DoF: the far content is already soft, so **bake the background blur once** (in the
  composited layer), not a multi-tap Gaussian per pixel per frame — that per-frame blur is
  the classic battery trap. The shader keeps drop interiors crisp by sampling with low/no
  blur there.
- Subtle condensation: low-amplitude noise reducing clarity between drops.
- Uniforms: `time` (Float), `gyro` (a `float2` derived from `CMDeviceMotion.attitude`
  roll/pitch — **CoreMotion is a new dependency, not yet imported anywhere in the repo**),
  palette. No `settle` uniform — settle stops the loop (see §6.1).

## 7. Success criteria ("done")

On a real iPhone, installed, propped at a bedside, screen on, over a full timer run:
1. Droplets **visibly refract** the lights behind them (the lens reads as a lens, not a dot).
2. Clear front-to-back depth from focus falloff (sharp glass, soft beyond).
3. With the phone in hand, tilt produces believable window parallax; **flat on a nightstand
   it still reads as deep** (focus + refraction carry it without motion — see §8).
4. Settles to a static, dark frame when `paused` — the loop is *stopped*, not frozen by a uniform.
5. **Running-state power is acceptable, measured not assumed.** The honest risk: a full-screen
   per-frame `.layerEffect` can cost more than today's ~16-ellipse Canvas. Check thermals +
   battery drain over a 30–60 min run on device; if it's hot or heavy, cut drop count / fps /
   DoF taps until it isn't. (Settled-state battery is trivially equal — it proves nothing.)
6. The honest one: **you prop your phone up and want to keep looking at it.**

## 8. Open questions

- **Bedside parallax is moot when the phone is flat/charging.** At night the phone is often
  stationary on a nightstand → gyro gives nothing. Depth **must** read from focus +
  refraction alone; treat parallax as a held-only bonus, never the load-bearing cue. (This
  is why §2 ranks refraction first.)
- **Background source:** procedural bokeh in-shader (**primary** — self-contained,
  animatable, the clean fit for `.layerEffect`'s single-layer model per §6.0) vs. baking the
  SwiftUI bokeh via `ImageRenderer` into the composited layer (fallback, if procedural can't
  match the art). Either way the far layer must be *brightened* first (§6.1).
- **Build the app-level "Ambient motion" toggle first?** `SCREENSAVER-LIBRARY-SPEC.md §5/§8`
  flags it as the right home for the motion-vs-Reduce-Motion decision. Cheap; worth doing
  before the scene count grows — but it is **a separate feature, explicitly out of this
  build's definition of done.** Follow the current convention (motion runs) for now.
- **Reactive-depth (the §4 premise-3 sequel):** as `sleepTimer.nightProgress` rises, thin
  the rain, fog the glass, defocus the bokeh further. Free narrative; not this build.
- **One shader for the render loop, or shader + `TimelineView`+`Canvas` hybrid?** Leaning
  single `TimelineView`-driven `.layerEffect` pass at ~30 fps, frozen on settle.

## 9. Distribution

None needed — this is a scene inside the existing app. Ships via the same App Store /
TestFlight pipeline as everything else. No new infra.

## 10. Next steps (build order)

1. **DoF + gyro on the existing drops (Approach-A slice).** Heavier bokeh blur, CoreMotion
   parallax on the bokeh layer, fog overlay. No shader yet — pure composition + feel. Ship-
   visible improvement, low risk, validates the layer stack on device.
2. **Stand up the shader seam.** A `.layerEffect`/`Shader` that samples the rendered
   background and passes it through unchanged (identity). Prove the plumbing + settle +
   uniforms before any drop math.
3. **The droplet-as-lens shader (the heart).** Hash-grid drops + UV refraction of layer 1.
   This is the session where it becomes a different category of thing.
4. **Tune on device.** Refraction strength, DoF radius, drop density/size, catch-light —
   against a real rain-on-glass reference (see the assignment). Iterate by eye, at the
   bedside, in the dark.
5. **Parallax polish (held-only) + battery/settle verification** over a full timer run.
6. **(Later) reactive-depth seam** wired to `sleepTimer.nightProgress`.

Keep `RainGlassView`'s current implementation as the fallback until the shader is device-
verified to match-or-beat it on power. Simplest coexistence for a personal project: build the
shader as a new `RainGlassDepthView` + `RainOnGlassDepthScene` registered alongside the old
one (or behind a `#if DEBUG` flag), so you can A/B them on device and only retire the old
struct once the new one clearly wins. No runtime capability check needed (iOS 17 floor).

## 11. The assignment (do this before writing any code)

**Go watch real rain on a real window at night, and capture a 10-second reference.** Shoot
it on your phone (or find a clip), then prop it up and *study what your eye actually does*.
Name the three things that make it read as depth:
1. Which drops are sharp, and what's soft behind them?
2. How do the far lights **bend and flip** inside each drop?
3. How "far" do the background lights feel — are they shapes, or just glows?

That clip is your art-direction north star. You'll tune the shader against it in step 4.
This is the craft version of "watch a user, don't demo to them": watch reality, don't
trust your memory of what rain looks like.

## 12. What I noticed about how you think

- You picked the **craft** answer over the **clever** one. When I offered "bind it to live
  weather" — the gimmick that demos beautifully — you went for "depth you can fall into,"
  the thing that only pays off if you actually nail the rendering. People who optimize for
  the demo pick the weather trick. You picked the hard, quiet thing.
- You didn't chase a sexier new scene. You chose rain-on-glass **because you'd already
  started it.** Build-on-what-exists over chase-the-shiny — and it happened to also be the
  right strategic pick (the recipe generalizes). Good instincts usually look like that.
- Your repo has a blind code audit and a UI/UX review you commissioned **on your own work,
  the day before this session.** You review yourself harder than most people review others.
  You've earned the shader — you already paid the iteration tax once (the starfield
  "rendering-bug saga," your words).

## 13. Review log

Survived one round of adversarial review (independent reviewer, fresh context, 7/10 → fixed).
Issues caught and addressed in this revision:
- **Feasibility (the big one):** `.layerEffect` samples only the layer it's attached to, not
  an arbitrary "far layer." Restructured §6.0/§6.1/§6.2 to composite the background into one
  layer; made **procedural-in-shader bokeh the primary plan** (was the fallback).
- **The far layer is too dark to refract** (5 dim blobs over black). Added "brighten the
  background" as a prerequisite for the lens to read (§6.1).
- **Battery criterion measured the wrong phase** (settled state is trivially equal). Added a
  running-state thermal/power criterion (§7.5); softened "near-zero CPU / visual-per-watt"
  to flag real per-frame GPU cost (§5).
- **Settle mechanism** clarified: stop the `TimelineView`, don't keep it alive with a uniform (§6.1).
- **Stale facts:** deployment target is 17.0 not 17.6 (verified); `TESTING.md` is web-only,
  not the native device gate; preserved `.allowsHitTesting(false)`/`.accessibilityHidden(true)` (§3).
- **CoreMotion is a new dependency** (not imported anywhere); gyro is `CMDeviceMotion`
  attitude, not `CGVector` (§6.2).
- Carried-over flag for `SCREENSAVER-LIBRARY-SPEC.md`: its §5 "~60s settle" claim is wrong —
  both current scenes freeze instantly / over a 1.2s fade, not a 60s ramp. Worth correcting there.
