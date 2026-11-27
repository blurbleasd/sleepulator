# Sleepulator 1.0: store text drafts

Drafts for the launch plan's B2 (privacy policy and support pages), B3 (the App Store listing:
name, subtitle, promotional text, description, keywords) and B4 (App Review notes),
`docs/designs/APP-STORE-LAUNCH-1.0.md`. Written against the code at the 1.0 branch; every claim
below is checked against it. Fill the **[OPEN: …]** inputs, then host the two pages (B2: any
static page works) and enter their URLs, the listing and the notes in App Store Connect.

Open inputs (the same ones the code waits on):
- **[OPEN: support address]**: also `AppInfo.supportEmail` in `Services/AppInfo.swift`.
- **[OPEN: privacy page URL]** and **[OPEN: support page URL]**: wherever the pages are hosted.
- **[OPEN: sample feed]**: optional, a public RSS feed for App Review to paste.

---

## App Store listing (draft for App Store Connect)

**Parked (2026-11-07):** the app is being built for personal use and isn't headed for submission
yet. Re-check every claim below against the code before using any of it.

Drafted 2026-11-07 from a `/last30days` scan of what people said about sleep-sound apps that
month (raw file: `~/Documents/Last30Days/sleep-sound-and-white-noise-apps-on-iphone-what-people-love-hate-and-wish-for-raw-v3.md`).
Each field is in a block to copy as is; its length against Apple's limit is under it.

**App name** (30 max). Words here are searchable, so they're left out of the keywords.

```
Sleepulator: Noise & Podcasts
```

29 / 30. Alternatives: `Sleepulator: Sleep Sounds` (25), or `Sleepulator` alone (11, which moves
"noise" and "podcasts" into the keywords).

**Subtitle** (30 max)

```
Sleep timer with a gentle fade
```

30 / 30.

**Promotional text** (170 max; it can change any time without a new version)

```
Fall asleep to a podcast with soft noise under it. When the timer ends, everything fades out and stops, and nothing starts up again at full volume.
```

**Description** (4,000 max)

```
Sleepulator is for falling asleep to something: soft noise, a podcast, or both at once. Choose how long the night lasts, press play and put the phone down. When the time is up, everything fades out over ten minutes and stops. Nothing starts up again at full volume.

THE SLEEP TIMER IS THE RING
Drag the ring around the play button to choose how long the night lasts, or leave it at All night. The timer starts on its own whenever sound starts: from the app, the lock screen, your AirPods or Siri. Need longer? Add 15 minutes from the lock screen without opening the app. Listening to an episode? Choose "Stop after this episode" instead. You can also have the podcast stop first and the noise carry on a little longer before it fades.

SOUND THAT DOESN'T LOOP
Every sound is generated live on your iPhone, so there's no loop to notice at 2 a.m. Sleep has Brown, Pink, Green, Rain, Ocean and Forest. Focus has Pink, White, Gray and Fan. Layer a noise with a binaural tone, set each level, and save the mix to start again with one tap.

PODCASTS, WITH NOISE UNDERNEATH
Search for any show or paste its feed, bring your subscriptions over from another app (OPML), and download episodes to play offline. Sleepulator remembers where you stopped. The noise plays under the podcast, so the quiet between sentences isn't silence.

A SCREEN THAT GOES DARK
While sound plays, the screen goes black a minute after your last touch. One tap brings back a dim glimpse of the timer; a second tap wakes the controls. Behind them, choose a slow scene: Night sky, Fireflies, Lamplight, Rain on glass, Still water, Aurora, Embers, Deep space or Breathe. As the night goes on, the scenes darken and settle.

FOCUS
Switch to Focus for Pomodoro sessions with their own sounds and scenes (Current, Tide, Sandfall, Contour). The session shows on your lock screen.

THE MORNING AFTER
After a night that played through, the Sleep screen shows one quiet line in the morning: how long the sound played and when it eased out.

PRIVATE
No account, no ads, no tracking. Your mixes, shows and nights stay on your iPhone. Podcast search goes to Apple, and episodes come straight from each show's publisher, as in any podcast app. Moving to a new phone? Export a backup file and restore it there.

FREE
Everything in Sleepulator is free. There's an optional tip jar, and tips unlock nothing. Sleepulator never asks for a rating or a tip at night.

A NOTE ON BINAURAL BEATS
They need headphones. They're here because many people find them pleasant to fall asleep or work to. Sleepulator doesn't claim they change your brain; the research is mixed.

Works with Siri ("Play Sleepulator", "Set a sleep timer in Sleepulator") and a Home Screen widget that resumes your last mix.
```

