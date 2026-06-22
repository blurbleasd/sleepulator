# Sleepulator (native) — implementation punch-list for Antigravity

Scope: the iOS app under `Sleepulator/`. This is an ordered, code-level spec to close
the reported bugs and the highest-value web-parity gaps. Do **P0** first (the four
reported bugs + cheap wins), then **P1**. Don't start **P2** until P0/P1 are on-device
verified.

> **Status note (latest audit):** ALL items in this punchlist have been implemented and verified. P0, P1, UI/UX v2, and Podcast browser v2 (B1-B6) are fully complete. This punchlist is fully closed out. **Exception:** the **Noise curation** section was later *reversed* by AUDIO-PALETTE-SPEC.md (green/forest/gray re-added) — see its in-section supersede note. Archived to `docs/shipped/`.

Conventions:
- "AE" = `Sleepulator/Sleepulator/Services/AudioEngine.swift` (the store/coordinator).
- "PP" = `Sleepulator/Sleepulator/Services/PodcastPlayer.swift`.
- "GAE" = `Sleepulator/Sleepulator/Services/GenerativeAudioEngine.swift`.
- "Home" = `Sleepulator/Sleepulator/Views/HomeView.swift`.
- "Settings" = `Sleepulator/Sleepulator/Views/SettingsView.swift`.
- Keep existing `UserDefaults` key names exactly — do not rename or existing users lose state.
- Every change must keep the build green (`xcodebuild`), and `xcodebuild test` must still pass.

---

## P0 — reported bugs + cheap wins

### P0.1 — Home screen must scroll

**Problem:** Home content is a `VStack` inside a `ZStack` with no `ScrollView`
(`HomeView.body`). Giant button + timer + breathing + seek + three mixer rows +
the mini-player overlay exceed the viewport on most iPhones, so the lower controls
are unreachable.

**Fix:** Wrap the main content `VStack` in a `ScrollView`. Because the layout uses
`Spacer()`s to vertically center, preserve centering-when-short + scroll-when-tall
with a `GeometryReader` min-height:

```swift
ZStack {
    // background + BreathingOrb stay as-is, OUTSIDE the ScrollView
    GeometryReader { geo in
        ScrollView {
            VStack(spacing: 30) {
                // ... existing content ...
            }
            .frame(minHeight: geo.size.height)   // center when short, scroll when tall
            .padding(.bottom, 120)               // clearance for the MiniPlayer overlay
        }
    }
}
```

Acceptance: on the smallest supported device, every control (down to the Podcast
mixer row) is reachable by scrolling, and nothing hides behind the mini-player.

---

### P0.2 — Prepopulate proxy URLs from config

**Problem:** AE `init` defaults `audioProxyUrl` / `feedProxyUrl` to `""`. The web app
defaults them from `public/config.js`. So the Sleep-Safe and feed-proxy fields are
empty on a fresh install.

**Fix:** Add a single source of truth mirroring `config.js`, and use it as the
default in AE `init`. Keep the Sleep-Safe **toggle** defaulting to `false` (matches
web — a sleeping Render box must not be able to block playback).

Create `Sleepulator/Sleepulator/Services/Config.swift`:

```swift
import Foundation

enum AppConfig {
    static let feedProxyUrl  = "https://sleepulator-feed-proxy.chesteraarfer.workers.dev"
    static let audioProxyUrl = "https://sleepulator-audio-proxy.onrender.com"
    static let sleepSafeAudioEnabled = false
}
```

In AE `init`, change the two defaults:

```swift
self.feedProxyUrl  = UserDefaults.standard.string(forKey: "feedProxyUrl")  ?? AppConfig.feedProxyUrl
self.audioProxyUrl = UserDefaults.standard.string(forKey: "audioProxyUrl") ?? AppConfig.audioProxyUrl
self.sleepSafeAudio = UserDefaults.standard.object(forKey: "sleepSafeAudio") as? Bool ?? AppConfig.sleepSafeAudioEnabled
```

Acceptance: fresh install shows both proxy URLs pre-filled in Settings; Sleep-Safe
toggle is off; an episode still plays with the toggle off.

---

### P0.3 — Tap-to-change noise & binaural on Home (chip selectors)

**Problem:** Home shows the current sound type only as a text label in
`WarmMixerRow`; there's no way to change it without going to Settings. The web app
rendered a tappable chip-row of every `NOISE_TYPES` / `BINAURAL` preset in the mixer.

