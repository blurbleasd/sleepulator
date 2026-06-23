# Podcast resume / queue-advance audit (2026-06)

Audit of the mix-save/resume + podcast playback-position + queue-advance system, prompted by two
reported symptoms:

1. **Resume continues the *last-played* podcast, not the one that was playing when the mix was saved.**
2. **The next podcast in the queue doesn't always start at the beginning of the track.**

Both are real. They live in three files: `Models/Models.swift` (the saved-mix / preset models),
`Services/AudioEngine.swift` (save/resume + queue wiring), and `Services/PodcastPlayer.swift` (the
AVPlayer, the position map, and the resume-seek). `Services/PodcastQueueManager.swift` holds the
queue order. Nothing here has been built or device-verified — per the `CLAUDE.md` gate, anything
touching the player must be confirmed on a real iPhone over a full run.

---

## How the system works today

**The position store.** `PodcastPlayer` keeps `cachedPositions: [episodeId: seconds]`, persisted
to `positions.json`. A single periodic time observer (created once, `PodcastPlayer.swift:222-243`)
writes `cachedPositions[self.currentId] = time.seconds` every ~1 s, flushes to disk every 30 s, and
on a natural finish clears that episode's entry (`itemDidFinishPlaying`, `:379-386`).

**Loading an episode.** `play(url:id:title:)` (`:178-261`):
- sets `currentId = id` **synchronously** (`:193`);
- then, inside an `async` `Task`, swaps the AVPlayer item (`replaceCurrentItem`, `:245`) and — if
  `cachedPositions[id] > 5.0` — **seeks to `savedTime - 2.0`** (`:248-251`). This single seek is how
  *every* load "resumes where you left off."

**The queue.** `queue[0]` is the now-playing episode. `playEpisode` inserts at 0 and plays
(`PodcastQueueManager.swift:103-111`); `advanceQueue` removes `queue[0]` and plays the new `queue[0]`
(`:144-166`); `onNearEnd` preloads `queue[1]` (`AudioEngine.swift:364-371`).

**Saved mixes.** Two distinct things share the word "mix":
- **"Last Night"** — an *auto-snapshot* (`SavedMix`) captured on every pause/stop
  (`saveLastMix`, `AudioEngine.swift:518-532`). It stores `podcastUrl` + `podcastId` of
  `queue.first` (only when `isPodPlaying`). The Home "Resume · …" button calls
  `resumeMix` (`:534-548`), which reloads that podcast.
- **Named saved mixes** — these are now `SoundPreset` (`Models.swift:43-58`), which **deliberately
  carry no podcast** (see the doc comment at `:43-47`). `applyPreset` (`AudioEngine.swift:584-596`)
  swaps only the sounds and *"leaves any playing podcast alone."*

---

## Bug 1 — "Resume Last Night" doesn't reliably continue the last-playing podcast

**Intended behavior (confirmed):** Resume Last Night should continue *whatever podcast was last
playing*, as long as a podcast is selected/active in the mixer. So the single-slot "continue the most
recent podcast" model is correct, and the named-mix → `SoundPreset` decoupling (saved mixes are
sound-only) is **also working as designed — not a bug.** The defects are reliability gaps in
capturing and restoring that last-playing podcast:

1. **Capture is gated on the wrong condition.** `saveLastMix` stores a podcast only when
   `isPodPlaying` is true at the *instant* of capture (`AudioEngine.swift:528-529`). It runs from
   `pauseAll`/`stopAll`, and on a sleep-timer terminal stop the player may already be stopped → it
   captures `podcastUrl = nil`, so Resume restores **no** podcast. It should capture the last-loaded
   episode whenever a podcast layer is selected in the mixer, regardless of the transient play/pause
   state at that exact moment.

2. **No saved position → wrong resume point.** `SavedMix` stores no position
   (`Models.swift:29-41`); resume leans entirely on `positions.json[podcastId]` — the same map Bug 2
   can poison. So even when the right episode loads, it can resume at the wrong spot, or at 0 if the
   id never matched (older snapshots stored only a URL as the id, `resumeMix:546`).

3. **Stale slot.** `saveLastMix` only writes on pause/stop (`:511, 609`). Any path that ends a
   session without routing through those (a crash, an interruption-driven stop) leaves the slot
   pointing at an earlier episode, which then "resumes" the wrong show.

**Resolved direction:** keep the single Last-Night snapshot; make capture + restore reliable
(see fixes). No re-coupling of podcasts to named saved mixes.

---

## Bug 2 — the next track doesn't always start at the beginning

**Root cause: `currentId` is reassigned *before* the player item is swapped, so the 1 Hz position
writer can stamp the old track's elapsed time under the *new* episode's id — and the resume-seek then
honors that poisoned position.** The "not *always*" is the tell: it's a timing race.

The sequence on an advance / "play next":
1. `play(nextUrl, nextId)` sets `currentId = nextId` **synchronously** (`PodcastPlayer.swift:193`).
2. The item swap + resume-seek run **later**, in the `async Task` (`:245`, `:248-251`).
3. In the window between (1) and (2), the persistent periodic observer keys writes by `self.currentId`
   (`:223-224`). The player is still positioned on the **old** item (at/near its end). A trailing tick
   writes `cachedPositions[nextId] = oldElapsed` — a large value.
4. The resume-seek at `:248-251` reads `cachedPositions[nextId]`, sees `> 5.0`, and **seeks the new
   track to `oldElapsed - 2`** → the next episode starts deep into the track (or the seek clamps near
   the end and instantly re-fires "finished").