**Keywords** (100 max, commas, no spaces; leaves out the name's and subtitle's words)

```
white,brown,pink,binaural,rain,ocean,fan,focus,pomodoro,ambient,bedtime,nap,relax,mixer,soundscape
```

**Screenshot captions** (optional, one per screenshot, in this order)

1. Set the night on the ring
2. Soft noise under your podcast
3. It fades out, then stays off
4. A screen that goes dark
5. Focus, one session at a time

**Why it says what it says** (the research behind each line)

- *Fades out, stops, nothing starts again at full volume; the timer starts on its own; +15 from
  the lock screen.* The month's loudest complaints about podcast sleep timers: a timer that turns
  the sound down but keeps playing, the next episode starting at full volume and waking the
  listener, and a request for a timer that starts with playback and can be extended without
  fully waking. Sleepulator already does each of these, so the listing says so first.
- *Generated live, no loop.* Several new indie apps lead with this. It's now expected, so it sits
  in the description, not the name or subtitle.
- *No account, no ads, no tracking; free; tips unlock nothing.* Small apps are pitching privacy
  and a one-time price against subscriptions. Sleepulator's version (free, tip jar) is stronger;
  the launch plan already names it the positioning.
- *The binaural note.* A TikTok for a sleep app that "admits which sounds actually have evidence
  behind them" drew 90k views. Saying it plainly costs nothing and sets the app apart from
  frequency claims.

**Checked against the code** (2026-11-07)

- Ten-minute fade on a fixed timer: `AudioMath.getFadeMultiplier` (`fadeDuration` 600 s).
- Timer starts with any Sleep sound, including lock screen, AirPods, Siri and the widget:
  `AudioEngine.noteSessionEdge` (CLAUDE.md, "The sleep timer starts from the Home orb's night ring").
- "+15m" on the lock screen: `SleepTimerLiveActivity.swift` (`BumpSleepTimerIntent`); hidden for
  "Stop after this episode" and in the noise-only tail.
- Podcast stops first, noise carries on: the ambient tail (`SleepTimerService.beginTail`), an
  option in the timer sheet and the player, off by default.
- Sounds per mode: `AudioEngine.sleepNoises` / `focusNoises`; every one is a render case in
  `GenerativeAudioEngine` (no audio files).
- Scenes: `SceneRegistry.all`, by mood; "Rain (depth)" and "Still water (depth)" are DEBUG-only
  experiments and aren't listed.
- Siri phrases: `SleepulatorShortcuts`. Widget: `ResumeMixWidget`.

**Left out on purpose**

- *"Soften loud moments"* (the Night Limiter): it ships off and its device acceptance pass
  (TESTING.md §3D) hasn't run. Add a line once it passes.
- *Apple Music in Focus*: hidden until 1.1 (launch plan, AM-1).
- *Other apps' names*, in any field: App Review Guideline 2.3.7.
- *"Free" in the name, subtitle or keywords*: 2.3.7 lists pricing terms there as keyword stuffing.
  The description can say it.
- *Health words* ("insomnia", "ADHD", "tinnitus") and any promise to cure or treat anything: they
  read as medical claims.

---

## Privacy policy (page text)

# Sleepulator privacy policy

*Last updated: [OPEN: date published]*

Sleepulator has no account, no ads, no analytics and no tracking. The developer collects no
data from the app.

## What stays on your iPhone

- Your mixes, settings, podcast subscriptions, queue, listening positions and downloaded episodes.
- A short record of your recent nights: when sound started and stopped, when it was interrupted
  (a call or an alarm) or the audio output changed (headphones out), and whether playback ran
  into a problem. The last two nights are kept in detail and the last 30 as a one-line result.
  It never contains web addresses. The app uses it to show a one-line note on the Sleep screen
  the morning after a night that played without a problem, to list your recent nights (Settings ▸
  Backup & support ▸ Recent nights), to decide when to ask for a rating or show the tip card, and
  to attach to feedback you choose to send.
