# Sleepulator — strengthening recommendations (2026-06)

A blind read of the native SwiftUI app (engine, players, timer, session, persistence,
networking, views). The hard parts are already done well: a lock-free atomic double-buffer
hand-off to the render thread (`GenerativeAudioEngine.updateParams` + `SLPAtomicIndex`),
denormal flushing in the DSP loops, per-sample gain smoothing, a single-writer invariant
asserted in DEBUG, a belt-and-suspenders sleep-timer keep-alive (RMS tap **and** the AVPlayer
observer both feed `backgroundTick`), and careful interruption/route handling. These notes are
about hardening edges, not rescuing a mess.

A line runs through everything below: **the verification gate** in `CLAUDE.md`. Anything that
touches the render thread, audio session, limiter, or sleep/Pomodoro timer must be verified on a
real iPhone, installed, screen locked, over a full timer run. So this round implements only the
changes that are *safe to land without device audio verification* (persistence, networking,
downloads, feed parsing) and leaves the audio-thread / view-tree work specified-but-deferred.

---

## Priority 1 — implemented this round

### 1.1 Durable persistence + corruption recovery  *(StorageManager)*
**Problem.** `StorageManager.save` (was fire-and-forget on `ioQueue`) and `load` returned `nil`
on *any* error — including a corrupt-JSON **decode** failure — with no logging. The `.atomic`
write protects against partial files, but if `library.json` or `mixes.json` is ever truncated by
a crash mid-replace or corrupted at rest, the next launch silently decodes to `nil` and the user
loses their entire library / presets, with no signal and no fallback.

**Fix.** Every successful save now also writes a `.bak` sibling. `load` distinguishes *missing*
(benign first-run → silent `nil`) from *corrupt* (decode threw → log it, fall back to `.bak`,
and self-heal the primary from the backup when the backup is good). New `loadResult` exposes the
outcome (`.missing` / `.loaded` / `.recovered` / `.failed`) so callers and tests can assert on it.
Backup/restore raw paths (`rawData` / `writeRaw`) keep their `.bak` siblings in sync.

### 1.2 Network timeouts + retry-with-backoff  *(Net, PodcastParser, ITunesSearchManager)*
**Problem.** `PodcastParser.parseFeed` and `ITunesSearchManager.search` used `URLSession.shared`
with default timeouts and **failed immediately** on any transient error. For an app people
refresh half-asleep, one Wi-Fi blip reads as "feed broken."

**Fix.** A new `Net` helper owns two configured sessions — `feed` (20 s request / 60 s resource,
`waitsForConnectivity`) and `download` (longer resource timeout) — plus a pure, generic
`retry(attempts:baseDelay:isRetryable:)` with exponential backoff that only retries transient
errors (timeouts, connection-lost, DNS, 5xx), never a 4xx. Both feed fetch and iTunes search go
through it. The retry policy is split into a pure, unit-tested classifier (`Net.isRetryable`).

### 1.3 Malformed-feed memory cap  *(PodcastParser)*
**Problem.** `accumulate()` appended CDATA/character data with no ceiling; a pathological feed
with a giant `<content:encoded>` block could grow a buffer unbounded and OOM.

**Fix.** Per-field accumulation is capped (titles/dates/durations small; descriptions to a
generous but bounded size). Once a buffer hits its cap, further text for that field is dropped.

### 1.4 Download cache: free-space guard, play-recency, testable eviction  *(AudioDownloader)*
**Problems.** (a) The 2 GB cap was enforced only *after* a download landed, so the cache could
transiently balloon. (b) LRU sorted on `contentAccessDate`, which streaming a cached file doesn't
reliably bump — so a re-played favorite could be evicted before a downloaded-once-never-played
file. (c) Eviction logic was untestable (pure FS side effects).

**Fix.** (a) A pre-download free-space check throws a clear `lowDiskSpace` error if the volume is
under a headroom floor. (b) `getCachedUrl` now "touches" the file's modification date on every
cache hit, and eviction ranks by the **more recent** of access/modification date, so a played
file counts as recently used. (c) The ordering decision is extracted to a pure, unit-tested
`evictionPlan(files:maxBytes:)`.

---

## Priority 2 — specified, deferred (need device verification or larger surface)

### 2.1 Split `AudioEngine` into observable slices
`HomeView` and `LibraryView` still hold `@ObservedObject var audio: AudioEngine`; any `@Published`
change invalidates the whole subtree. The big offenders are already tamed (`rmsPower` is not
`@Published`; the sleep-timer republish is throttled to 1 Hz; `EpisodeRowView` observes only
`queueManager`). The durable fix is to break playback / timer / settings into separate
`@Observable` types so each view subscribes only to what it renders. **Deferred:** wide surface,
and re-render behavior under a locked all-night session should be confirmed on device.

### 2.2 Ambient backdrop rendering
The `TimelineView(.animation)` + `Canvas` scenes draw 20–30 fps on the main thread. They already
freeze at `screenDimmed` (the big all-night battery win). Remaining polish: drop frame rate under
Low Power Mode, and gate on `accessibilityReduceMotion` for users who want the battery savings.
**Deferred:** touches rendering paths; verify battery/thermal on device.

### 2.3 Accessibility pass
Inconsistent VoiceOver labels (e.g. "Play All" in `PodcastDetailView`, `OrbButton`), Dynamic Type
not handled in `MiniPlayerView`, and ambient scenes hardcode colors instead of taking the
`Palette` (blocks future theming/light mode). Worth one focused session; low risk but broad.

### 2.4 Feed-proxy URL validation
`feedProxyUrl` is user-editable with no scheme check — a bad paste silently reroutes feed traffic.
Add an https/host validator. **Deferred:** the setter lives on `AudioEngine` (a `@Published`
property with audio-adjacent `didSet`s); fold it into the settings-slice work in 2.1.

---

## Priority 3 — new features that fit the architecture

- **Sleep/focus session history + HealthKit.** `SleepTimerAttributes` and Live Activities are
  already in place; logging "fell asleep to" sessions and writing sleep / mindful-minutes to
  HealthKit is a natural extension with most plumbing present.
- **Gentle wake fade-in (alarm).** The app fades *out* beautifully via
  `AudioMath.getFadeMultiplier`; a morning fade-*in* is the mirror image and reuses the same curve.
- **Scene presets / auto-rotate.** `SoundPreset` already captures `sceneId`; let users save/rotate
  favorite backdrops.
- **Differential feed refresh.** Track the newest known `pubDate` per podcast and stop parsing at
  the first already-known item — less bandwidth, and it bounds parse work (complements §1.3).
- **OPML export.** Import exists (`OPMLParser`); export is trivial and makes subscriptions
  portable. (Note: OPML import isn't currently surfaced in a view — worth wiring both together.)

---

## Notes on verification

The sandbox can't build an iOS target, so the changes below were written for correctness and ship
with unit tests in the existing XCTest style, but **have not been compiled or run here.** Before
relying on them:

1. Build the `Sleepulator` scheme in Xcode (iOS 17+).
2. Run the test target — new tests: `StorageManagerTests`, `NetRetryTests`, `CacheEvictionTests`,
   plus an added malformed-feed case in `PodcastParserTests`.
3. None of these touch the render thread / session / limiter / timer, so the on-device audio gate
   does not apply to them — but a normal smoke test (add a feed, download an episode, kill Wi-Fi
   mid-refresh, relaunch) is worth doing.
</invoke>
