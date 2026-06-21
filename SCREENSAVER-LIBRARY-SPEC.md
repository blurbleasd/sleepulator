# Screensaver Library — Spec

_Date: 2026-06-21 · Build-first. Monetization is intentionally deferred (your call): this
spec designs the **entitlement seam** so a paywall can drop in later without rework, but the
goal here is to build a real, pluggable scene library and ship content. Grounded in the
existing SwiftUI scenes (`StarfieldView` + `MoonArc` + `ShootingStarView`, `FocusBackdrop`)._

Priority key: **P0** must-have · **P1** strong follow-up · **P2** later.

---

## 1. Opportunity

The ambient screensaver (just shipped) is the part of the app users actually *stare at* —
all night in Sleep, or in the corner of their eye while focusing. That makes it the ideal
home for a content library: swappable "scenes" are pure cosmetic upside, they don't touch
the free core experience (sounds, timers, podcasts all stay free), and they're emotionally
sticky. Building the library first — a clean way to add scenes and let users pick one — is
worthwhile on its own; a premium tier can wrap it whenever you decide.

## 2. The unit: a "scene"

A **scene** is a self-contained ambient backdrop with an identity, a mood, and a SwiftUI
view. Today's night sky and focus backdrop are scenes that happen to be hardcoded into
`HomeView`. The work is to make them first-class, listable, and selectable — then adding a
new scene is "conform to a protocol and register it," not "edit `HomeView`."

A scene declares:

