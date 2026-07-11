#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Sandfall (Focus) — energy-first. A downpour of falling light: per-column
// comet streaks with trails, over a soft descending curtain.
// ----------------------------------------------------------------------------
// Rewrite of the first energy-first attempt, which was BROKEN on device: its
// mote layer hashed a quantized grid cell that shifted every frame, so the
// sparkle field re-rolled ~26×/sec — flicker, not falling ("extremely choppy").
// Lesson (device 2026-07-11): motion must be TRANSLATION — features that
// visibly travel — never per-frame decorrelation of a random field.
//
// Here every element translates smoothly at any frame rate:
//   • background curtain: FBM streaks scrolling straight down,
//   • comet layer ×3 depths: each column owns a bright head at
//     `fract(seed + fall·speed)` with a tail above it — pure travel.
//   energy (0…1) — work builds it with progress (faster, denser, brighter),
//                   rest eases, idle sits mid.  tint — work/rest/idle colour.
// `phase` is a SceneClock time (frozen under Reduce Motion / occlusion).
// ============================================================================

namespace sf {

constant float3 BASE_TOP = float3(0.03, 0.05, 0.11);
constant float3 BASE_BOT = float3(0.015, 0.02, 0.05);

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
    for (int i = 0; i < 4; i++) { v += amp * vnoise(p); p = p * 2.0 + float2(11.3, 7.7); amp *= 0.5; }
    return v;
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

    float e = clamp(energy, 0.0, 1.0);
    float fall = phase * (0.22 + 0.30 * e);              // master descent rate

    // Background curtain: soft streaks scrolling straight DOWN (feature at
    // y·3 − fall·2 = const ⇒ y grows with fall). Smooth translation.
    float streak = fbm(float2(x * 9.0, y * 3.0 - fall * 2.0));
    col += tint * pow(smoothstep(0.55, 0.95, streak), 1.6) * (0.20 + 0.45 * e);

    // Comet layer: three depths of per-column falling heads with tails above.
    for (int L = 0; L < 3; L++) {
        float sc  = 14.0 + 10.0 * float(L);              // columns across the width
        float cxi = floor(x * sc);
        float fx  = fract(x * sc);
        float h   = hash21(float2(cxi, float(L) * 17.0));
        // Sparse: not every column carries a comet (varies per depth layer).
        float gate = step(0.35, hash21(float2(cxi, float(L) * 29.0 + 3.0)));
        float spd  = (0.55 + 0.75 * h) * (0.55 + 0.75 * e);
        float headY = fract(h * 7.31 + fall * spd * 3.0);       // head travels down, wraps
        float td    = fract(headY - y);                          // 0 at head → grows up the tail
        float trail = pow(1.0 - td, 12.0);                       // comet tail above (shorter = airier)
        // Soft glow around the head so the streak ends in light, not a hard cut edge
        // (sim capture 2026-07-11: the bare fract() head read as a sliced-off bottom).
        float hd    = fract(headY - y + 0.5) - 0.5;              // signed distance to the head
        float headG = exp(-(hd * hd) / (0.02 * 0.02)) * 0.5;
        float across = smoothstep(0.5, 0.05, abs(fx - 0.5));     // soft column profile
        float depth  = 1.0 - 0.25 * float(L);                    // far layers dimmer
        col += (tint + float3(0.10)) * (trail + headG) * across * gate * depth * (0.30 + 0.55 * e);
    }

    // Ambient glow lifts with energy.
    col += tint * 0.04 * e;

    col = col / (col + 0.85);                             // filmic roll-off
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
