#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Tide (Focus) — energy-first. Rising, pulsing bands of cool light surging up
// the field: a "tide" of energy, not a slow water level.
// ----------------------------------------------------------------------------
// The Focus brief is INVIGORATING (the opposite of the Sleep scenes' calm). So
// this pivoted away from the Canvas TideView's slow rising level: the Pomodoro
// now drives ENERGY (intensity + speed + colour), not a slow gauge, and the
// primary motion is kinetic — bright FBM-warped bands scroll upward and pulse.
//   energy (0…1) — work builds it with progress, rest eases, idle sits mid
//   tint         — work=blue / rest=teal / idle=muted blue
// Helpers are local (namespace `tide`); `phase` is a SceneClock time (frozen
// under Reduce Motion / occlusion).
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
    float scroll = phase * (0.5 + 0.9 * e);              // bands rise faster with energy

    // Bright bands scrolling UP the field, each FBM-warped so it wanders, each pulsing on its own
    // beat — a surging, rhythmic energy that reads as awake, not a calm rising level.
    float bands = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float warp = (fbm(float2(x * 3.0 + scroll, fi * 4.0)) - 0.5) * 2.4;
        float yy   = y * 4.0 + scroll + fi * 0.37;       // upward travel (continuous → no seam)
        float band = pow(0.5 + 0.5 * sin(yy * 6.28318530718 - warp), 6.0);
        float pulse = 0.6 + 0.4 * sin(phase * 2.0 + fi * 1.7 + x * 2.0);
        bands += band * pulse * (0.85 - 0.10 * fi);
    }
    col += tint * bands * (0.30 + 0.70 * e) * 0.45;

    // A faint ambient glow lifts with energy so a work sprint literally brightens the field.
    col += tint * 0.04 * e;

    col = col / (col + 0.85);                             // filmic roll-off
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
