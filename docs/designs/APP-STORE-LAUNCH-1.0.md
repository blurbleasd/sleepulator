# Sleepulator 1.0: App Store launch (free, with a tip jar)

Working plan for `/plan-ceo-review` (2026-10-11), branch `claude/app-store-readiness-391005`, base `main` @ 0843f65.
Ask: "what else could this app use before I add it (free, with tip jar) to the App Store?"
Review depth: **strategy-only** (scope and priorities; implementation owners prove the details).
Deferrals live in this file's "NOT in scope" section, not TODOS.md (binding decision 2026-10-09: this repo doesn't use gstack TODOS/VERSION/CHANGELOG).

## Step 0 findings

### 0A. Premise

**The real problem.** Getting a free app approved is the easy part. The hard part for a sleep app is the first 100 public reviews: its worst failures (audio stops at 3am, a podcast goes silent, the timer never fades) happen while the person is asleep. They can't report them. They just leave one star or quietly delete the app. Free apps live on ratings, so the launch has to be one where the night works.

**Premise challenge: the app doesn't need more features.** It already has two modes, generative noise and binaural beds, podcasts with a night limiter, Apple Music in Focus, a Pomodoro, Live Activities, a widget, Siri intents, backup with Undo, and 10+ Metal scenes. What it lacks:
1. **Proof it works on glass.** The device-pass log has one row (§3R, `TESTING.md:660-664`). The release checklist's §3A/§3B/§3C/§3E (background audio, interruptions, timer fade, all-night soak) have no logged pass since the 2026-06 refactor. CLAUDE.md's own verification gate says audio/timer work isn't done until it passes on an installed, locked iPhone over a full run.
2. **Launch plumbing.** No StoreKit code at all (grep: 0 hits), no privacy-policy or support URL (App Store Connect requires a privacy policy URL for every app), no rating prompt, no feedback path.
3. **One-way doors nobody has decided.** iPad and landscape are switched on (`project.pbxproj:609-610`, `TARGETED_DEVICE_FAMILY = "1,2"` at `:625`) but no view reads a size class. Once a build ships with iPad support, App Store Connect rejects any update that drops it.

**Do-nothing cost** (submit what's on `main` today): the submission can't be completed without a privacy policy URL; review may test on iPad and in landscape, which were never designed; and every night-failure bug that the device pass would catch becomes a public review instead.

### 0B. Existing code to reuse

| Need | Reuse | Receipt |
|---|---|---|
| Tip jar home | Settings ▸ Backup & support page (already one level down, owned by `SettingsView`) | `Views/BackupSupportView.swift` |
| Feedback with evidence | `LogExport` exports this process's log only (`OSLogStore(scope: .currentProcessIdentifier)`, `Services/Log.swift:50`; the row already says "since the app opened", `BackupSupportView.swift:40`), and MetricKit diagnostics arrive on the next launch. After a 3am death, the morning's log is empty (FB-1 reopened) | `Services/Log.swift:42-56` |
| Crash / hang visibility | `MetricsCollector` (MetricKit, on-device, shared via Settings) | `Services/MetricsCollector.swift:1-40` |
| "When is it OK to ask?" | Pure, unit-tested rules in `SessionGuards` / `HomeScreensaverPolicy` | `Views/Home/SessionGuards.swift` |
| "Did the night end cleanly?" | Nothing persisted today: `recordNightEnd` is private, in-memory and runs only on a timer's terminal stop (`SleepTimerService.swift:166-169`), and the default is All night. The night signal is new work (NT-1) | `SleepTimerService.swift:160-181` |
| New persisted keys | The night count and the "already asked / already tipped" flags stay on the device and out of backups, like `hasSeenNightRingTip` and `restoreUndoTakenAt` (`Backup.swift:87`). Not `exportOnlyKeys`: those export as Bools (`Backup.swift:302`) | `Services/Backup.swift:87, 302` |
| First-run | `FirstRunCoachmark` already ships | `Views/Home/FirstRunCoachmark.swift` |
| Store screenshots material | Live Activity, Resume widget, Siri shortcuts, scenes | `SleepulatorWidget/ResumeMixWidget.swift:63-69`, `Services/SleepulatorIntents.swift:34` |

No rebuilds proposed. The tip jar is the only new subsystem (StoreKit 2, consumables, no server).

### Landscape check

- [Layer 1] The category is crowded with free-download, subscription-gated sound apps (White Noise Deep Sleep, Sleep Dose, Sleepo, Serenity, White Noise Pro). They compete on catalog size and binaural claims.
- [Layer 2] Listings lean on unproven "healing" binaural claims and paywalls. Sleepulator's UI names beats "Deep" / "Drift" (`Views/SoundNames.swift:8`), with no medical claims in the app, which keeps it clear of guideline 1.4.1.
- [Layer 3, eureka] **A sleep app's worst bugs are invisible to its users, because they're asleep.** Conventional launch kits (screenshots, ASO, onboarding) don't touch that. The pre-launch work that matters most is a beta of real nights plus a one-tap way to send the playback log the app already writes. Second: in a subscription-saturated category, "free, no subscription, no ads, no account, data not collected" is the positioning, and the tip jar has to obey the same 2am rules as the rest of the app (never asks at night).
- Tips must use In-App Purchase when tied to the app (guideline 3.1.1). Consumables, nothing unlocked.

### 0C. Dream state

```
  CURRENT STATE                    THIS PLAN                          12-MONTH IDEAL
  Feature-rich, 1 of ~19 device    Prove the night on glass,          "It just works all night, and it's
  sections logged; no StoreKit,    close the submission gaps,         free." 4.7+ rating, word of mouth,
  no store presence; iPad and      add a tip jar and a rating ask     tips cover the developer fee and then
  landscape on but unbuilt         that obey the 2am rules            some; the reactive scenes, tuned on
                                                                      device, lead the product page
```

This plan moves toward the ideal if it ships a verified night and a store page that sells "free, no strings". It moves away if it adds features that widen the unverified surface.

### Baseline scope (from the ask, plus what submission requires)

These are in scope without a question: the user asked for a free App Store release with a tip jar, and App Store Connect won't accept a submission without them. Owners: **code** = an implementation session on this repo; **user** = App Store Connect, the developer portal, hosting, art, and the device passes.

| ID | Item | Owner | Done when |
|---|---|---|---|
| B1 | Tip jar: StoreKit 2 consumable tips (3 tiers; product IDs and prices are the user's call, set in App Store Connect and mirrored in a `.storekit` file); nothing unlocked; a thank-you state. Handles: products that fail to load (offline, or before the Paid Apps agreement is active: the row says tips aren't available right now, never a spinner forever); `AppStore.canMakePayments == false` (row hidden); cancelled; pending (Ask to Buy); failed; unverified. Listens to `Transaction.updates` from launch and finishes every transaction. Once someone has tipped, the TJ-1 card never shows | code (StoreKit, tests); user (products, agreement) | Unit tests over the pure purchase-state mapping pass; a sandbox purchase on device succeeds and finishes; a new TESTING.md §T (tips, the card, the rating ask, feedback) passes on device |
| B2 | Privacy policy and support pages: what stays on device, what goes to Apple's podcast search and to feed publishers, and that "Send feedback" (FB-1) is an email the person chooses to send. Names the support email address | user (host + address); code (page text) | Both URLs load and are entered in App Store Connect |
| B3 | App Store Connect setup: Paid Apps agreement + tax + banking (required for any IAP, even in a free app), tip products with review screenshots, App Privacy answers, the age-rating questionnaire (2025 tiers; see AR-1), category, iPhone screenshots, and availability: untick Apple silicon Mac and Apple Vision Pro (they default on for iPhone apps; D2 chose "iPhone only") | user | The submission form has no missing fields. App Privacy: "Data Not Collected" holds, since FB-1 is optional, user-initiated, infrequent and clearly labeled (Apple's optional-disclosure criteria); recorded on the privacy page |
| B4 | App Review notes: why background audio runs, a sample podcast feed to test with, what "Soften loud moments" is, how to reach Focus | user (text in ASC); code (draft) | Notes entered with the build |
| B5 | `ITSAppUsesNonExemptEncryption = NO` (HTTPS only; the MD5 in `AudioDownloader.swift:46` is a cache key, not encryption) | code | An upload doesn't stop on the export-compliance question |
| B6 | Privacy manifest: declare the System boot time API (`ProcessInfo.systemUptime` at `ContentView.swift:114,132`, the veil glance's monotonic clock: reason 35F9.1, elapsed time in the app) and the Disk space API (`volumeAvailableCapacityForImportantUsageKey` at `AudioDownloader.swift:134`, the download cache's eviction: reason E174.1). `PrivacyInfo.xcprivacy` declares neither today, which draws ITMS-91053 on upload. Also fix File timestamp: the manifest declares only DDA9.1 (dates shown to the person), and its comment calls C617.1 "the wrong code", but C617.1 is the reason for metadata of files inside the app's own container, which the cache eviction (`AudioDownloader.swift:206-214`) and the reports list's sort (`MetricsCollector.swift:73-79`) read. Declare C617.1, and keep DDA9.1 for dates the app shows (`AppInfo.builtAt`, the Reports list) | code | Every required-reason API the app calls is declared with the reason that matches its use (checked against Apple's list, not just the absence of ITMS-91053), and the first TestFlight upload draws no ITMS-91053 notice |

## Decision ledger

| ID and owner | Contract and evidence | Current | Proposed | Status | Exact approval and scope |
|---|---|---|---|---|---|
| LG-1 launch gate (owner: user; device pass: user) | CLAUDE.md verification gate; `TESTING.md:647-664` checklist + 1-row log | **A: TestFlight beta first.** Core device pass §3A/B/C/E logged before submit; 10–20 external testers for ~2 weeks; submit after a week with no "it stopped" report; other sections run during the beta, not gating; Night Limiter stays off | — | approved | D1 answer "TestFlight beta first (recommended)", 2026-10-11; scope: the launch gate only |
| DF-1 device family + orientation (owner: code) | `project.pbxproj` device family `"1,2"` at 625, 659 (app Debug/Release), 690, 721 (widget), 454, 469, 737, 754 (test targets); iPhone landscape at 610, 644; no size-class code; iPad support can't be removed after release | **A: iPhone only, portrait only** (device family 1 on the app and widget, Debug and Release; iPhone orientations portrait). iPad stays a later, reversible choice. (Mac and Vision Pro availability moved to B3; the iPad compatibility-mode smoke test moved to the gate's review-readiness checks: see spec review round 2, S1) | — | approved | D2 answer "iPhone only, portrait (recommended)", 2026-10-11; decision cfdf2286; scope: device family + orientation build settings only |
| AM-1 Apple Music in 1.0 (owner: user) | `SPEC-STATUS.md:16` MusicKit App Service is a manual portal step; no device pass | **A: Defer to 1.1.** Hide the Apple Music picker entry in the Focus mixer for 1.0; code stays; returns in 1.1 after its own device pass | — | deferred | D3 answer "Defer to 1.1 (recommended)", 2026-10-11; scope: the 1.0 entry point only |
| TJ-1 where the tip jar appears (owner: user) | B1; 2am rules (CLAUDE.md § UI conventions) | **A: Settings + one morning card.** Tip jar in Settings ▸ Backup & support; once, after the 5th clean night (NT-1), a dismissible card on the first open after that night ended (NT-1 timing; was "daytime open"); a pure, unit-tested rule keeps it off any playing session, sheet or the veil; never twice; nothing unlocked | — | approved | D4 answer "Settings + one morning card (recommended)", 2026-10-11; scope: tip-jar surfaces + the good-night counter + the may-ask rule |
| RP-1 rating prompt (owner: user) | No `requestReview` anywhere | **A: Add to 1.0.** Apple's own prompt on the first open after the 3rd clean night (NT-1), through TJ-1's may-ask rule, at most once per app version, never the same day as the tip card; a "Rate Sleepulator" row in Settings | — | approved | D5 answer "Add to 1.0 (recommended)", 2026-10-11; scope: the prompt timing + the Settings row |
| FB-1 feedback with the log (owner: user) | `SettingsView.swift:415` ShareLink exists; `LogExport` (`Services/Log.swift:42`); manual export at `BackupSupportView.swift:38` | **A: Add to 1.0.** "Send feedback" row in Settings ▸ Backup & support: mail draft to the support address with version, build, iOS, device + last night's playback log attached; share-sheet fallback without Mail; person sees the attachment first | — | approved (attachment superseded by D9: the persisted night trail + MetricKit, not the process log) | D6 answer "Add to 1.0 (recommended)", 2026-10-11; scope: the row + mail/share sheet + a support address |
| IC-1 app icon (owner: user) | `AppIcon.png` 1024² RGB, white baked into the corners (pixel (40,40) = 254,254,254; (60,60) = navy); EarPod-like earbuds (guideline 5.2.5 risk) | **A: Repair this icon.** Full-bleed re-export (no baked rounding), earbuds removed or clearly generic, iOS 18 dark + tinted variants, checked on a real home screen before the beta; art direction unchanged | — | approved | D7 answer "Repair this icon (recommended)", 2026-10-11; scope: repair of the existing art only |
| NT-1 what counts as a clean night (owner: code) | Spec review F1/L1/L2: no persisted night signal | **A: Night record.** Opened at a Sleep session's start, closed at its end; clean = played to its timer's end or 3+ h on All night, ended by a person, the timer or an episode end, no AVPlayer rebuild, no failure streak; an unclosed record (app died) isn't clean. Asks come on the first open after a clean night ended, nothing playing, no sheet, no veil. Pure rule, unit-tested; device-only storage | — | approved (round 3: clarified, not changed — live audio only, force-quit closes the record, pauses < 30 min keep the night; asks at a natural break, 09:00–21:00, 2+ h after) | D8 answer "Night record (recommended)", 2026-10-11; scope: the night record + the may-ask timing for TJ-1 and RP-1 |
| FB-1 reopened: last night's log after a crash (owner: code) | Spec review F2: `Log.swift:50` current process only | **A: Persist a night trail.** Night key events (start/stop, interruptions, routes, player rebuilds, failures, terminal stop) also written to a small file in App Support, excluded from backup, last 2 nights, ~256 KB cap, off main, never from the render block; "Send feedback" attaches it + MetricKit diagnostics delivered since | — | approved | D9 answer "Persist a night trail (recommended)", 2026-10-11; scope: the trail file + its attachment in FB-1 |
| LG-1 reopened: add §3P to the gate (owner: user) | Spec review K1: `TESTING.md:658` | **A: Add §3P.** Gating device sections are now §3A, §3B, §3C, §3E and §3P | — | approved | D10 answer "Add §3P to the gate (recommended)", 2026-10-11; scope: adds §3P to LG-1's gate; the rest of LG-1 unchanged |
| AR-1 podcast content and the age rating (owner: user) | Spec review C3: `ITunesSearchManager.swift:22` no explicit filter; feeds can be pasted | **A: Rate for open podcast access.** The questionnaire says the app plays third-party podcasts that can include mature content; accept the tier Apple computes; no filter, no code | — | approved | D11 answer "Rate for open podcast access (recommended)", 2026-10-11; scope: the B3 age-rating answers |
| LG-1 reopened (2): the beta's exit evidence (owner: user) | Spec review round 2, L3: "no report" isn't evidence | **A: Count real nights.** Submit after 7 days in a row with no app-caused stop AND ≥ 30 reported tester-nights from ≥ 8 testers; one-line morning check-ins outside the app; "Send feedback" with the trail on any bad night | — | approved | D12 answer "Count real nights (recommended)", 2026-10-11; scope: replaces D1's exit rule only |
| TS-1 StoreKit purchase-path tests (owner: user; implementer: code) | Section 6: pending/failed/Ask-to-Buy unreachable by hand | **A: Add StoreKitTest.** SKTestSession tests against the .storekit file: success, cancel, Ask to Buy, failure, interrupted, approved-while-closed; both CI legs | — | approved | D14 answer "Add StoreKitTest (recommended)", 2026-10-11; scope: purchase-path tests in the unit target |
| TS-2 a CI check for the card on Home (owner: user; implementer: code) | Section 6: HomeLayoutUITests never runs with the card present | **A: Add a UI test.** Seeded clean night via launch args; card shows; Home controls hittable; clears the mini-player; "Not now" → waitForNonExistence; persisted state left as found; both CI legs. Re-run `setup_ui_tests.rb` after adding the file | — | approved | D15 answer "Add a UI test (recommended)", 2026-10-11; scope: one XCUITest for the card |


**Approval readiness: PASS** (2026-10-11). Checked rows and their answers: LG-1 (D1), DF-1 (D2), AM-1 (D3, deferred), TJ-1 (D4), RP-1 (D5), FB-1 (D6; attachment per D9), IC-1 (D7), NT-1 (D8), FB-1 reopened (D9), LG-1 reopened (D10), AR-1 (D11), LG-1 reopened (2) (D12), TS-1 (D14), TS-2 (D15); documents approved (D13, admin). Baseline B1–B6 cite the ask plus App Store Connect's submission requirements. Repairs made without a question cite the invariant or answer they implement: B6 (upload requirement); the daytime window (D4's "never at night" + CLAUDE.md's 2am rules); Mac/Vision Pro off (D2's "iPhone only"); §3E on All night (D1's "the sections that decide whether a night works"); the trail never writes a URL (B2's privacy promise); filing by night id (CLAUDE.md's "filed by item" invariant); the Rate row's App ID (RP-1). Not accepted: the delight list (opt-in, on request) and the candidates not raised. No pending rows.

## Mode

SELECTIVE EXPANSION (from the ask's wording, "what else could this app use": a request to see options; no mode question asked). Baseline B1–B6 held; each candidate below goes to the user as Add / Defer / Skip.

## Answered: LG-1 (D1 → A, TestFlight beta first)
Commitment comparison:

```text
Commitment                      | Source/approval or pending      | Current          | A (TestFlight first)        | B (full pass first)     | C (submit now)
Core device pass §3A/B/C/E      | CLAUDE.md verification gate     | not run          | before submit               | before submit           | after submit
Other sections (§3D, F–Q, S)    | TESTING.md                      | not run          | run during beta, not gating | before submit           | after submit
External testers, real nights   | pending                         | none             | 10–20 for about 2 weeks     | optional                | none
Night Limiter default           | CLAUDE.md (off until §3D)       | off              | off                         | on only if §3D passes   | off
Submit date (estimated)         | pending                         | —                | ~2–3 weeks                  | ~3–4 weeks              | this week
```

Question: D1 — LG-1: What has to pass before you submit 1.0? <gstack-qid:plan-ceo-review-launch-gate>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: The app's own rule is that audio and timer changes aren't done until they pass on a real, locked iPhone over a full night. Right now only one small section of that checklist is logged as passed. The bugs that matter most happen while people sleep, so they won't report them; they'll leave one star. This decides how much proof you get before strangers start using it.
Stakes if we pick wrong: a night-time failure ships to the public and the first reviews say "stopped playing at 3am", which is hard for a free app to recover from.
Recommendation: A because it gets real nights from people who aren't you, gates only on the four sections that decide whether a night works, and lands in about 2–3 weeks.
Completeness: A=8/10, B=10/10, C=3/10
Net: a couple of weeks of real nights now, versus finding the failures in your reviews later.
Header: Launch gate
A) TestFlight beta first (recommended)
You run the core device pass (§3A background, §3B interruptions, §3C timer fade, §3E all-night soak) and log it, while 10–20 TestFlight testers sleep with it for about 2 weeks; submit when a week passes with no "it stopped" report. Effort M, risk low, zero new code. ✅ Real nights from other phones, routes and podcasts catch what one tester can't. ✅ Gates on the four sections that decide whether a night works, not on visual polish. ❌ Adds about 2–3 weeks before the store, and you have to recruit testers.
B) Full device pass first
Run and log every TESTING.md section (§3A through §3S) on device before submitting. Effort L, risk low, zero new code. ✅ Most complete: every unverified fix since June gets checked on glass. ✅ Lets the Night Limiter ship on by default if §3D passes. ❌ About 3–4 weeks of your own nights, and only one phone's routes and podcasts get tested.
C) Submit now, verify after
Submit this week and run the device pass in parallel with review. Effort S, risk high, zero new code. ✅ Fastest path to a live listing and the first downloads. ✅ App Review itself is free extra testing on Apple's devices. ❌ Any night-time bug reaches the public first and lands in the reviews that free apps live on.

