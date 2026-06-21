# Focus Mode — Spec

_Date: 2026-06-21 · Grounded in the SwiftUI source (`HomeView.swift`, `Theme.swift`,
`SleepTimerService.swift`/`PomodoroService`, `ContentView.swift`) and the two current
home screenshots. Covers both the **visual redesign** of the Focus home and the
**functional gaps** in the Pomodoro engine._

Priority key: **P0** must-fix to ship · **P1** strong follow-up · **P2** future / architectural insurance.

---

## 1. Problem statement

Focus mode was built as "Sleep, recolored." It reuses the same composition — same orb,
same positions, same status line, same `Build mix` drawer — swaps the palette from warm
amber to cool cyan, and removes Sleep's character (moon, starfield, breathing). The result
reads as *the absence of Sleep* rather than its own headspace: a flat blue void with no
focal point. Sleep and Focus are psychologically opposite — Sleep dissolves structure,
Focus imposes it — but the screen treats them as a tint swap. That's why Focus "feels
especially off."

On top of the visual problem, the Focus home currently shows a **cross-mode content leak**
(a real bug, visible in the screenshot) and the Pomodoro engine behind the mode is
half-built compared to what a focus timer needs.

## 2. Diagnosis (why it feels off)

**a. Focus is Sleep minus its soul.** In `HomeView`, the Sleep branch renders a moon, a
52-star twinkling field, and a "Breathing exercise" affordance (`if !audio.focusMode`).
The Focus branch (`FocusBackdrop`) renders only a single slow-rotating blurred gradient.
So Focus has strictly *less* on screen than Sleep, in the same layout — it looks emptier,
not more alert. The asymmetry of richness is the core feeling.

**b. No focal element, no sense of time.** Focus mode exists to run structured time
(Pomodoro). But the screen surfaces no time structure at all: no progress ring, no phase
indicator, the same passive play orb as Sleep. There's nothing for the eye to anchor on,
so the blue gradient reads as a dead void.

