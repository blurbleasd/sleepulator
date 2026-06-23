#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Embers — smoldering coals: a dark field of deep reds slowly churning, as if
// staring into banked coals through ash. Significant *but slow* motion (a gentle
// differential swirl + domain-warped drift) so it's hypnotic, not stimulating —
// no flames, no white-hot cores, no sparks. Deep and dark, bottom-weighted.
// ----------------------------------------------------------------------------
// Second take on the Metal embers: the first was a bright flickering fire, wrong
// for sleep. The brief: dark, lulling, hypnotic — motion is fine, brightness and
// fast/darting elements are not. Colour is capped at a muted ember orange.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation; standard hash + value-noise + FBM technique (public
// domain), no third-party shader source copied. Clean to ship.
//
// Driven from SwiftUI `.colorEffect`. Swift owns time, size, nightProgress,
// audioLevel; everything else is a `constant` below (edit + rebuild).
// ============================================================================

namespace ember {

// ---- tunables --------------------------------------------------------------------
constant int   OCTAVES   = 4;      // FBM detail — the battery knob.
constant float DRIFT      = 0.080; // texture drift speed (slow churn)
constant float SWIRL       = 0.050; // differential swirl speed
constant float BREATH_SEC  = 12.0;  // slow brightness breath

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
    for (int i = 0; i < OCTAVES; i++) {
        v += amp * vnoise(p);
        p = p * 2.0 + float2(11.3, 7.7);
        amp *= 0.5;
    }
    return v;
}

// Dark ember ramp: black → deep maroon → dark red → muted orange. Capped low on purpose —
// the brightest coal never reaches yellow/white, so the field stays dark and restful.
inline float3 ramp(float d) {
    float3 c = float3(0.0);
    c = mix(c, float3(0.18, 0.015, 0.004), smoothstep(0.00, 0.45, d));
    c = mix(c, float3(0.42, 0.090, 0.020), smoothstep(0.40, 0.72, d));
    c = mix(c, float3(0.62, 0.200, 0.050), smoothstep(0.72, 0.97, d));
    return c;
}

} // namespace ember

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 emberField(float2 pos, half4 color,
                 float time, float2 size,
                 float night, float audio) {
    using namespace ember;

    float2 uv = pos / size;
    float aspect = size.x / size.y;
    float vY = 1.0 - uv.y;                     // 0 floor → 1 top
    float p = clamp(night, 0.0, 1.0);
    float a = clamp(audio, 0.0, 1.0);
    float dim = 1.0 - 0.5 * p;                 // coals settle darker toward night
    float tA = time * DRIFT * (1.0 - 0.3 * p); // drift slows a touch as the night deepens
    float tS = time * SWIRL;

    // Gentle differential swirl around a low center — inner and outer churn at different rates,
    // which reads as slow, hypnotic rotation rather than a uniform spin.
    float2 q   = float2(uv.x * aspect, uv.y);
    float2 ctr = float2(0.5 * aspect, 0.66);
    float2 rel = q - ctr;
    float rad  = length(rel);
    float ang  = atan2(rel.y, rel.x) + tS - rad * 1.2;
    float2 sw  = ctr + float2(cos(ang), sin(ang)) * rad;

    // Domain-warped FBM advected slowly upward → churning coal texture.
    float2 P    = sw * 3.0;
    float warp  = fbm(P * 1.1 + float2(0.0, tA * 1.4));
    float dens  = fbm(P + warp * 0.9 + float2(0.0, -tA));
    dens = smoothstep(0.35, 0.95, dens);

    // Bottom-weighted like a hearth: brightest low, fading to near-black up top.
    float weight = mix(0.25, 1.0, smoothstep(1.0, 0.05, vY));
    dens *= weight;

    // Slow ~12s breath; gentle audio lift.
    float breath = 0.80 + 0.20 * (1.0 - 0.4 * p) * (0.5 - 0.5 * cos(time * 6.28318530718 / BREATH_SEC));
    float e = clamp(dens * breath * dim * (1.0 + 0.25 * a), 0.0, 1.0);

    float3 col = ramp(e);

    // Faint deep-red ambient + a low hearth glow so the dark isn't a dead flat black.
    col += float3(0.020, 0.004, 0.002);
    col += float3(0.30, 0.07, 0.02) * smoothstep(0.45, 0.0, vY) * 0.06 * dim * breath;

    // Soft vignette toward the warm low center.
    float vg = distance(uv, float2(0.5, 0.6));
    col *= 1.0 - smoothstep(0.45, 0.95, vg) * 0.55;

    // Filmic roll-off + hash dither (kills OLED banding).
    col = col / (col + 0.85);
    col += (hash21(pos + time) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