## 0G. HOLD checks (SELECTIVE runs them first)

1. **Complexity.** Baseline B1–B6 is about 9 files (estimate) and one new service (the tip store). Under the 8-file / 2-service bar; no challenge.
2. **Minimum change.** B1–B6 is the minimum for a free + tips submission. Nothing in it can be deferred without blocking submission.
3. **Invariants the baseline must keep** (CLAUDE.md): the tip store is its own `ObservableObject`, never `@Published` on `AudioEngine`; any class tests create and free declares `nonisolated deinit {}`; new persisted keys either join `Backup.kinds` (settings worth restoring) or stay device-only (counters and one-time flags, never `exportOnlyKeys`, which export as Bools); nothing asks for money or attention over a playing Sleep session or under the veil (2am rules).
4. **Deferral candidate from the HOLD pass:** AM-1 (Apple Music), asked below with Defer / Keep.

## Answered: DF-1 (D2 → A, iPhone only, portrait)
Commitment comparison:

```text
Commitment                        | Source/approval or pending        | Current       | A (iPhone, portrait) | B (iPhone, + landscape)  | C (keep iPad + landscape)
Device family                     | project.pbxproj:625               | iPhone + iPad | iPhone               | iPhone                   | iPhone + iPad
iPhone landscape                  | project.pbxproj:610               | on, unbuilt   | off                  | on, designed + UI-tested | on, designed + UI-tested
iPad layouts + 13" screenshots    | App Store Connect                 | none          | not needed           | not needed               | required before submit
Can change later                  | forum reports on ASC validation   | —             | can add iPad later   | can add iPad later       | iPad can never be removed
Launch gate                       | LG-1 approved (D1 → A)            | TestFlight    | unchanged            | unchanged                | unchanged
```

Question: D2 — DF-1: Which devices and orientations does 1.0 support? <gstack-qid:plan-ceo-review-device-family>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: The project is set to run on iPad and to rotate to landscape on iPhone, but no screen was designed or tested for either. App Review can test on an iPad. And once a version ships with iPad support, Apple won't accept an update that removes it. So this is the one choice here you can't take back.
Stakes if we pick wrong: either a review bounce or bad reviews from a stretched, untested iPad and landscape layout, or a permanent promise to support iPad that you never meant to make.
Recommendation: A because it's the only option that keeps the iPad door open, and it ships exactly the layout you've built and UI-tested.
Note: options differ in kind, not coverage — no completeness score.
Net: ship the screen you've tested and keep iPad as a later choice, versus committing to two unbuilt layouts now.
Header: Devices
A) iPhone only, portrait (recommended)
Set the device family to iPhone and the iPhone orientations to portrait only: two build settings. Effort S, risk low. ✅ Reversible: iPad can be added in any later version, while shipping it now makes it permanent. ✅ Review and screenshots cover one layout, the one HomeLayoutUITests already guards. ❌ iPad owners get the iPhone app in compatibility mode (letterboxed) until you add iPad.
B) iPhone only, keep landscape
Drop iPad but design and UI-test landscape for Home, the night ring, Now Playing, the scenes and the veil before submitting. Effort M, risk medium. ✅ People who dock the phone sideways on a nightstand get a rotated screen. ✅ iPad stays a later, reversible choice. ❌ Every screen needs a landscape layout and test pass first, which delays the beta.
C) Keep iPad and landscape
Ship universal: build iPad layouts, test on iPad, and make 13-inch iPad screenshots before submitting. Effort L, risk high. ✅ A real iPad app and iPad listing from day one. ✅ No letterboxed compatibility mode for iPad owners. ❌ One-way door: iPad support can never be dropped, and none of its layouts exist yet.

## Answered: AM-1 (D3 → A, defer to 1.1)
Commitment comparison:

```text
Commitment                         | Source/approval or pending           | Current                          | A (defer to 1.1)                 | B (keep in 1.0)
Apple Music picker in Focus        | Views/Home/MixPanel.swift:137        | shown                            | hidden in 1.0 (one entry point)  | shown
MusicKit App Service on the App ID | SPEC-STATUS.md:16 (manual portal)    | unknown                          | not needed for 1.0               | enabled and checked before the beta
Apple Music device pass            | APPLE-MUSIC-FOCUS-SPEC; none logged  | none                             | in 1.1                           | added to the beta's gate (LG-1)
Review notes (B4)                  | baseline                             | —                                | no Apple Music section           | explain the optional subscription path
Launch gate                        | LG-1 approved (D1 → A)               | TestFlight first                 | unchanged                        | unchanged, one more gating section
```

Question: D3 — AM-1: Ship Apple Music in Focus with 1.0, or hold it for 1.1? <gstack-qid:plan-ceo-review-apple-music-defer>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: Focus mode can play your own Apple Music under the focus sounds. The code is done, but it has never been tested on a phone, and it only works if MusicKit is switched on for the app in Apple's developer portal, a manual step nobody has confirmed. If a reviewer taps it and it fails, the whole app can be rejected. Holding it back means hiding one button until 1.1.
Stakes if we pick wrong: keep it untested and a broken Apple Music button can sink the review; hold it and Focus loses a nice hook for its first few weeks.
Recommendation: A because 1.0 should prove the Sleep night, and Apple Music lands better as the headline of a 1.1 update than as one more untested path in review.
Note: options differ in kind, not coverage — no completeness score.
Net: a smaller, proven 1.0 with an easy 1.1 story, versus a richer Focus mode that adds a gate and a review risk.
Header: Apple Music
A) Defer to 1.1 (recommended)
Hide the Apple Music picker in 1.0 (one entry point in the Focus mixer); the code stays, and it comes back in 1.1 after its own device pass. Recorded in this plan's Deferred list (this repo doesn't use TODOS.md). Effort S, risk low. ✅ One less untested path for App Review and the beta. ✅ Gives 1.1 a real "What's new" headline. ❌ Focus users who live in Apple Music wait a few weeks for it.
B) Keep it in 1.0
Enable the MusicKit App Service now, add the Apple Music device section to the beta's gate, and explain the optional subscription path in the review notes. Effort M, risk medium. ✅ Focus ships with its most distinctive feature. ✅ The code is already written, so no work is thrown away. ❌ Adds a gate to the beta, and if MusicKit isn't set up right, review fails on it.

## Answered: TJ-1 (D4 → A, Settings + one morning card)
Commitment comparison:

```text
Commitment                           | Source/approval or pending        | Current   | A (Settings + one morning card)              | B (Settings only)
Tip jar in Settings ▸ Backup & support| B1 (baseline, the ask)            | not built | yes                                          | yes
One-time card after good nights      | pending                           | none      | once, after the 5th night that ended cleanly | never
When the card may appear             | 2am rules (CLAUDE.md)             | —         | daytime open only; never over a playing      | —
                                     |                                   |           | session, a sheet or the veil; never twice    |
Rule location + tests                | SessionGuards pattern             | —         | a pure, unit-tested rule                     | none needed
New persisted keys                   | Backup.kinds invariant            | —         | good-night count, card shown (exportOnly)    | none
Nothing unlocked by tipping          | guideline 3.1.1                   | —         | yes                                          | yes
```

