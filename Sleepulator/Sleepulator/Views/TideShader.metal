#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Tide (Focus) — energy-first. A surge of cool light rising up the field.
// ----------------------------------------------------------------------------
// Rewrite of the first energy-first attempt, which read STATIC on device: its
// five bands were phase-offset ~evenly across one period, so although every
// band moved, their SUM flattened to a near-uniform glow. Lesson (device
// 2026-07-11): keep features few and UNEQUAL — a dominant surge the eye can
// track — and make motion translation, not superposition mush.
//
// Two deliberately unequal band systems, both travelling UP (feature at
// (y+rise)·k = const ⇒ y falls as rise grows):
//   • main surge: sharp bright ridges (pow 7), ~3 on screen, undulating in x,
//     with crest sparkle that rides the ridge (same moving frame),
//   • counter-swell: broad dim bands at a different frequency and 0.55× the
//     speed — depth without evening out the sum.
//   energy (0…1) — work builds it with progress (faster + brighter), rest
//                   eases, idle sits mid.  tint — work/rest/idle colour.
// `phase` is a SceneClock time (frozen under Reduce Motion / occlusion).
// ============================================================================

namespace tide {

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

} // namespace tide

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 tideField(float2 pos, half4 color,
                float phase, float2 size,
                float energy, float3 tint) {
    using namespace tide;

    float2 uv = pos / size;
    float x = uv.x, y = uv.y;
    float3 col = mix(BASE_TOP, BASE_BOT, y);

    float e = clamp(energy, 0.0, 1.0);
    float rise = phase * (0.22 + 0.26 * e);              // upward travel rate

    // Main surge: ridges with a CRISP bright crest line the eye can track (the first cut's
    // soft pow-only lobes read as drifting smoke — sim capture 2026-07-11; the crest core is
    // what makes it a wavefront).
    float wob1  = (fbm(float2(x * 2.6, phase * 0.25)) - 0.5) * 0.55;
    float yy1   = (y + rise) * 3.0 + wob1;
    float s1    = 0.5 + 0.5 * sin(yy1 * 6.28318530718);
    float band1 = pow(s1, 10.0);
    float core  = smoothstep(0.955, 0.998, s1);          // thin bright waterline at each crest

    // Crest sparkle rides the surge (same moving frame, so it travels with it).
    float spark = fbm(float2(x * 8.0, (y + rise) * 8.0));
    float crest = band1 * (0.35 + 0.65 * pow(spark, 2.0)) + core * (0.55 + 0.45 * spark);

    // Counter-swell: broad dim bands, different frequency, 0.55× the speed —
    // depth behind the surge without flattening the sum.
    float wob2  = (fbm(float2(x * 1.7 + 3.7, phase * 0.18)) - 0.5) * 0.8;
    float yy2   = (y + rise * 0.55) * 1.6 + wob2 + 0.3;
    float band2 = pow(0.5 + 0.5 * sin(yy2 * 6.28318530718), 3.0);

    // A slow whole-field pulse keeps it breathing; energy brightens everything.
    float pulse = 0.75 + 0.25 * sin(phase * 1.6);
    col += tint * crest * (0.50 + 0.80 * e) * pulse;
    col += tint * band2 * (0.11 + 0.18 * e);
    col += tint * 0.05 * e;

    col = col / (col + 0.85);                             // filmic roll-off
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
