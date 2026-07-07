#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Current (Focus) — cool streams flowing across a deep-indigo field.
// ----------------------------------------------------------------------------
// The Metal edition of the CPU `CurrentView` (which stroked 7 sine paths on a
// Canvas). Here each pixel samples a domain-warped FBM flow field: streams fold
// and drift, never visibly repeat, and cost almost nothing on CPU. Peripheral by
// design — calm momentum, never attention-grabbing.
//
// The noise/dither/filmic helpers are defined locally (namespace `cur`), same
// self-contained convention as StillWaterShader/AuroraShader (each .metal is its
// own translation unit).
//
// Swift owns the live values, all from the shared FocusDrivers mapping so the
// Metal A/B reads the Pomodoro identically to the Canvas CurrentView:
//   flow      — the SceneClock phase (driveSpeed integrated into a rate → monotonic,
//               pauses in place; Reduce Motion feeds rate 0 so `flow` freezes → static field)
//   driveOp   — stream opacity   (work ramps with progress)
//   driveAmp  — vertical sway    (work ramps with progress)
//   tint      — work=blue / rest=teal / idle=muted blue
// Everything else is a `constant` below (edit + rebuild, no Swift change).
// ============================================================================

namespace cur {

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant int   STREAMS  = 7;      // depth of flowing streams accumulated additively (Focus = livelier)
constant int   FBM_OCT  = 4;      // FBM detail for the fold — the battery knob (3 cheaper)
constant float DRIFT    = 1.25;   // maps SceneClock phase → advection distance (faster flow)
constant float SWAY     = 0.16;   // vertical undulation amplitude (scaled by driveAmp)

// Deep-indigo base (matches the Canvas Current gradient: top → bottom).
constant float3 BASE_TOP = float3(0.04, 0.06, 0.12);
constant float3 BASE_BOT = float3(0.02, 0.03, 0.06);

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
inline float fbm(float2 p, int octaves) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < octaves; i++) {
        v += amp * vnoise(p);
        p = p * 2.0 + float2(11.3, 7.7);
        amp *= 0.5;
    }
    return v;
}

} // namespace cur

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 currentField(float2 pos, half4 color,
                   float flow, float2 size,
                   float driveOp, float driveAmp, float3 tint) {
    using namespace cur;

    float2 uv = pos / size;
    float x = uv.x;
    float y = uv.y;

    // Deep-indigo base.
    float3 col = mix(BASE_TOP, BASE_BOT, y);

    float t   = flow * DRIFT;                              // advection distance from the SceneClock phase
    float amp = SWAY * (0.6 + clamp(driveAmp, 0.0, 1.5));  // vertical sway
    float op  = 0.30 + 0.70 * clamp(driveOp, 0.0, 1.0);    // stream opacity

    for (int i = 0; i < STREAMS; i++) {
        float fi = float(i);
        float baseY = 0.16 + fi / float(STREAMS) * 0.66;
        float speed = 0.55 + 0.5 * fract(sin(fi * 12.9898) * 43758.5453);

        // Advect left→right — the "it's flowing" cue.
        float xl = x + t * speed;

        // Domain-warp the vertical position → folds that move and never repeat.
        float warp = fbm(float2(xl * 1.7, fi * 3.1 + t * 0.40), FBM_OCT);
        float cy   = baseY + (warp - 0.5) * amp;

        // Soft line around the stream centre; thickness breathes with a second noise.
        float thick = 0.010 + 0.028 * fbm(float2(xl * 3.0 + fi, t * 0.5), 3);
        float line  = smoothstep(thick, 0.0, abs(y - cy));

        // Brightness varies along the stream so it reads as light, not a wire.
        float glow  = 0.35 + 0.65 * fbm(float2(xl * 5.0, fi * 7.0 - t), 3);

        float depth = 1.0 - 0.22 * fi / float(STREAMS);   // nearer streams a touch dimmer → depth
        col += tint * line * glow * op * depth;
    }

    // Faint low glow the streams seem to ride over.
    float floorGlow = smoothstep(1.0, 0.55, y) * 0.05;
    col += tint * floorGlow * op;

    // Filmic roll-off + hash dither (kills OLED banding). Wrap the (monotonic) `flow` small before
    // the hash so its internal fract() doesn't overflow float precision hours in (see AuroraShader).
    col = col / (col + 0.85);
    col += (hash21(pos + fmod(flow, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
