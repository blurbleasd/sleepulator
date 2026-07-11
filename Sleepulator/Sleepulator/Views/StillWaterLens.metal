#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Still Water — Depth Edition · reflected-horizon layer effect
// ----------------------------------------------------------------------------
// The depth-grammar sibling of StillWaterShader.metal — the ocean generalization
// of the rain-glass depth recipe (RAIN-ON-GLASS-DEPTH-SPEC §2: "near swell / hazy
// horizon"). Instead of painting a procedural moonpath, this samples a composited
// FAR WORLD (sky gradient + moon glow + hazy horizon band, drawn once by
// StillWaterDepthView) and builds the water as a REFLECTION of it, wave-distorted
// by the near swell:
//   • near foreground swell = sharp, high-amplitude distortion (breaks the mirror),
//   • far (near the horizon) = a soft, near-mirror reflection (the focus gap = depth),
//   • the moon + horizon glow appear inverted + rippling in the water (the "whoa").
//
// Reactive (F1 `DepthReactivity`, Swift side): `swell` calms toward night, `fogAmt`
// milks the horizon, `defocus` softens the reflection near the waterline; motion
// slows via the host SceneClock rate (phase already arrives night-slowed).
// `refraction` is the A/B master (0 = flat mirror, proves the seam; 1 = full swell —
// §10 step 2/3). Tune the constants + knobs on device (§10 step 4).
//
// Cost: the water samples the layer a handful of times (reflection + 2 soft taps),
// never a per-frame Gaussian (§6.2 battery trap). The reflection reaches across the
// horizon, so the Swift side sets a full-height maxSampleOffset.
//
// LICENSE: original; standard hash / value-noise / FBM technique (public domain),
// no third-party shader copied. Same noise basis as the repo's other shaders,
// redefined locally (each .metal file is its own translation unit).
// ============================================================================

namespace swd {

constant int   OCTAVES = 4;        // FBM detail — the battery knob
constant float HORIZON = 0.42;     // sky / water split (must match the far-world composition)
constant float FLOW    = 0.5;      // surface drift (× phase; night-slowdown lives in phase)
constant float AMP     = 0.045;    // max reflection displacement, uv units (near foreground)
constant float MOONX   = 0.5;      // moon column x (matches the far world's moon glow)

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1.0, 0.0));
    float c = hash21(i + float2(0.0, 1.0)), d = hash21(i + float2(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
inline float fbm(float2 p) {
    float v = 0.0, amp = 0.5;
    for (int i = 0; i < OCTAVES; i++) { v += amp * vnoise(p); p = p * 2.0 + float2(11.3, 7.7); amp *= 0.5; }
    return v;
}

} // namespace swd

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 stillWaterLens(float2 pos, SwiftUI::Layer layer,
                     float phase, float2 size,
                     float refraction, float swell, float fogAmt, float defocus) {
    using namespace swd;

    float2 uv = pos / size;
    float t = phase * FLOW;

    #define SW_SAMPLE(u) layer.sample(clamp((u) * size, float2(0.0), size)).rgb

    // --- sky: sampled straight from the far world (the moon + gradient + haze) ---------
    if (uv.y < HORIZON) {
        return half4(SW_SAMPLE(uv), 1.0h);
    }

    // --- water: a wave-distorted reflection of the sky --------------------------------
    // depth: 0 at the horizon line → 1 at the near foreground. The swell grows and the
    // mirror breaks up toward the viewer; near the horizon it stays a soft clean mirror.
    float depth = (uv.y - HORIZON) / (1.0 - HORIZON);

    // Perspective-stretched, domain-warped wave field (features lengthen toward the foreground).
    float2 wuv = float2(uv.x * 8.0, depth * depth * 16.0 - t * 1.1);
    float warp  = fbm(wuv * 0.5 + float2(0.0, t * 0.2));
    float waves = fbm(wuv + float2(warp * 0.6, 0.0)) - 0.5;      // signed, ~[-0.5, 0.44]

    // Reflected sky coordinate: mirror y about the horizon, then push by the wave slope.
    float amp = AMP * refraction * swell * mix(0.25, 1.0, depth);   // stronger near, calm far
    float2 refl = float2(uv.x + waves * amp * 0.6,
                         2.0 * HORIZON - uv.y + waves * amp);
    half3 reflected = SW_SAMPLE(refl);

    // Focus gap: the near-horizon reflection reads soft (one extra vertical tap pair, widened by
    // `defocus`), the foreground stays crisp on the wave detail. No per-frame Gaussian (§6.2).
    float e = (0.004 * defocus) * (1.0 - depth);
    half3 soft = (SW_SAMPLE(refl + float2(0.0, e)) + SW_SAMPLE(refl - float2(0.0, e))) * 0.5h;
    reflected = mix(reflected, soft, half(clamp(1.0 - depth, 0.0, 1.0)));

    // Deep near-black water + the reflection: stronger at the grazing horizon, broken up (and
    // milkier as the night fogs) toward the foreground.
    half3 water = half3(half(0.008), half(0.012), half(0.028));
    float reflectivity = mix(0.85, 0.35, depth) * (1.0 - 0.4 * fogAmt);
    half3 col = mix(water, reflected, half(clamp(reflectivity, 0.0, 1.0)));

    // Moon glint on the wave ridges under the moon column — a soft specular sparkle.
    float column = smoothstep(0.34, 0.0, abs(uv.x - MOONX));
    float glint  = pow(clamp(waves + 0.5, 0.0, 1.0), 5.0) * column * (0.35 + 0.65 * depth);
    col += half3(half(0.66), half(0.78), half(0.98)) * half(glint * (1.0 - 0.5 * fogAmt));

    // A soft haze band at the waterline that milks up as the night settles.
    col += half3(half(0.30), half(0.40), half(0.60))
         * half(smoothstep(0.06, 0.0, depth) * (0.05 + 0.10 * fogAmt));

    #undef SW_SAMPLE
    return half4(clamp(col, 0.0h, 1.0h), 1.0h);
}