**Fix:** Add a reusable horizontal chip selector and render it under the ambient and
binaural rows on Home.

Add to `Sleepulator/Sleepulator/Views/Components.swift`:

```swift
struct ChipRow: View {
    let options: [String]          // raw keys, e.g. ["brown","pink",...]
    let labels: [String: String]?  // optional display overrides
    @Binding var selection: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { key in
                    let isSel = selection == key
                    Button(action: { selection = key }) {
                        Text((labels?[key] ?? key).capitalized)
                            .font(.system(.caption, design: .rounded).bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(isSel ? Color(red: 0.9, green: 0.7, blue: 0.4)
                                              : Color.white.opacity(0.08))
                            .foregroundColor(isSel ? .black : .gray)
                            .clipShape(Capsule())
                    }
                    .accessibilityLabel(Text((labels?[key] ?? key)))
                    .accessibilityAddTraits(isSel ? .isSelected : [])
                }
            }
            .padding(.horizontal, 2)
        }
    }
}
```

In Home, under the noise `WarmMixerRow`:

```swift
ChipRow(options: ["brown","pink","white","green","fan","rain","ocean","forest"],
        labels: nil, selection: $audio.noiseType)
```

Under the binaural row (use friendly labels):

```swift
ChipRow(options: ["delta","theta","alpha","gamma"],
        labels: ["delta":"Deep","theta":"Drift","alpha":"Relax","gamma":"Focus"],
        selection: $audio.binauralPreset)
```

`audio.noiseType` / `audio.binauralPreset` already drive `syncGenEngine()` via their
`didSet`, so changes apply live. The Settings pickers can stay (or be removed) — your
call; the home chips are the parity requirement.

Acceptance: tapping a chip on Home switches the active sound/preset immediately while
playing, with the selected chip highlighted.

---

### P0.4 — Clean podcast resume from Home

**Problem (two causes):**
1. After relaunch, `podTitle` is restored from the saved queue but **no `AVPlayer`
   exists** (`loadPodcast` only runs on explicit episode tap). So `togglePodcast →
   PP.toggle()` hits `player == nil` and silently no-ops.
2. The giant button conflates layers: it `stopAll`s if anything is on, and otherwise
   force-enables `noiseOn` while toggling the podcast. It can never cleanly resume
   just the paused track.

**Fix A — lazy load on resume (PP + AE).** Make resume able to spin up the player
from the current queue item, restoring saved position.

In AE, add:

```swift
func resumePodcast() {
    if podPlayer.hasPlayer {           // see PP flag below
        podPlayer.resume()
    } else if let first = queue.first {
        podTitle = first.title
        loadPodcast(first.audioUrl)    // play() restores saved position
    }
}
```

In PP, expose whether a player/item exists:

```swift
var hasPlayer: Bool { player?.currentItem != nil }
```

Point the Home Podcast row and `MiniPlayerView` play action at a single toggle that
uses this:

```swift
// AE
func togglePodcast() {
    if isPodPlaying { podPlayer.pause() } else { resumePodcast() }
}
```

**Fix B — giant button = resume-what-was-on, no surprise noise.** Stop force-enabling
noise. Remember the layer snapshot at stop, and restore it on the next press.

In AE add a snapshot used by `stopAll` / the giant button:

```swift
private var lastActiveSnapshot: (noise: Bool, bin: Bool, pod: Bool) = (false, false, false)

var isAnythingPlaying: Bool { isPodPlaying || noiseOn || binauralOn }

func toggleMasterTransport() {
    if isAnythingPlaying {
        lastActiveSnapshot = (noiseOn, binauralOn, isPodPlaying)
        pauseAll()                     // pause, don't tear down (see below)
    } else {
        // resume exactly what was on; default to noise only on a truly cold start
        let snap = lastActiveSnapshot
        if !snap.noise && !snap.bin && !snap.pod {
            noiseOn = true
        } else {
            if snap.noise { noiseOn = true }
            if snap.bin   { binauralOn = true }
            if snap.pod   { resumePodcast() }
        }
    }
}

/// Like stopAll but keeps the podcast player alive (paused) so it can resume.
func pauseAll() {
    saveLastMix()
    noiseOn = false
    binauralOn = false
    if isPodPlaying { podPlayer.pause() }
}
```

Wire the Home giant button to `audio.toggleMasterTransport()` and its icon to
`audio.isAnythingPlaying ? "pause.fill" : "play.fill"`. Keep `stopAll()` (full
teardown) for the sleep-timer expiry path.