**c. "Energizing" isn't delivered.** `Theme.swift` describes Focus as "cool + energizing,"
but `focusBg` is a very dark indigo-navy `(0.04, 0.06, 0.11)` and the only motion is a
640pt angular gradient at `blur 90` rotating on a 36s loop. Dark navy + a slow blur drift
reads as cold and inert, not calm-alert. (Design review already flagged this motion as
pulling focus — #2, #14.)

**d. Misleading resume label — COPY BUG (not a functional leak).** The status line under the
orb comes from `statusText()`, which falls back to `lastMix`. In Focus mode it can read
**"Resume · Brown + Delta + Podcast"** — Sleep-only sounds. Confirmed with the dev: tapping
it *correctly* resumes the last **Focus** state; only the label is wrong, because
`statusText()` renders `lastMix` (the last-played, possibly-Sleep mix) rather than the focus
mix that will actually resume. So this is a display/copy bug, not the functional cross-mode
leak first suspected — but it still reads as broken and must be fixed to show the focus mix.

**e. The mode is invisible from the chrome.** `ContentView` hardcodes the first tab as
`Label("Sleep", systemImage: "moon.stars.fill")`. In Focus mode you're looking at a "Sleep"
tab with a moon icon, rendered in cyan. (Design review #6.)

**f. Same layout = modes don't feel distinct.** Beyond palette + the relabeled bottom
button ("Sleep timer" → "Focus session"), nothing about the composition signals a different
activity. Two opposite headspaces share one screen skeleton.

## 3. Goals

- **Focus reads as its own mode within 1 second** — a glance should tell you you're in a
  work headspace, not a recolored sleep screen, without reading any label.
- **The Focus home makes time/structure visible** — the Pomodoro state is the hero, not a
  hidden timer behind a button.
- **No cross-mode content ever appears in Focus** — sounds, resume prompts, and copy are
  all Focus-native.
- **A focus session survives backgrounding** — phase boundaries notify reliably when the
  user is working in another app.
- **The mode feels calm-alert, not cold-empty** — energizing without competing with the
  work.

## 4. Non-goals

- **Not redesigning Sleep mode.** Sleep's composition stays; this spec only changes Focus
  and the shared chrome that misrepresents it (tab label). _Why: Sleep is the more-finished
  of the two and out of scope here._
- **Not adding task lists / to-do management.** Focus stays an ambient-audio + timer tool,
  not a productivity suite. _Why: scope, and it's a different product._
- **Not building cross-device sync or accounts for focus stats.** Local-only history is
  enough for v1. _Why: premature; no backend for it._
- **Not changing the audio engine or sound generation.** Only *which* sounds surface and
  *when* they change intensity. _Why: the engine is a separate, hard-won subsystem._
- **Not a full theming overhaul.** We adjust the Focus palette/backdrop, not the global
  theme system. _Why: contain blast radius._

## 5. The redesign — Focus home

The organizing idea: **Sleep is a place you sink into; Focus is a session you run.** Make
the Focus home a *session surface*, not a recolored ambient screen.

**5.1 The timer is the hero.** Replace the passive Sleep-style orb with a **circular
progress ring** around the play control that depletes over the current Pomodoro phase. When
no session is running, the ring is a calm idle state inviting "Start focus session." When
running, it's the focal element the whole screen lacks today. This single change gives
Focus its anchor and makes time visible (fixes diagnosis b + lack of focal point).

**5.2 Give Focus its own character, don't just strip Sleep's.** Sleep has moon + stars;
Focus needs an equivalent *positive* signature, not emptiness. Options (pick one, by eye on
device): a faint geometric grid/contour field, a single steady horizon glow, or a subtle
"breathing-to-static" energy band that settles after the session starts. The bar is: Focus
should have roughly the *same visual weight* as Sleep, expressed as alert/structured rather
than cozy/organic.

**5.3 Lift the palette toward calm-alert.** Nudge `focusBg` slightly brighter / less pure-
navy and increase contrast of the focal ring + accent so the screen reads crisp rather than
dark-and-inert. Keep cyan as the accent. Verify WCAG AA on `focusText`/`focusDim` against
the new background (the codebase already tracks ratios — keep that discipline).

**5.4 Settle the motion.** Per design review #2/#14: the rotating blurred gradient should
fade to near-static within ~30–60s of a session starting (Focus is a concentration mode;
large drifting glows compete with the work). Reduce-Motion users get static immediately.

**5.5 Phase-aware surface.** When the Pomodoro is in **rest**, the home should *look*
different from **work** — e.g. the ring color/copy shifts to "Break · 5m," and (see 6.3)
the audio softens. The screen should always answer "am I working or resting right now?"
without tapping.

**5.6 Fix the chrome that lies.** Make the first tab mode-aware — either rename it to a
mode-neutral "Home"/"Now," or reflect the active mode's label+icon (moon vs. bolt). No more
cyan "Sleep" tab while focusing.

**5.7 Kill the cross-mode resume.** The status line and resume prompt must be Focus-native:
either scope `lastMix` per mode (a `lastFocusMix` / `lastSleepMix`) or suppress the resume
prompt entirely when the saved mix doesn't belong to the current mode. Focus should never
say "Resume · Brown + Delta."

## 6. Functional gaps — the Pomodoro engine

`PomodoroService` is currently a two-phase `work ↔ rest` loop (defaults 25/5) that chimes
at each boundary via `chimeFn`. It's missing the things that make a focus timer feel real.

**6.1 Long breaks + cycle count (P0).** Standard Pomodoro takes a longer break every N work
intervals (typically a 15–20m break every 4). Add `completedCycles`, a `longRestMinutes`,
and a `cyclesBeforeLongBreak` (default 4). The home should show progress through the set
(e.g. "Cycle 2 of 4"). Without this, the loop is just a metronome.

**6.2 Survive backgrounding (P0 — correctness, not polish).** The chime fires from a
`DispatchSourceTimer` on a background queue, and unlike the sleep timer (which has a Live
Activity), Focus has no out-of-app surface. The normal focus workflow is to work in *another*
app while the timer runs — at which point iOS suspends the timer and the boundary chime is
unreliable or silent. Fix by scheduling `UNUserNotificationCenter` local notifications at the
computed phase-end `Date`s (and/or a Live Activity mirroring the sleep timer's), so each
work→rest→work boundary alerts even when Sleepulator is backgrounded. Reschedule on
start/stop and on phase change.

**6.3 Make the break audibly different (P1).** Today only the chime and countdown change at
a boundary; the same noise/binaural bed plays identically through work and rest. Use the
existing `phase` gating to cue the brain: on `rest`, drop binaural intensity and/or soften
volume; restore on `work`. Cheap given how much already branches on `phase`/`focusMode`.

**6.4 Lightweight session history (P1).** Focus tools live on the feeling of progress.
Persist a simple local count of completed work intervals per day ("3 sessions today") and
surface it on the Focus home. No stats screen, no sync — just a reason to come back.

**6.5 Configurable durations are reachable (P1).** `workMinutes`/`restMinutes` already
persist but are buried. Expose work / short-break / long-break / cycles-before-long-break in
the Focus session sheet so the defaults aren't the only realistic option.

## 7. Requirements & acceptance criteria

### P0 — must-fix to ship the redesign

**R1. Focus home has a timer-centric focal element.**
- [ ] A circular progress ring surrounds the primary play/session control in Focus mode.
- [ ] Running: the ring depletes over the current phase and is the visual focal point.
- [ ] Idle: the ring shows a calm "start" state, not an empty orb.
- [ ] Given Reduce Motion is on, the ring updates without continuous spin animation.

**R2. The resume label matches what will actually resume (copy fix).**
- [ ] Given Focus mode is active, the status line shows the sounds of the **focus** state
      that tapping will resume — never a stale Sleep mix's sounds.
- [ ] Behavior is unchanged (resume already restores the correct focus state); only
      `statusText()`'s rendered string is corrected.
- [ ] Switching modes never leaves a cross-mode sound *audibly* active (existing
      `reconcileSoundsToMode()` behavior preserved).

**R3. The mode is honest in the chrome.**
- [ ] The first tab does not display "Sleep" + moon while Focus mode is active.
- [ ] Resolution chosen and applied: mode-neutral label OR mode-reflective label+icon.

**R4. Pomodoro supports cycles + long breaks.**
- [ ] `PomodoroService` tracks `completedCycles`.
- [ ] After `cyclesBeforeLongBreak` (default 4) work intervals, the next break uses
      `longRestMinutes`.
- [ ] The home shows current position in the set (e.g. "Cycle 2 of 4").

**R5. Phase boundaries alert when backgrounded.**
- [ ] Given a running session, when the app is backgrounded and a phase ends, the user
      receives a notification (and/or Live Activity update) at the correct time.
- [ ] Notifications are rescheduled on start, stop, and manual phase change; none fire after
      `stop()`.
- [ ] Given notification permission is denied, the in-app chime still works and the user is
      prompted once to enable notifications for background alerts.

### P1 — strong follow-ups

**R6. Break phase changes the audio bed.** On `rest`, binaural intensity/volume softens;
restores on `work`. No clicks/pops at the transition.

**R7. Daily completed-session count** is persisted locally and shown on the Focus home;
resets at local midnight.

**R8. Focus session sheet exposes** work / short-break / long-break / cycles-before-long-
break, persisted via the existing `UserDefaults` keys (extend `pomoWork`/`pomoRest`).

**R9. Focus backdrop settles to near-static** within ~30–60s of session start (immediate
under Reduce Motion).

### P2 — future / architectural insurance

- Per-mode saved mixes (`lastFocusMix` / `lastSleepMix`) instead of a single mode-agnostic
  `lastMix` — designing R2 so this is a clean extension.
- Multi-day focus streaks / weekly summary (depends on R7's local store).
- A "deep work" variant with no breaks (single long countdown) toggled from the session
  sheet.

## 8. Open questions

- **(design)** Which Focus signature from 5.2 — grid/contour, horizon glow, or settling
  energy band? Needs an on-device eye test against the brightened palette.
- **(eng)** Live Activity vs. local notifications vs. both for R5? Live Activity matches the
  sleep timer pattern but is more work; notifications are simpler and sufficient for the
  chime. Recommend notifications for v1, Live Activity as P1.
- **(design)** Does the brightened `focusBg` in 5.3 still hold WCAG AA for `focusDim`? Must
  re-derive ratios after any background change.
- **(product)** Should idle Focus auto-start a session on first play, or require an explicit
  "Start focus session"? Affects whether the ring is interactive when idle.

## 9. Phasing

- **Phase 1 (ship the fix):** R2 + R3 (the leak + the lying tab — small, high-credibility
  wins) and R5 (backgrounding correctness). These make Focus *correct*.
- **Phase 2 (make it feel right):** R1 + R4 + the 5.x visual redesign. These make Focus
  *feel like Focus*.
- **Phase 3 (make it sticky):** R6–R9. Polish and retention.

## 10. Implementation status (2026-06-21)

First PR landed (unverified on device):

- **R4 done** — `PomodoroService` now tracks `completedCycles`, `restIsLong`, and config
  `longRestMinutes` (15) / `cyclesBeforeLongBreak` (4); a long break replaces the short one
  every 4th interval. Added a `progress` fraction for the ring.
- **R1 done** — `FocusHero` wraps the play orb in a depleting progress ring;
  `FocusSessionReadout` shows phase + live countdown + `CycleDots` ("Cycle 2 of 4"). Idle
  falls back to the normal status + `LayerPills`.
- **R3 done** — the first tab now reads "Focus"/bolt while focusing instead of "Sleep"/moon.

Still open from Phase 1/2: R2 copy fix, R5 backgrounding notifications, the palette lift +
"daylight" option (5.2/5.3), motion settling (R9), break-aware audio (R6), and session
history (R7).

---

_Device gate (per CLAUDE.md): anything touching the audio bed (R6), timer/background
behavior (R5), or volume changes must be verified on a real iPhone, installed as a PWA/native
build, with the app backgrounded — unit tests can't catch the suspend/notification timing._