- The app's playback log for the last 3 days: what played and what went wrong (a stream that
  stalled, a player that restarted), without web addresses. It leaves your iPhone only when you
  export it or attach it to feedback you send.
- The battery and crash reports iOS provides to the app (Settings ▸ Backup & support ▸ Reports
  from iOS).

Downloaded episodes, the night record, the playback log and the iOS reports are kept out of
iCloud and computer backups. Your library and settings are part of your iPhone's own backup, like any app's data.
"Export a backup" makes a file that you save wherever you choose.

## What leaves your iPhone

- **Podcast search.** What you type in Add Podcast goes to Apple's iTunes Search API, which
  returns matching shows. Apple's privacy policy covers it.
- **Podcast feeds and episodes** come straight from each show's publisher, as in any podcast
  app. The publisher's server sees an ordinary web request, including your IP address.
- **Tips** are handled entirely by Apple through the App Store. The developer never sees your
  payment details or your Apple Account, only the totals in Apple's sales reports.
- **Send feedback** (Settings ▸ Backup & support) opens an email, or the share sheet, that you
  read and choose to send. It holds your message, a one-line count of how your recent nights
  went, the last two nights' playback events (no web addresses), any iOS reports on the phone,
  and the app version, iOS version and device type. It
  goes to [OPEN: support address] and is used only to answer you and fix the problem.

## Children

Sleepulator isn't directed at children and collects no data from anyone.

## Changes

Changes to this policy are posted on this page with a new date.

## Contact

[OPEN: support address]

---

## Support page (page text)

# Sleepulator support

Sleepulator plays layered noise, binaural beats and podcasts to help you fall asleep or focus,
with a sleep timer that fades everything out.

**Contact:** [OPEN: support address]

**Reporting a problem.** In the app, Settings ▸ Backup & support ▸ Send feedback. It attaches the
last two nights' playback events (no web addresses), which shows where a night went wrong. Send it
the morning after, before the next night: only the last two nights are kept in detail.

**Setting a sleep timer.** On the Sleep screen, drag the ring around the play button. With the
ring at its start (All night), the sound plays until you stop it.

**Do tips unlock anything?** No. Everything in Sleepulator is free. Tips (Settings ▸ Backup &
support ▸ Support Sleepulator) help keep it going.

**Moving to a new iPhone.** Settings ▸ Backup & support ▸ Export a backup, then Restore from a
backup on the new phone. Your mixes, shows, queue and settings come across. Downloads don't; the
episodes download again.

**Privacy.** [OPEN: privacy page URL]

---

## App Review notes (draft for App Store Connect)

- **No account.** Every feature works without signing in.
- **Background audio (UIBackgroundModes: audio).** Sleepulator is a sleep-sound app: it plays
  generated noise, binaural tones and podcasts through the night with the screen locked, and a
  sleep timer fades them out. To check: on the Sleep screen, tap the play button in the middle,
  then lock the phone. The sound continues and the lock screen shows its controls.
- **Podcasts.** Podcasts tab ▸ Add podcast (the + button) ▸ search for any show, or paste a feed
  link: [OPEN: sample feed]. Search uses Apple's iTunes Search API; feeds come straight from their
  publishers.
- **Focus mode.** The Sleep | Focus switch at the top of the first screen. Focus runs Pomodoro
  sessions with its own sounds.
- **"Soften loud moments"** (Settings ▸ Podcasts at night) is an on-device loudness limiter for
  podcasts, so a loud ad or intro doesn't wake the listener. It's off by default in this version.
- **Tips.** Settings ▸ Backup & support ▸ Support Sleepulator: three consumable tips that unlock
  nothing. A small card on the Sleep screen offers them once, only after five nights of use, so
  it won't appear during review.
- **Rating prompt.** Apple's standard review request, after three nights of use, in the daytime.
- **Send feedback** is an optional email the person writes and sends themselves, with the last
  two nights' playback events attached. Nothing is sent automatically, so the App Privacy answer
  is "Data Not Collected" (Apple's optional-disclosure criteria).
- **iPhone only**, portrait.
