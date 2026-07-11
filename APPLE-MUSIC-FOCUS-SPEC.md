# APPLE-MUSIC-FOCUS-SPEC

Adding Apple Music as a mixer source in **Focus mode**. Status: **implemented in code,
unverified on device** (cannot be compiled or device-tested in the authoring environment; see
Verification gate). One manual portal step remains — see Entitlements.

## Goal

Let a Focus session layer the user's Apple Music alongside generative noise + binaural,
the way podcasts layer today. Scoped to Focus only.

## The constraint that shapes everything

Apple Music catalog tracks are **DRM-protected**. They cannot be loaded into `AVPlayer` /
`AVAudioEngine`, so the app gets **no PCM access**. This rules out the entire podcast model:

- Apple Music audio **cannot** flow through `GenerativeAudioEngine`'s `AVAudioSourceNode` mixer.
- The Night Limiter `MTAudioProcessingTap` (`PodcastPlayer.makeLimiterTap`) **cannot** attach to it.
- The per-sample `volume` / `fadeInGain` path (`PodcastPlayer.applyVolumeToStates`) does not apply.

So Apple Music is **not** a true channel in the mixer. The only viable design is a **parallel
system player** (`MusicKit.ApplicationMusicPlayer`) playing simultaneously, with the app's
audio session set to mix.

This is acceptable specifically for **Focus** because:

- The Night Limiter is already off in Focus (`applyLimiterForMode`, Sleep = on / Focus = off),
  so losing the tap costs nothing here.
- Focus is the awake / Pomodoro case, not the all-night screen-locked case that drives the
  app's hardest invariants. Missing fade-out and per-source balance matter far less.

## Non-goals

- No Apple Music in Sleep mode (would lose the limiter, which Sleep depends on).
- No sample-level mixing, EQ, or limiting of Apple Music audio (impossible — see above).
- No re-hosting or caching of Apple Music content (prohibited by Apple).
- No sleep-timer fade-out *of the music itself* in v1 (the music is paused, not faded — see Edge cases).

## Architecture

### 1. Audio session: allow mixing

Today the session is `.playback` with **no options**, set in two places:
`AudioSessionController.activateSession` (line 27) and `GenerativeAudioEngine` (line 350). With no
`.mixWithOthers`, the app interrupts other audio, so Apple Music could not coexist.

Change: when Apple Music is the active Focus source, the session must use
`.playback` with `[.mixWithOthers]`. Two sub-decisions:

- **Scope it.** Only enable `.mixWithOthers` while Focus + Apple Music is active; revert to
  the current exclusive `.playback` otherwise (esp. when returning to Sleep). `.mixWithOthers`
  changes interruption/ducking behavior app-wide, so it should not be the permanent default.
- **Single owner.** The category is currently set in two files. Route the option through one
  path (extend `AudioSessionController`) so generative re-activation (`GenerativeAudioEngine`
  line 573) doesn't silently reset the option mid-session.

### 2. New service: `AppleMusicPlayer`

A sibling to `PodcastPlayer` under `Services/`, owning the MusicKit integration. Surface mirrors
`PodcastPlayer`'s closure-callback style so `AudioEngine` can wire it the same way.

```
final class AppleMusicPlayer {
    // auth
    func requestAuthorization() async -> Bool        // MusicAuthorization.request()
    var isAuthorized: Bool                            // MusicAuthorization.currentStatus == .authorized

    // content selection (Focus picker)
    func setQueue(_ items: ...) async                 // ApplicationMusicPlayer.shared.queue = ...
    func play() async
    func pause()
    func stop()
    var isPlaying: Bool

    // callbacks (match PodcastPlayer)
    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onNowPlayingChanged: ((String, String) -> Void)?   // title, artist
}
```

Uses `ApplicationMusicPlayer.shared` (app-scoped queue, app controls the now-playing info)
rather than `SystemMusicPlayer` (shares state with the Music app). `ApplicationMusicPlayer` is
the right choice so Focus controls its own queue without hijacking the user's Music app session.

### 3. Now-Playing & remote-command arbitration

`PodcastPlayer` already owns `MPRemoteCommandCenter` targets and writes
`MPNowPlayingInfoCenter.default().nowPlayingInfo` (`setupRemoteCommands`, `updateNowPlaying`).
`ApplicationMusicPlayer` **also** drives the system now-playing info and lock-screen transport.
Two writers = a lock-screen fight.