Acceptance:
- Relaunch app, press play on the Podcast row or mini-player → the saved episode
  loads at its saved position and plays.
- Pause the podcast while noise plays → pressing the podcast control resumes only the
  podcast; noise is untouched.
- Giant button pauses then resumes the same set of layers that were active; it does
  not silently switch noise on.

---

## P1 — use-case parity

### P1.1 — Custom sleep-timer length

**Problem:** Home offers only 15/30/60 via an action sheet. Web had presets
[15/30/45/60] **plus** a 5–120 min slider (step 5).

**Fix:** Replace the action sheet with a small sheet/menu containing the four presets
**and** a `Slider(value:in:step:)` 5...120 step 5 bound to a `@State var customMins`,
with a "Start" button calling `audio.startSleepTimer(minutes: customMins)`. Persist
the last-chosen length under key `timerMinutes` to match the web default of 30.
Keep the existing fade (final 10 min) and the "Still Awake? (+15m)" behavior.

Acceptance: user can start a timer of any 5-min increment up to 120; last length is
remembered across launches.

---

### P1.2 — Lock-screen artwork + album

**Problem:** `PP.updateNowPlaying` sets only title + artist. The lock screen art tile
is blank. Web set artwork (app icon) + album "SLEEPULATOR".

**Fix:** In `updateNowPlaying`, add artwork once (cache the `MPMediaItemArtwork`) and
the album:

```swift
info[MPMediaItemPropertyAlbumTitle] = "Sleepulator"
if let art = Self.artwork { info[MPMediaItemPropertyArtwork] = art }
```

```swift
private static let artwork: MPMediaItemArtwork? = {
    guard let img = UIImage(named: "AppIcon") ?? UIImage(named: "icon-512") else { return nil }
    return MPMediaItemArtwork(boundsSize: img.size) { _ in img }
}()
```

If `AppIcon` isn't loadable as a `UIImage` at runtime, add a 512×512 PNG to the asset
catalog as a normal image set (e.g. `nowPlayingArt`) and reference that.

Acceptance: lock screen / Control Center shows the app art while a podcast plays.

---

### P1.3 — Fix position-memory correctness (PP)

**Problems:** positions are keyed by the **resolved** playback URL (`finalUrlStr`), so
toggling Sleep-Safe or playing a downloaded vs. streamed copy loses the saved spot;
positions only flush on pause/stop/finish (an OS-killed overnight session with no
timer loses them); `episodePositions` is never pruned (UserDefaults bloat).

**Fixes:**
1. Key positions by a stable id. Have AE pass the canonical `episode.id` (or
   `episode.audioUrl`) into `PP.play(url:title:positionKey:)` and use that for
   `cachedPositions`, independent of proxy/cache resolution.
2. Flush periodically: in the existing 5-second periodic observer, also call
   `flushPositionsToDisk()` (throttle to ~every 30s), and flush on
   `scenePhase == .background` (observe from the App/Scene).
3. Cap the dict: when writing, if `> 100` entries, drop the oldest. Simple approach:
   store `[id: [pos, lastUpdated]]` or keep a parallel recency list and trim.

Acceptance: start an episode, fall asleep (no timer), force-quit, relaunch → resumes
within a few seconds of where you were; toggling Sleep-Safe does not reset position;
the dict stays bounded.

---

### P1.4 — Connectivity + feed/playback messaging

