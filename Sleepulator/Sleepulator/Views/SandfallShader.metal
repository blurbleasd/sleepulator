#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Sandfall (Focus) — energy-first. A fast downward cascade of light streaks and
// motes: a "fall" of energy, not a slow hourglass.
// ----------------------------------------------------------------------------
// Pivoted from the Canvas SandfallView's slow hourglass (a calm progress gauge)
// to the invigorating Focus brief: the Pomodoro drives ENERGY (density + speed +
// colour), not a slow level, and the primary motion is a kinetic downpour —
// advected FBM streaks plus sparse bright motes streaming down.
//   energy (0…1) — work builds it with progress, rest eases, idle sits mid
//   tint         — work=blue / rest=teal / idle=muted blue
// Helpers are local (namespace `sf`); `phase` is a SceneClock time.
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
    float fall = phase * (1.0 + 1.6 * e);                // faster downpour with energy

    // Vertical streaks: FBM scrolled downward reads as a fast falling curtain of light.
    float streak = fbm(float2(x * 9.0, y * 4.0 + fall * 1.6));
    col += tint * pow(smoothstep(0.55, 0.95, streak), 1.5) * (0.30 + 0.65 * e);

    // Sparse bright motes streaming down their own columns — the kinetic sparkle.
    for (int i = 0; i < 2; i++) {
        float sc = 34.0 + 14.0 * float(i);
        float2 g = floor(float2(x * sc, (y * sc) + fall * (26.0 + 10.0 * float(i))));
        float h = hash21(g + float2(float(i) * 7.0, 0.0));
        float mote = step(0.93, h);
        float twinkle = 0.5 + 0.5 * sin(phase * 4.0 + h * 6.28318530718);
        col += (tint + float3(0.12)) * mote * twinkle * (0.28 + 0.5 * e);
    }

    // Ambient glow lifts with energy.
    col += tint * 0.04 * e;

    col = col / (col + 0.85);                             // filmic roll-off
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