Question: D4 — TJ-1: Where does the tip jar show up? <gstack-qid:plan-ceo-review-tip-surface>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: A tip jar only earns if people see it, but this is an app for falling asleep, and nothing should ever ask for money at night. Option A puts it in Settings and also shows one small, dismissible thank-you card once, in the daytime, after someone has had five nights that ended cleanly: the moment they know it works. Option B leaves it in Settings only, where few people look.
Stakes if we pick wrong: a pushy ask breaks the calm that's the whole product; a hidden one means the tip jar earns close to nothing.
Recommendation: A because one ask, timed to proof that the app worked and never at night, is the most tips you can earn without spending any of the app's calm.
Note: options differ in kind, not coverage — no completeness score.
Net: one well-timed daytime ask, versus zero asks and a near-silent tip jar.
Header: Tip jar
A) Settings + one morning card (recommended)
The tip jar lives in Settings ▸ Backup & support, and once, after the fifth night that ended cleanly, a small dismissible card offers it on a daytime open. A pure, unit-tested rule keeps it off any playing session, sheet or the veil, and it never shows twice. Effort M, risk low. ✅ Asks at the moment people know the app worked, the best time to earn a tip. ✅ Never at night, never twice, so the calm holds. ❌ Needs a good-night counter and a tested "may ask" rule, about a day more than B.
B) Settings only
The tip jar lives in Settings ▸ Backup & support and the app never mentions it anywhere else. Effort S, risk low. ✅ Zero interruptions, ever. ✅ Smallest build and nothing new to test beyond the purchase itself. ❌ Few people open Settings, so expect very few tips.

## Answered: RP-1 (D5 → A, add to 1.0)
Commitment comparison:

```text
Commitment                         | Source/approval or pending        | Current | A (add to 1.0)                              | B (defer to 1.1) | C (skip)
System rating prompt               | none in code (grep: 0 hits)       | none    | Apple's own prompt (requestReview)          | in 1.1           | never
When it may appear                 | 2am rules; TJ-1 may-ask rule      | —       | daytime open after the 3rd clean night;     | —                | —
                                   |                                   |         | same rule as TJ-1; never the same day as    |                  |
                                   |                                   |         | the tip card                                |                  |
Good-night counter                 | TJ-1 approved (D4 → A)            | —       | reused                                      | reused by TJ-1   | reused by TJ-1
"Rate Sleepulator" row in Settings | pending                           | none    | yes (opens the App Store review page)       | in 1.1           | none
Tip card (TJ-1)                    | approved                          | —       | unchanged                                   | unchanged        | unchanged
```

Question: D5 — RP-1: Add Apple's rating prompt to 1.0? <gstack-qid:plan-ceo-review-expansion-proposal>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: Free apps get found through ratings. Apple has a built-in "rate this app" prompt that it shows at most three times a year, and the app decides when to ask. With the night counter from the tip jar, the app can ask on a daytime open after a person's third night that ended cleanly, and never on the same day as the tip card. Unhappy people find the App Store on their own; this asks the happy ones.
Stakes if we pick wrong: without it, early reviews skew toward people who had a problem, and the app's rating undersells it.
Recommendation: A because ratings are how a free app grows, and with the tip jar's counter and rule already planned it's a few lines and one more test.
Note: options differ in kind, not coverage — no completeness score.
Net: a small build that asks the people the app worked for, versus leaving the rating to whoever is upset enough to look for the review page.
Header: Rating ask
A) Add to 1.0 (recommended)
Ask with Apple's own prompt on a daytime open after the third clean night, through the same tested may-ask rule as the tip card and never on the same day; add a "Rate Sleepulator" row in Settings. Effort S, risk low. ✅ Ratings come from people the app has already worked for. ✅ Reuses TJ-1's counter and rule, so it's about a day's work. ❌ Apple decides whether the prompt actually shows, so results are hard to measure.
B) Defer to 1.1
Leave rating prompts out of 1.0 and add them in the first update, recorded in this plan's Deferred list. Effort S, risk low. ✅ 1.0 has one less thing to build and test before the beta. ✅ You see how organic ratings land before nudging. ❌ The first weeks of reviews, the ones that set the rating, come without it.
C) Skip
Never prompt; people rate on their own. Effort S (zero implementation work), risk low. ✅ The calmest possible app, no asks of any kind beyond the tip card. ✅ Nothing to build or maintain. ❌ Ratings come mostly from people with problems, which pulls the average down.

## Answered: FB-1 (D6 → A, add to 1.0)
Commitment comparison:

```text
Commitment                        | Source/approval or pending              | Current                                  | A (add to 1.0)                                  | B (defer to 1.1) | C (skip)
"Send feedback" row               | pending                                 | none                                     | Settings ▸ Backup & support                     | in 1.1           | none
What it sends                     | LogExport (Services/Log.swift:42)       | log exportable by hand (BackupSupport:38)| mail to the support address with version,      | —                | —
                                  |                                         |                                          | build, iOS, device + the last night's log      |                  |
                                  |                                         |                                          | attached; ShareLink fallback with no Mail      |                  |
Person sees what's attached first | privacy page (B2)                       | —                                        | yes, in the compose sheet                      | —                | —
Support address                   | B2 support URL                          | none                                     | one address, also on the support page          | on support page  | on support page
Beta evidence (LG-1)              | approved                                | testers would export by hand             | one tap from the tester                        | by hand          | by hand
```

Question: D6 — FB-1: Add a one-tap "Send feedback" that attaches the night's log? <gstack-qid:plan-ceo-review-expansion-proposal>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: When a night goes wrong, the app already writes down what happened (the playback log), but getting it to you takes several taps through Settings and a share sheet. This adds one "Send feedback" button that opens an email to you with the app version, the phone model and last night's log attached. The beta you just chose depends on testers reporting night failures with evidence, and this is how they'd do it.
Stakes if we pick wrong: a tester says "it stopped around 3am" and you have nothing to debug with, so the beta finds problems it can't help fix.
Recommendation: A because the TestFlight gate is only as good as the reports it produces, and the log export already exists; this wires it to one button.
Note: options differ in kind, not coverage — no completeness score.
Net: a small button that turns "it broke" into a debuggable report, versus asking testers and users to dig through Settings.
Header: Feedback
A) Add to 1.0 (recommended)
A "Send feedback" row in Settings ▸ Backup & support opens a mail draft to your support address with version, build, iOS and device filled in and last night's playback log attached (a share sheet when Mail isn't set up). The person sees the attachment before sending. Effort S, risk low. ✅ Makes the beta's reports debuggable from the first night. ✅ Reuses the existing log export, so it's mostly one row and a mail sheet. ❌ You need a support email address, and you'll get email to answer.
B) Defer to 1.1
Testers and users export the log by hand from Settings for now; recorded in this plan's Deferred list. Effort S, risk low. ✅ 1.0 has one less thing to build before the beta. ✅ The manual export already works today. ❌ Few testers will find and send the log, so most night reports arrive with no evidence.
C) Skip
Rely on TestFlight's own feedback, App Store reviews and the support page's address. Effort S (zero implementation work), risk medium. ✅ Nothing to build. ✅ TestFlight already takes screenshot feedback during the beta. ❌ TestFlight feedback can't carry the playback log, which is what night bugs need.

## Answered: IC-1 (D7 → A, repair this icon)
Commitment comparison:

```text
Commitment                          | Source/approval or pending                  | Current                         | A (repair this icon)               | B (redesign to match the app)     | C (keep as is)
Full-bleed square, no baked corners | AppIcon.png corners white to ~40-60 px      | white corners baked in          | yes                                | yes                               | no
White earbuds in the art            | guideline 5.2.5 (Apple product imagery)     | EarPod-like wired earbuds       | removed or made clearly generic    | gone (new art)                    | kept
Dark + tinted variants (iOS 18+)    | asset catalog has one universal 1024 image  | none                            | added from the same art            | designed with the new art         | none
Art direction                       | pending                                     | storybook sheep on a moon       | unchanged                          | the app's dusk look (orb, ring,   | unchanged
                                    |                                             |                                 |                                    | ember)                            |
Checked on a real home screen       | pending                                     | no                              | yes, before the beta               | yes, before the beta              | no
```

Question: D7 — IC-1: What happens to the app icon before launch? <gstack-qid:plan-ceo-review-expansion-proposal>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: The icon file has white baked into its corners (pixel (40,40) is white, (60,60) is navy), so iOS's own rounding can leave white slivers on the home screen and the store page. The sheep also wears white wired earbuds that look a lot like Apple's EarPods, and App Review can reject icons that show Apple products. Separately, the icon is a bright storybook sheep while the app itself is a calm, dark, amber-and-dusk night screen, so the icon sets a different expectation than the app delivers. This decides how much to change.
Stakes if we pick wrong: white corner slivers and a possible Apple-imagery rejection on the most-seen image of the app, or a redesign that eats beta time for a taste call.
Recommendation: A because it removes both concrete risks while keeping the art you chose; whether the sheep matches the app is a taste call you can revisit with real store data.
Note: options differ in kind, not coverage — no completeness score.
Net: a quick, safe repair of the art you have, versus a new icon that matches the product, versus shipping the known defects.
Header: App icon
A) Repair this icon (recommended)
Re-export the current art full-bleed (navy to the edges, no baked rounding), remove or clearly genericize the earbuds, add iOS 18 dark and tinted variants, and check it on a real home screen before the beta. Effort S, risk low. ✅ Fixes the white corners and the Apple-imagery risk without a new design. ✅ Keeps the counting-sheep idea that the name already plays on. ❌ The storybook style still doesn't match the app's dark, calm look.
B) Redesign to match the app
A new icon in the app's own dusk language (the orb, the night ring, an ember on navy), with dark and tinted variants, done before the beta. Effort M, risk medium. ✅ The icon promises exactly what the app delivers, which helps people who tap through from search. ✅ Fixes the corners and the earbuds by starting over. ❌ Design time before the beta, and a taste call you'd make without store data.
C) Keep as is
Ship the current file. Effort S (zero implementation work), risk medium. ✅ No design work at all. ✅ The art is charming and on-theme for "Sleepulator". ❌ Ships the white-corner defect and the EarPods-lookalike review risk.

## Spec review, round 1 (score 5/10, FAIL; 4 of 5 dimensions)

Reviewer: one independent subagent, both inputs in full, claims checked against code at 0843f65. I re-checked its code claims (`ContentView.swift:114,132`, `AudioDownloader.swift:134`, `SleepTimerService.swift:166-181`, `Log.swift:50`, `BackupSupportView.swift:40`, `Backup.swift:87,302`, `SettingsView.swift:244`, `TESTING.md:658`): all hold.

| # | Finding | Disposition |
|---|---|---|
| C1 | Privacy manifest misses two required-reason APIs | Repaired: **B6** |
| C2 | StoreKit gaps (load failure, can't pay, card after a tip) | Repaired: **B1** done-conditions |
| C3 | Age rating can't be answered with an unfiltered podcast search + pasted feeds | **Decision AR-1** (D11) |
| C4 | iPad compatibility mode, Mac and Vision Pro availability | Repaired inside DF-1 ("iPhone only"): opt out of Mac and Vision Pro; smoke-test iPad compatibility mode |
| C5 | No "done" for new code or the beta | Repaired: B1 adds TESTING.md §T; LG-1 restart rule and first-build contents in "Launch sequence"; done-when per item in "Work items" |
| K1 | Gate skips §3P, which `TESTING.md:658` requires after the podcast-engine changes (PR #28) | **Decision LG-1 reopened** (D10) |
| K2 | Night Limiter is as unverified as Apple Music but stays selectable | Resolved, no change: unlike AM-1 it passed on device before the refactor (`SPEC-STATUS.md:12`), its tap runs on every item anyway (the fade lives there), so §3A/§3C exercise the pipeline; it fails open with one dim line (CLAUDE.md); §3D gates only default-on. §3D runs during the beta |
| K3 | "Data not collected" vs FB-1's email | Repaired: **B3** records Apple's optional-disclosure criteria; B2 says so |
| K4 | "Morning" vs "daytime" | Folded into NT-1's "when may it ask" |
| L1, L2 | "Clean night" and "daytime" undefined | **Decision NT-1** (D8) |
| L3 | B1–B5 have no owner or done condition | Repaired: owner + done columns. Open inputs for the user: B2's host and the support address (see "Launch sequence": needed before build 1) |
| L4 | Card location, its tap, RP-1 repeats | Repaired: the card shows on the tab the app opens to, above the measured mini-player clearance; a tap opens the tip sheet; "Not now" ends it for good. RP-1 asks at most once per app version (Apple's 3-a-year cap still applies) |
| L5 | DF-1 cited Debug lines only | Repaired: ledger cites every target's lines |
| F1 | No clean-night signal exists | **Decision NT-1** (D8) |
| F2 | FB-1 can't attach last night's log after a 3am death | **Decision FB-1 reopened** (D9) |
| F3 | `exportOnlyKeys` export as Bools | Repaired: counters and flags stay device-only (0B, 0G.3) |
| F4 | `requestReview` never shows in TestFlight | Repaired: RP-1 is proved by unit tests on the rule plus a development build on device; the beta can't show it |
| F5 | IC-1 is "Effort S" but there's no source art | Corrected: **Effort M**, owner user (or a designer): the only file is one flattened 1024 px PNG, so removing the earbuds and making a dark variant means redrawing or retouching. Choice A stands |

## Answered: NT-1 (D8 → A, night record)
Commitment comparison:

```text
Commitment                       | Source/approval or pending          | Current                     | A (night record)                         | B (2h played)        | C (usage days)
Signal stored                    | none (SleepTimerService.swift:166)   | nothing persisted           | a night record, opened at the Sleep      | played minutes per   | days with a Sleep
                                 |                                      |                             | session's start, closed at its end       | session              | session
Counts as clean                  | pending                              | —                           | played to its timer's end, or 3+ h on    | 2+ h of sound        | any day the app
                                 |                                      |                             | All night; ended by a person, the timer  |                      | played in Sleep
                                 |                                      |                             | or an episode end; no AVPlayer rebuild,  |                      |
                                 |                                      |                             | no failure streak; an unclosed record    |                      |
                                 |                                      |                             | (app died) is not clean                  |                      |
When the app may ask (TJ-1/RP-1) | TJ-1, RP-1 approved                  | "daytime open"              | first open after a clean night ended,    | same                 | first open of a
                                 |                                      |                             | nothing playing, no sheet, no veil       |                      | new day
Rule + tests                     | SessionGuards pattern                | —                           | pure rule, unit-tested                   | pure rule            | pure rule
Storage                          | 0B (device-only)                     | —                           | device-only, out of backups              | device-only          | device-only
```

Question: D8 — NT-1: What counts as a "good night" for the rating and tip asks? <gstack-qid:plan-ceo-review-clean-night>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: You approved asking for a rating after 3 good nights and a tip after 5, but the reviewer found the app doesn't remember nights at all today. So we have to define a good night and start recording it. The careful version only counts nights where the sound really played through; the simple versions count time or days and could ask someone right after a night that broke.
Stakes if we pick wrong: the app asks for a rating the morning after it stopped at 3am, which turns the rating ask into a one-star invitation.
Recommendation: A because it only counts nights that actually worked, and an unclosed record also tells you which nights didn't.
Completeness: A=9/10, B=6/10, C=3/10
Net: a day more of work for asks that only follow nights that worked, versus simpler counters that can ask at the worst moment.
Header: Good night
A) Night record (recommended)
Record each Sleep night when it starts and close it when it ends. Clean means it played to its timer's end, or 3+ hours on All night, ended by a person, the timer or an episode, with no player rebuild or failure streak; a record left open (the app died) isn't clean. The asks come on the first open after a clean night, with nothing playing. Effort M, risk low. ✅ Never asks after a night that broke. ✅ The open records double as a count of nights that died, useful in the beta. ❌ About a day more work than B, and it touches the session edges in AudioEngine.
B) Two hours of sound
Any Sleep session with 2+ hours of sound counts, however it ended. Effort S, risk medium. ✅ Small: one counter at the session's end. ✅ Easy to test. ❌ A night that played 2 hours and then died still counts, so an ask can follow a bad night.
C) Days used
Count days the app played in Sleep, regardless of how the night went. Effort S, risk medium. ✅ Smallest possible counter. ✅ Works even for short naps. ❌ Knows nothing about whether nights worked, so it asks blind.

