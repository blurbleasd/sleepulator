# SLEEPULATOR — agent guide

A native SwiftUI iOS app for falling asleep and focusing: layer generative ambient noise +
binaural beats, optionally mix in a podcast, and set a sleep timer that fades everything out.
Two moods — **Sleep** (warm "dusk") and **Focus** (cool, Pomodoro). Built for the hard case
that drives most decisions: **installed on iPhone, screen locked, playing all night.**

> The original React/Vite **PWA is archived** in `archive_webapp/` (not built or deployed).
> The server-side "Sleep Safe" ffmpeg proxy is **gone**, replaced by an on-device Night
> Limiter (see `AUDIO-LIMITER-SPEC.md`). The only live service is the Cloudflare **feed proxy**
> (`AppConfig.feedProxyUrl` in `AudioEngine.swift`).

## Layout (Xcode project at `Sleepulator/Sleepulator.xcodeproj`)
- **App** — `Sleepulator/Sleepulator/`
  - `SleepulatorApp.swift` (entry); `ContentView.swift` — the `TabView` root (Home / Podcasts / Settings).
  - `Views/` — SwiftUI screens + components (HomeView, LibraryView, PodcastDetailView,
    NowPlayingSheet, MiniPlayerView, SettingsView, BreathingView, the `AmbientScene` backdrop
    library, Components, Theme).
  - `Services/` — the engine + plumbing (below).
  - `Models/Models.swift` — `Podcast`, `Episode`, `SavedMix`, `NoiseType`.
  - `PrivacyInfo.xcprivacy`, `Info.plist`.
- **Widget** — `SleepulatorWidget/` (sleep-timer Live Activity).
- **Tests** — `SleepulatorTests/` (XCTest: `AudioMathTests`, `AudioStateTests`).

## Services (the core)
- `AudioEngine` — the app-facing `ObservableObject` facade. Owns UI state + policy, delegates
  to the engines below; forwards child `objectWillChange` (queue, timer, mixes).
- `GenerativeAudioEngine` — `AVAudioEngine` + `AVAudioSourceNode`. Renders noise/binaural on the
  **real-time render thread**, reading params **lock-free** via an atomic double-buffer.
- `PodcastPlayer` — `AVPlayer` + an `MTAudioProcessingTap` Night Limiter (loudness-bounded so
  spikes don't wake you). Owns remote commands, the time observer, and gapless preload.
- `AudioSessionController` — session activation + interruption / route / background observers.
- `SleepTimerService` (+ `PomodoroService`, `ChimePlayer`) — the fade-out sleep timer and the
  Focus Pomodoro. `AudioMath` holds the fade curve.
- `PodcastQueueManager`, `MixStore`, `PersistenceMigrator`, `StorageManager` (JSON file store),
  `AudioDownloader` (offline cache), `PodcastParser` / `OPMLParser` / `ITunesSearchManager`.

## Audio + state invariants (the hard-won stuff — change with care)
- **Never block the render thread.** It reads params lock-free; hand-offs are atomic. No locks,
  allocation, or `DispatchQueue` work inside the `AVAudioSourceNode` render block.
- **`AudioEngine` is a coarse `ObservableObject`** — *any* `@Published` change invalidates
  *every* observing view. Keep high-frequency values OUT of `@Published` (`rmsPower` is a plain
  property; the sleep-timer republish is throttled to 1Hz in `SleepTimerService.tick`). Don't
  give a view `@ObservedObject var audio` unless it actually displays engine state — that
  re-render storm is what overwhelmed the podcast list (`perf(podcasts)` fix, 2026-06).
- **The Night Limiter (on-device tap) replaced the server proxy.** Loudness-bounded so a loud
  podcast spike can't jolt you awake; it can follow the mode (on for Sleep, off for Focus).
- **Downloads live in Application Support**, not Documents (Apple 2.5.x: re-downloadable content
  must not be iCloud-backed). `isExcludedFromBackup`, ~2GB LRU cap (`AudioDownloader`).
- **Persistence is per-key JSON** via `StorageManager`; one oversized write must not abort the
  rest. `PersistenceMigrator` owns the fragile launch-time legacy reads.
- **Sound palettes are mode-scoped** — Sleep and Focus deliberately share no sounds
  (`AudioEngine.reconcileSoundsToMode`).

## Build / run
- **Native Xcode build** — open `Sleepulator/Sleepulator.xcodeproj`. NOT Capacitor/CLI; there's
  no `npm` / `cap sync` step (that was the archived PWA).
- Deployment target **iOS 17.0** (uses SwiftUI `Shader`/`.layerEffect`, `.contentMargins`).

## Verification gate (read before claiming an audio fix works)
Unit tests can't catch the iOS audio bugs (no real render thread / session in XCTest):
interruptions, route changes, background keep-alive, looping, the limiter, and the sleep-timer
**fade + terminal stop** are device-specific. Anything touching the engine, session, limiter, or
timer must be verified on a **real iPhone, installed, screen locked, over a full timer run.**
State clearly when something is shipped-but-unverified-on-device. (Note: `TESTING.md` still
describes the archived web PWA — there is no written native device-test pass yet.)

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
- Save progress, checkpoint, resume → invoke checkpoint
- Code quality, health check → invoke health
