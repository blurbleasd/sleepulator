#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Still Water — a low moon over a dark pond, its light a shimmering reflected
// path on the surface, with faint concentric ripples spreading from a few points.
// ----------------------------------------------------------------------------
// The Metal replacement for the CPU `StillWaterView` (which stroked ellipse
// *outlines* — wireframe rings that read as a diagram of water, not water).
// Here the surface is a per-pixel FBM wave field: the moonpath shimmers on the
// wave ridges as real specular glints, and ripples perturb the field locally
// rather than being drawn as rings.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation; standard hash + value-noise + FBM technique (public
// domain), no third-party shader source copied. Clean to ship with credit to
// the technique. (Cf. AuroraShader.metal — same noise basis, redefined locally
// because each .metal file is its own translation unit.)
//
// Driven from SwiftUI `.colorEffect`. Swift owns time, size, nightProgress,
// audioLevel; everything else is a `constant` below (edit + rebuild).
// ============================================================================

namespace sw {

// ---- tunables --------------------------------------------------------------------
constant int   OCTAVES   = 4;      // FBM detail — the battery knob.
constant float FLOW       = 0.50;  // surface drift speed (× motion)
constant float HORIZON    = 0.42;  // sky / water split (0 top → 1 bottom)
constant float2 MOON      = float2(0.5, 0.16);   // moon position in the sky
constant float3 MOONLIGHT = float3(0.66, 0.78, 0.98);  // cool moonlit blue-white

// Ripple sources (in uv space, in the water) and their phase offsets.
constant float2 SRC[3] = { float2(0.30, 0.62), float2(0.70, 0.74), float2(0.50, 0.88) };
constant float  RPH[3] = { 0.0, 0.37, 0.71 };

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

} // namespace sw

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 stillWaterField(float2 pos, half4 color,
                      float time, float2 size,
                      float night, float audio) {
    using namespace sw;

    float2 uv = pos / size;
    float p = clamp(night, 0.0, 1.0);
    float a = clamp(audio, 0.0, 1.0);
    float motion = 1.0 - 0.5 * p;
    float t = time * FLOW * motion;
    float moonDim = 1.0 - 0.6 * p;

    // --- base sky / water gradient ---
    float3 col;
    if (uv.y < HORIZON) {
        float s = uv.y / HORIZON;                         // 0 top → 1 horizon
        col = mix(float3(0.05, 0.08, 0.15), float3(0.03, 0.05, 0.10), s);
    } else {
        float d = (uv.y - HORIZON) / (1.0 - HORIZON);     // 0 horizon → 1 foreground
        col = mix(float3(0.015, 0.02, 0.045), float3(0.008, 0.01, 0.025), d);
    }

    // --- moon disc + halo ---
    float md = distance(uv, MOON);
    col += MOONLIGHT * smoothstep(0.045, 0.0, md) * 0.9 * moonDim;   // disc
    col += float3(0.40, 0.55, 0.85) * smoothstep(0.28, 0.0, md) * 0.18 * moonDim;  // halo

    // --- water surface ---
    if (uv.y >= HORIZON) {
        float depth = (uv.y - HORIZON) / (1.0 - HORIZON);   // perspective: 1 = near foreground
        float x = uv.x;

        // Perspective-scaled wave field: features stretch toward the foreground. A domain warp
        // gives the ridges an organic, non-repeating wander.
        float2 wuv = float2(x * 8.0, depth * depth * 16.0 - t * 1.1);
        float warp  = fbm(wuv * 0.5 + float2(0.0, t * 0.2));
        float waves = fbm(wuv + float2(warp * 0.6, 0.0));

        // Concentric ripples spreading from a few points — perturb the wave field locally
        // (extra sparkle rings) instead of being drawn as outlines. Far sources still first.
        float ripple = 0.0;
        for (int i = 0; i < 3; i++) {
            float dist = distance(uv, SRC[i]);
            float prog = fract(t * 0.10 + RPH[i]);
            float r    = prog * 0.55;
            float ring = smoothstep(0.045, 0.0, abs(dist - r)) * (1.0 - prog);
            ripple += ring;
        }
        waves += ripple * 0.5 * motion;

        // The moon's reflected path: a soft vertical column under the moon, shimmering where the
        // wave ridges catch the light. Wider + brighter toward the foreground.
        float column = smoothstep(0.34, 0.0, abs(x - MOON.x));
        float glint  = pow(clamp(waves, 0.0, 1.0), 5.0);
        float path   = column * glint * (0.35 + 0.65 * depth);

        float still = 1.0 - 0.55 * p;        // the pond stills toward night
        float swell = 1.0 + 0.30 * a;        // ripples reach a little brighter on a swell
        col += MOONLIGHT * path * still * swell * moonDim;

        // A faint overall sheen so the dark water isn't dead flat.
        col += float3(0.20, 0.30, 0.45) * pow(clamp(waves, 0.0, 1.0), 2.0) * 0.04 * still;
    }

    // Faint band where sky meets water.
    col += float3(0.30, 0.40, 0.60) * smoothstep(0.06, 0.0, abs(uv.y - HORIZON)) * 0.05;

    // Stars in the sky, dimmed near the moon and as the night deepens.
    if (uv.y < HORIZON) {
        float2 sg = floor(pos / 3.0);
        float sh  = hash21(sg);
        float star = step(0.992, sh) * smoothstep(0.0, 0.5, (HORIZON - uv.y) / HORIZON);
        float tw   = 0.55 + 0.45 * sin(time * 1.7 + sh * 100.0);
        float nearMoon = smoothstep(0.0, 0.25, md);
        col += float3(0.85, 0.90, 1.0) * star * tw * 0.5 * (1.0 - 0.6 * p) * nearMoon;
    }

    // Soft vignette to settle the eye toward the center.
    float vg = distance(uv, float2(0.5, 0.5));
    col *= 1.0 - smoothstep(0.45, 0.95, vg) * 0.5;

    // Filmic roll-off + hash dither (kills OLED banding).
    col = col / (col + 0.85);
    col += (hash21(pos + time) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
