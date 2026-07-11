#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Aurora — generative curtains via FBM value-noise + domain warping.
// ----------------------------------------------------------------------------
// The Metal proof-of-concept replacement for the CPU `AuroraView` (which drew
// striated gradient rectangles on a Canvas). Here the whole sky is a continuous
// noise field evaluated per pixel on the GPU: curtains fold and flow from
// domain-warped FBM, never visibly repeat, and cost almost nothing on CPU.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation. The noise is the standard hash + value-noise + FBM
// construction (a public-domain *technique*, not copied code — cf. Morgan
// McGuire's hash and the value-noise lerp every shader text teaches). No
// third-party shader source is reproduced, so this is clean to ship; credit the
// technique, not any one author. (RainGlass.metal, once a CC BY-NC-SA port, was
// rewritten 2026-07 as an original implementation on this same kit.)
//
// Driven from SwiftUI `.colorEffect`: each pixel returns its own colour, so it
// attaches to a plain full-screen Rectangle. Swift owns the live values —
// phase, time, size, nightProgress, audioLevel, gyro — and everything else is
// a `constant` below (edit + rebuild, no Swift change).
//
// TIME CONTRACT (all four Metal scenes; see SceneClock in ShaderBackdrop.swift):
//   `phase` — night-slowed *integrated* time. Use for every motion term (flow,
//     travel, waves). Never multiply it by a night factor here: scaling an
//     absolute time by a shrinking factor rewinds the motion — that was the
//     "aurora drifts backward late in the timer" bug.
//   `time`  — monotonic elapsed time, rate-independent. Use for cyclic terms
//     (breath, twinkle, dither) whose *frequency* shouldn't slow with the night.
// ============================================================================

