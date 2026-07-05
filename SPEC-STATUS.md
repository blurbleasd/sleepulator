# Spec & plan status index

**As of 2026-07-04.** One line per doc so future sessions don't re-derive this. Shipped/archived
plans live in `docs/shipped/`; historical audits, reviews, handoffs, and superseded plans were
moved to `docs/archive/` (2026-07-04) — their findings were acted on; treat nothing there as a
current plan.

| Doc | Status | Remaining |
|-----|--------|-----------|
| AUDIO-LIMITER-SPEC | ✅ shipped + device-verified (pre-refactor) | Re-verify per TESTING.md §3D before re-enabling default-on |
| SLEEP-MODE-SPEC | ✅ ~80% (moon, starfield, screensaver, settle) | P1 audio-bed softening, history |
| SCREENSAVER-LIBRARY-SPEC | ✅ framework (registry + 2 scenes) | More scenes, picker UI, motion toggle |
| docs/shipped/ARCHITECTURE-REFACTOR-PLAN | ✅ shipped 2026-06-21 (all slices A1–A4, B1–B3) | Device verification only |
| REFACTOR-PLAN-observation-slices | 🔶 Phases 1–3 in code | On-device re-render audit; Phase 4 skipped deliberately |
| APPLE-MUSIC-FOCUS-SPEC / -HANDOFF | 🔶 code complete | MusicKit on App ID (portal, manual); full device pass |
| PODCAST-RESUME-AUDIT-2026-06 | 🔶 both bug fixes in code | Device verification (auto-advance position race) |
| FOCUS-MODE-SPEC | 🔶 ~70% (ring, cycles, tab label; 2026-07-04: R5 phase-end notifications, R6 break softening, skip-phase, Pomodoro Live Activity) | R7 history, R8 config sheet |
| AUDIO-PALETTE-SPEC | 🔶 P1 partial | ~~P0 isochronic beats~~ — **already implemented** (`isochronicActive` + `setBeatMode`, route-aware auto; verify audibly on speaker). Remaining: P2 nature textures / tonal beds |
| IMPLEMENTATION-PLAN-2026-06-24 | 🔶 ~60% of "Now" scope | Idle-based scene freeze; shader multi-hour OLED A/B |
| SESSION-HANDOFF-2026-06-24 | 📜 checkpoint | §5 HomeView decompose: **done** (Views/Home/, committed 2026-07-04); §3A PersistenceTests target membership: **done** (pbxproj) |
| RAIN-ON-GLASS-DEPTH-SPEC | 🔶 v2 shader in code (2026-07-04) | Was a CC BY-NC-SA "Heartfelt" port; rewritten as an original lens (inverted-image drops + fog blur DoF). Needs device A/B vs shipping rain scene |

## Open work, ranked

1. Device pass (TESTING.md) — unblocks the limiter default, Apple Music, resume-race, and observation-slice verifications in one run. Now also covers: noise-type soft-swap, "Start Sleep Mix" Siri intent, resume widget deep link, MetricKit payload delivery (all added 2026-07-04, unverified).
2. Idle-based scene freeze without a running timer.
3. Scene A/B on device: retuned Metal aurora (star twinkle decorrelated, motion up, lateral travel) and the v2 rain-depth lens shader — both tuned blind, expect a knob-turning round.
4. Wake alarm (gentle rising audio — reverse of the sleep fade) and a StandBy-mode check of the Live Activity: discussed 2026-07-04, need design input / a device.
5. ~~Focus resume-label cross-mode copy bug (FOCUS-MODE-SPEC R2)~~ — fixed 2026-07-04 (HomeView statusText mirrors the palette snap).
