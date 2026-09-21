#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Sandfall (Focus) — a vertical downpour of light: bright comet heads with long
// tails, falling through a fine scrolling grain.
// ----------------------------------------------------------------------------
// v3 "bold" rewrite (2026-09-21). v2's faults, from sim capture + device use:
//
//  1. IT DID NOT READ AS VERTICAL. The dominant element was a broad `fbm`
//     curtain at (x·9, y·3) whose low y-frequency smeared it into soft
//     horizontal-ish cloud — so the scene looked like Current and Tide instead
//     of like falling. The curtain is now a fine, high-x-frequency grain
//     (x·44, y·1.6) that is unambiguously elongated DOWN the screen, and it is
//     dim support rather than the main event. The comets carry the scene.
//  2. TONEMAP CRUSH. `col/(col + 0.85)` maps 1.0 → 0.54, so nothing could ever
//     approach white — every scene sat in the same washed-out mid band.
//     Replaced with an exposure curve (shared with Current/Tide v3).
//  3. NO HEAD CONTRAST. The heads were a 0.5-weight gaussian over a lit
//     background. Heads are now near-white and bright against a near-black
//     field, with an exponential tail — an actual comet.
//
// Motion is translation at every frame rate: each column owns a head at
// `fract(seed + fall·speed)` that travels down and wraps, with the tail sampled
// relative to that head. Nothing is re-rolled per frame — the rule from the
// 2026-07-11 device pass, where a per-frame hashed mote grid read as flicker.
//
//   energy (0…1) — work builds it (faster, denser, brighter), rest eases, idle
//   mid.  tint — work/rest/idle colour.  `phase` is a SceneClock time, frozen by
//   occlusion / the app's Ambient-motion toggle — NOT by Reduce Motion.
// ============================================================================

namespace sf {

constant int   LAYERS   = 3;      // depth planes (v3.1: was 4 — see density note below)
constant float EXPOSURE = 1.7;
constant float3 BASE_TOP = float3(0.012, 0.018, 0.044);
constant float3 BASE_BOT = float3(0.004, 0.006, 0.018);

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0));
    float d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
inline float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < 3; i++) { v += amp * vnoise(p); p = p * 2.0 + float2(11.3, 7.7); amp *= 0.5; }
    return v;
}

/// Compact-support bump, a drop-in for `exp(-(d/w)^2)` without the transcendental. Pass d² and
/// 1/r² with r = 1.6w, which matches the gaussian's mid-falloff; the compact support (exactly 0
/// beyond r) is a bonus, since those gaussian tails were invisible yet cost a full `exp` each.
/// Focus draws these several times per stream/layer per pixel, so this is the hot path.
inline float bump(float d2, float invR2) {
    float t = max(0.0, 1.0 - d2 * invR2);
    return t * t;
}

} // namespace sf

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 sandField(float2 pos, half4 color,
                float phase, float2 size,
                float energy, float3 tint) {
    using namespace sf;

    float2 uv = pos / size;
    float x = uv.x, y = uv.y;
    float3 col = mix(BASE_TOP, BASE_BOT, y);

    float e    = clamp(energy, 0.0, 1.0);
    float fall = phase * (0.22 + 0.30 * e);        // master descent rate
    float3 headCol = mix(tint, float3(1.0), 0.78); // heads read as light, tails carry hue

    // ---- fine vertical grain --------------------------------------------------------
    // High frequency ACROSS x, low frequency down y ⇒ features stretched vertically.
    // Scrolls straight down (y·k − fall·k' = const ⇒ y grows with fall).
    float grain = fbm(float2(x * 44.0, y * 1.6 - fall * 2.4));
    col += tint * pow(smoothstep(0.58, 0.97, grain), 2.0) * (0.04 + 0.10 * e);

    // ---- comet layers ----------------------------------------------------------------
    for (int L = 0; L < LAYERS; L++) {
        float fl  = float(L);
        float sc  = 8.0 + 7.0 * fl;                          // columns across the width
        float cxi = floor(x * sc);
        float fx  = fract(x * sc);
        float h   = hash21(float2(cxi, fl * 17.0));
        // Sparse: not every column carries a comet, and the pattern differs per depth.
        // v3.1 density: 4 layers x (9+17+25+33) columns past a 58%-pass gate put ~49 comets
        // on screen — striking but busy, and it fought the UI. 3 layers x (8+15+22) past a
        // 34%-pass gate is ~15: the same boldness with air between the streaks.
        float gate = step(0.66, hash21(float2(cxi, fl * 29.0 + 3.0)));

        float spd   = (0.50 + 0.80 * h) * (0.55 + 0.85 * e);
        float headY = fract(h * 7.31 + fall * spd * 2.2);    // travels down, wraps

        // Tail trails UPWARD from the head: td grows as we move above it.
        float td    = fract(headY - y);
        float tail  = exp(-td * (9.0 + 6.0 * fl));           // nearer layers = longer tails

        // Head: a tight gaussian on the signed wrapped distance, so it ends in light
        // rather than a sliced edge (the v1 defect, sim capture 2026-07-11).
        float hd    = fract(headY - y + 0.5) - 0.5;
        float hw    = 0.008 + 0.005 * h;
        float head  = bump(hd * hd, 1.0 / (2.56 * hw * hw));

        // Narrow streak within the column — this is what makes it a falling line
        // rather than a lit band.
        float wx     = 0.16 + 0.10 * h;
        float across = bump((fx - 0.5) * (fx - 0.5), 1.0 / (2.56 * wx * wx));

        float depth = 1.0 - 0.18 * fl;                       // far layers dimmer
        float amt   = gate * across * depth * (0.45 + 0.75 * e);

        col += tint    * tail * 0.55 * amt;
        col += headCol * head * 2.30 * amt;
    }

    // Ambient lift with energy.
    col += tint * 0.03 * e;

    // Vignette — edges to black so the fall reads as the subject.
    float2 vp = (uv - 0.5) * float2(1.0, 1.22);
    col *= 1.0 - 0.48 * dot(vp, vp);

    col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
