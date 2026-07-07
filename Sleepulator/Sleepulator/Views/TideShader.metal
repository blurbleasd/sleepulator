#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Tide (Focus) — a cool water level whose height tracks the Pomodoro.
// ----------------------------------------------------------------------------
// The Metal edition of the CPU `TideView` (which stroked one sine surface + a
// flat gradient fill on a Canvas). Here the surface is per-pixel: an FBM-warped
// waterline with depth shading below and a crisp bright line + specular shimmer
// at the surface. `level` (0…1) is the fill height; the waterline undulates from
// `phase` (a SceneClock time, frozen under Reduce Motion / occlusion).
//
// Helpers are defined locally (namespace `tide`), same self-contained convention
// as CurrentShader/StillWaterShader (each .metal is its own translation unit).
// Swift owns level + tint from the same mapping the Canvas TideView uses.
// ============================================================================

namespace tide {

constant float3 BASE_TOP = float3(0.03, 0.05, 0.10);   // sky above the water
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
                float level, float3 tint) {
    using namespace tide;

    float2 uv = pos / size;
    float x = uv.x, y = uv.y;

    // Base sky above the water.
    float3 col = mix(BASE_TOP, BASE_BOT, y);

    // Waterline (uv-y, 0 top → 1 bottom): water sits below it. Two offset waves + a little FBM so
    // the surface breathes organically instead of marching.
    float surfaceY = 1.0 - clamp(level, 0.0, 1.0);
    float wave = 0.012 * sin(x * 2.2 * 6.28318530718 + phase * 0.5)
               + 0.006 * sin(x * 1.3 * 6.28318530718 - phase * 0.32)
               + 0.005 * (fbm(float2(x * 3.0, phase * 0.2)) - 0.5);
    float surf = surfaceY + wave;

    float below = y - surf;                              // > 0 under the surface
    if (below > 0.0) {
        float d = clamp(below / max(1.0 - surf, 0.001), 0.0, 1.0);   // 0 at surface → 1 at floor
        col += tint * mix(0.30, 0.05, d);                            // brighter near the surface
        // Specular shimmer riding the surface (fades with depth).
        float sh = fbm(float2(x * 6.0 - phase * 0.10, d * 4.0));
        col += tint * pow(sh, 3.0) * 0.06 * (1.0 - d);
    }

    // Crisp waterline + a faint glow just above it.
    col += tint * smoothstep(0.006, 0.0, abs(y - surf)) * 0.5;
    col += tint * smoothstep(0.03, 0.0, max(surf - y, 0.0)) * 0.05;

    col = col / (col + 0.85);                            // filmic roll-off
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither (kills OLED banding)
    return half4(half3(saturate(col)), 1.0h);
}
