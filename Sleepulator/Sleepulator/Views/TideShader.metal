#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Tide (Focus) — a real water SURFACE that rises with the session.
// ----------------------------------------------------------------------------
// v3 "bold" rewrite (2026-09-21). v2 was "rising pulsing bands": repeating
// ridges tiled over the whole field. On device (and in sim capture) that was
// visually INTERCHANGEABLE with Current — both read as pale horizontal smears —
// and it never read as a tide, because a tide needs a waterline, not stripes.
//
// This version commits to the concept: one horizon. Below it is water (dark,
// dense, with swells travelling up through the body); at it is a crisp, near-
// white crest with glints riding along; above it is open field with a soft spill
// of light. The waterline HEIGHT is driven by `energy`, so a work interval
// visibly fills the screen — the glanceable progress cue the scene is for.
//
// Also fixed, shared with the other two Focus shaders: the old
// `col/(col + 0.85)` tonemap mapped 1.0 → 0.54, so nothing could approach white
// and the whole image sat in one washed-out mid band. Now an exposure curve.
//
//   energy (0…1) — work builds it with progress, rest eases, idle sits mid.
//   tint — work/rest/idle colour.  `phase` is a SceneClock time (frozen under
//   Reduce Motion / occlusion).
// ============================================================================

namespace tide {

constant float EXPOSURE = 1.7;
// Near-black so the crest has something to be bright against.
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

    // ---- the waterline -------------------------------------------------------------
    // Height tracks energy, so a work interval visibly fills the field. uv-y grows
    // downward, so a HIGHER level is a SMALLER y.
    float level = 0.28 + 0.34 * e;
    float yl    = 1.0 - level;

    // Travelling surface shape: two counter-moving sines plus a slow fbm roll. All are
    // functions of (x ± phase), i.e. pure translation — features slide along the
    // surface rather than boiling in place (the 2026-07-11 device rule).
    float wave = 0.0;
    wave += sin((x * 3.1 + phase * 0.33) * 6.28318530718) * 0.013;
    wave += sin((x * 6.7 - phase * 0.21) * 6.28318530718) * 0.006;
    wave += (fbm(float2(x * 2.4, phase * 0.16)) - 0.5) * 0.030;
    float surf  = yl + wave;
    float below = y - surf;                       // > 0 under water

    // Soft masks instead of branches.
    float mBelow = smoothstep(-0.0015, 0.0015, below);
    float mAbove = 1.0 - mBelow;

    // ---- water body ----------------------------------------------------------------
    // Brighter just under the surface, falling away into darkness with depth.
    float depth01 = saturate(below / max(level, 0.001));
    float bodyFall = 1.0 - depth01;
    col += tint * mBelow * (0.10 + 0.26 * e) * pow(bodyFall, 1.6);

    // Swells travelling UP through the body (feature at y + phase·k = const ⇒ y falls).
    float swWarp = (fbm(float2(x * 2.0, phase * 0.19)) - 0.5) * 1.1;
    float sw     = 0.5 + 0.5 * sin(((y + phase * (0.16 + 0.22 * e)) * 4.6 + swWarp) * 6.28318530718);
    float swell  = pow(sw, 6.0);
    col += tint * mBelow * swell * (0.14 + 0.26 * e) * pow(bodyFall, 0.8);

    // ---- crest -----------------------------------------------------------------------
    // A thin near-white waterline — the crisp structure v2 never had. Glints ride the
    // surface in its own moving frame so they travel with it.
    float below2 = below * below;
    float crest = bump(below2, 1.0 / (2.56 * 0.0032 * 0.0032));
    float glint = pow(fbm(float2(x * 9.0 - phase * 0.5, phase * 0.4)), 3.0);
    col += mix(tint, float3(1.0), 0.80) * crest * (1.5 + 1.9 * e) * (0.55 + 0.9 * glint);

    // A wider, dimmer shoulder just under the crest gives the surface thickness.
    float shoulder = bump(below2, 1.0 / (2.56 * 0.022 * 0.022));
    col += tint * shoulder * (0.30 + 0.45 * e);

    // ---- spill above the waterline ---------------------------------------------------
    float above = max(0.0, surf - y);
    col += tint * mAbove * exp(-above / 0.11) * (0.09 + 0.18 * e);

    // Slow whole-field breath.
    col *= 0.90 + 0.10 * sin(phase * 1.5);

    // Vignette — edges to black so the horizon reads as the subject.
    float2 vp = (uv - 0.5) * float2(1.0, 1.22);
    col *= 1.0 - 0.48 * dot(vp, vp);

    col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