## Answered: FB-1 reopened (D9 → A, persist a night trail)
Commitment comparison:

```text
Commitment                         | Source/approval or pending          | Current (FB-1 as approved)        | A (persist a night trail)                  | B (narrow the promise)
What "Send feedback" attaches      | FB-1 approved (D6 → A)              | "last night's log"                | the night trail + MetricKit diagnostics    | the log since the app opened +
                                   |                                     |                                   | delivered since                            | MetricKit diagnostics
After the app died at 3am          | Log.swift:50 (current process only) | attachment would be empty         | the trail has the night up to the death    | the night is missing
Trail contents                     | pending                             | —                                 | session start/stop, interruptions, routes, | —
                                   |                                     |                                   | player rebuilds, failures, terminal stop   |
Where it's written, and how        | render-thread + backup invariants   | —                                 | App Support, excluded from backup, last 2  | —
                                   |                                     |                                   | nights capped ~256 KB, off main, never     |
                                   |                                     |                                   | from the render block                      |
Row wording                        | BackupSupportView.swift:40 note     | —                                 | "Send feedback" (includes last night)      | says "since the app opened"
```

Question: D9 — FB-1 (reopened): How does "Send feedback" get last night's log after a crash? <gstack-qid:plan-ceo-review-night-trail>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: You approved a feedback button that sends last night's log. But iOS only lets the app read its own log from the time it's been running, so if the app died at 3am, the morning's log starts empty, exactly when you need it. The fix is for the app to also write a short diary of the night's key events to a small file as it goes. The alternative is to send what's available and say so.
Stakes if we pick wrong: the beta's most important reports ("it stopped in the night") arrive with no record of the night, so you're guessing at fixes.
Recommendation: A because the night that died is the one the beta exists to catch, and the night record from D8 already marks the same start and end points.
Completeness: A=9/10, B=5/10
Net: about a day of work so crash nights are debuggable, versus an honest button that can't explain the failures that matter.
Header: Night log
A) Persist a night trail (recommended)
The app also writes the night's key events (start and stop, interruptions, route changes, player rebuilds, failures, the timer's stop) to a small file kept on the phone, excluded from backup, last 2 nights, about 256 KB at most, never written from the audio thread. "Send feedback" attaches it plus any iOS crash or hang reports. Effort M, risk low. ✅ Survives the app dying, so a 3am failure arrives with its story. ✅ Shares its start and end points with the night record, so little new plumbing. ❌ About a day more work, and one more file to test for size and cleanup.
B) Narrow the promise
"Send feedback" attaches the log since the app opened plus iOS crash and hang reports, and the row says exactly that. Effort S, risk medium. ✅ Ships with the existing export, nothing new to store. ✅ Honest about what it holds. ❌ After a night where the app died, the attachment has no night in it.

## Answered: LG-1 reopened (D10 → A, add §3P)
Commitment comparison:

```text
Commitment                     | Source/approval or pending               | Current (LG-1 as approved) | A (add §3P)                          | B (keep the four)
Gating device sections         | LG-1 approved (D1 → A); TESTING.md:658   | §3A, §3B, §3C, §3E         | §3A, §3B, §3C, §3E, §3P              | §3A, §3B, §3C, §3E
§3P (pauses during loads, late | TESTING.md:503-545; PR #28 changed       | runs during the beta,      | gating, before submit                | runs during the beta, not gating
ends, offline Auto-Play)       | PodcastPlayer + queue                    | not gating                 |                                      |
Testers, clean-week rule       | LG-1 approved                            | unchanged                  | unchanged                            | unchanged
```

Question: D10 — LG-1 (reopened): Add the podcast-engine checks (§3P) to what must pass before submitting? <gstack-qid:plan-ceo-review-gate-3p>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: You chose to gate the launch on four device checks: background audio, interruptions, the timer fade and an all-night run. The repo's own release checklist also requires the podcast-engine checks (§3P) after any change to the podcast player or queue, and PR #28 changed both. §3P is where "a pause from the lock screen didn't stick" and "offline, the queue emptied overnight" get caught: podcast nights that go wrong.
Stakes if we pick wrong: a podcast-at-night failure, the app's most complex path, reaches the public untested on a phone, against the repo's own checklist.
Recommendation: A because §3P covers exactly the "stopped or silent in the night" class the gate exists for, and the repo's checklist already requires it.
Completeness: A=9/10, B=7/10
Net: one more evening of device checks, versus shipping the riskiest night path on simulator evidence alone.
Header: Gate + §3P
A) Add §3P to the gate (recommended)
Run and log TESTING.md §3P (loads that hold, late ends, offline Auto-Play) on the phone before submitting, alongside §3A, §3B, §3C and §3E. Effort S, risk low. ✅ Matches the repo's own release checklist, which requires §3P after the PR #28 changes. ✅ Covers podcast nights, the path with the most moving parts. ❌ About one more evening of your device time before submitting.
B) Keep the four
Gate on §3A, §3B, §3C and §3E only; §3P runs during the beta but doesn't block. Effort S (zero implementation work), risk medium. ✅ The gate stays exactly as you approved it. ✅ Beta testers who use podcasts still exercise the path. ❌ Departs from the repo's own checklist, and podcast-night bugs could ship untested on a phone.

## Answered: AR-1 (D11 → A, rate for open podcast access)
Commitment comparison:

```text
Commitment                       | Source/approval or pending              | Current                  | A (rate for open access)         | B (filter search + rate for open) | C (filter + rate younger)
Podcast search results           | ITunesSearchManager.swift:22            | all shows, explicit too  | unchanged                        | non-explicit shows only           | non-explicit shows only
Pasted RSS feeds                 | LibraryView add(feedURL:)               | any feed                 | any feed                         | any feed                          | any feed
Age-rating answers (B3)          | 2025 questionnaire                      | not answered             | say third-party podcasts can     | same as A                         | answer as if only the app's
                                 |                                         |                          | carry mature content; accept the |                                   | own sounds count
                                 |                                         |                          | tier Apple computes              |                                   |
Code                             | pending                                 | —                        | none                             | one query parameter + a test      | one query parameter + a test
```

Question: D11 — AR-1: How do podcasts factor into the age rating? <gstack-qid:plan-ceo-review-age-rating>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: Apple sets the app's age rating from a questionnaire you fill in. The sounds are fine for anyone, but the app plays any podcast: its search shows explicit shows too, and people can paste any feed. So the honest answer says the app can play mature content, and Apple will likely give it an older rating (estimated; Apple computes it). Filtering search keeps the app from suggesting explicit shows but can't stop a pasted feed, so it doesn't make a younger rating honest.
Stakes if we pick wrong: answer too young and a reviewer who finds an explicit show can reject the app or force a re-rating; filter for nothing and you've spent effort that doesn't change the rating.
Recommendation: A because your listeners are adults, honesty is required either way, and a filter can't change what a pasted feed plays.
Note: options differ in kind, not coverage — no completeness score.
Net: an honest older rating with no code, versus a cleaner search for a small build, versus a younger rating that review can overturn.
Header: Age rating
A) Rate for open podcast access (recommended)
Answer the questionnaire saying the app plays third-party podcasts that can include mature content, and accept the tier Apple computes. No code change. Effort S (zero implementation work), risk low. ✅ Honest, so nothing for review to overturn later. ✅ No code, nothing to test. ❌ An older rating hides the app from kids' accounts with Screen Time limits, a small audience for a sleep app anyway.
B) Filter search, rate for open access
Add a non-explicit filter to podcast search so the app never suggests explicit shows, and still answer the questionnaire for open access. Effort S, risk low. ✅ The app's own suggestions stay bedtime-appropriate. ✅ Still honest about pasted feeds. ❌ A small build and test that doesn't change the rating.
C) Filter search, rate younger
Filter search and answer the questionnaire as if only the app's own sounds count, treating pasted feeds as the person's own choice. Effort S, risk high. ✅ The youngest possible rating and widest audience. ✅ The filter covers what the app itself shows. ❌ A reviewer who pastes or finds an explicit feed can reject the app or force a re-rating.

## Spec review, round 2 (score 6/10, FAIL; feasibility passed)

Re-checked: `TESTING.md:142-144` (§3E is "mix + timer"), `AudioDownloader.swift:206-214` and `MetricsCollector.swift:73-79` (container file metadata, so C617.1). All hold.

| # | Finding | Disposition |
|---|---|---|
| C1 | NT-1 misreads how All night ends (alarm, headphones out, a long pause, a morning swipe-kill) and counts a 15-minute nap | **Reverted in round 3** (it let a night that died at 3am count as clean, the stake D8 named). Was: repaired to match D8's own wording ("only counts nights where the sound really played through"): a night becomes clean **the moment** it reaches its threshold (its timer's end, or 3 h of sound on All night), written to disk then, so whatever ends it afterwards can't undo it. Before the threshold: pauses under 30 minutes keep the night (UntimedNight's rule); any rebuild, failure streak or app death means not clean. Timed nights count from a 30-minute timer up |
| C2 | The gate never runs a night on the default setting; §3H/§3L | §3E's soak runs on All night with a podcast queue as well as mix + timer (the default is what an "all-night soak" must cover). §3H/§3L stay non-gating, run during the beta: D1 chose to gate "on the sections that decide whether a night works, not on visual polish" |
| C3 | B6 missed C617.1 | Repaired: **B6** |
| C4 | No done-when for NT-1, the trail, the card, RP-1 | Repaired: "Work items" table |
| C5 | The card could offer tips that can't be bought | Repaired: the card shows only once products have loaded and `canMakePayments` is true; otherwise it waits, and the one-time ask isn't used up |
| C6 | An unsuitable first open | Repaired: the ask waits for the next suitable open; it's never used up by an open where it couldn't show |
| K1 | "First open after a clean night" can be 3am or the next bedtime | Repaired to keep the 2am rule both D4 ("on a daytime open", "never at night") and this plan state: the may-ask rule also requires local time 09:00–21:00 and 2+ hours since the night ended. D4 and D8 both hold |
| K2 | Stale text (B1–B5, "six above", "0I", FB-1's attachment) | Repaired |
| K3 | Round-1 counts | Corrected: 19 rows; 11 repaired, 7 settled by decisions D8–D11 (C3, K1, K4, L1, L2, F1, F2), 1 kept with rationale (K2) |
| L1 | Ledger "owner" ≠ implementer | Repaired: ledger owner = who decides; "Work items" names the implementer and done-when |
| L2 | Which build the gate covers | Repaired: submit the build that completed the clean week; after any change to the engine, session, timer or podcast player, rerun the affected gating sections on that build |
| L3 | A clean week is just an absence of reports | **Decision LG-1 reopened** (D12) |
| L4 | The support address is needed before build 1 | Repaired: "Launch sequence" |
| S1 | DF-1 grew past its approval | Repaired: back to build settings; Mac and Vision Pro availability is a B3 setting (D2's "iPhone only"); the iPad compatibility smoke test is a gate review-readiness check (App Review runs iPhone apps there) |

## Spec review, round 3 (score 7/10, FAIL; the review cap, no further reviews)

Re-checked `SleepTimerService.swift:337-342` (the reconcile fires the terminal stop on the morning foreground). The round-3 fixes below are applied but **not reviewer-verified** (cap reached); my own check of each against the plan text is in the report.

| # | Finding | Disposition |
|---|---|---|
| 1 | A deadline reconciled on the morning foreground could count as a clean night | Repaired: the threshold counts only on live ticks with audio; the reconcile path is in the unit tests |
| 2 | Open inputs incomplete (tip product IDs and prices; who runs the check-ins) | Repaired: "Launch sequence" lists every open input and when it's needed |
| 3 | "Never after a tip" holds only per install | Repaired: stated as per install, by design (device-only flags) |
| 4 | Round-2's NT-1 repair contradicted D8 and let a 3am death count | **Reverted to D8's approved rule**, plus two clarifications that don't change it: a force-quit closes the record as "ended by a person"; pauses under 30 min keep the night. The sub-30-minute nap limit (round 2) is dropped: never approved |
| 5 | The gate's build defined two ways | Repaired: one build rule in "Work items" |
| 6 | §T isn't a submit condition | Repaired: in the one build rule and the submit line |
| 7 | RP-1 "on the first open" isn't a natural break | Repaired: asks at a natural break (closing a sheet, leaving a tab), never at launch (Apple HIG, ratings and reviews) |
| 8 | MetricKit sends no diagnostic for a background kill by iOS | Repaired: FB-1 also attaches the metric payloads delivered since the night started |
| 9 | The window + 2 h wait + defer may mean the asks rarely fire | Kept, with the beta measuring it: the check-in asks whether testers saw the tip card. Reach is unknown until then [estimated: low for bedtime-only users]; widening the window is a later call |

## Answered: LG-1 reopened (2) (D12 → A, count real nights)
Commitment comparison:

```text
Commitment                    | Source/approval or pending          | Current (D1)                    | A (count real nights)                       | B (keep D1's rule)
Exit rule                     | LG-1 approved (D1 → A)              | a week with no "it stopped"     | 7 days in a row with no app-caused stop,    | a week with no "it stopped" report
                              |                                     | report                          | AND at least 30 reported tester-nights      |
                              |                                     |                                 | from at least 8 testers in the beta         |
How nights are reported       | B3 "Data Not Collected"; FB-1       | —                               | a one-line morning check-in outside the app | —
                              |                                     |                                 | (form or thread); "Send feedback" with the  |
                              |                                     |                                 | trail on any bad night                      |
App-caused vs not             | Launch sequence restart rule        | owner records why               | unchanged                                   | unchanged
Gating device sections        | D1 + D10                            | §3A/B/C/E/P                     | unchanged                                   | unchanged
```

Question: D12 — LG-1 (reopened): What proves the beta's clean week? <gstack-qid:plan-ceo-review-beta-evidence>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: You chose to submit after a beta week with no "it stopped" reports. But testers who are asleep, busy or quiet don't send anything, and the app collects no data on its own, so a silent week could mean it worked or that nobody used it. Option A asks testers for a one-line morning check-in and requires enough real nights before you submit; option B keeps the rule as it is.
Stakes if we pick wrong: you submit on silence that was really "nobody tested", and the public finds the night bugs instead.
Recommendation: A because a clean week only means something if real nights happened in it, and a one-line check-in is cheap for testers.
Completeness: A=9/10, B=6/10
Net: a little tester effort that turns silence into evidence, versus a simpler rule that can pass on no data.
Header: Beta proof
A) Count real nights (recommended)
Submit after 7 days in a row with no app-caused stop AND at least 30 reported tester-nights from at least 8 testers. Testers send a one-line morning check-in outside the app (a form or a group thread) and use "Send feedback" with the trail on any bad night. Effort S (zero implementation work), risk low. ✅ The week means something: it counts nights that happened, not just silence. ✅ Needs no data collection in the app, so "Data Not Collected" holds. ❌ Testers have to check in daily, and recruiting 8 active ones can stretch the beta.
B) Keep D1's rule
Submit after a week with no "it stopped" report, as approved. Effort S (zero implementation work), risk medium. ✅ The simplest rule, already approved. ✅ No daily ask of testers. ❌ A quiet week can pass with almost no nights tested.