Contributing factors that widen the blast radius:
- **The resume-seek is unconditional.** The same `cachedPositions[id] > 5` seek used for legitimate
  "resume where I left off" also runs on auto-advance and on tapping a fresh episode. For any next
  track that has a *stale* saved position (partially heard earlier, never finished, then re-queued),
  it resumes mid-track instead of starting fresh — even with no race involved.
- **No "this is a fresh start" intent.** `play()` cannot tell "resume the thing I was on" from "start
  the next thing." There is one code path and it always tries to resume.

Note: a *normally finished* episode does have its position cleared (`itemDidFinishPlaying:382`), so the
common auto-advance case is usually fine — which is why the symptom is intermittent rather than constant.

---

## Proposed fixes

### Bug 2 (safe to fix now; deterministic + race both)
1. **Stop keying position writes off a pre-mutated field.** Either (a) set `currentId` only *after*
   `replaceCurrentItem` inside the Task, or (b) capture the id alongside the item and have the time
   observer resolve the id from the *current item*, not a mutable `currentId`. Add a short
   `isSwappingItem` guard so no tick is recorded between the id change and the seek completing.
2. **Make load intent explicit.** Add a `resume: Bool` (or `startAt: TimeInterval?`) parameter to
   `play(...)`. Apply the saved-position seek **only** when resuming ("Resume Last Night", tapping an
   in-progress episode). Pass `resume: false` for `advanceQueue` and `playEpisode`-from-list so the
   next track deterministically starts at 0.
3. **Belt-and-suspenders:** clamp the resume seek to the new item's duration, and ignore a saved
   position that's within ~N seconds of the *old* track's end when the id was just reassigned.

### Bug 1 (resolved direction: make Resume Last Night reliable)
- **Capture on "podcast selected," not "playing now."** In `saveLastMix`, store `queue.first`'s
  url + id whenever a podcast layer is selected/loaded in the mixer (e.g. gate on
  `hasLoadedEpisode` / a non-empty queue), instead of `isPodPlaying` at the capture instant
  (`AudioEngine.swift:528-529`).
- **Store the position in the mix.** Add `podcastPosition` to `SavedMix`, capture `podcastElapsed`
  at save time, and on `resumeMix` seek to it directly — don't depend on `positions.json` (which
  Bug 2 can poison). Keep `positions.json` as a fallback only.
- **Refresh the slot more than on pause/stop** (optional): also snapshot when the loaded episode
  changes, so an interruption that bypasses `saveLastMix` can't strand the slot on an old episode.

---

## Decisions (2026-06)

- **Bug 1 — intended behavior confirmed:** Resume Last Night continues *whatever podcast was last
  playing*, gated on a podcast being selected in the mixer. Saved mixes stay sound-only. Fix = make
  capture + restore reliable (above), no podcast/preset re-coupling.
- **Bug 2 — fixed in this pass** (was "audit only"; user then asked to implement both).

**Status: BOTH FIXES IMPLEMENTED — unverified on device (the `CLAUDE.md` gate still applies).**

---

## Implementation (2026-06)

**Bug 2 — position-poison race + explicit load intent.**
- `PodcastPlayer`: new `isLoadingItem` flag, set the instant a new item starts loading and cleared
  only after the resume-seek completes. The 1 Hz time observer now skips *all* position/progress
  work (`cachedPositions` write, `onTimeUpdate`, `onNearEnd`, flush) while it's set, so a trailing
  tick on the old item can no longer land under the new episode's id. `backgroundTick` (sleep-timer
  keep-alive) stays **outside** the guard and keeps firing across the swap.
- `play(...)` gains `resume: Bool = true` and `startAt: TimeInterval?`. The resume-seek now runs in
  priority order: explicit `startAt` → saved map (only when `resume`) → no seek (fresh start at 0).
- Intent threaded through `loadPodcastFn` (now 4-arg) → `loadPodcast(resume:startAt:)`:
  `advanceQueue` passes `resume: false` (next track starts at 0); `playEpisode` / `playAll` pass
  `resume: true` (user-initiated plays still resume).

**Bug 1 — reliable Last Night capture + restore.**
- `SavedMix` gains `podcastPosition: Double? = nil` (optional/defaulted → old snapshots decode as
  nil and fall back to the saved-position map; existing call sites and tests unchanged).
- `saveLastMix` captures the podcast whenever one is **loaded in the mixer** (`hasLoadedEpisode`),
  not only when `isPodPlaying` is true at the capture instant, and stores `podcastElapsed`.
- `resumeMix` seeks via `startAt: mix.podcastPosition`, so the restore no longer depends on the
  (now un-poisoned) `positions.json`.

**Tests:** updated the `loadPodcastFn` stub to the 4-arg shape; added
`testLoadIntentFreshOnAdvanceResumeOnPlayEpisode` to lock in advance=fresh / playEpisode=resume.
Unit tests can't exercise the real render thread / AVPlayer race — the device gate below is still
required.

---

## Verification (per `CLAUDE.md` gate)

On a real iPhone, installed, screen locked:
- Auto-advance through several queued episodes; confirm each next track **starts at 0** (watch the
  scrubber at the transition, not just eventually).
- Queue an episode you've partially heard, advance into it; confirm intended start (0 vs resume per
  the chosen design).
- Tap an in-progress episode from the list; confirm it still **resumes** where you left off.
- "Resume Last Night" after a full sleep-timer run; confirm it loads the **exact** episode that was
  playing and at the right position.
- Run one auto-advance across the device-lock boundary to exercise the background path.