Rule: **at most one transport owner at a time.**

- Focus + Apple Music active → let MusicKit own now-playing; have `PodcastPlayer` *not* publish
  now-playing info (it shouldn't be playing in Focus anyway — podcasts are a Sleep/Library flow,
  but assert it explicitly).
- Returning to podcast/Sleep → `PodcastPlayer` reclaims now-playing on its next `updateNowPlaying`.
- Generative-only → unchanged (no now-playing info today).

Concretely: gate `PodcastPlayer.updateNowPlaying` so it no-ops while Apple Music is the active
source, and have `AppleMusicPlayer` not fight back (MusicKit manages its own info center).

### 4. `AudioEngine` integration

`AudioEngine` is the facade that owns sources and policy. Add Apple Music as a Focus-only source:

- Hold an `AppleMusicPlayer` instance; forward its `objectWillChange`-equivalent via callbacks,
  **not** `@Published` high-frequency values (respect the coarse-`ObservableObject` rule in
  CLAUDE.md — keep playback-position churn out of `@Published`).
- `reconcileSoundsToMode` already snaps sounds to the mode palette and drops cross-mode layers.
  Mirror that: **leaving Focus must stop Apple Music and revert the session option.** Add the
  teardown to the `focusMode` `didSet` path (line 269) next to `applyLimiterForMode()`.
- `syncAllVolumes` (line 304) currently fans master/fade/mute into `genEngine` + `podPlayer`.
  Apple Music volume is **not** controllable per-source here (see Volume below), so it is
  deliberately excluded from `syncAllVolumes`; document that asymmetry inline.

### 5. Volume & balance (the honest limitation)

`ApplicationMusicPlayer` does not expose a clean per-instance output volume. It plays at the
device/system music volume. Consequences to surface in UI, not hide:

- The Focus "music" slider can't behave like the noise/binaural/podcast sliders. Options:
  (a) ship **no** in-app music slider and label it "controlled by your device volume", or
  (b) lower the *generative* bed under the music (duck noise/binaural when music plays) so the
  user balances by raising/lowering the noise, not the music. Recommend (b) as the v1 balance story.
- `masterVolume` / `isMuted` / sleep-timer `fadeMultiplier` reach `genEngine` and `podPlayer`
  but **not** Apple Music. Mute and master will not affect the music. State this in the UI.

### 6. Entitlements & auth

- **MusicKit is NOT a code-signed entitlement.** It is enabled server-side on the App ID's
  **App Services** (Apple Developer portal → Certificates, Identifiers & Profiles → the app's
  Identifier → App Services → check **MusicKit**). There is no `.entitlements` file key, so
  nothing to add to `project.pbxproj`. ← **the one remaining manual step before this runs.**
- `NSAppleMusicUsageDescription` **is** required and is file-editable — added to `Info.plist`.
- `MusicAuthorization.request()` runs on first use (`AppleMusicPlayer.ensureAuthorized`); denied /
  restricted is surfaced as a gentle note via the existing `playbackNote` path, not a hard failure.
- Active subscription needed at playback; `AppleMusicPlayer.canPlayCatalog()` wraps
  `MusicSubscription.current.canPlayCatalogContent` for optional UI gating.

## Edge cases

- **Sleep timer ends (if a timer is ever set in Focus).** The fade ramps the generative bed and
  podcast via `fadeMultiplier`; Apple Music can't be smoothly faded. v1: **pause** Apple Music at
  terminal stop instead of fading it. Acceptable in Focus (awake). Note it as a known rough edge.
- **Interruptions / route changes.** MusicKit handles its own session interruptions; verify the
  app's interruption handler (`AudioEngine` line 899+) doesn't pause the music or double-handle.
- **User opens the Music app.** `ApplicationMusicPlayer` keeps its own queue; confirm behavior
  when the user starts playback in Music directly (expected: independent, but verify).
- **Backgrounding / screen lock.** Focus is foreground-ish, but confirm music + generative both
  survive a lock with `.mixWithOthers` set.
- **No subscription / region without Apple Music.** Hide or disable the source cleanly.

## Phasing

