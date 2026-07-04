# Apple Music (Focus) — Handoff

Picking this up in Xcode. Everything below was written in an environment that **could not compile
or run** it, so treat the first real build + device pass as the source of truth.

- **Commit:** `a428cd3` on `main` — "Add Apple Music as a Focus-only mixer source; fix Swift 6 isolation warnings"
- **Design doc:** `APPLE-MUSIC-FOCUS-SPEC.md` (rationale, architecture, decisions)
- **Status:** implemented in code; **unverified on device**; one manual portal step required.

## TL;DR of the approach

Apple Music catalog audio is DRM-protected → no PCM → it can't go through the `AVAudioEngine`
mixer or the Night Limiter tap like podcasts do. So it runs as a **parallel** system player
(`MusicKit.ApplicationMusicPlayer`) **alongside** the generative bed, with the audio session
switched to `.mixWithOthers` while music plays, and the noise+binaural bed **ducked** beneath it.
Scoped to **Focus only** (the limiter is already off there; it's not the all-night locked case).

## Do this first (blocks everything)

1. **Enable MusicKit on the App ID.** Apple Developer portal → Certificates, Identifiers &
   Profiles → identifier `app.sleepulator.Sleepulator` → App Services → check **MusicKit** → save.
   This is server-side, *not* a code-signed entitlement — there is nothing to add to the project
   file. Without it, auth/search fail at runtime even though the code is correct.
2. **Regenerate/refresh the provisioning profile** if you use manual signing (automatic signing
   picks it up on next build).
3. Confirm a test device is signed into an account with an **active Apple Music subscription**.

## Build expectations

- New files are picked up automatically (the project uses Xcode synchronized file groups — no
  `.pbxproj` edits were needed for the new sources).
- First compile is the real check. **Most-likely-to-need-a-tweak spots** (MusicKit API drift across
  SDK versions), all in `Services/AppleMusicPlayer.swift`:
  - `player.queue = [item]` (array-literal queue assignment) — if it complains, use
    `ApplicationMusicPlayer.Queue(for: [item])`.
  - `ArtworkImage(artwork, width:height:)` in `Views/AppleMusicPickerView.swift`.
  - `entry.title` / `entry.subtitle` on `MusicPlayer.Queue.Entry`.
  - `player.state.objectWillChange` / `player.queue.objectWillChange` observation.
- The Swift 6 isolation fixes assume **Swift 6.2 / Xcode 26** (your project already sets
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + `SWIFT_APPROACHABLE_CONCURRENCY`, both 6.2). If the
  toolchain is older, `nonisolated struct`/`nonisolated class` won't parse — tell me and I'll
  switch to per-member `nonisolated`.

## Device verification gate (the real test — per CLAUDE.md)

Install on a **real iPhone**, then verify:

1. In Focus, pick something in the Apple Music sheet → music + generative noise play
   **simultaneously**; the bed audibly **ducks** when music starts and rises when it stops.
2. **Lock screen** shows the *music* now-playing/transport — no fight with the podcast info center.
3. Switch **Focus → Sleep**: music **stops** and the session reverts to exclusive `.playback`.
   Then confirm Sleep is unaffected — start a noise+binaural bed, set a sleep timer, lock the
   screen, and let it fade + terminal-stop normally. **This is the regression that matters most**
   (the session-category change is the risky bit).
4. Interruption (phone call) and route change (unplug headphones) recover sanely with music active.
5. Deny Apple Music permission on first prompt → app shows a gentle note, rest of the Focus mix
   keeps playing (no hard failure).

Until this passes, mark it **shipped-but-unverified-on-device** in any release notes.

## Files changed (commit a428cd3)

New:
- `Services/AppleMusicPlayer.swift` — MusicKit wrapper: auth, subscription check, catalog search,
  queue + transport, now-playing callbacks.
- `Views/AppleMusicPickerView.swift` — search-to-play catalog sheet.

Modified:
- `Services/AudioSessionController.swift` — `AudioSessionConfig` (single owner of the session
  category options).
- `Services/GenerativeAudioEngine.swift` — `setupEngine` reads `AudioSessionConfig` so a generative
  restart can't drop `.mixWithOthers`.
- `Services/AudioEngine.swift` — Focus-only source: `appleMusic`, `appleMusicOn`/`appleMusicTitle`/
  `hasAppleMusicSelection`, `startAppleMusic`/`toggleAppleMusic`/`stopAppleMusic`/
  `setAppleMusicMixing`/`searchAppleMusic`/`ensureAppleMusicAuthorized`, Focus→Sleep teardown,
  `pauseAll`/`stopAll` hooks, now-playing arbitration, and **duck-the-bed** in `syncAllVolumes`.
- `Services/PodcastPlayer.swift` — `suppressNowPlaying` so MusicKit owns the lock screen.
- `Views/HomeView.swift` — `AppleMusicMixRow` (Focus-only) + picker sheet.
- `Info.plist` — `NSAppleMusicUsageDescription`.
- `Models/Models.swift`, `Services/OPMLParser.swift`, `Views/SettingsView.swift` — `nonisolated`
  fixes for the Swift 6 warnings (unrelated to Apple Music but in the same commit).

## Tunables / knobs

- **Duck depth:** `AudioEngine.musicDuckLevel` (currently `0.45`, ≈ −7 dB). Adjust by ear on device.
- **Transport mutual-exclusion:** starting Apple Music pauses any podcast (one spoken/music owner).
  If you want them to truly coexist, revisit `startAppleMusic` / `toggleAppleMusic`.

## Deferred / not done (candidates for the next pass)

- **Subscribe upsell** for non-subscribers (currently just a note; `AppleMusicPlayer.canPlayCatalog()`
  exists to gate it).
- **Master transport / Resume-Last-Night** doesn't include Apple Music — it's intentionally outside
  `isAnythingPlaying` and the resume snapshot. Wiring it in means persisting the selection.
- **Persistence:** the music selection lives only in `ApplicationMusicPlayer`'s queue and is **not**
  saved across launches — fresh each session by design.
- **Library/recently-played browsing** — v1 is search-only.

## Repo / git caveat (only relevant in the assistant sandbox)

The commit was made through a mount that allows writes but **blocks file deletion**, so git couldn't
remove its own `.lock` files and left a few `*.lock.stale-*` files in `.git/`. They're inert. Running
git natively on your Mac is unaffected; if you ever see "index.lock exists," `rm .git/index.lock`.

## Other uncommitted work in the tree (not mine, left untouched)

Pre-existing modified files (`AudioMath`, `Log`, `MixStore`, `StorageManager`, `PersistenceMigrator`,
`PodcastQueueManager`, the `.metal` shaders, `ContentView`, `MiniPlayerView`, `PodcastDetailView`,
`AudioStateTests`) and untracked files (`IMPLEMENTATION-PLAN-2026-06-24.md`,
`SESSION-HANDOFF-2026-06-24.md`, `BreathingOnRampView.swift`, `PersistenceTests.swift`) are **not**
part of `a428cd3` — commit those separately.
