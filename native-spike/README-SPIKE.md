# Sleepulator — native audio spike

A throwaway proof-of-concept to answer one question: **is native AVAudioEngine
audio rock-solid for the all-night, screen-locked use case on your actual
phone?** If yes, the full SwiftUI rewrite is worth it. If somehow not, we've
learned that cheaply before rewriting the UI.

This is **not** the real app or design — it's a bare test harness wired to every
engine feature so you can sleep with it for a night.

## What it proves
- **Background audio that never dies** — `.playback` session + the Background
  Audio capability keep the engine running with the screen locked all night.
- **Gapless, infinite ambient + binaural** — generated sample-by-sample in real
  time (`AVAudioSourceNode`), so there's no loop seam and no sample-rate floor
  (the two problems that caused the brown-noise "gap" and silent binaural in the
  PWA).
- **Real per-layer volume + a podcast mix slider** — no `volume`-is-locked
  workaround; every layer's gain is yours.
- **Sleep-timer fade** — same perceptual exponential taper as the web app.
- **Lock-screen Now Playing controls** — play/pause + skip ±15s from the lock
  screen / Control Center.
- **Auto-resume after an interruption** (a phone call) — this is the PWA's open
  "Gap 2" that the web platform can't fully solve.

## Run it (≈5 minutes)
1. On your Mac: **Xcode → File → New → Project → iOS → App.**
   - Product Name: `SleepulatorSpike`
   - Interface: **SwiftUI**, Language: **Swift**
2. Delete the auto-generated `ContentView.swift` and the `…App.swift`, then drag
   these three files into the project (check "Copy items if needed"):
   `SleepulatorSpikeApp.swift`, `ContentView.swift`, `AudioEngine.swift`.
3. **Enable background audio:** select the project → your target → **Signing &
   Capabilities → + Capability → Background Modes → check "Audio, AirPlay, and
   Picture in Picture."** (This adds `UIBackgroundModes: [audio]`.) Without this,
   audio stops when the screen locks.
4. Set your **Team** under Signing (your Apple Developer account) so it can run
   on a real device.
5. Plug in your iPhone, select it as the run target, **⌘R**.

> Use a **real device**, not the Simulator — the locked-screen / background test
> only means something on hardware.

## What to test tonight
- Start brown noise, lock the phone, leave it overnight → still playing in the morning?
- Put on headphones, toggle binaural → audible, smooth, no seam?
- Paste a direct `.mp3` episode URL, Load, play → mixes under the noise; lock the
  screen and use the lock-screen play/pause + skip buttons.
- Start the 2-minute timer → everything fades smoothly to silence and stops.
- While playing, call the phone (or ask someone to) → after the call ends, audio
  should resume on its own.

## Honest caveats (these are spike shortcuts, not blockers)
- The render callbacks touch `self` and use a simple PRNG — fine for a spike, but
  a production engine would make the audio thread fully lock-free (pass state via
  atomics / a parameter buffer). This won't affect your overnight judgment.
- Podcast uses `AVPlayer` for simple streaming; the real app might prefer
  `AVAudioPlayerNode` for downloaded files so it routes through the same mixer.
- No persistence, no feed parsing, no real UI — all deliberately out of scope.

If it feels great, the path is: keep the Cloudflare feed proxy (or drop it —
native can fetch RSS directly), retire the Render ffmpeg proxy (on-device
normalization), and rebuild the UI to the home IA we agreed on.