## Accepted scope (1.0)

Baseline (the ask + submission): B1 tip jar (StoreKit 2 consumables, with its edge cases), B2 privacy + support pages, B3 App Store Connect setup (App Privacy "Data Not Collected" via the optional-disclosure criteria; age rating per AR-1), B4 review notes, B5 export-compliance key, B6 privacy-manifest reasons.
Added or settled by decision:
- LG-1 (D1, D10, D12): TestFlight beta first. Device pass §3A, §3B, §3C, §3E (incl. a night on All night with podcasts) and §3P logged on the submitted build; 10–20 external testers for ~2 weeks; submit after 7 days with no app-caused stop and ≥ 30 reported tester-nights from ≥ 8 testers (one-line morning check-ins outside the app).
- DF-1 (D2): iPhone only, portrait only, on the app and widget targets; opt out of Mac and Vision Pro; smoke-test iPad compatibility mode.
- NT-1 (D8, with round-3 clarifications): a persisted night record. Clean = sound actually played (live ticks with audio, never a deadline reconciled on the morning foreground, `SleepTimerService.swift:337-342`) to its timer's end, or 3+ h on All night; ended by a person, the timer or an episode end; no AVPlayer rebuild and no failure streak across the whole night; a record left open (the app died) isn't clean. A force-quit while playing closes the record as "ended by a person" (the terminate notification a running background-audio app receives; device-checked in §T). Pauses under 30 min keep the night (UntimedNight's rule). Asks come at a natural break (the person closes a sheet or leaves a tab, never at launch) during a suitable open: nothing playing, no sheet, no veil, 09:00–21:00 local, 2+ h after the night ended; an unsuitable open defers the ask, never uses it up.
- TJ-1 (D4): tip jar in Settings ▸ Backup & support + one card after the 5th clean night; never after a tip; never twice.
- RP-1 (D5): Apple's rating prompt after the 3rd clean night, at most once per version, never the tip card's day + a "Rate Sleepulator" row.
- FB-1 (D6, D9): "Send feedback" with version/device + the persisted night trail + MetricKit diagnostics.
- IC-1 (D7): repair the icon (full-bleed, generic earbuds, dark + tinted), effort M, art by the user or a designer.
- AR-1 (D11): age rating answered for open podcast access; no search filter.
Cut from 1.0 by decision: AM-1 Apple Music picker (deferred to 1.1).

## 0I. Temporal interrogation (documents approved: D13 → A)

```
  HOUR 1 (foundations)     The implementer needs: the night lifecycle (AudioEngine.noteSessionEdge, UntimedNight,
                           SleepTimerService.fireTerminalStop / reconcileIfExpired), where Log calls live (Services/Log.swift),
                           the Backup allowlist rule (device-only keys), the isolated-deinit rule, SessionGuards' pure-rule pattern.
  HOUR 2-3 (core logic)    Ambiguities: which session edge opens and closes a night when Sleep and a podcast overlap; how a
                           player rebuild and a failure streak reach the night record (PodcastPlayer → AudioEngine); what the
                           trail writes for a route change vs an interruption; the may-ask rule's inputs (clock injected).
  HOUR 4-5 (integration)   Surprises: StoreKit products don't load in TestFlight until the Paid Apps agreement is active; the
                           terminate notification only reaches a running (background-audio) app, not a suspended one;
                           requestReview is silent in TestFlight; the card must respect Home's measured mini-player clearance
                           and "hidden means not rendered".
  HOUR 6+ (polish/tests)   They'll wish they'd planned: an injectable clock + file location for the night record and trail
                           (unit tests, no real nights); a .storekit config in the test scheme; a §T device section written
                           before build 1, not after; a CI-safe UI test for the card that leaves persisted state as it found it.
```

Effort (both scales):

| Work | Human team | CC + gstack |
|---|---|---|
| Code: B5, B6, DF-1, AM-1 hide | ~half a day | ~20 min |
| Code: NT-1 record + may-ask rule + tests | ~2–3 days | ~1–2 h |
| Code: FB-1 trail + Send feedback + tests | ~2 days | ~1 h |
| Code: B1 tip jar + TJ-1 card + RP-1 + tests | ~3 days | ~1–2 h |
| TESTING.md §T + B2 page text + B4 notes draft | ~1 day | ~30 min |
| User: agreements, products, ASC, hosting, address | ~1 day of tasks, plus days of Apple processing | same (user-owned) |
| User: icon retouch | ~half a day to 2 days | same (user-owned) |
| User: device pass §3A/B/C/E/P + §T | ~6 evenings/nights | same (user-owned) |
| Beta (D12 exit) | ~2 weeks calendar | same |

Feasibility blockers: none found in code. External blockers, all user-owned: the Paid Apps agreement (tips can't load without it), the support address (FB-1 and external TestFlight need it), and recruiting 8+ testers who check in daily. Pending implementation choices (owner: the implementation session; strategy depth leaves them open): tip tiers' names and prices (user supplies), the trail's exact event list and file format, the card's copy.

## Review sections (strategy depth: capability rows and "implementation owner must prove" notes)

### Section 1: Architecture

```
 SleepulatorApp ──starts at launch──> TipStore (own ObservableObject; Transaction.updates + unfinished)
        │                                   │ products, state (idle/loading/unavailable/purchasing/pending/thanked)
        │                                   ▼
 AudioEngine ──noteSessionEdge──────> NightRecorder ──open / threshold / close──> NightRecordStore (JSON, App Support,
   ├ PodcastPlayer: rebuild, failure ─┘      │                                        device-only, last ~30 records)
   ├ SleepTimerService: terminal stop ───────┘ (reconcile-on-foreground path flagged: not live audio)
   └ Log events (key night events) ──────────> NightTrail (rolling text file, App Support, excluded from backup,
                                                 last 2 nights, ~256 KB, serial queue, no URLs)
 ContentView / HomeView ──reads──> AskPolicy (pure) <── NightRecordStore, TipStore.state, injected clock,
        │                                              SessionGuards (sheet up, veil down, playing)
        ├──> TipCard ──tap──> TipStore.purchase              (existing, unchanged) MetricsCollector ──payload files──┐
        └──> requestReview (SwiftUI environment)                                                                  │
 BackupSupportView ──> Tip rows · Rate row · Send feedback ──> FeedbackComposer (MessageUI or ShareLink) <────────┘
                                                                     └── attaches NightTrail + MetricKit payloads + night summary
```

New coupling: one hook from `AudioEngine.noteSessionEdge` (and the player's rebuild/failure callbacks) into `NightRecorder`. Justified: those edges already define a Sleep night (UntimedNight), so the record follows the existing lifecycle instead of inventing one.

Night record state machine:

```
  (none) ──Sleep session edge: idle→playing──> OPEN(started, livePlayed=0)
  OPEN ──live audio ticks──> OPEN(livePlayed += Δ)      [deadline reconciled on foreground: no Δ]
  OPEN ──pause < 30 min──> OPEN                          [UntimedNight's rule]
  OPEN ──rebuild / failure streak──> OPEN(tainted)
  OPEN ──person stop · timer end · episode end · force-quit (terminate notice)──> CLOSED(clean if reached threshold and not tainted)
  OPEN ──found open at next launch (app died)──> CLOSED(not clean, died)
  Invalid: CLOSED→OPEN (a new night opens a new record); two OPEN at once (opening one closes any prior OPEN as died)
```

| # | Finding | Severity | Disposition |
|---|---|---|---|
| A1 | The record must follow `noteSessionEdge` + UntimedNight's pause rule, not a parallel lifecycle | WARNING | Implementation owner must prove: open/close come from the existing session edges; unit tests share UntimedNight's 30-minute fixtures. Covered by D8 |
| A2 | New engine-owned or test-created classes (`NightRecorder`, `NightTrail`, `TipStore`) hit the isolated-deinit runtime bug | WARNING | Implementation owner must prove: each declares `nonisolated deinit {}` (CLAUDE.md § Isolated deinits); `IsolatedDeinitRuntimeBugTests` stays green on the iOS 26.2 CI leg |
| A3 | Nothing new may be `@Published` on `AudioEngine` | OK | Covered by the 0G.3 invariant; `TipStore` and `NightRecorder` are their own objects |
| A4 | Failure scenario: StoreKit unreachable at launch | OK | B1: the row says tips aren't available; the card waits |
| A5 | Failure scenario: the trail or record can't be written (disk full) | OK | Writes are best-effort off main; a failure logs once and never touches audio |
| A6 | Rollback posture | WARNING | No backend, so no remote kill switch. 1.0's rollback is the beta itself; after launch, a fix ships as a new build (expedited review for a night-breaking bug). From 1.0.1 on, use phased release for updates. Recorded in Section 9 |

Platform note (SELECTIVE): the night record is the foundation the specs already want for history (SLEEP-MODE-SPEC "history", FOCUS-MODE-SPEC R7). Keep its format versioned (Section 10).

### Section 2: Error & Rescue Map (capability level)

```
  CAPABILITY                  | WHAT CAN GO WRONG                                  | CLASS
  ----------------------------|----------------------------------------------------|------------------------------
  TipStore.loadProducts       | offline; agreement inactive; IDs mismatch → []     | StoreKitError.networkError; empty result
  TipStore.purchase           | person cancels                                     | .userCancelled
                              | Ask to Buy                                         | .pending
                              | not allowed (restrictions)                         | PurchaseError.purchaseNotAllowed / canMakePayments=false
                              | network                                            | StoreKitError.networkError
                              | verification fails                                 | VerificationResult.unverified
  TipStore launch listener    | transaction approved while the app was closed      | Transaction.updates / .unfinished
  NightRecordStore read       | file missing; corrupt JSON; future schema version  | DecodingError; version mismatch
  NightRecordStore / Trail    | disk full; write while locked                      | CocoaError.fileWriteOutOfSpace; NoPermission
  write                       |                                                    |
  NightTrail read             | last line truncated (killed mid-write)             | partial UTF-8 line
  FeedbackComposer            | Mail not set up                                    | MFMailComposeViewController.canSendMail()=false
                              | attachments too big                                | size over cap
  requestReview               | Apple declines to show                             | (no signal)

  CLASS                         | RESCUED? | RESCUE ACTION                                  | PERSON SEES
  ------------------------------|----------|------------------------------------------------|----------------------------------
  empty products / networkError | Y        | retry on next Settings open; card waits        | "Tips aren't available right now"
  .userCancelled                | Y        | nothing                                        | the row as it was
  .pending                      | Y        | wait for Transaction.updates                   | "Waiting for approval"
  purchaseNotAllowed            | Y        | hide the tip rows and the card                 | no tip jar
  .unverified                   | Y        | don't thank, don't set tipped, finish, log     | "That didn't go through"
  updates / unfinished          | Y        | finish; set tipped; thank on next Settings open| a thank-you
  DecodingError / version       | Y        | treat as no record; log once; no asks          | nothing
  fileWriteOutOfSpace etc.      | Y        | drop this write; log once; never block audio   | nothing
  truncated trail line          | Y        | reader skips a partial last line               | nothing
  canSendMail=false             | Y        | ShareLink with the same attachments            | the share sheet
  attachments over cap          | Y        | newest-first until under the cap; note omitted | a note in the mail body
  requestReview silent          | n/a      | log "asked" once per version                   | maybe nothing (Apple's call)
```

No catch-alls: each StoreKit outcome maps to one state (the pure mapping B1 unit-tests). GAPS: none left unrescued.
Implementation owner must prove: night files are written with the default data-protection class (the app has no data-protection entitlement, so "until first unlock" applies); never `.completeFileProtection`, which would fail every write at 3am with the phone locked. Checked by the killed-night device step.

### Section 3: Security & Threat Model

| Threat | Likelihood | Impact | Mitigated? |
|---|---|---|---|
| **The trail leaks private feed tokens.** Paid podcast feeds (Patreon, Supercast and similar) carry the subscriber's secret in the URL. The trail is a plain text file (OSLog's privacy redaction doesn't apply), and FB-1 mails it to the developer | Med | High (a paid-feed credential in an email) | **Repaired:** the trail never writes a URL: show and episode titles, the feed's host at most. Unit test: no `://` in trail output. The existing OSLog lines already keep URLs private (checked: no feed URL logged `.public`) |
| Forged "tipped" state (jailbreak) | Low | None (tips unlock nothing) | n/a |
| Unverified transaction counted as a tip | Low | Low | Yes: `.unverified` never sets tipped |
| Mail attachment includes more than the person expects | Med | Med | Yes: the compose sheet shows the attachments; the privacy page (B2) describes them |
| New dependencies | None | — | StoreKit and MessageUI are system frameworks |
| Injection | None | — | The mail body is built from device facts and app strings only |

### Section 4: Data Flow & Interaction Edge Cases

```
 SESSION EDGE ─> NightRecorder (main) ─> classify (pure) ─> NightRecordStore.write (serial queue) ─> AskPolicy on next suitable open
   shadow: no Sleep session (Focus) → no record · reconcile-on-foreground → no live Δ · corrupt file → no asks
           two edges in one runloop → one open record · write fails → dropped, logged

 LOG EVENT ─> NightTrail.append (serial queue) ─> rotate at cap ─> FeedbackComposer reads newest-first
   shadow: URL in message → stripped · disk full → dropped · killed mid-write → partial last line skipped
```

Async ordering. Invariant: an event (failure, rebuild, end) is filed under the night that was open when it happened, never the next one. Mirrors CLAUDE.md's "item-level news is filed by item". Callbacks from `PodcastPlayer` can arrive off main and after a night closed (`.AVPlayerItemDidPlayToEndTime` already does).

```
  t   | Player callback (off main)       | Person / engine (main)           | NightRecord state
  ----|----------------------------------|----------------------------------|----------------------------
  1   | failure on item X (night N)      |                                  | N open
  2   | (hop to main pending…)           | stop → close N                   | N closed(clean?)
  3   | lands on main                    |                                  | must NOT taint N+1 or reopen N
  4   |                                  | new session → open N+1           | N+1 open
```

Mechanism: every event carries the night id captured when it was raised. The recorder ignores ids that aren't the open night (and taints N only if N is still open). Regression proof: unit test with a controlled callback held across a close and a reopen, both orders.

| Interaction | Edge case | Handled? | How |
|---|---|---|---|
| Tip button | double tap | Yes | Disabled while purchasing |
| Tip button | leave Settings mid-purchase | Yes | `Transaction.updates` finishes it; thanks on next open |
| Tip card | tap, then cancel the purchase | Yes | The card counts as used (D4: never twice) |
| Tip card | VoiceOver on | Yes | A labeled container with a reachable "Not now" (Section 11) |
| Rate row | before the App Store app ID exists | **Gap → repaired** | The row needs the app's numeric App Store ID (`…/id<ID>?action=write-review`), known only after the App Store Connect record is created. Added to the open inputs |
| Send feedback | no night recorded yet | Yes | The mail says "no night recorded yet" and attaches what exists |
| Send feedback | tapped twice | Yes | One sheet at a time |

### Section 5: Code Quality

| # | Finding | Disposition |
|---|---|---|
| Q1 | Reuse: "a sheet or dialog is up" and "the veil is down" already live in `SessionGuards` (`veilTimeout`, `mayNightDim`) | Implementation owner must prove: `AskPolicy` takes those as inputs instead of re-deriving them |
| Q2 | Over-engineering risk: a generic "prompt framework" | One `AskPolicy` with two asks (rate, tip); no registry |
| Q3 | Fit: pure rules next to `SessionGuards` (unit-tested), services in `Services/`, rows in `BackupSupportView` | OK |
| Q4 | Naming | Name things for what they hold: `NightRecord`, `NightTrail`, `TipStore`, `AskPolicy` |
| Q5 | Complexity: the classifier is the branchiest new function | Keep it a table-driven pure function; tests enumerate the state machine above |

### Section 6: Tests

```
 NEW THING                         | TYPE        | HAPPY                         | FAILURE                               | EDGE
 ----------------------------------|-------------|-------------------------------|---------------------------------------|------------------------------------
 Night classifier (NT-1)           | unit        | 3h live All night → clean     | rebuild / failure streak → not clean  | reconcile path; pause 29 vs 31 min; force-quit after threshold
 Night id filing (Section 4)       | unit        | event during N taints N       | late event after close ignored        | held callback across close+reopen, both orders
 AskPolicy (TJ-1, RP-1)            | unit        | 3rd clean → rate; 5th → card  | playing / sheet / veil → defer        | 08:59 vs 09:00; 1h59 vs 2h; same day; new version; tipped
 TipStore mapping (B1)             | unit        | verified → thanked            | unverified → not tipped               | each StoreKit outcome → one state
 TipStore with StoreKit (TS-1)     | unit (SKTest)| success → thanked             | failure / cancel / interrupted        | Ask to Buy pending → approved later via updates
 NightTrail                        | unit        | append + read newest-first    | write fails → dropped                 | cap + rotate; partial last line; no "://"
 FeedbackComposer attachments      | unit        | trail + payloads + summary    | no Mail → share list                  | over cap → newest-first + note
 Card on Home (TS-2)               | UI (XCUITest)| card shows; controls hittable | "Not now" → gone (waitForNonExistence)| mini-player shown; state restored after
 Device §T                         | device      | sandbox tip; dev-build rating | killed night → open record + trail    | force-quit closes record; locked-phone writes
```

Assertion check (B1/TJ-1/RP-1/NT-1/FB-1 tests are approved coverage; listed so nothing is silently dropped):
- Classifier: asserts `clean == true` only when live-played ≥ threshold, untainted and closed normally. Rejects a reconciled deadline counting. no_claim=real AVAudioSession behavior at 3am (injected events; §3E/§T cover it on device).
- AskPolicy: asserts the exact boundaries above with an injected clock. no_claim=whether Apple shows the rating prompt (Apple's call; dev build on device).
- Trail: asserts no `://` and the 256 KB cap. no_claim=file protection while locked (device step).
- Test ambition: the 2am-Friday test is the killed-night device step; hostile QA changes the clock and time zone mid-night (the classifier counts live ticks, not wall-clock differences); the chaos test kills the app mid-write (partial line skipped). Flakiness: every time-based rule takes an injected clock (the `now()` pattern `SleepTimerService` already uses).

## Answered: TS-1 (D14 → A, add StoreKitTest)
Commitment comparison:

```text
Commitment                                  | Source/approval or pending        | Current (B1 as approved)            | A (add StoreKitTest)                         | B (keep B1's plan)
Pure purchase-state mapping unit tests      | B1 approved                       | yes                                 | yes                                          | yes
Purchase paths against StoreKit in CI       | pending                           | none                                | SKTestSession on the .storekit file: success,| none
                                            |                                   |                                     | cancel, Ask to Buy, failure, interrupted,    |
                                            |                                   |                                     | approved-while-closed (updates)              |
Sandbox purchase on device (§T)             | B1 approved                       | yes                                 | yes                                          | yes
Runs on CI's iOS 26.2 + 26.5 legs           | ci-full-suite memory              | —                                   | yes (simulator, no account)                  | —
```

Question: D14 — TS-1: Test the tip purchase paths against StoreKit in CI? <gstack-qid:plan-ceo-review-storekit-tests>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: The approved plan tests the tip jar's logic with plain unit tests and one real sandbox purchase on your phone. But the cases App Review and real people hit (a parent's Ask to Buy approval, a failed payment, a purchase approved after the app closed) are hard to trigger by hand. Apple's StoreKit test tools can simulate each of them on the simulator, so CI checks them on every change. A broken tip purchase is a common reason apps get rejected.
Stakes if we pick wrong: a pending or failed purchase leaves the tip jar stuck or thanks someone who wasn't charged, and App Review or a parent finds it first.
Recommendation: A because these paths are cheap to simulate and nearly impossible to reproduce by hand, and the engineering preference here is that every behavior gets a test that would catch its regression.
Completeness: A=9/10, B=6/10
Net: a small test file that covers every purchase outcome on every change, versus trusting one manual purchase.
Header: IAP tests
A) Add StoreKitTest (recommended)
Add simulator tests that run the tip jar against the .storekit file with Apple's StoreKit test session: success, cancel, Ask to Buy, failure, interrupted, and a purchase approved while the app was closed. They run in CI on both iOS legs. Effort S, risk low. ✅ Every purchase outcome is checked on every change, with no Apple account. ✅ Catches the stuck-or-wrong-thanks bugs App Review rejects for. ❌ One more test file to keep in step with the products, and StoreKit testing on CI simulators can need a retry.
B) Keep B1's plan
Pure mapping unit tests plus one sandbox purchase on device during §T. Effort S (zero implementation work), risk medium. ✅ Nothing more to build or maintain. ✅ The sandbox purchase still proves the happy path for real. ❌ Ask to Buy, failures and late approvals are never exercised before review.

## Answered: TS-2 (D15 → A, add a UI test)
Commitment comparison:

```text
Commitment                                  | Source/approval or pending          | Current                     | A (add a UI test)                              | B (device check only)
Card's layout on Home                       | TJ-1 approved; §T                   | §T device check             | §T + a CI UI test                              | §T device check
What the UI test asserts                    | HomeLayoutUITests patterns          | —                           | card shown from a seeded clean night (launch   | —
                                            |                                     |                             | args); Home controls hittable; card clears the |
                                            |                                     |                             | mini-player; "Not now" → waitForNonExistence;  |
                                            |                                     |                             | persisted state left as found                  |
Runs on CI                                  | ci-full-suite memory                | —                           | both iOS legs, with the dropped-tap retries    | —
```

Question: D15 — TS-2: Add a CI check that the tip card doesn't break Home's layout? <gstack-qid:plan-ceo-review-card-ui-test>
Project/branch/task: Sleepulator App Store 1.0 readiness on claude/app-store-readiness-391005.
ELI10: Home's layout has broken twice before: the mini-player once hid Focus's controls, and an accessibility shape once made Home's buttons untappable in tests. A UI test now guards both, but it never runs with the new tip card on screen. This adds one UI test that fakes a good night so the card appears, then checks Home's buttons still work, the card clears the mini-player, and "Not now" really removes it.
Stakes if we pick wrong: the card covers or blocks a Home control on some screen size, and nobody notices until a tester's fifth good night.
Recommendation: A because the card sits on the screen that has broken before, and the engineering preference is a test for every regression we can name.
Completeness: A=9/10, B=6/10
Net: one more UI test in a pattern that already exists, versus checking the card by hand once on one phone.
Header: Card test
A) Add a UI test (recommended)
One XCUITest launches with a seeded clean night (launch arguments, as the existing UI tests do), asserts the card shows, Home's controls stay hittable, the card clears the mini-player, and "Not now" removes it (waitForNonExistence); it leaves persisted state as it found it. Effort S, risk low. ✅ Guards the screen that has regressed before, on every change. ✅ Reuses HomeLayoutUITests' patterns and CI's tap retries. ❌ A UI test adds a little CI time and can need a retry on slow runners.
B) Device check only
Check the card's layout by hand in §T on your phone. Effort S (zero implementation work), risk medium. ✅ Nothing more to build. ✅ A real screen, real fingers. ❌ One phone size, once, and no guard against later changes.

