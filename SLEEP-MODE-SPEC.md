# Sleep Mode — Spec

_Date: 2026-06-21 · Grounded in the SwiftUI source (`HomeView.swift`,
`SleepTimerService.swift`, `ContentView.swift`). Companion to `FOCUS-MODE-SPEC.md` —
the two modes now share a design language: each has a **time-aware celestial hero**
(Focus = a tightening ring, Sleep = a setting moon), expressed in opposite moods._

Priority key: **P0** must-have · **P1** strong follow-up · **P2** future.

---

## 1. Problem statement

Sleep mode is prettier than Focus was, but it shares the same root weakness — the screen
is decorative, not functional — plus two specific soft spots. The **moon is a sticker**: a
flat `moon.fill` SF Symbol pinned at a hardcoded offset (`padding(.top, 200)`,
`.leading, 50`), rotated −20°, unrelated to the starfield or the horizon glow. The
**starfield is a screensaver that never settles**: 52 uniform random circles doing a
`repeatForever` opacity twinkle that deliberately ignores Reduce Motion — generic to look at
and, on an all-night bedside screen, exactly the always-on motion the design review (#2)
flagged for battery. And nothing on screen *embodies* the one thing Sleep mode does: fade
you out over a timer.

## 2. Goals

- **The screen makes the sleep timer felt, not read** — you can sense how much night is left
  without looking at a number.
- **The night sky looks like a real sky** — depth, varied stars, a Milky Way — not TV static.
- **It becomes a pleasant ambient screensaver while playing** — controls melt away, the sky
  stays.
- **Motion is calm and battery-aware**, and fully static under Reduce Motion.

## 3. Non-goals

- **Not changing the audio engine or the fade curve.** The moon visualises the existing
  `timerRemaining`; it doesn't alter how audio fades. _Why: separate subsystem._
- **Not removing the deep night-dim.** The full-black veil in `ContentView` (`autoNightDim`,
  ~60s) stays for true bedside darkness; the screensaver is a lighter, earlier stage.
  _Why: different job — winding down vs. asleep._
- **Not a 3D / parallax sky or live astronomy.** A beautiful flat starfield is enough.
  _Why: scope and battery._
- **Not redesigning Focus.** Covered separately. _Why: contain blast radius._

## 4. The setting moon (functional hero)

**4.1 Moonset = the timer.** The moon rides a gentle Bézier arc from a high resting spot
down to the horizon. Its position maps to `sleepTimer.nightProgress` (0 at timer start → 1
at the end), so as the night winds down the moon visibly sinks toward the warm horizon glow
the gradient already paints at the bottom. When the timer ends and audio has faded, the moon
has set. Idle (no timer running) the moon rests high — a calm static scene.

**4.2 A real moon, not a glyph.** Replace the SF Symbol with a soft radial-lit disc: a warm
halo, a subtle light direction, and a few faint craters. It sits *in* the sky, lit
consistently with the horizon.

**4.3 The sky deepens as the night ends.** A black overlay ramps with `nightProgress` (up to
~35%), so the whole scene quietly darkens toward sleep — a second, ambient read on "time
left" and a smooth handoff into the deeper night-dim.

## 5. A realistic starfield

**5.1 Power-law brightness.** Most stars faint, a few bright. The bright ones get a soft
halo (glow) so they read as nearer/brighter rather than just bigger dots.

**5.2 Colour temperature.** Stars aren't uniform white — most cool white, some warm amber, a
few blue-white. Subtle, but it's the difference between "sky" and "dots."

**5.3 A Milky Way band.** A denser diagonal swath of small faint stars over a soft luminous
haze, for depth and composition instead of an even scatter.

**5.4 Calm, settling motion.** Only a sparse subset twinkles, slowly. Reduce Motion holds
the entire field static. (See open question on a hard settle-to-static for battery.)

## 6. The ambient screensaver

**6.1 Controls fade on inactivity.** While audio is playing in Sleep mode, after ~12s of no
interaction the whole control layer (mode switch, status, buttons, orb) fades out, leaving
the sky + moon — a pleasant screensaver. A tap anywhere brings the controls back and re-arms
the timer.

**6.2 Never in Focus mode.** Focus must keep its session readout visible, so the screensaver
is Sleep-only.

**6.3 Relationship to night-dim.** The screensaver is the *first, light* stage (sky stays);
the existing full-black `autoNightDim` remains the *deep* stage for actual sleep. They
compose: controls fade, then later the black veil drops if enabled.

## 7. Requirements & acceptance criteria

### P0

**R1. Moon maps to the sleep timer.**
- [ ] Given a sleep timer of N minutes, the moon starts high and reaches the horizon as the
      timer reaches 0.
- [ ] Given no active timer, the moon rests high and still.
- [ ] Bumping the timer (+15m) eases the moon back up proportionally (`timerTotal` grows too).

**R2. Realistic starfield.**
- [ ] Brightness follows a power-law (most faint, few bright); bright stars have a halo.
- [ ] Stars vary in colour temperature; a Milky Way band is visible.
- [ ] Reduce Motion → the field is completely static.

**R3. Ambient screensaver.**
- [ ] While playing in Sleep mode, controls fade after ~12s of no interaction; the sky stays.
- [ ] A tap restores controls and re-arms the fade.
- [ ] Stopping playback restores controls; Focus mode never triggers the screensaver.

### P1

**R4. Hard settle for battery.** Twinkle stops entirely once the screensaver engages (or
after ~60s), so an all-night screen is fully static. (Currently a sparse twinkle continues.)
**R5. Fade the tab bar + mini-player too** when the screensaver engages, for a truly
full-screen ambient view (currently `ContentView` chrome stays). **R6. Reset the idle timer
on any control interaction**, not just taps on the wake layer.

### P2

- Moon **phase** reflecting the real lunar phase (crescent → full).
- A **shooting star** every few minutes as a rare delight (respecting Reduce Motion).
- Replace the deep black night-dim with a "moonset" end state so the scene, not a black
  rectangle, is the final image.

## 8. Open questions

- **(design/eng)** Battery vs. ambience on the twinkle (R4): keep a faint perpetual shimmer
  for the screensaver feel, or settle hard to static? Needs an on-device battery read.
- **(design)** Screensaver delay — 12s feels right in theory; tune on device.
- **(product)** Should the screensaver also dismiss the tab bar/mini-player (R5), or is the
  deep night-dim enough for that?

## 9. Implementation status (2026-06-21)

First PR landed (unverified on device):

- **R1 done** — `SleepTimerService` now tracks `timerTotal` and exposes `nightProgress`;
  `MoonArc` + `MoonView` place a soft moon along a Bézier arc by that fraction; a black
  overlay deepens the sky as the night ends.
- **R2 done** — `StarfieldView` rewritten: power-law brightness, bright-star halos, cool/
  warm/blue tints, a Milky Way band + haze, sparse twinkle, fully static under Reduce Motion.
- **R3 done** — `HomeView` fades the control layer after ~12s idle while playing in Sleep,
  with a tap-to-wake catcher; gated off in Focus mode.

Second PR (P1, also unverified on device):

- **R4 done** — `StarfieldView` now settles to fully static ~60s after appearing and the
  moment the screensaver engages (`paused`), so an all-night screen stops animating.
- **R5 done** — the screensaver flag moved to `AudioEngine.ambientScreensaver`; `ContentView`
  hides the tab bar (`.toolbar(.hidden, for: .tabBar)`) and fades the mini-player with it,
  and resets it on tab change so it can't hide another tab's bar.
- **R6 done** — a simultaneous `TapGesture` on the home controls pushes the idle countdown
  back on any interaction, not just taps on the wake layer.

Third PR (P2 delights, also unverified on device):

- **Moon phase done** — `MoonPhase.current()` derives tonight's illuminated fraction +
  waxing from days since a known new moon; `MoonView` renders the matching crescent →
  gibbous via a terminator ellipse, with a halo that dims for thin slivers.
- **Shooting star done** — `ShootingStarView` streaks a meteor across the sky every ~1.5–3.5
  min with random start points; fully disabled under Reduce Motion.

**Held (deliberately not built): the moonset end-state replacing the black night-dim.** The
full-black veil (`ContentView.autoNightDim`) is intentional bedside behaviour — CLAUDE.md
calls out true-OLED-black overnight as a design goal (battery + zero light emission).
Swapping it for a lit "moonset" scene would re-introduce light all night and regress that,
so it needs a product call, not a silent change. The sky already darkens via the
`nightProgress` overlay up to the point the night-dim takes over, which is a softer partial
version of the same idea. Open question for you: keep true-black, or accept some all-night
glow for the prettier end image?

Remaining open: on-device tuning of the 12s delay / 60s settle / battery tradeoff, and the
moonset decision above.

---

_Device gate (per CLAUDE.md): starfield realism/twinkle, moon motion, the screensaver
timing, and battery behaviour are all device-specific (no real timing or GPU cost in
happy-dom). Verify on a real iPhone, installed, screen on, over a full timer run — and
confirm the screensaver and the existing night-dim compose cleanly._