namespace aur {

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant int   OCTAVES   = 4;     // FBM detail. THE battery knob — 3 is cheaper, 5 richer.
constant float FLOW       = 0.115; // base time scale (was 0.060 — read as static at arm's length)
constant float WARP_AMT   = 0.55;  // domain-warp strength → how much the curtains fold (was 0.35)
constant float TRAVEL     = 0.011; // lateral sky drift, uv/s — real aurora marches across the sky
constant float BREATH_SEC = 11.0;  // per-layer brightness breath period (phase-offset per layer)
constant int   LAYERS     = 3;     // depth layers of curtains accumulated additively

// Curtain palette (linear-ish): green/teal base rising to violet tips.
constant float3 C_GREEN  = float3(0.18, 0.85, 0.55);
constant float3 C_TEAL   = float3(0.16, 0.55, 0.62);
constant float3 C_VIOLET = float3(0.55, 0.42, 0.95);

// -- hash + value-noise + FBM (standard technique) ---------------------------------
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);          // smootherstep weights
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < OCTAVES; i++) {
        v += amp * vnoise(p);
        p = p * 2.0 + float2(11.3, 7.7);          // offset each octave to decorrelate
        amp *= 0.5;
    }
    return v;
}

} // namespace aur

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 auroraField(float2 pos, half4 color,
                  float phase, float time, float2 size,
                  float night, float audio, float2 gyro) {
    using namespace aur;

    float2 uv = pos / size;                  // 0..1, top-down
    float vY = 1.0 - uv.y;                   // bottom-up height (0 floor → 1 sky)
    float x  = uv.x;

    float p = clamp(night, 0.0, 1.0);        // night progress: 0 start → 1 timer end
    float a = clamp(audio, 0.0, 1.0);        // smoothed audio level
    float motion = 1.0 - 0.5 * p;            // wind motion *amplitude* down as the night settles
    // Rate slowdown lives in `phase` (integrated Swift-side) — see the time contract above.
    float t = phase * FLOW;

    // Gyro parallax (a watching-window bonus; 0 on a flat nightstand).
    x += gyro.x * 0.03;
    float baseShift = gyro.y * 0.02;

    // --- accumulate the curtains ---
    float3 col = float3(0.0);
    for (int L = 0; L < LAYERS; L++) {
        float fl     = float(L);
        float scale  = 1.4 + fl * 1.1;        // nearer layers have finer curtains
        float speed  = 0.5 + fl * 0.5;        // …and flow a little faster
        float baseY  = 0.34 + fl * 0.06 + baseShift;  // far layers sit higher in the sky
        float bright = 1.0 - 0.22 * fl;

        // Lateral march: the whole field travels across the sky, nearer layers faster —
        // the strongest "it's alive" cue at nightstand distance. Slows as the night settles
        // (via `phase`, whose rate the night modulates).
        float xl = x + phase * TRAVEL * (0.6 + 0.4 * fl);

        // Domain warp the horizontal coordinate → folds that move and never repeat.
        float w  = fbm(float2(xl * 1.6 + t * speed, fl * 3.1 + t * 0.30));
        float xx = xl * scale + (w - 0.5) * WARP_AMT * motion;

        // Where light lives across x, and the moving vertical striations within it.
        float dens = smoothstep(0.45, 0.95, fbm(float2(xx * 2.0, fl * 5.0 + t * speed * 0.7)));
        float ray  = 0.4 + 0.6 * fbm(float2(xx * 6.0, vY * 2.2 - t * speed * 1.5 + fl));

        // Vertical profile: rises sharply just above the base, long soft tail upward.
        float up   = vY - baseY;
        float band = smoothstep(-0.05, 0.10, up) * smoothstep(0.55, 0.0, up);

        // Per-layer breath, phase-offset — with one collective breath the sky's most
        // visible motion was everything dimming in lockstep, which read as a pulse,
        // not weather. Offsetting per layer keeps total brightness roughly steady
        // while individual curtains swell and fade against each other.
        float breath = 0.82 + 0.18 * (1.0 - 0.4 * p)
                     * (0.5 - 0.5 * cos(time * 6.28318530718 / BREATH_SEC + fl * 2.4));
        float intensity = pow(dens * ray * band * bright, 1.3) * breath;

        // Colour by height within the curtain: green/teal base → violet tips. The warm
        // base fades faster than the violet as night deepens, so the end state is a dim
        // violet wash.
        float h = clamp(up / 0.5, 0.0, 1.0);
        float3 base = mix(C_GREEN, C_TEAL, 0.3 + 0.5 * p);   // less green, more teal at night
        float3 cc   = mix(base * (1.0 - 0.35 * p), C_VIOLET, h);
        col += cc * intensity;
    }

    // (The ~11s breath now lives per-layer inside the loop, phase-offset — see above.)

    // Night dim + a gentle audio swell.
    col *= (1.0 - 0.45 * p) * (1.0 + 0.4 * a);

    // Faint low horizon glow the curtains seem to rise from.
    float horizon = smoothstep(0.30, 0.0, vY) * 0.12;
    col += float3(0.10, 0.45, 0.35) * horizon * (1.0 - 0.6 * p);

    // Deep blue-black base sky.
    col += mix(float3(0.012, 0.015, 0.030), float3(0.004, 0.005, 0.013), vY);

    // Faint stars, weighted toward the upper sky and dimmed wherever a curtain is bright.
    // Twinkle phase/rate come from hashes INDEPENDENT of the existence gate: `sh` survives
    // `step(0.992, …)` so it's compressed into [0.992, 1] — deriving the phase from it gave
    // every star the same frequency and near-identical phase (the whole sky blinked in
    // unison). A third of the stars hold steady; the rest twinkle at their own rate.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    float2 sg = floor(pos / 3.0);
    float sh  = hash21(sg);
    float star = step(0.992, sh) * smoothstep(0.05, 0.65, vY);
    float ph     = hash21(sg + 19.7) * 6.28318530718;    // full 0..2π phase spread
    float fr     = 0.5 + 1.6 * hash21(sg + 47.3);        // per-star rate, 0.5..2.1 rad/s
    float steady = step(hash21(sg + 71.1), 0.35);        // ~35% don't twinkle at all
    float tw     = mix(0.55 + 0.45 * sin(time * fr + ph), 0.9, steady);
    col += float3(0.85, 0.90, 1.0) * star * tw * 0.6 * (1.0 - clamp(lum * 3.0, 0.0, 1.0));

    // Gentle Reinhard-ish roll-off keeps highlights from clipping harshly (filmic, OLED-kind).
    col = col / (col + 0.85);

    // Ordered-ish hash dither: breaks the gradient banding that plagues flat OLED sleep scenes.
    // Wrap `time` to a small magnitude before the hash. Hours into a session `time` reaches tens
    // of thousands; `hash21`'s internal `fract(p * 123.34)` then overflows float precision and
    // returns a near-constant, so the dither freezes and the banding it exists to hide creeps
    // back. Wrapping keeps the hash input in the precise range it had at t≈0. The 64 s period is
    // arbitrary — the dither is pure noise, so the wrap boundary is invisible (unlike the smooth
    // motion above, which must keep the unwrapped `time` and tolerates the slow precision drift).
    float ditherT = fmod(time, 64.0);
    float dither = (hash21(pos + ditherT) - 0.5) / 255.0;
    col += dither;

    return half4(half3(saturate(col)), 1.0h);
}
