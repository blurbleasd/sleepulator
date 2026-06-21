# Screensaver Library — Spec

_Date: 2026-06-21 (rewritten) · A pluggable library of ambient "scenes" you can swap behind
the home screen — built for the craft of it. Sleepulator is a personal project, so there is
**no monetization, no tiers, no paywall, no launch gate** here: the only question for any
scene is "is it beautiful / does it feel right." Grounded in the existing SwiftUI scenes
(`StarfieldView` + `MoonArc` + `ShootingStarView`, `FocusBackdrop`)._

---

## 1. The idea

The ambient backdrop is the part of the app you actually live with — the sky you drift off
under in Sleep, the sweep in the corner of your eye while focusing. Making it **swappable**
turns "the one hardcoded background" into a small collection of moods you can pick between.
It's pure cosmetic upside: it never touches sounds, timers, or podcasts, and each new scene
is a self-contained piece of generative art. The work is to make scenes first-class —
listable, selectable, easy to add — so building the next one is "conform to a protocol and
register it," not "edit `HomeView`."

## 2. The unit: a "scene"

A **scene** is a self-contained ambient backdrop with an identity, a mood, and a SwiftUI
view. Today's night sky and focus sweep are scenes that happened to be hardcoded into
`HomeView`. A scene declares:

- **id / title** — stable id for persistence, display name.
- **mood** — `sleep` or `focus` (which mode it's offered in; could grow a `both`).
- **timeReactive** — does it bind to the sleep timer / Pomodoro (the setting moon, or a fire
  burning down)? Reactive scenes read the timer from the context; ambient-only ones ignore it.
- **a view** — built from a small `SceneContext` (palette, reduceMotion, paused-for-settle,
  timer handles). Scenes never reach into `AudioEngine` directly.

(No `tier` field, no entitlement. Every scene is just available.)

## 3. The catalog — scenes worth making

Two axes: **mood** (sleep vs focus) and **how it's made**. On the "how," strongly favour
**generative** scenes (SwiftUI / Canvas / `TimelineView` / Metal shaders) over authored video:
generative is original (no licensing baggage), tiny, infinitely varied, and the
motion/brightness can be **tuned for OLED battery** and forced static — the whole reason the
current scenes are cheap. Authored video/photo loops are heavy (battery, app size, decoding)
and carry sourcing baggage; reserve them for a look that genuinely can't be done generatively.

Tags: **⚙︎** generative (cheap, recommended) · **✦** time-reactive · **🔊** pairs with a sound.

**Sleep (dark, calm, OLED-friendly):**
- **Night sky** ⚙︎✦ — _current default._ Stars + setting moon + rare meteor.
- **Rain on glass** ⚙︎🔊 — droplets running down a window, soft blurred lights behind. Pairs
  with the rain sound; the definitive sleep aesthetic. _(Highest-value next scene.)_
- **Embers / fireplace** ⚙︎🔊 — slow flickering coals and rising sparks; warm and very dark.
- **Aurora** ⚙︎ — slow ribbons of green/violet over a dark horizon (Metal shader). The "wow."
- **Moonlit ocean** ⚙︎✦ — gentle swells with a moon-glint path; the moon can set with the timer.
- **Drifting clouds** ⚙︎✦ — clouds crossing the moon; thickens (darkens) as the night ends.
- **Snowfall** ⚙︎🔊 — gentle snow over a faint treeline silhouette.
- **Fireflies** ⚙︎ — drifting warm points over a dark forest silhouette.
- **Single candle** ⚙︎ — one flame on near-black; the most OLED-pure, almost no light emission.
- **Deep space** ⚙︎ — slow-parallax starfield + a faint nebula; comets instead of meteors.

**Focus (calm-alert; the ring stays the hero):**
- **Energy sweep** ⚙︎ — _current default._ The cool sweep behind the timer.
- **Flow field** ⚙︎ — particles drifting along a slow vector field.
- **Contour topography** ⚙︎ — subtle moving contour lines; a "deep work" feel.
- **Rain on glass (day)** ⚙︎🔊 — the rain scene in a cool daytime key.

**Quality over quantity.** A "cheap generative scene" is deceptively expensive to make
genuinely beautiful (the current starfield took several iterations + a rendering-bug saga).
Four or five scenes you love beat sixteen mediocre ones. Build the ones you actually want.

**Cross-cutting knobs (more from fewer engines):** palette/accent, intensity (calm ↔ lively),
density (few stars ↔ many), time-reactivity on/off. Nice for stretching an engine, but a
night sky in three palettes is still basically one scene — don't pad the list with them.

## 4. Architecture (the library)

**4.1 `AmbientScene` protocol + `SceneContext`** — every scene conforms to a protocol, fed a
lightweight context so it stays decoupled from `AudioEngine`:

```
struct SceneContext {
    let palette: Palette
    let reduceMotion: Bool
    let paused: Bool                 // screensaver settle
    let sleepTimer: SleepTimerService  // for ✦ time-reactive sleep scenes
    // add `pomodoro` here when a time-reactive focus scene needs it
}

protocol AmbientScene {
    var id: String { get }
    var title: String { get }
    var mood: SceneMood { get }      // .sleep / .focus
    func makeBackdrop(_ ctx: SceneContext) -> AnyView
}
```

**4.2 The two current scenes live behind the protocol.** `NightSkyScene` wraps
`StarfieldView` + `MoonArc` + `ShootingStarView` + the darkening overlay; `EnergyScene` wraps
`FocusBackdrop`. A no-behaviour-change refactor — the home looks identical. `SceneRegistry.all`
lists them; `scenes(for: mood)` filters.

**4.3 Home renders the selected scene.** `HomeView`'s backdrop is
`SceneRegistry.selected(for: mood).makeBackdrop(ctx)` instead of a hardcoded `if focusMode`
branch. Selection persists per mood (`UserDefaults`: `sceneSleep` / `sceneFocus`) and defaults
to the mood's first scene — so nothing changes until you pick something.

**4.4 Rendering tech per scene (cheapest that sells the look):**
- **SwiftUI shapes / Canvas** — what the current scenes use; great for stars, snow, embers.
- **`TimelineView` + `Canvas`** — one cheap redraw loop for continuously animated scenes;
  better than many `repeatForever` views, and easy to *stop* for the settle.
- **Metal shaders** (`.colorEffect` / `.layerEffect`, iOS 17+) — for fluid looks (aurora,
  fire, flow field) at near-zero CPU. Highest visual-per-watt.
- **SpriteKit** — only if a scene needs thousands of particles.
- **AVPlayer video loop** — last resort, for an authored look that can't be generated.

## 5. Battery + accessibility are part of the contract

Every scene must honour:
- **`paused`** — settle to static when the screensaver engages (an all-night screen shouldn't
  animate), exactly as `StarfieldView` does (`paused` + a ~60s settle).
- **The ambient-motion preference** — NOT raw system Reduce Motion. We deliberately decided
  Sleep's decorative motion (twinkle, moon glide, meteor) should run even with system Reduce
  Motion on, because the opacity twinkle isn't vestibular motion and the sky reads dead static
  otherwise. The proper home for this is an **app-level "Ambient motion" toggle** (not yet
  built) that scenes read from the context; until it exists, the current scenes simply run
  their motion. New scenes should follow the same rule, not re-gate on system Reduce Motion.

## 6. A picker (only once there's something to pick)

With two scenes a picker is overkill — a simple toggle, or just editing the default, is enough.
Once there are ~4-5, a **Scenes** screen earns its place: a grid of cards with a static or live
thumbnail and title, filtered to the current mood, tap to select (with a quick full-screen
preview). Lives either as a button on the Build-mix sheet or its own entry — decide when it's
real. A "surprise me" shuffle and per-scene knobs (palette/intensity) can live here too.

## 7. Build phasing

- **Phase 1 — the seam (DONE).** `AmbientScene` + `SceneContext` + `SceneRegistry`; the two
  existing backdrops moved behind the protocol; the home renders the selected scene. Invisible
  to the eye, unblocks everything.
- **Phase 2 — build scenes you want.** Add them one at a time, conforming + registering. No
  picker needed until a handful exist. Rain-on-glass and embers are the obvious first sleep
  additions; aurora is the showpiece (Metal shader).
- **Phase 3 — the picker + knobs**, if/when the collection is big enough to want browsing.

There's no queue and no deadline: build the next scene whenever the itch hits.

## 8. Open questions

- **`TimelineView` + `Canvas` as the standard engine** for new scenes (better for battery + the
  settle) vs. the hand-rolled `repeatForever` views the current sky uses? Leaning Timeline/Canvas
  for anything continuously animated; revisit the current two if/when convenient.
- **The app-level "Ambient motion" toggle** (§5) — worth adding before the second scene, so the
  contract is real and consistent rather than ad-hoc per scene.
- **Per-mode vs shared selection**, and whether a `both`-mood scene remembers separate settings
  per mode. Likely independent per mood.

## 9. Status (2026-06-21)

- **Phase 1 (seam) shipped** — `AmbientScene` / `SceneContext` / `SceneRegistry` added,
  `NightSkyScene` + `EnergyScene` wrap the current backdrops, `HomeView` renders the selected
  scene per mood. No-behaviour-change refactor (device-confirm the backdrops look identical).

---

_Device gate (per CLAUDE.md): every scene's motion, battery cost, and settle behaviour are
device-specific — verify each on a real iPhone, installed, screen on, over a full timer run,
before calling it done. The Phase 1 seam is a refactor: confirm the sky + focus sweep render
exactly as before._