**Problem:** Failures are silent except `podTitle` flipping to "Failed: …". Web
surfaced offline state and feed/playback notes (e.g. "Sleep Safe enabled but no proxy
configured — playing directly").

**Fix:**
- Add lightweight reachability via `NWPathMonitor` in AE; publish `isOnline: Bool`.
- In `LibraryView.loadFeed` / `PodcastDetailView.loadFeed`, on failure show the
  caught error in a visible label (not just `print`), and if offline show "You're
  offline — connect to load feeds."
- In `loadPodcast`, if `sleepSafeAudio == true` but `audioProxyUrl` is empty, set a
  visible note "Sleep Safe on but no proxy set — playing directly" (mirror web copy)
  and still play the direct URL.
- Keep the existing `onPlaybackFailed` path, but show a non-destructive banner rather
  than overwriting `podTitle` with the raw error.

Acceptance: airplane mode → loading a feed shows a clear message; dead episode URL →
visible failure + queue advances; Sleep-Safe-on-without-proxy shows the note.

---

## P2 — polish / robustness (after P0/P1 verified on device)

- **Master volume + mute.** Add `masterVolume` (persist `masterVolume`, default 1.0)
  applied on top of per-source gains in `syncGenEngine` and `syncPodPlayer`; add a
  global mute. Web parity.
- **Reduced motion.** Gate `BreathingOrb` and the giant-button spring on
  `UIAccessibility.isReduceMotionEnabled` (and observe `reduceMotionStatusDidChange`).
- **KVO cleanup (PP).** Remove the `status` observer in `deinit` and hold a reference
  to the observed `AVPlayerItem` so removal targets the right object.
- **Preload-next.** When a track is within ~30s of the end and `autoPlay` is on,
  pre-create the next `AVPlayerItem` for a gapless advance.
- **Session config consolidation.** `setActive`/`setCategory` is now in three places
  (AE init, GAE setup, GAE interruption). Harmless (all `.playback`) but the
  "consolidated to AudioEngine" comment is misleading — either centralize for real or
  fix the comment.

---

## The verification gate (do not skip)

Code-correct on paper ≠ correct on hardware. Before calling any of this done, on a
**real iPhone, installed (not Simulator), screen locked**:
1. Start brown noise + an episode, lock, leave overnight → still playing in the morning.
2. Mid-session phone call → after it ends, podcast resumes on its own at the right rate.
3. Pull earbuds out → binaural mutes, brown noise keeps playing on the speaker (does
   NOT pause the whole mix).
4. Load a dead/garbage episode URL → visible failure, queue advances, app stays alive.
5. Start a sleep timer, **lock the screen**, and wait for expiry → verify the timer fires while locked, fades over the final 10 minutes, everything stops, and saved per-source volumes are intact on next launch.

---

# UI/UX v2 — simple but robust controls

Goal: the app is operated **in the dark, half-asleep**. Every control must be large,
unambiguous, and hard to trigger by accident. The current screen is *capable* but
over-supplied (duplicate transports), small (sub-44pt targets), and the theming is
hardcoded (so "Bedtime" can't really dim anything). Do these in order — **U1–U3 are
the high-leverage ones.**

Design rules for everything below:
- Minimum tappable area **44×44pt** for any control.
- No raw color literals in views — use the `Theme` palette (U3).
- Every icon-only button gets an `accessibilityLabel`; every slider is accessible.
- One control per job. If two surfaces do the same thing, delete one.

---

## U1 — Consolidate the podcast transport (highest leverage)

**Problem:** the podcast can be played/paused from 3 places (giant button, Podcast
mixer-row toggle, mini-player) and seeked from 2 (Home ±15 row at `HomeView` ~178–193
**and** the mini-player). Both seek rows render at once while playing. Redundant and
cluttered.

**Target model — one control per job:**
- **Mini-player = the podcast transport.** It owns play/pause, seek ±15, title, and
  (U6) a scrubber. It is the *only* podcast-specific transport.
- **Delete the Home ±15 seek row** (`HomeView` ~178–193).
- **Podcast mixer row** becomes on/off + volume only, exactly like the noise and
  binaural rows (it already routes through `togglePodcast()` — keep that, drop any
  seek affordance from Home).
- **Giant button** stays the master transport (all layers) — see U2.

Acceptance: when a podcast plays, there is exactly one seek control (mini-player) and
the Home screen below the giant button is just: timer, breathing, then the mixer panel.

---

## U2 — Make the master button's state model unambiguous

**Problem:** `toggleMasterTransport` restores a *stale* layer snapshot. Pause-all →
toggle a layer via its row → press play restores the old snapshot, contradicting what
the user just did. Also the button has no accessibility label and no "what's on" cue.

**Fixes:**
1. Single source of truth. When master-paused, either (a) disable the per-layer
   toggles, or (b) have any per-layer change update `lastActiveSnapshot`. Prefer (b):
   in `noiseOn`/`binauralOn`/`isPodPlaying` `didSet`, if not currently in a master-pause
   transition, refresh the snapshot. The invariant: **pressing play resumes exactly the
   set that was on at the last pause, and manual edits while paused are honored.**
2. Add `.accessibilityLabel(audio.isAnythingPlaying ? "Pause all audio" : "Play")` to
   the giant button.
3. Add a one-line **status summary** directly under the giant button, e.g.
   `Brown + Delta · Podcast paused · 28m` — built from `noiseOn/binauralOn/isPodPlaying/
   timerRemaining`. Glanceable state without scanning three rows. Dim it in Bedtime.

Acceptance: the giant button's behavior always matches the visible toggles; VoiceOver
announces it; the user can read current state in one line.

---

## U3 — Centralize colors into a `Theme`, then make Bedtime real

**Problem:** `Color(red: 0.9, green: 0.7, blue: 0.4)` (the gold) is hand-typed ~40×
across views. Because nothing is tokenized, **Bedtime mode can only recolor the few
spots that were special-cased** — the mixer panel, sliders, chips, and white body text
stay full brightness, so Bedtime is nearly a no-op below the header.

**Fix A — palette.** Add `Sleepulator/Sleepulator/Views/Theme.swift`:

```swift
import SwiftUI

enum Theme {
    // Day (normal) values
    static let gold     = Color(red: 0.90, green: 0.70, blue: 0.40)
    static let bg       = Color.black
    static let text     = Color.white
    static let textDim  = Color.gray

    // Bedtime (low-luminance, red-shift-safe) values
    static let bedGold  = Color(red: 0.54, green: 0.47, blue: 0.38)
    static let bedBg    = Color(red: 0.10, green: 0.08, blue: 0.05)
    static let bedText  = Color(red: 0.66, green: 0.60, blue: 0.52)
    static let bedDim   = Color(red: 0.40, green: 0.36, blue: 0.32)
}
```

Provide a resolver so views ask for a role, not a literal, given `bedtimeMode`:

```swift
struct Palette {
    let bedtime: Bool
    var accent: Color { bedtime ? Theme.bedGold : Theme.gold }
    var bg: Color      { bedtime ? Theme.bedBg   : Theme.bg }
    var text: Color    { bedtime ? Theme.bedText : Theme.text }
    var dim: Color     { bedtime ? Theme.bedDim  : Theme.textDim }
}
```

Pass a `Palette(bedtime: bedtimeMode)` down (or expose via `@Environment`). Replace
**every** raw gold/white/gray literal in `HomeView`, `MiniPlayerView`, `Components`,
`LibraryView`, `SettingsView`, `PodcastDetailView` with `palette.accent/.text/.dim`.

**Fix B — Bedtime actually dims.** With the palette in place, Bedtime should: dim all
text to `bedText`/`bedDim`, switch accent to `bedGold`, reduce slider/chip contrast,
and drop the glass-panel glow/shadow (or lower its opacity). Goal: noticeably darker
*everywhere*, not just the header. Reconsider showing the breathing orb *in* Bedtime
(calming visual belongs at bedtime) rather than only when awake.

Acceptance: toggling Bedtime visibly dims the entire screen; no `Color(red:…)` literals
remain in the view files (grep check).

---

## U4 — Fix the sliders (reachability + accessibility + consistency)

**Problem:** `WarmSlider` only responds to a drag that *starts on the 24pt thumb* — no
tap-to-set, no track drag, 24pt < 44pt target, and zero accessibility. Meanwhile master
volume uses a native `Slider`, so there are two slider styles.

**Fix (pick one, prefer A):**
- **A — adopt native `Slider` everywhere.** Style it with `.tint(palette.accent)` and a
  ≥44pt row. Accessible and tap-anywhere for free; kills the inconsistency.
- **B — keep `WarmSlider` but make it robust:** put a transparent ≥44pt-tall drag layer
  over the whole track; support tap-to-set (not just drag); move the `DragGesture` to the
  track, not the thumb; add `.accessibilityElement`, `.accessibilityValue("\(Int(value*100))%")`,
  and `.accessibilityAdjustableAction`.

Acceptance: a tap anywhere on any volume track sets it; VoiceOver can read and adjust
every slider; one slider style across the app.

---

## U5 — Tame the always-on chips

**Problem:** 8 noise + 4 binaural chips are always visible under each row — lots of live
controls, easy to mis-swipe at night, and the horizontal chip `ScrollView` nested in the
vertical page scroll fights for gestures.

**Fix:**
- Collapse chips by default; reveal on tapping the row's title/name (disclosure), or only
  show a layer's chips when that layer is **on**.
- Show the current selection as a small label on the row when collapsed (e.g. the noise
  row already shows `noiseType.capitalized` — keep that as the resting display).
- This removes the nested-scroll gesture conflict because the chips aren't in the scroll
  path at rest.

Acceptance: resting Home shows no chip rows (just the current selection per layer);
expanding a layer reveals its chips; no accidental horizontal-scroll hijack.

---

## U6 — Mini-player: scope it, make it tappable, unify insets

**Problem:** it appears whenever a queue exists (shows "Paused" during noise-only
sessions), tapping it does nothing, and each tab reserves a different bottom inset
(Home 120 / Library 100 / Settings 100).

**Fix:**
- Show the mini-player **only when a podcast item is loaded** (`audio.podPlayer.hasPlayer`
  / a dedicated `audio.hasLoadedEpisode` flag), not merely when a queue exists.
- Make tapping it open a full now-playing sheet (title, scrubber bound to
  `changePlaybackPosition`, speed, ±15, queue) — or, minimum viable, deep-link to the
  Podcasts tab scrolled to the current episode.
- Add a thin progress scrubber to the mini-player bound to elapsed/duration.
- Define one constant `miniPlayerInset` and apply it as the bottom content inset on all
  three tabs so content never hides behind it.

Acceptance: mini-player only shows with a real episode; tapping expands to full controls;
no tab clips its last row behind it.

---

## U7 — Touch targets + accessibility sweep

- Bump every icon button (seek, mute, bedtime toggle, chip, queue delete) to a 44×44pt
  tappable area with adequate spacing.
- `accessibilityLabel` on all icon-only buttons.
- Replace fixed `.font(.system(size: 10/12, …))` with scalable text styles
  (`.caption2`, `.caption`) so Dynamic Type works (e.g. the "RESUME LAST NIGHT" label).
- Verify secondary gray-on-near-black text meets WCAG AA; bump dim values if not.
- Optional: run the `design:accessibility-review` skill for a formal WCAG pass.

Acceptance: VoiceOver can operate the whole Home screen; controls are reachable in the
dark; text scales with Dynamic Type.

---

## UI/UX v2 priority

1. **U1** (consolidate podcast transport) — removes the most clutter/confusion.
2. **U4** (sliders) — biggest reachability/accessibility win for night use.
3. **U3** (Theme + real Bedtime) — makes the comfort feature actually work; unblocks consistent theming.
4. **U2** (master button state + status line) — robustness + clarity.
5. **U5** (collapse chips), **U6** (mini-player), **U7** (targets/a11y) — polish.

---

# Podcast browser v2 — richer data + cleaner IA

Goal: the podcast side currently *works* but feels thin — subscriptions are named after
URL hosts, there's no artwork, no durations, no dates, and one screen does four jobs.
The controls are fine; the problem is **discarded feed metadata** and **information
architecture**. Do **B1 first** — it's the root unlock that makes everything else
visible. B2/B3 are the IA cleanup; B4–B6 are enrichment and polish.

File shorthand adds:
- "Parser" = `Sleepulator/Sleepulator/Services/PodcastParser.swift`
- "Library" = `Sleepulator/Sleepulator/Views/LibraryView.swift`
- "Detail" = `Sleepulator/Sleepulator/Views/PodcastDetailView.swift`
- "Models" = `Sleepulator/Sleepulator/Models/Models.swift`

---

## B1 — Enrich the feed parser (root unlock, do first)

**Problem:** `Parser` extracts only `title`, enclosure `url`, `guid`, `description`. It
ignores channel title, artwork, pub date, and duration. Consequences today: podcasts
are named after the URL host (`feeds.simplecast.com`), `EpisodeRowView` renders
`ep.pubDate` that is **always nil** (dead UI), `Episode.duration` is never populated,
and there's no artwork anywhere. `Episode.duration` and `Episode.pubDate` already exist
on the model — the parser just never fills them.

**Add to Models** (artwork fields don't exist yet):

```swift
struct Podcast { … ; var artworkUrl: String? = nil }   // channel image
struct Episode { … ; var artworkUrl: String? = nil }    // item image (falls back to channel)
```

**Parse these RSS/iTunes tags in `Parser`:**
- Channel `<title>` → return it from `parseFeed` (change the signature to return
  `(title: String, artworkUrl: String?, episodes: [Episode])`, or a small `ParsedFeed`
  struct). `Library.loadFeed` must use this for `Podcast.name` instead of `url.host`.
- Channel image: `<itunes:image href="…">` (attribute) or `<image><url>…</url></image>`.
- Per-item:
  - `<pubDate>` → parse RFC 822 with a `DateFormatter` (`EEE, dd MMM yyyy HH:mm:ss Z`,
    `Locale(identifier: "en_US_POSIX")`). Set `Episode.pubDate`.
  - `<itunes:duration>` → may be seconds (`"1832"`) or `HH:MM:SS` / `MM:SS`. Parse both
    into `Episode.duration` (TimeInterval).
  - `<itunes:image href>` (item-level) → `Episode.artworkUrl`, fall back to channel.
- **Sort episodes newest-first** by `pubDate` before returning.

Note: `foundCharacters` can arrive in fragments — keep accumulating into the current
buffer (already done for title/description); do the same for `pubDate`/`duration`.

Acceptance: a freshly added feed shows the real show name, channel art, and each
episode shows a real date + duration; newest episode is first.

---

## B2 — Split "Saved Mixes" from podcast playlists (fix the concept)

**Problem:** `SavedMix` is a *sound-environment* snapshot (noise + binaural + volumes +
one podcast URL). But it lives under the Podcasts tab and the **"Save Mix"** button is
in the **Up Next** header, implying it saves the *queue* — it doesn't (it never stores
`[Episode]`). Two distinct concepts are conflated and misplaced.

**Fix:**
- **Move "Saved Mixes" off the Podcasts tab** — they're sound presets; surface them on
  Home/Mixer (e.g. under the mixer panel) or Settings. Keep `resumeMix` as-is.
- **Remove the "Save Mix" button from the Up Next header** (it's misleading there).
- If you want **podcast playlists** (optional, nice-to-have): add a `Playlist` model
  (`id, name, episodes: [Episode]`), a "Save queue as playlist" action, and a playlists
  list that reloads the ordered episodes into the queue. Keep this separate from
  `SavedMix`.

Acceptance: sound presets and podcast content are no longer mixed on one screen; no
button claims to save something it doesn't.

---

## B3 — Declutter the Podcasts tab (information architecture)

**Problem:** one `List` does four jobs: add-feed field, Up Next queue, Saved Mixes,
subscriptions.

**Target layout:**
- **Subscriptions become the primary content** of the tab (the actual browser).
- **Up Next** moves into the now-playing surface — add an "Up Next" list inside
  `NowPlayingSheet` (swipe up from the mini-player), which is where people look for the
  queue. Keep reorder/swipe-delete there.
- **Add feed** becomes a **"+" toolbar button** → sheet (drop the always-visible text
  field and the hardcoded default-feed pre-fill).
- **Saved Mixes** leave per B2.

Acceptance: the Podcasts tab opens to a clean subscription browser; adding a feed is a
"+" action; the queue lives with the player.

---

## B4 — Make the subscription list browser-grade

**Problem:** subscriptions are a manual `VStack`/`ForEach` (not a `List` section), so
no swipe-to-delete, no reorder, no native polish (just a trash button); no artwork, no
search, no sort, no refresh.

**Fix:**
- Render subscriptions as a real `List`/`Section` with `.onDelete` (swipe) — drop the
  trash button — and artwork thumbnails via `AsyncImage(url:)` (from B1's `artworkUrl`).
- **Search** with `.searchable` (essential after an OPML import of many shows).
- **Sort** control: recently updated / A–Z.
- **Pull-to-refresh** (`.refreshable`) to re-fetch episodes across subscriptions.
- Optional: per-show "new / unplayed" count.

Acceptance: subscriptions are searchable, swipe-deletable, show art, and refresh on pull.

---

## B5 — Enrich episode rows with state you already have

**Problem:** `EpisodeRowView` shows only title + (nil) date + a download checkmark, even
though you persist per-episode playback position (`cachedPositions`) and download state.

**Fix:**
- Show **duration + relative date** ("2d ago · 47 min") from B1 data — directly helps
  pick a bedtime-length episode.
- Show **in-progress / played** state from `cachedPositions`: a thin progress bar or a
  "23 min left" / "Played" label, so the browser remembers the listener.
- Show episode artwork thumbnail if present.

Acceptance: each episode row communicates length, recency, and listen progress at a glance.

---

## B6 — Smaller related fixes

- `NowPlayingSheet`: add **next/previous episode** buttons (it only has ±15s) and the
  inline Up Next list from B3.
- `description` is parsed but displayed nowhere now — show it in Detail (expandable) or
  in `NowPlayingSheet`.
- `Detail` shows the offline wall even when episodes are cached — if `!isOnline` but
  `podcast.episodes` is non-empty, show the cached episodes anyway.
- Remove dead `expandedEpisodeId` state in `Library`.
- `cover art` in `NowPlayingSheet` currently uses the **app icon** — switch to the
  episode/show `artworkUrl` (B1), falling back to the app icon.

---

## Podcast browser v2 priority

1. **B1** (parser) — unlocks names, art, dates, durations everywhere. Do first.
2. **B2 + B3** (split mixes/playlists, declutter IA) — fixes the conceptual confusion.
3. **B4** (browser-grade subscriptions) — search/art/refresh/swipe.
4. **B5** (episode-row state) — leverage the position data you already store.
5. **B6** (polish) — next/prev, descriptions, offline-with-cache, cover art.

---

# Noise curation (NC)

> **SUPERSEDED (2026-06-22) by AUDIO-PALETTE-SPEC.md.** This section cut green/white/forest down
> to 5 sounds and had `NoiseType.migrate` fold them away. The later audio-palette work deliberately
> reversed that: green/forest are back as **re-implemented** generators (mid-band green, 20-second
> breeze-swell forest — not the old brown-dupe / 4.2 Hz tremolo this section rightly flagged), gray
> was added for Focus, and `migrate` no longer folds anything. Live palette is now 6 Sleep + 4 Focus
> sounds. Kept here as history — and the critiques below are still a useful ear-test checklist for
> the new green/forest.

Goal: trim the 8 noise types to a tight, distinct set. Several are the same engine
with a tweaked knob: **Green** is just Brown with a higher cutoff (near-duplicate),
**White** is harsh/alerting, **Forest** uses a ~4.2 Hz tremolo that reads as restless.
Keep the 5 that are sonically distinct and sleep-appropriate.

**Final set (order matters — this is the selectable list):**
`["brown", "pink", "rain", "ocean", "fan"]`

- Brown — deep rumble (sleep favorite)
- Pink — balanced/natural (sleep favorite)
- Rain — bright steady texture (distinct)
- Ocean — brown + slow swell (distinct)
- Fan — brown + 60 Hz hum (common real-world sleep sound; note: the hum only
  reproduces on headphones/decent speakers, not the phone speaker)

**Cut: `green`, `white`, `forest`.**

### NC1 — Update the selectable lists (UI)
- `HomeView`: the noise `WarmMixerRow` `options:` → `["brown","pink","rain","ocean","fan"]`.
- `SettingsView`: `noiseOptions` → same 5.
- No grouping needed at 5 items (it's a Menu now). If you later keep more, group as
  a `Menu` with two `Section`s ("Noise": brown/pink, "Ambience": rain/ocean/fan).

### NC2 — Migrate stored values (don't break saved mixes)
Old installs may have `noiseType` (and `SavedMix.noiseType` / `lastMix.noiseType`)
set to a removed key. Add a normalizer and run it wherever a noise type is read in
from persistence:

```swift
enum NoiseType {
    static let valid: Set<String> = ["brown","pink","rain","ocean","fan"]
    static func migrate(_ raw: String) -> String {
        switch raw {
        case "green": return "brown"   // green was brown-with-higher-cutoff
        case "white": return "pink"    // gentler full-spectrum replacement
        case "forest": return "rain"   // both are filtered-white textures
        default: return valid.contains(raw) ? raw : "brown"
        }
    }
}
```

Apply in `AudioEngine.init` when loading `noiseType`, and when decoding any
`SavedMix`/`lastMix` (map `mix.noiseType` through `NoiseType.migrate`). This is
required — a stored "green"/"white"/"forest" must resolve to a valid case or the
chip/menu shows nothing selected and the engine falls through to brown silently.

### NC3 — Remove the dead generators (optional cleanup)
Once migration is in, the `green`/`white`/`forest` cases in
`GenerativeAudioEngine`'s render switch and `mapNoiseType` are unreachable. Removing
them is optional (they're harmless if left), but it's a clean reduction. If you
remove them, keep `default` → brown so any unexpected value is safe.

### NC4 — Stereo decorrelation (optional quality win)
All generators currently write `ch1 = ch0` (mono). For ambient sleep noise,
generating **independent** noise per channel makes it sound wider and less
"pressing on the eardrums." With fewer types this is worth doing: give the render a
second PRNG state (`rng2`) and per-channel filter state, and compute `ch1` from its
own stream instead of copying `ch0`. (Binaural stays as-is — it needs its specific
L/R phase relationship.) Quality-over-quantity: 5 stereo sounds beat 8 mono ones.

Acceptance: only the 5 curated sounds are selectable; a saved mix referencing a cut
type loads as its migrated equivalent (not blank); (if NC4) ambient sounds noticeably
wider in headphones.