- **id / title** — stable id for persistence, display name.
- **mood** — `sleep`, `focus`, or `both` (which mode(s) it's offered in).
- **timeReactive** — does it bind to the sleep timer / Pomodoro (like the setting moon or a
  fire burning down)? Reactive scenes get the timer handle; ambient-only ones don't.
- **a view** — built from a small `SceneContext` (palette, reduceMotion, timer state,
  `paused` for the screensaver settle).
- **thumbnail / preview** — for the picker.
- **tier** — `free` or `premium` (used only by the deferred entitlement gate).

## 3. Content catalog (the options)

Two axes matter for picking what to build: **mood** (sleep vs focus) and **how it's made**.
On the "how," strongly favour **generative** scenes (SwiftUI / Canvas / `TimelineView` /
Metal shaders) over authored video:

- Generative = original (no copyright risk — same principle as the algorithmic-art skill),
  tiny binary, infinitely varied, and the motion/brightness can be **tuned for OLED battery**
  and forced static under Reduce Motion. This is the whole reason the current scenes are cheap.
- Authored video/photo loops = highest fidelity but heavy (battery, app size, decoding),
  and they carry sourcing/licensing baggage. Use sparingly, if at all.

Tags below: **⚙︎** generative (cheap, recommended) · **✦** time-reactive (binds to the
timer) · **🔊** pairs naturally with an existing/expandable sound.

### Sleep scenes (dark, calm, OLED-friendly)

- **Night sky** ⚙︎✦ — _current default, free._ Stars + setting moon + rare meteor.
- **Rain on glass** ⚙︎🔊 — droplets running down a window, soft blurred lights behind. Pairs
  with the rain sound; the definitive sleep aesthetic.
- **Embers / fireplace** ⚙︎🔊 — slow flickering coals and rising sparks; very warm, very dark.
- **Aurora** ⚙︎ — slow ribbons of green/violet drifting over a dark horizon (Metal shader).
- **Moonlit ocean** ⚙︎✦ — gentle swells with a moon-glint path; the moon can set with the timer.
- **Drifting clouds** ⚙︎✦ — clouds crossing the moon; thickens (darkens) as the night ends.
- **Snowfall** ⚙︎🔊 — gentle snow over a faint treeline silhouette.
- **Fireflies** ⚙︎ — drifting points of warm light over a dark forest silhouette.
- **Single candle** ⚙︎ — one flame on near-black; the most OLED-pure, almost no light emission.
- **Deep space** ⚙︎ — slow-parallax starfield + a faint nebula; comets instead of meteors.

### Focus scenes (calm-alert; the ring stays the hero)

- **Energy ring backdrop** ⚙︎ — _current default, free._ The cool sweep behind the timer.
- **Flow field** ⚙︎ — particles drifting along a slow vector field (the algorithmic-art look).
- **Contour topography** ⚙︎ — subtle moving contour lines; structured, "deep work" feel.
- **Daylight / daydream** ⚙︎ — the bright "Daylight" palette from the Focus mockup as a scene.
- **Rain on glass (day)** ⚙︎🔊 — the rain scene in a cool daytime key, for focus.
- **Lo-fi window** ⚙︎ — a stylized desk-by-a-window with minimal looping motion (original art).

### Cross-cutting "content" levers (more catalog from fewer assets)

Each scene multiplies if you expose a few knobs, so a handful of engines yields a large
library: **palette/accent** (warm/cool/custom), **intensity** (calm ↔ lively), **density**
(few stars ↔ many), and **time-reactivity on/off**. A "night sky" with 3 palettes and 2
densities is already several catalog entries.

## 4. Architecture (the library)

**4.1 `AmbientScene` protocol + `SceneContext`.** Define a protocol every scene conforms to,
fed a lightweight context so scenes don't reach into `AudioEngine` directly:

```
struct SceneContext {
    let palette: Palette
    let reduceMotion: Bool
    let paused: Bool            // screensaver settle
    let sleepTimer: SleepTimerService   // for ✦ time-reactive scenes
    let pomodoro: PomodoroService
}

protocol AmbientScene: Identifiable {
    var id: String { get }
    var title: String { get }
    var mood: SceneMood { get }        // .sleep / .focus / .both
    var tier: SceneTier { get }        // .free / .premium
    @ViewBuilder func makeView(_ ctx: SceneContext) -> AnyView
    func thumbnail() -> AnyView        // small static preview
}
```

**4.2 Refactor the current scenes into the registry.** `NightSkyScene` wraps
`StarfieldView` + `MoonArc` + `ShootingStarView`; `EnergyScene` wraps `FocusBackdrop`. This
is a no-behaviour-change refactor — the home looks identical, but the two backdrops now live
behind the protocol. A `SceneRegistry.all` lists every scene; `registry.scenes(for: mood)`
filters for the picker.

**4.3 Home renders the *selected* scene.** Replace the hardcoded `if audio.focusMode { … }`
backdrop branch in `HomeView` with `selectedScene(for: mode).makeView(ctx)`. Selection is
persisted per mode (`UserDefaults`: `sceneSleep`, `sceneFocus`), defaulting to the two free
scenes — so nothing changes until the user picks something.

**4.4 Rendering tech per scene (pick the cheapest that sells the look).**
- **SwiftUI shapes / Canvas** — what the current scenes use; great for stars, snow, embers.
- **`TimelineView` + `Canvas`** — for continuously animated generative scenes with one cheap
  redraw loop (better than many `repeatForever` views; also easy to *stop* for the settle).
- **Metal shaders** (`Shader` / `.colorEffect` / `.layerEffect`, iOS 17+) — for fluid looks
  (aurora, fire, flow field) at near-zero CPU. Highest visual-per-watt.
- **SpriteKit** — only if a scene needs thousands of particles.
- **AVPlayer video loop** — reserve for authored scenes; heaviest, last resort.

**4.5 Battery + accessibility are scene contract, not afterthoughts.** Every scene must
honour `paused` (settle to static when the screensaver engages) and `reduceMotion` (static),
exactly as `StarfieldView` now does. This is a conformance requirement, enforced in review.

## 5. The library UI

A **Scenes** screen (a new tab, or a button on the home/Build-mix sheet): a 2-column grid of
scene cards showing a live or static thumbnail, title, and a lock badge on premium ones.
Tapping a free scene selects it (with a quick full-screen preview + "Use this"); tapping a
locked one opens the preview with an unlock CTA (the paywall hook, deferred). Filter by the
current mood by default, with a toggle to browse the other mood. Long-term, a "Surprise me"
shuffle and a per-scene settings sheet (palette/intensity from §3) live here too.

## 6. Freemium seam (deferred — designed in, not built)

Monetization is your later call; the only thing this spec commits to now is the **seam** so
it's a small change when you decide:

- A single `entitlements.isPro` boolean (stubbed `true` in dev) is the *only* gate. Scenes
  carry a `tier`; the picker shows locks and the home refuses to select a premium scene when
  `!isPro`. Nothing else in the app reads entitlements.
- Keep the current two scenes (and ideally 1–2 more) **free** so the library feels generous
  before any paywall.
- When you choose a model (one-time unlock / subscription / per-scene), it's a StoreKit 2
  layer that flips `isPro` (or a per-scene set) — no scene or home changes required.

Until then: build every scene as `.free`, ship the picker, and validate that people actually
switch scenes. That signal tells you whether a paywall is even worth it.

## 7. Requirements & acceptance criteria

### P0 — the library exists

**R1. `AmbientScene` protocol + registry.**
- [ ] Protocol + `SceneContext` defined; `SceneRegistry.all` enumerates scenes.
- [ ] `NightSkyScene` and `EnergyScene` wrap the existing backdrops with zero visual change.

**R2. Home renders the selected scene.**
- [ ] `HomeView` background is driven by the selected scene per mode, not a hardcoded branch.
- [ ] Selection persists across launches; defaults to the free scenes.
- [ ] Every scene honours `paused` (settle) and `reduceMotion` (static).

**R3. Scene picker.**
- [ ] A grid lists scenes for the current mood with thumbnails and titles.
- [ ] Selecting a scene updates the home immediately and persists.
- [ ] Premium scenes show a lock; selecting one is blocked when `!isPro` (gate stubbed open).

### P1 — make it a real library

**R4. Ship 3–4 new generative scenes** across both moods (e.g. rain-on-glass, embers, flow
field), each conforming to the battery/accessibility contract.
**R5. Live previews** in the picker (animated thumbnails), and a full-screen "preview before
apply."
**R6. Per-scene knobs** (palette/intensity/density) so a few engines yield many catalog entries.

### P2 — later

- StoreKit 2 entitlement layer + paywall (once monetization is decided).
- Metal-shader scenes (aurora, fire) for high visual-per-watt.
- Seasonal/limited scenes; a "Surprise me" shuffle; iCloud-synced selection.
- An authored/video scene path if a specific look can't be done generatively.

## 8. Build phasing

- **Phase 1 (the seam):** R1 + R2 — extract the protocol, move the two existing backdrops
  behind it, drive the home from selection. Invisible to users, unblocks everything.
- **Phase 2 (the library):** R3 + R4 — the picker and the first new scenes. This is the
  shippable "we have a screensaver library" moment.
- **Phase 3 (depth):** R5 + R6, then the entitlement layer when you're ready to charge.

## 9. Open questions

- **(product)** Where does the picker live — a new tab, or tucked in the Build-mix sheet?
  A tab signals "this is a feature"; a sheet keeps the chrome minimal.
- **(eng)** Adopt `TimelineView`+`Canvas` (and later Metal shaders) as the standard engine
  for new scenes, or keep hand-rolled `repeatForever` views like the current sky? The former
  is better for battery and for the settle, but is a small rework of the existing two.
- **(product)** Should scene selection be independent per mode (likely yes), and should a
  scene that's `.both` remember separate settings per mode?
- **(design)** Do reactive scenes (✦) all map the timer the same way (something "sets" /
  "burns down"), so the time-left read is consistent across the library?

## 10. Reusable assets & licensing

There is **no drop-in open-source screensaver pack for iOS** — desktop screensavers
(XScreenSaver, macOS `.saver` bundles) are the wrong platform (C/X11/AppKit) and carry mixed
licenses. The reusable path is **MIT-licensed SwiftUI/Metal shader libraries used as
engines**, with original scenes composed on top (own palette, motion, time-reactivity) — fast
and copyright-clean, consistent with §3's generative-first stance.

**Candidate engines** (reported MIT — verify each repo's `LICENSE` before shipping, and keep
the MIT notices in an in-app acknowledgements screen):

- **Inferno** — twostraws / Paul Hudson. Water, fire, gradient/light fragment shaders →
  bases for embers, rain-on-glass, aurora. The most reputable. <https://github.com/twostraws/Inferno>
- **SwiftUIShaders** — krispuckett. 41 drop-in effects incl. aurora and field looks → aurora,
  focus flow-field. <https://github.com/krispuckett/SwiftUIShaders>
- **SwiftBits** — liseami. Parameterized aurora shader. <https://github.com/liseami/SwiftBits>
- **SwiftMotion** — ajagatobby. ~58 animations / 31 shaders. <https://github.com/ajagatobby/SwiftMotion>
- **SwiftUI-Shader-Effects** — GrishTad. <https://github.com/GrishTad/SwiftUI-Shader-Effects>

**License rules for an App Store / freemium app:**

- **Safe to ship:** MIT / Apache-2.0 / BSD / Unlicense / CC0. (MIT/BSD/Apache require
  preserving the copyright + license notice → add an acknowledgements screen.)
- **Avoid:** GPL / LGPL (App Store distribution conflict); anything **NC (non-commercial)**
  given the planned paid tier; CC-BY needs visible attribution.
- **Shadertoy trap:** the site's **default license is CC BY-NC-SA 3.0 — non-commercial +
  ShareAlike**. Do not copy or port a Shadertoy shader unless that specific shader explicitly
  states a commercial-friendly license; even porting the algorithm can be a derivative under
  ShareAlike. Treat Shadertoy as inspiration only. <https://www.shadertoy.com/terms>

---

_Device gate (per CLAUDE.md): every new scene's motion, battery cost, and Reduce-Motion /
settle behaviour are device-specific — verify each on a real iPhone, installed, screen on,
over a full timer run, before calling it done._
