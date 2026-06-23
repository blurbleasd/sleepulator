#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Aurora — generative curtains via FBM value-noise + domain warping.
// ----------------------------------------------------------------------------
// The Metal proof-of-concept replacement for the CPU `AuroraView` (which drew
// striated gradient rectangles on a Canvas). Here the whole sky is a continuous
// noise field evaluated per pixel on the GPU: curtains fold and flow from
// domain-warped FBM, never visibly repeat, and cost almost nothing on CPU.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation. The noise is the standard hash + value-noise + FBM
// construction (a public-domain *technique*, not copied code — cf. Morgan
// McGuire's hash and the value-noise lerp every shader text teaches). No
// third-party shader source is reproduced, so this is clean to ship; credit the
// technique, not any one author. Unlike RainGlass.metal (a CC BY-NC-SA port),
// this carries no licensing baggage.
//
// Driven from SwiftUI `.colorEffect`: each pixel returns its own colour, so it
// attaches to a plain full-screen Rectangle. Swift owns the live values — time,
// size, nightProgress, audioLevel, gyro — and everything else is a `constant`
// below (edit + rebuild, no Swift change).
// ============================================================================

namespace aur {

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant int   OCTAVES   = 4;     // FBM detail. THE battery knob — 3 is cheaper, 5 richer.
constant float FLOW       = 0.060; // base time scale (smaller = slower, calmer)
constant float WARP_AMT   = 0.35;  // domain-warp strength → how much the curtains fold
constant float BREATH_SEC = 11.0;  // collective brightness breath period
constant int   LAYERS     = 3;     // depth layers of curtains accumulated additively

// Curtain palette (linear-ish): green/teal base rising to violet tips.
constant float3 C_GREEN  = float3(0.18, 0.85, 0.55);
constant float3 C_TEAL   = float3(0.16, 0.55, 0.62);
constant float3 C_VIOLET = float3(0.55, 0.42, 0.95);

// -- hash + value-noise + FBM (standard technique) ---------------------------------
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

inline float vnoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);          // smootherstep weights
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
        p = p * 2.0 + float2(11.3, 7.7);          // offset each octave to decorrelate
        amp *= 0.5;
    }
    return v;
}

} // namespace aur

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 auroraField(float2 pos, half4 color,
                  float time, float2 size,
                  float night, float audio, float2 gyro) {
    using namespace aur;

    float2 uv = pos / size;                  // 0..1, top-down
    float vY = 1.0 - uv.y;                   // bottom-up height (0 floor → 1 sky)
    float x  = uv.x;

    float p = clamp(night, 0.0, 1.0);        // night progress: 0 start → 1 timer end
    float a = clamp(audio, 0.0, 1.0);        // smoothed audio level
    float motion = 1.0 - 0.5 * p;            // wind motion amplitude down as the night settles
    float t = time * FLOW * motion;

    // Gyro parallax (a watching-window bonus; 0 on a flat nightstand).
    x += gyro.x * 0.03;
    float baseShift = gyro.y * 0.02;

    // --- accumulate the curtains ---
    float3 col = float3(0.0);
    for (int L = 0; L < LAYERS; L++) {
        float fl     = float(L);
        float scale  = 1.4 + fl * 1.1;        // nearer layers have finer curtains
        float speed  = 0.5 + fl * 0.5;        // …and flow a little faster
        float baseY  = 0.34 + fl * 0.06 + baseShift;  // far layers sit higher in the sky
        float bright = 1.0 - 0.22 * fl;

        // Domain warp the horizontal coordinate → folds that move and never repeat.
        float w  = fbm(float2(x * 1.6 + t * speed, fl * 3.1 + t * 0.30));
        float xx = x * scale + (w - 0.5) * WARP_AMT * motion;

        // Where light lives across x, and the moving vertical striations within it.
        float dens = smoothstep(0.45, 0.95, fbm(float2(xx * 2.0, fl * 5.0 + t * speed * 0.7)));
        float ray  = 0.4 + 0.6 * fbm(float2(xx * 6.0, vY * 2.2 - t * speed * 1.5 + fl));

        // Vertical profile: rises sharply just above the base, long soft tail upward.
        float up   = vY - baseY;
        float band = smoothstep(-0.05, 0.10, up) * smoothstep(0.55, 0.0, up);

        float intensity = pow(dens * ray * band * bright, 1.3);

        // Colour by height within the curtain: green/teal base → violet tips. The warm
        // base fades faster than the violet as night deepens, so the end state is a dim
        // violet wash.
        float h = clamp(up / 0.5, 0.0, 1.0);
        float3 base = mix(C_GREEN, C_TEAL, 0.3 + 0.5 * p);   // less green, more teal at night
        float3 cc   = mix(base * (1.0 - 0.35 * p), C_VIOLET, h);
        col += cc * intensity;
    }

    // Collective ~11s breath; its swell shrinks as the night settles.
    float breath = 0.82 + 0.18 * (1.0 - 0.4 * p) * (0.5 - 0.5 * cos(time * 6.28318530718 / BREATH_SEC));
    col *= breath;

    // Night dim + a gentle audio swell.
    col *= (1.0 - 0.45 * p) * (1.0 + 0.4 * a);

    // Faint low horizon glow the curtains seem to rise from.
    float horizon = smoothstep(0.30, 0.0, vY) * 0.12;
    col += float3(0.10, 0.45, 0.35) * horizon * (1.0 - 0.6 * p);

    // Deep blue-black base sky.
    col += mix(float3(0.012, 0.015, 0.030), float3(0.004, 0.005, 0.013), vY);

    // Faint stars, weighted toward the upper sky and dimmed wherever a curtain is bright.
    float lum = dot(col, float3(0.299, 0.587, 0.114));
    float2 sg = floor(pos / 3.0);
    float sh  = hash21(sg);
    float star = step(0.992, sh) * smoothstep(0.05, 0.65, vY);
    float tw   = 0.55 + 0.45 * sin(time * 1.7 + sh * 100.0);
    col += float3(0.85, 0.90, 1.0) * star * tw * 0.6 * (1.0 - clamp(lum * 3.0, 0.0, 1.0));

    // Gentle Reinhard-ish roll-off keeps highlights from clipping harshly (filmic, OLED-kind).
    col = col / (col + 0.85);

    // Ordered-ish hash dither: breaks the gradient banding that plagues flat OLED sleep scenes.
    float dither = (hash21(pos + time) - 0.5) / 255.0;
    col += dither;

    return half4(half3(saturate(col)), 1.0h);
}