### Section 7: Performance

| Path | Cost | Bound |
|---|---|---|
| Night record writes | open, threshold, close: about 3 small JSON writes a night, off main | Last ~30 records kept |
| Live-audio accumulation | in memory on the existing tick; never a write per tick | none needed |
| Trail appends | key events only (session edges, interruptions, routes, rebuilds, failures, the stop): tens a night | ~256 KB, 2 nights, rotate |
| `Transaction.updates` listener | idle until StoreKit delivers | none |
| Feedback assembly | reads the trail + newest MetricKit files on tap, off main | total attachment cap |
| AskPolicy | a pure check on scene activation | O(1) |

Slowest new paths: feedback assembly (a few hundred KB read on tap: well under a second, estimated), product loading (network-bound; the row shows a loading state), the first trail rotation. No render-thread work (CLAUDE.md: never block the render thread): nothing here runs in the `AVAudioSourceNode` block. No issues found that need a decision.

### Section 8: Observability & Debuggability

The night record and trail are this release's observability: with no backend and "Data Not Collected", evidence only leaves the phone when a person sends it.

| Signal | Tells you it works | Tells you it broke |
|---|---|---|
| Beta check-ins (D12) | reported clean nights | an "it stopped" check-in |
| Night records (in the feedback mail's summary line) | clean nights | open records (app died), tainted nights |
| Night trail | the night's events up to the end | where it stopped: a rebuild, an interruption, a route change, the last event before a death |
| MetricKit (existing) | daily metrics | exit counts (background kills), hang/crash diagnostics |
| TestFlight / Xcode Organizer | crash-free sessions | crash reports (opt-in users) |

**Runbook: a "stopped / silent at 3am" report.**
1. Read the trail's last events before the gap. CLAUDE.md first: `podcast resume:` and `rebuilding the AVPlayer` lines before touching volume code.
2. Read the MetricKit metric payload's background exit counts (a memory or watchdog kill shows only there) and any diagnostic.
3. Match it to a TESTING.md section, reproduce on device, fix, and ship a new build. If the cause is in the app, the 7 clean days restart (D12).

The feedback mail carries a one-line night summary (e.g. "last 7 nights: 5 clean, 1 ended early, 1 left open"), built from the night records FB-1 already attaches. **Pending (delight list, opt-in):** this line is listed below, not added.

### Section 9: Deployment & Rollout

- **Migrations:** none. New files only; older builds ignore them; backups and restores are unchanged (the new keys are device-only).
- **Feature flags:** none remote (no backend, by design). Launch arguments seed the card and the night records for tests only.
- **Order:** internal TestFlight → external TestFlight (Beta App Review, ~1 day estimated) → App Review → release.
- **Release control:** choose "Manually release this version" in App Store Connect so approval doesn't launch the app before you're ready (a B3 form choice, user-owned).
- **Rollback:** a shipped binary can't be rolled back. A night-breaking bug gets a fix build with expedited review; from 1.0.1, phased release for updates.
- **Production check after release:** install 1.0 from the App Store (not Xcode) on your phone, run one night, and buy the smallest tip yourself. Production StoreKit isn't the sandbox, and that's the only proof the live products work.
- **Smoke tests:** CI already runs the unit and UI suites on both iOS legs per PR (ci-full-suite); TS-1 and TS-2 join them.

### Section 10: Long-Term Trajectory

| Item | Reversibility (1 = one-way, 5 = easy) | Note |
|---|---|---|
| iPhone-only (DF-1) | 5 | iPad can be added later; that's why D2 chose it |
| Bundle ID `app.sleepulator.Sleepulator` | 1 | Permanent once the first build uploads. It reads fine; confirm before build 1 |
| App Store name | 3 | Names are unique per store and can change with a version; check "Sleepulator" is free when creating the record |
| Night record + trail formats | 4 | Implementation owner must prove: a schema version field from day one, so history features can read old records |
| Consumable tips | 4 | Tips carry no entitlement, so the jar can change freely |
| Age rating (AR-1) | 4 | Re-answerable per version |

Debt introduced: two file formats (versioned), one new test file each for StoreKit and the card, TESTING.md §T. Documentation: CLAUDE.md gains the night record's invariants (filed by night id; live audio only; device-only keys) when the code lands.
What comes after: 1.1 = Apple Music (AM-1) plus what the beta teaches; then the visual moat's device-tuned scenes on the product page; then night history, which the night record already makes possible.
Retrospective (SELECTIVE): the accepted cherry-picks hold up: FB-1 and NT-1 turned out to be the beta's backbone, and deferring Apple Music removed the only review path that depended on a portal step. No rejected expansion was load-bearing (none were rejected).

**Delight list (at least 5; each opt-in, available on request, none added):**
1. The night summary line in the feedback mail (from Section 8).
2. A thank-you that fits the app: after a tip, the orb glows a little warmer that night, once (no unlock).
3. A one-sentence, honest tip jar line: "Sleepulator is free, with no ads or account. Tips keep it that way."
4. Repeatable App Store screenshots from a UI test (the simulator capture recipe already in this repo's learnings).
5. TestFlight "What to test" notes that point testers at the morning check-in and Send feedback.
6. A daytime-only "What's new" sheet when 1.1 brings Apple Music back.

### Section 11: Design & UX

```
 night 1–2: nothing new ─> night 3 ends clean ─> next suitable daytime open ─> natural break ─> Apple's rating prompt (maybe)
 night 5 ends clean ─> next suitable daytime open (not the rating's day) ─> Tip card on the opening tab
        ├─ "Not now" ─> gone for good
        └─ tap ─> tip sheet ─> pick a tip ─> (cancel → card used) / (pending → "Waiting for approval") / (success → thank-you)
 any time: Settings ▸ Backup & support ─> Support Sleepulator (tips · Rate · Send feedback)
```

| Feature | Loading | Empty | Error | Success | Partial |
|---|---|---|---|---|---|
| Tip rows | "Loading…" row, never forever | "Tips aren't available right now" | "That didn't go through" | thank-you line | "Waiting for approval" (Ask to Buy) |
| Tip card | not shown until products load | not shown | card stays, sheet shows the error | card gone, thank-you | card gone, pending note in Settings |
| Send feedback | gathering (progress in the row) | "no night recorded yet" in the mail | share sheet if no Mail | mail sent (system) | attachments trimmed + a note |
| Rate row | — | — | opens the App Store page | — | — |

Design intent: Settings rows reuse `SettingActionRow`. The card follows the 2am rules even in daylight: `Palette(focusMode:)`, `EmberButtonStyle`, no solid accent slab, dim text. It sits above the measured mini-player clearance, and "Not now" removes it from the hierarchy ("hidden means not rendered"). Copy is plain and short, with no guilt and no streaks. VoiceOver reads the card as one labeled container with two actions; it scales with Dynamic Type; tap targets are 44 pt.
Recommendation: run `/plan-design-review` on the card and the Support group before implementation, and `/design-review` on device after.

## Work items (implementer and done-when)

| Item | Implementer | Done when |
|---|---|---|
| DF-1 build settings | code | Device family 1 and portrait-only on the app and widget, Debug and Release; HomeLayoutUITests pass |
| AM-1 hide | code | The Apple Music entry in the Focus mixer (`MixPanel.swift:130-137`) is gone in 1.0; nothing else changes |
| NT-1 night record + may-ask rule | code | Pure, unit-tested: a night's classification (threshold reached on live audio, the reconcile-on-foreground path never counting, pauses under 30 min, rebuild, failure streak, app death anywhere in the night, force-quit closing the record) and the may-ask rule (nothing playing, no sheet, no veil, 09:00–21:00 local, 2+ h since the night ended, a natural break, waits rather than lapses). Device: one night killed mid-sleep leaves an unclosed record and a trail up to the kill (TESTING.md §T) |
| FB-1 night trail + Send feedback | code (support address from user) | Trail capped and pruned, never writes a URL (unit-tested: no `://` in output); on device, "Send feedback" after a killed night attaches that night's trail plus any MetricKit diagnostic and metric payloads delivered since the night started (a background kill by iOS shows up only as exit counts in the metric payload) (§T) |
| TJ-1 tip jar + card | code (products from user) | B1's list; the card's rule is unit-tested (5th clean night, products loaded, never after a tip on this install, never twice; per install by design, since the flags are device-only); a sandbox purchase on device (§T) |
| TS-1 / TS-2 tests | code | StoreKitTest file covers the six purchase outcomes; the card's XCUITest passes on both CI legs and restores persisted state |
| RP-1 rating prompt + row | code | The rule is unit-tested (3rd clean night, once per version, never the card's day); a development build on device shows the prompt (TestFlight never does) |
| IC-1 icon | user (or a designer) | Full-bleed, no earbuds that read as EarPods, dark + tinted variants; checked on a real home screen |
| LG-1 gate | user | **One build rule:** the gating sections (§3A, §3B, §3C, §3E incl. a night on All night with podcasts, §3P) and §T pass on the submitted build, or on an earlier build when every later change is outside the engine, session, timer and podcast player (icon, StoreKit, copy). A build that changes the engine, session, timer or podcast player reruns the affected sections and restarts the 7 clean days; the ≥ 30 reported tester-nights from ≥ 8 testers (D12) may span builds. Plus the iPad compatibility smoke test |
| B2–B4 | user | See the baseline table |

## Launch sequence

```
 USER (parallel, start now)                         CODE (one implementation session, then PRs)
 ─────────────────────────                          ───────────────────────────────────────────
 Support address (before build 1) ────┐             Build 1 (internal TestFlight):
 Paid Apps agreement + tax + banking ─┤               B5, B6, DF-1 settings, AM-1 hide,
 Host for B2 ─────────────────────────┤               (B2 can follow; the address can't)
 Icon retouch (IC-1) ─────────────────┤               NT-1 night record, FB-1 trail + Send feedback,
 Device pass §3A/B/C/E/P on build 1 ──┤               TJ-1/RP-1 may-ask rule, tip jar (if products load)
 Recruit 10–20 testers ───────────────┘             Build 2 (external TestFlight, needs Beta App Review):
                                                       tip jar live, repaired icon, any gate fixes
          │                                                      │
          └──────────────── beta: ~2 weeks of real nights ───────┘
                 an "it stopped" report with an app cause → fix → new build → the clean week restarts
                 (a report traced to the tester's setup, e.g. the phone died, is recorded and doesn't)
                                         │
     gate + §T passed (one build rule) + D12's exit met + B2/B3/B4 done → submit 1.0
```

Open inputs only the user can supply, and when: the support address (before build 1); the app's numeric App Store ID, from creating the App Store Connect record (before the build with the Rate row); tip product IDs and prices (before the build that carries the tip jar, so the `.storekit` file matches App Store Connect); the morning check-in form or thread and who reads it (before external testing, D12; it also asks "did you see the tip card?", since the card shows in TestFlight but the rating prompt can't); B2's host (before submit); who retouches the icon (before build 2).

The first build testers get must include FB-1 and the night trail: they're how the beta reports night failures. The support address must exist before build 1 (FB-1 mails it, and external TestFlight asks for a feedback email); B2's host can follow. The gate covers the build that's submitted: after any change to the engine, session, timer or podcast player, rerun the affected gating sections on that build.

### Candidates not raised (available on request)

Ranked below the decisions above; each would go through its own Add / Defer / Skip if you want it.
1. Accessibility Nutrition Labels on the product page (App Store Connect answers; claims need a VoiceOver / Larger Text check on device first).
2. An app preview video of the reactive scenes (the moat, per the 2026-07-05 CEO plan) on the product page.
3. (Promoted to AR-1 by the spec review.)
4. A richer first run than `FirstRunCoachmark` (it was cut to "one thing" on purpose in c3674ad).
5. Localization (English only today; no `.xcstrings`).

## NOT in scope

| Item | Disposition | Answer | Reason |
|---|---|---|---|
| Apple Music in Focus (AM-1) | Deferred to 1.1 | D3 | Never device-tested; MusicKit portal step unconfirmed; better as 1.1's headline. Hide the picker at `Views/Home/MixPanel.swift:137`; keep `NSAppleMusicUsageDescription` while MusicKit code is linked |
| iPad layouts, iPhone landscape (DF-1) | Not in 1.0 | D2 | iPhone portrait only; iPad can be added later, never removed |
| A podcast-search explicit filter | Not added | D11 | Honest rating either way; a filter can't stop pasted feeds |
| §3H / §3L as gating sections | Run during the beta, not gating | D1 | "Gates on the sections that decide whether a night works, not on visual polish" |
| A minimum timer length for a clean night | Dropped | round 3 | Added in round 2 without approval; D8 counts any timer that played through |
| Delight list (6 items, Section 10) | Pending, opt-in on request | — | Offered, not accepted |
| Candidates not raised (a11y labels, preview video, richer first run, localization) | Pending, opt-in on request | — | Ranked below the decisions taken |

## What already exists

See 0B: the Settings ▸ Backup & support page, `LogExport`, `MetricsCollector`, `SessionGuards`, `UntimedNight` and the session edges, `Backup`'s device-only precedent, `FirstRunCoachmark`, the widget and intents. All reused; the only new subsystems are the tip store, the night record and the trail.

## Dream state delta

After this plan: a 1.0 whose night is proven on glass by you and by ≥ 8 testers over ≥ 30 nights, that asks for nothing until it has worked, and that tells you what happened when it doesn't. Still to reach the 12-month ideal: the reactive scenes tuned on device and leading the product page, Apple Music back (1.1), iPad if demand shows, night history on top of the night record, and a rating that earns "it just works".

## Error & Rescue Registry (capability level)

| Capability | Failure mechanism | Person sees | Safeguard | Verify owner |
|---|---|---|---|---|
| Tip products load | offline, agreement inactive, ID mismatch | "Tips aren't available right now"; card waits | B1 state | code (TS-1) |
| Tip purchase | cancel, pending, not allowed, network, unverified | row as was / "Waiting for approval" / no jar / retry note / "didn't go through" | B1 mapping | code (TS-1 + unit) |
| Late transaction | approved while closed | thank-you next time | `Transaction.updates` + unfinished | code (TS-1) |
| Night record read | missing, corrupt, newer schema | nothing; no asks | treat as none; versioned | code (unit) |
| Night files write | disk full; locked phone | nothing; audio unaffected | best-effort off main; default protection class | code (unit) + user (§T locked night) |
| Trail read | truncated last line | nothing | skip partial line | code (unit) |
| Feedback | no Mail; attachments too large | share sheet; trimmed + note | ShareLink; cap | code (unit) + user (§T) |
| Rating prompt | Apple declines | nothing | none needed | user (dev build) |
| Late player event | arrives after the night closed | nothing | filed by night id | code (unit, both orders) |

## Failure Modes Registry

```
  CODEPATH (capability)   | FAILURE MODE                  | RESCUED? | TEST?        | USER SEES?                | LOGGED?
  ------------------------|-------------------------------|----------|--------------|---------------------------|--------
  TipStore.load           | no products                   | Y        | Y (TS-1)     | "not available right now" | Y
  TipStore.purchase       | pending / failed / unverified | Y        | Y (TS-1)     | a clear line              | Y
  TipStore.updates        | late approval                 | Y        | Y (TS-1)     | thanks later              | Y
  NightRecorder           | late event after close        | Y        | Y (unit)     | nothing                   | Y
  NightRecorder           | reconciled deadline           | Y        | Y (unit)     | no false "good night"     | Y
  NightRecordStore        | corrupt / newer schema        | Y        | Y (unit)     | no asks                   | Y
  NightTrail              | disk full / locked            | Y        | device (§T)  | nothing (audio safe)      | Y
  NightTrail              | URL in a message              | Y        | Y (no "://") | nothing                   | n/a
  FeedbackComposer        | no Mail                       | Y        | Y (unit)     | share sheet               | Y
  AskPolicy               | unsuitable open               | Y        | Y (unit)     | nothing; ask waits        | n/a
  TipCard on Home         | overlaps a control            | Y        | Y (TS-2)     | nothing broken            | n/a
  requestReview           | Apple declines                | n/a      | dev build    | nothing                   | Y
```
CRITICAL GAPS: 0 (no row is unrescued, untested and silent).

## Scope Expansion Decisions

CEO plan: `~/.gstack/projects/blurbleasd-sleepulator/ceo-plans/2026-10-11-app-store-launch-1-0.md`.
- Accepted: DF-1, TJ-1, RP-1, FB-1 (+ trail, D9), IC-1, TS-1, TS-2; settled definitions NT-1, AR-1; gate LG-1 (+ §3P, + counted nights).
- Deferred: AM-1 (Apple Music) to 1.1.
- Skipped: none.

## Diagrams

Produced: system architecture (Section 1), data flow with shadow paths (Section 4), night record state machine (Section 1), error flow (below), deployment sequence ("Launch sequence"), rollback (below), async schedule (Section 4), user flow (Section 11).

```
 ERROR FLOW (tips)                                      ROLLBACK (after release)
 purchase ─┬─ success ─ verified? ─ yes ─> finish, thank   bug report ─> night-breaking? ─ yes ─> fix build ─> expedited review
           │                       └ no ──> finish, "didn't go through"                        └ no ──> next scheduled update (phased release)
           ├─ cancelled ─> no-op                           can't roll back a binary; TestFlight keeps the last good build for testers
           ├─ pending ───> "Waiting for approval" ─> updates ─> finish, thank
           └─ error ─────> retry note; not allowed ─> hide the jar
```

## Stale Diagram Audit

Files this plan touches (to be determined in implementation; known: `AudioEngine.swift`, `SleepTimerService.swift`, `PodcastPlayer.swift`, `BackupSupportView.swift`, `ContentView.swift`, `HomeView.swift`, `SleepulatorApp.swift`, `MixPanel.swift`, `PrivacyInfo.xcprivacy`, `Info.plist`, `project.pbxproj`, `TESTING.md`, `CLAUDE.md`): no ASCII diagrams found (the only hit, `TESTING.md:314`, is a ▶ glyph in prose). Stale diagrams: 0.

## Implementation Tasks
Synthesized from this review's findings. Strategy depth: each task names the next action and its owner. Run with Claude Code; checkbox as you ship.

- [ ] **T1 (P1, human: ~2h / CC: n/a, user-owned)** — App Store Connect — Create the app record (confirm "Sleepulator" is free and the bundle ID is final), note the numeric App ID, start the Paid Apps agreement + tax + banking, create the support address
  - Surfaced by: Baseline B3; Section 4 (Rate row needs the App ID); Section 10 (bundle ID is one-way)
  - Files: none
  - Verify: agreement shows Active; App ID recorded in the plan
- [ ] **T2 (P1, human: ~4h / CC: ~20min)** — build settings + manifest — B5, B6 (incl. C617.1), DF-1 on app and widget, hide Apple Music (AM-1)
  - Surfaced by: Baseline B5/B6; D2; D3
  - Files: `Sleepulator/Sleepulator.xcodeproj/project.pbxproj`, `Sleepulator/Sleepulator/Info.plist`, `Sleepulator/Sleepulator/PrivacyInfo.xcprivacy`, `Sleepulator/Sleepulator/Views/Home/MixPanel.swift`
  - Verify: CI green on both legs; the first upload draws no ITMS-91053
- [ ] **T3 (P1, human: ~3d / CC: ~1.5h)** — night record — NightRecorder + NightRecordStore + AskPolicy, filed by night id, live audio only, versioned, device-only
  - Surfaced by: D8; Section 1 (A1, A2); Section 4 (async ordering); round 3 (#1, #4)
  - Files: `Sleepulator/Sleepulator/Services/AudioEngine.swift`, `Sleepulator/Sleepulator/Services/SleepTimerService.swift`, `Sleepulator/Sleepulator/Services/PodcastPlayer.swift`, new files to be determined
  - Verify: unit suites for classification, filing (both orders) and AskPolicy boundaries; `IsolatedDeinitRuntimeBugTests` green on iOS 26.2
- [ ] **T4 (P1, human: ~2d / CC: ~1h)** — night trail + Send feedback — no URLs, capped, attaches trail + MetricKit payloads + night summary
  - Surfaced by: D6, D9; Section 3 (token leak); round 3 (#8)
  - Files: `Sleepulator/Sleepulator/Services/Log.swift`, `Sleepulator/Sleepulator/Views/BackupSupportView.swift`, new files to be determined
  - Verify: unit tests (cap, rotate, partial line, no "://"); §T killed-night step
- [ ] **T5 (P1, human: ~3d / CC: ~2h)** — tips + asks — TipStore, the Support group rows, TipCard, rating prompt + Rate row, `.storekit` file, TS-1, TS-2
  - Surfaced by: B1, D4, D5, D14, D15; Section 2; Section 11
  - Files: `Sleepulator/Sleepulator/SleepulatorApp.swift`, `Sleepulator/Sleepulator/Views/BackupSupportView.swift`, `Sleepulator/Sleepulator/Views/HomeView.swift`, `Sleepulator/SleepulatorUITests/` (re-run `Sleepulator/setup_ui_tests.rb`), new files to be determined
  - Verify: TS-1 and TS-2 green on both CI legs; sandbox purchase on device (§T)
- [ ] **T6 (P1, human: ~1d / CC: ~30min)** — docs — TESTING.md §T and §3E's All-night night; B2 page text; B4 notes draft; CLAUDE.md invariants for the night record
  - Surfaced by: round 1 (C5); round 2 (C2); Section 10
  - Files: `TESTING.md`, `CLAUDE.md`, B2 page (host to be determined)
  - Verify: §T reads as runnable steps with ✅ outcomes like the other sections
- [ ] **T7 (P1, human: ~0.5–2d / CC: n/a, user-owned)** — icon — Repair per IC-1
  - Surfaced by: D7; round 1 (F5)
  - Files: `Sleepulator/Sleepulator/Assets.xcassets/AppIcon.appiconset/`
  - Verify: no white corners on a real home screen; dark and tinted variants show
- [ ] **T8 (P1, human: ~6 nights / CC: n/a, user-owned)** — gate — Device pass §3A, §3B, §3C, §3E (incl. All night with podcasts), §3P and §T on the build to submit; iPad compatibility smoke test; log each in TESTING.md
  - Surfaced by: D1, D10; round 3 (#5, #6)
  - Files: `TESTING.md`
  - Verify: device-pass log rows for each section on the submitted build
- [ ] **T9 (P1, human: ~2 weeks calendar / CC: n/a, user-owned)** — beta — Recruit ≥ 8 testers, set up the morning check-in (with "did you see the tip card?"), run until D12's exit
  - Surfaced by: D12; round 3 (#2, #9)
  - Files: none
  - Verify: 7 days with no app-caused stop and ≥ 30 reported nights from ≥ 8 testers
- [ ] **T10 (P2, human: ~3h / CC: n/a, user-owned)** — submission — App Privacy ("Data Not Collected"), age rating per AR-1, Mac/Vision Pro off, manual release, screenshots, review notes
  - Surfaced by: B3, B4, D11; Section 9
  - Files: none
  - Verify: submission form complete; after release, a night + the smallest real tip on an App Store install
- [ ] **T11 (P2, human: ~1h / CC: ~15min)** — design — Run `/plan-design-review` on the tip card and the Support group before T5's UI
  - Surfaced by: Section 11
  - Files: none
  - Verify: design review report saved

## Reality rows

Premise table:

| # | Premise | Claim | Receipt | Verdict |
|---|---|---|---|---|
| 1 | No StoreKit code | 0 grep hits | `grep -rn StoreKit… --include='*.swift'` (empty) | verified |
| 2 | iPad + landscape on | device family "1,2", landscape keys | `project.pbxproj:609-610, 625` | verified |
| 3 | One device-pass row | log has §3R only | `TESTING.md:660-664` | verified |
| 4 | ASC requires a privacy policy URL | submission form | Apple docs (not fetched) | unverified |
| 5 | iPad support can't be removed later | ASC validation | forum reports via web search | unverified |
| 6 | White baked corners | (40,40) white, (60,60) navy | `AppIcon.png` pixel sample | verified |
| 7 | EarPods-like art risks 5.2.5 | review risk | inference | unverified |
| 8 | Manifest misses two APIs | systemUptime, disk space | `ContentView.swift:114,132`; `AudioDownloader.swift:134`; `PrivacyInfo.xcprivacy` | verified |
| 9 | C617.1 = container metadata; DDA9.1 = shown dates | reason codes | Apple's required-reason list (not fetched) | unverified |
| 10 | Log export is process-only | OSLogStore current process | `Services/Log.swift:50` | verified |
| 11 | No persisted night signal | recordNightEnd private, in-memory | `SleepTimerService.swift:166-169` | verified |
| 12 | exportOnlyKeys export as Bools | `defaults.bool` | `Backup.swift:302` | verified |
| 13 | Tips must use IAP | guideline 3.1.1 | web search (secondary) | unverified |
| 14 | requestReview is silent in TestFlight | Apple behavior | documentation knowledge | unverified |
| 15 | No data-protection entitlement | no .entitlements file sets it | `find Sleepulator -name '*.entitlements'` (none) | verified |
| 16 | No MetricKit diagnostic for background kills | MetricKit behavior | reviewer claim, knowledge | unverified |
| 17 | Feed URLs aren't logged publicly | no `.public` URL interpolations | grep over `Log.*(` lines | verified |
| 18 | The reconcile path fires the stop on foreground | terminal stop on foreground | `SleepTimerService.swift:337-342` | verified |

unverified=7

Numbers: 1 device-pass row [measured: TESTING.md:660-664]; pixel values [measured: AppIcon.png]; 3 h threshold, 3rd/5th clean night [user-approved: D8, D4, D5]; 10–20 testers, 7 days, ≥ 30 nights, ≥ 8 testers [user-approved: D1, D12]; 256 KB, 2 nights, ~30 records, 09:00–21:00, 2 h [estimated]; effort and calendar figures [estimated]; ~1 day Beta App Review [estimated].

REALITY: premise-table finding 18 premises, unverified=7 (Apple-policy claims from docs knowledge or secondary sources) docs/designs/APP-STORE-LAUNCH-1.0.md:1
REALITY: already-done pass git log origin/main --since=2026-09-01 shows no StoreKit, tip, privacy-policy or iPad work; origin/main = 0843f65 TESTING.md:660
REALITY: surface-check pass the only named tool, Sleepulator/setup_ui_tests.rb, exists; no HTTP routes or CLI flags beyond Apple's documented write-review URL Sleepulator/setup_ui_tests.rb:1
REALITY: binding-decisions pass branch decision search empty; the 2026-10-09 "no TODOS/VERSION/CHANGELOG" decision is honored (deferrals live in NOT in scope) docs/designs/APP-STORE-LAUNCH-1.0.md:6
REALITY: numbers pass every number tagged measured, user-approved or estimated above TESTING.md:660
REALITY: deferred-asks pass no linked issue; from the chat ask, everything left out is listed with its answer and reason in NOT in scope (Apple Music, iPad/landscape, search filter, §3H/§3L gating, the nap limit, the delight list, the candidates not raised) docs/designs/APP-STORE-LAUNCH-1.0.md:5
REALITY: pr-count pass no .gstack/ship-policy.json, so one PR per wave; the code work (T2–T6) is one wave docs/designs/APP-STORE-LAUNCH-1.0.md:1

PLAN_REALITY: phase=ceo rows=7/7 missing=none unverified=7 verdict=complete

## Completion Summary

```
  +====================================================================+
  |            MEGA PLAN REVIEW — COMPLETION SUMMARY                   |
  +====================================================================+
  | Mode selected        | SELECTIVE EXPANSION                         |
  | System Audit         | No StoreKit; iPad + landscape on, unbuilt;  |
  |                      | 1 device-pass row; icon has white corners;  |
  |                      | manifest misses 2 APIs + wrong file code    |
  | Step 0               | TestFlight-first gate (D1, D10, D12); iPhone|
  |                      | portrait (D2); Apple Music → 1.1 (D3); tips,|
  |                      | rating, feedback, icon, night record, rating|
  |                      | answers (D4–D9, D11); docs approved (D13)   |
  | Section 1  (Arch)    | 6 issues found (0 needed a decision)        |
  | Section 2  (Errors)  | 12 error paths mapped, 0 GAPS               |
  | Section 3  (Security)| 1 issue found, 1 High severity (repaired)   |
  | Section 4  (Data/UX) | 7 edge cases mapped, 0 unhandled (1 fixed)  |
  | Section 5  (Quality) | 5 issues found                              |
  | Section 6  (Tests)   | Diagram produced, 2 gaps (D14, D15 closed)  |
  | Section 7  (Perf)    | 0 issues found                              |
  | Section 8  (Observ)  | 0 gaps found (runbook written)              |
  | Section 9  (Deploy)  | 3 risks flagged                             |
  | Section 10 (Future)  | Reversibility: 4/5 (bundle ID 1/5), debt: 3 |
  | Section 11 (Design)  | 4 states mapped; design review recommended  |
  +--------------------------------------------------------------------+
  | NOT in scope         | written (7 items)                           |
  | What already exists  | written                                     |
  | Dream state delta    | written                                     |
  | Error/rescue registry| 9 rows, 0 CRITICAL GAPS                     |
  | Failure modes        | 12 total, 0 CRITICAL GAPS                   |
  | TODOS.md updates     | 0 items proposed (repo doesn't use TODOS)   |
  | Scope proposals      | 8 proposed, 7 accepted (SEL)                |
  | CEO plan             | written                                     |
  | Outside voice        | codex: disabled (codex_reviews)             |
  | Lake Score           | 0/1 recommendations chose complete option   |
  | Diagrams produced    | 8 (arch, data flow, state, error, deploy,   |
  |                      | rollback, async schedule, user flow)        |
  | Stale diagrams found | 0                                           |
  | Unresolved decisions | 0                                           |
  | Reality rows         | 7/7 rows (PLAN_REALITY), 7 unverified       |
  +====================================================================+
```

Spec review: 3 rounds (5 → 6 → 7/10), cap reached; round-3 fixes verified against the text by the orchestrator (9 of 9), not re-reviewed.

## Unresolved Decisions

None. Every question asked (D1–D15) was answered.

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 1 | CLEAR | 8 proposals, 7 accepted, 1 deferred |
| Outside Review | codex via `/plan-ceo-review` outside voice | Independent 2nd opinion | 1 | disabled | disabled by config (`codex_reviews`); no completed external review |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 0 | — | — |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | — |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

- **OUTSIDE COVERAGE:** codex, plan-review phase, disabled by `codex_reviews` (recorded as skipped); no external findings. The three in-session spec reviews are native subagents and don't count as outside coverage.
- **VERDICT:** CEO CLEARED. Eng review required.

NO UNRESOLVED DECISIONS
