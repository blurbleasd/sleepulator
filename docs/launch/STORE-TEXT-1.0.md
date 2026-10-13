# Sleepulator 1.0: store text drafts

Drafts for the launch plan's B2 (privacy policy and support pages) and B4 (App Review notes),
`docs/designs/APP-STORE-LAUNCH-1.0.md`. Written against the code at the 1.0 branch; every claim
below is checked against it. Fill the **[OPEN: …]** inputs, then host the two pages (B2: any
static page works) and enter their URLs and the notes in App Store Connect.

Open inputs (the same ones the code waits on):
- **[OPEN: support address]**: also `AppInfo.supportEmail` in `Services/AppInfo.swift`.
- **[OPEN: privacy page URL]** and **[OPEN: support page URL]**: wherever the pages are hosted.
- **[OPEN: sample feed]**: optional, a public RSS feed for App Review to paste.

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
  It never contains web addresses. The app uses it to decide when to ask for a rating or show
  the tip card, and to attach to feedback you choose to send.
- The battery and crash reports iOS provides to the app (Settings ▸ Backup & support ▸ Reports
  from iOS).

Downloaded episodes, the night record and the iOS reports are kept out of iCloud and computer
backups. Your library and settings are part of your iPhone's own backup, like any app's data.
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
