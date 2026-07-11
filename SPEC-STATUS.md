# Spec & plan status index

**As of 2026-07-05.** One line per doc so future sessions don't re-derive this. Shipped/archived
plans live in `docs/shipped/`; historical audits, reviews, handoffs, and superseded plans live in
`docs/archive/` — their findings were acted on; treat nothing there as a current plan. (2026-07-05:
archived the web-PWA-era `audio-rebuild-design` and the superseded `device-test-checklist`, now that
`TESTING.md` is the canonical native device checklist.)

| Doc | Status | Remaining |
|-----|--------|-----------|
| AUDIO-LIMITER-SPEC | ✅ shipped + device-verified (pre-refactor) | Re-verify per TESTING.md §3D before re-enabling default-on |
| SLEEP-MODE-SPEC | ✅ ~80% (moon, starfield, screensaver, settle) | P1 audio-bed softening, history |
| SCREENSAVER-LIBRARY-SPEC | ✅ framework (registry + scenes); §5 motion toggle **done** (P6a, branch) | Full live-preview picker UI still deferred. Depth-host + a 2nd depth scene (ocean) landed via the visual-moat arc |
| docs/shipped/ARCHITECTURE-REFACTOR-PLAN | ✅ shipped 2026-06-21 (all slices A1–A4, B1–B3) | Device verification only |
| REFACTOR-PLAN-observation-slices | 🔶 Phases 1–3 in code | On-device re-render audit; Phase 4 skipped deliberately |
| APPLE-MUSIC-FOCUS-SPEC / -HANDOFF | 🔶 code complete | MusicKit on App ID (portal, manual); full device pass |
| PODCAST-RESUME-AUDIT-2026-06 | 🔶 both bug fixes in code | Device verification (auto-advance position race) |
| FOCUS-MODE-SPEC | 🔶 ~70% (ring, cycles, tab label; 2026-07-04: R5 phase-end notifications, R6 break softening, skip-phase, Pomodoro Live Activity) | R7 history, R8 config sheet |
| AUDIO-PALETTE-SPEC | 🔶 P1 partial | ~~P0 isochronic beats~~ — **already implemented** (`isochronicActive` + `setBeatMode`, route-aware auto; verify audibly on speaker). Remaining: P2 nature textures / tonal beds |
| IMPLEMENTATION-PLAN-2026-06-24 | 🔶 ~60% of "Now" scope | Idle-based scene freeze; shader multi-hour OLED A/B |
| SESSION-HANDOFF-2026-06-24 | 📜 checkpoint | §5 HomeView decompose: **done** (Views/Home/, committed 2026-07-04); §3A PersistenceTests target membership: **done** (pbxproj) |
| docs/archive/ACCESSIBILITY-AUDIT-2026-07 | 📜 archived audit (2026-07-04); 1 fix applied (breathing VoiceOver) | 4 minor recs open: OrbButton pulse under Reduce Motion (marked intentional), Dynamic Type wrap-vs-scale, dim-caption contrast spot-check (AX Inspector on Bedtime), timer-fade VoiceOver announce. Fold into TESTING.md §L if a11y becomes a release gate |
| RAIN-ON-GLASS-DEPTH-SPEC | 🔶 implemented via the visual-moat arc (branch, PR #3) | Reactive depth rain on the shared `DepthBackdrop` host (E1/F1/P2); original lens (license clear). Needs the device A/B + tuning round — TESTING.md §L. Superseded as the working plan by docs/designs/VISUAL-MOAT-REACTIVE-SCENES |
| docs/designs/VISUAL-MOAT-REACTIVE-SCENES | 🔶 built on branch `feat/reactive-scenes-audio-controls` (PR #3), unverified on device | CEO+eng reviewed (2 adversarial rounds 5→8/10). E1 depth-host, F1 reactivity vocab, P2 reactive rain, P4 ocean, F2 shader guard, F3 diagnostics, P6a toggle — all compile-clean + 14 unit tests. Remaining = device-only: P3 shader tuning, P5 idle-freeze verify, P1 gate (TESTING.md §L). Deferred: full picker, wake alarm |

## Open work, ranked

1. Device pass (TESTING.md) — unblocks the limiter default, Apple Music, resume-race, and observation-slice verifications in one run. Now also covers: noise-type soft-swap, "Start Sleep Mix" Siri intent, resume widget deep link, MetricKit payload delivery (all added 2026-07-04, unverified), and the 2026-07-05 night-audio fixes (interruption wasPlaying snapshot + stop-during-call invalidation §3B4-5, ambient-tail integrity + buffer-independent fade slew §3C3-4).
2. Device pass for the visual-moat depth scenes (branch `feat/reactive-scenes-audio-controls`, PR #3): freeze-in-place, the reactive settle, tuning the blind-authored ocean shader, and reading the F3 power log — TESTING.md §L. Idle-freeze-without-a-timer verification (P5) rides this same run.
3. Scene A/B on device: retuned Metal aurora (star twinkle decorrelated, motion up, lateral travel) + the SceneClock/ShaderBackdrop refactor (integrated night-slowdown phase — fixes the motion-runs-backward bug — freeze-in-place pause, meteor/comet night gating, FocusBackdrop paused conversion) — TESTING.md §3H, all unverified on device. (The rain-depth + ocean depth scenes moved to §L / item 2.)
4. Wake alarm (gentle rising audio — reverse of the sleep fade) and a StandBy-mode check of the Live Activity: discussed 2026-07-04, need design input / a device.
5. ~~Focus resume-label cross-mode copy bug (FOCUS-MODE-SPEC R2)~~ — fixed 2026-07-04 (HomeView statusText mirrors the palette snap).