1. **Spike (de-risk):** `.mixWithOthers` + `ApplicationMusicPlayer` playing a hardcoded queue
   alongside generative noise on a real device. Confirm they actually coexist and the lock-screen
   transport isn't a mess. This is the make-or-break test.
2. **Service + auth:** build `AppleMusicPlayer`, authorization flow, MusicKit entitlement.
3. **AudioEngine wiring:** Focus-only source, mode teardown, now-playing arbitration.
4. **UI:** Focus music picker + the "device-volume / ducking" balance model, subscription gating.
5. **Polish:** terminal-stop pause, interruption verification.

## What was built (file by file)

- **`Services/AppleMusicPlayer.swift`** (new) — MusicKit wrapper: `ensureAuthorized`,
  `canPlayCatalog`, catalog `search`, `play(_:)` for any `PlayableMusicItem`, `resume`/`pause`/
  `stop`, and `onPlaybackStateChanged` / `onNowPlayingChanged` / `onNote` callbacks mirroring the
  system player's `state`/`queue` observables.
- **`Services/AudioSessionController.swift`** — added `AudioSessionConfig` (single source of truth
  for category options); `activateSession` now reads it instead of hardcoding `[]`.
- **`Services/GenerativeAudioEngine.swift`** — `setupEngine` reads `AudioSessionConfig.applyCategory()`
  so a generative (re)start can't drop `.mixWithOthers` mid-session.
- **`Services/AudioEngine.swift`** — `appleMusic` instance; `appleMusicOn` / `appleMusicTitle` /
  `hasAppleMusicSelection`; `startAppleMusic` / `toggleAppleMusic` / `stopAppleMusic` /
  `setAppleMusicMixing` / `searchAppleMusic` / `ensureAppleMusicAuthorized`; teardown on Focus→Sleep;
  hooks in `pauseAll` / `stopAll`; callbacks that drive now-playing arbitration.
- **`Services/PodcastPlayer.swift`** — `suppressNowPlaying` flag; `updateNowPlaying` yields to
  MusicKit while it's set.
- **`Views/AppleMusicPickerView.swift`** (new) — search-driven catalog browser (songs/albums/
  playlists), tap-to-play.
- **`Views/HomeView.swift`** — `AppleMusicMixRow` (CTA → on/off toggle, no volume slider) shown in
  MixPanel **only in Focus**, plus the picker sheet.
- **`Info.plist`** — `NSAppleMusicUsageDescription`.

**Balance model chosen:** option (b) — duck the generative bed under the music. Apple Music plays
at device volume (DRM, can't be level-shaped); when it's on, `AudioEngine.syncAllVolumes` pulls the
noise+binaural bed to `musicDuckLevel` (0.45 ≈ −7 dB) via the master multiplier, so the dip/rise is
per-sample smoothed. No in-app music slider; the row reads "Plays over your sounds · device volume."
The podcast isn't ducked (it's paused while music plays).

**Decisions taken (were open questions):**

1. Balance: duck-the-bed (b), `musicDuckLevel` tunable on device. No music slider (DRM).
2. Persistence: Focus music starts fresh each session (the selection lives only in
   `ApplicationMusicPlayer`'s queue, not persisted) — simplest, avoids restoring a stale queue.
3. Subscription gating: no offer-to-subscribe sheet in v1; denied auth / no subscription shows a
   gentle note and the rest of the Focus mix keeps playing.

## Verification gate

Per CLAUDE.md, audio/session/timer changes aren't provable in XCTest, and this code was **neither
compiled nor device-tested** in the authoring environment. Before trusting it:

0. **Do the manual step:** enable **MusicKit** on the App ID's App Services (portal). Without it,
   authorization/search fail at runtime even though the code is correct.
1. Build in Xcode (a real Swift compile is the first true check — watch for MusicKit API drift).
2. On a **real iPhone, installed**: Apple Music + generative noise audibly playing
   **simultaneously** in Focus.
3. Lock-screen transport shows the music and behaves (no podcast/music now-playing fight).
4. Switching Focus → Sleep **stops** the music and reverts the session to exclusive `.playback`
   (the limiter and all-night Sleep behavior must be unaffected afterward).
5. An interruption (phone call) and a route change (unplug headphones) recover sanely.

This is **shipped-but-unverified-on-device** until that pass is done.
