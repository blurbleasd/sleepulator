#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Rain on Glass — Depth Edition · running-drops + lens layer effect
// ----------------------------------------------------------------------------
// Plan of record: RAIN-ON-GLASS-DEPTH-SPEC.md (§6.0 / §6.1 / §6.2).
//
// Attached (via SwiftUI `.layerEffect`) to a STATIC composited "far world":
// near-black gradient + a bright, soft bokeh field + a low band of distant
// windows (see RainGlassDepthView). That single layer is all the shader may
// sample (§6.0). The whole glass is alive: a dense scrolling grid streams a
// running drop down EVERY column, each with a trail + scattered droplets, over
// a fine animated mist (no "weirdly static" beads).
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// The running-drops technique is adapted (GLSL -> Metal) from Martijn Steinrucken
// (BigWIngs / "The Art of Code"), "Heartfelt" -- https://www.shadertoy.com/view/ltffzl
// (c) 2017 Martijn Steinrucken, CC BY-NC-SA 3.0. This Metal port is a derivative
// work and inherits that license: fine for THIS personal, non-commercial app, with
// credit. BEFORE PUBLISHING / MONETIZING Sleepulator, either get the author's
// permission (countfrolic@gmail.com / @The_ArtOfCode -- he has a public tutorial on
// this effect) or clean-room reimplement the idea. See RAIN-ON-GLASS-DEPTH-SPEC.md.
// ----------------------------------------------------------------------------
//
// Depth comes from two cues, no second texture and no per-frame blur pass:
//   1. Refraction — the drop field's slope (∇mask) bends the far-world sample,
//      so the bright lights smear/flip through the drops (§6.2 the lens).
//   2. Differential focus — dry glass is fogged + dim, drops are CLEAR windows
//      onto the far world; the eye reads that focus gap as distance (§6.1 DoF).
//
// Swift owns the live values: time, size, gyro, and two master A/B uniforms —
// `refraction` (0 = no bend, drops are just clear-vs-fog; 1 = full lens) and
// `density` (static-mist amount). Everything else is a `constant` below — edit
// + rebuild, no Swift change (§10 step 4).
// ============================================================================

namespace rg {

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant float RAIN_SPEED  = 0.14;   // overall fall speed (smaller = calmer)
constant float DROP_SCALE  = 2.1;    // >1 = smaller, denser drops (fixes "massive bubbles")
constant float REFRACT     = 0.32;   // lens displacement strength (× the refraction uniform)
constant float SPEC_SCALE  = 45.0;   // catch-light sensitivity to drop slope
constant float SPEC_BRIGHT = 0.16;   // catch-light brightness (low → no bright combs)
constant float FOG_DIM     = 0.55;   // how dark the dry (fogged) glass is vs a clear drop
constant float FOG_MILK    = 0.012;  // faint milky lift on the fogged glass (low → stays dark)
constant float PARALLAX_UV = 0.02;   // max gyro far-world shift, uv units (held-only bonus)
constant float STATIC_AMT  = 0.40;   // baseline static-mist amount (× the density uniform)
constant float TRAIL_SHEEN = 0.03;   // faint wet sheen along trails

// -- hashing (Heartfelt's) ---------------------------------------------------------
inline float  N(float x) { return fract(sin(x * 12.9898) * 43758.5453); }
inline float3 N13(float p) {
    float3 p3 = fract(float3(p, p, p) * float3(.1031, .11369, .13787));
    p3 += dot(p3, p3.yzx + 19.19);
    return fract(float3((p3.x + p3.y) * p3.z, (p3.x + p3.z) * p3.y, (p3.y + p3.z) * p3.x));
}
inline float saw(float b, float t) { return smoothstep(0.0, b, t) * smoothstep(1.0, b, t); }

// One layer of running drops over an aspect-square uv (uv * size.y == pos).
// Returns (dropMask, trailMask): a main teardrop falling per grid cell, scattered
// droplets along its wake, and the trail behind it.
inline float2 dropLayer(float2 uv, float t) {
    float2 UV = uv;                          // pre-scroll, for the wiggle + droplet phase
    uv.y += t * 0.75;                        // the whole field scrolls down
    float2 a = float2(6.0, 1.0);
    float2 grid = a * 2.0;
    float2 id = floor(uv * grid);
    uv.y += N(id.x);                         // stagger each column
    id = floor(uv * grid);
    float3 n = N13(id.x * 35.2 + id.y * 2376.1);
    float2 st = fract(uv * grid) - float2(0.5, 0.0);

    float x = n.x - 0.5;
    float y = UV.y * 20.0;
    float wiggle = sin(y + sin(y));
    x += wiggle * (0.5 - abs(x)) * (n.z - 0.5);
    x *= 0.7;

    float ti = fract(t + n.z);
    y = (saw(0.85, ti) - 0.5) * 0.9 + 0.5;   // the drop's falling position in-cell
    float2 p = float2(x, y);

    float d = length((st - p) * a.yx);       // squashed → a vertical teardrop
    float mainDrop = smoothstep(0.4, 0.0, d);

    float r = sqrt(smoothstep(1.0, y, st.y));
    float cd = abs(st.x - x);
    float trail = smoothstep(0.23 * r, 0.15 * r * r, cd);
    float trailFront = smoothstep(-0.02, 0.02, st.y - y);
    trail *= trailFront * r * r;

    float y2 = fract(UV.y * 10.0) + (st.y - 0.5);
    float dd = length(st - float2(x, y2));
    float droplets = smoothstep(0.3, 0.0, dd);

    float m = mainDrop + droplets * r * trailFront;
    return float2(m, trail);
}

// Fine static mist that fades in/out over time (so nothing reads as frozen).
inline float staticDrops(float2 uv, float t) {
    uv *= 40.0;
    float2 id = floor(uv);
    uv = fract(uv) - 0.5;
    float3 n = N13(id.x * 107.45 + id.y * 3543.654);
    float2 p = (n.xy - 0.5) * 0.7;
    float d = length(uv - p);
    float fade = saw(0.025, fract(t + n.z));
    return smoothstep(0.3, 0.0, d) * fract(n.z * 10.0) * fade;
}

// Combined drop "height" at a uv — running drops + mist. Also returns the trail.
//
// Two drop layers at different scales/speeds, with the second grid offset by a non-integer so
// its columns never line up with the first. A single grid read as "geometric" (evenly spaced
// columns marching down); interleaving a denser, faster, smaller-drop layer breaks that
// regularity into something that scans as real rain, and the scale gap reads as near/far depth.
inline float dropMask(float2 uv, float t, float density, thread float &trailOut) {
    float2 c1 = dropLayer(uv, t);                                   // near: larger, slower drops
    float2 c2 = dropLayer(uv * 1.85 + float2(4.3, 1.7), t * 1.27);  // far: smaller, faster, offset
    trailOut = max(c1.y, c2.y);
    float drops = c1.x + c2.x * 0.8;
    return drops + staticDrops(uv, t) * STATIC_AMT * density;
}

} // namespace rg

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 rainGlassLens(float2 pos, SwiftUI::Layer layer,
                    float time, float2 size, float2 gyro,
                    float refraction, float density) {
    using namespace rg;

    // Heartfelt assumes bottom-up Y (Shadertoy); `.layerEffect` is top-down, so flip
    // into a bottom-up uv → drops FALL down. DROP_SCALE shrinks/densifies the field.
    float2 uv = float2(pos.x, size.y - pos.y) / size.y;   // bottom-up, v in [0,1]
    float t = time * RAIN_SPEED;
    float2 duv = uv * DROP_SCALE;

    // height field + its gradient (3 taps, no extra texture samples).
    float trail = 0.0, tx = 0.0, ty = 0.0;
    float e  = 1.0 / size.y;                    // ~1px in uv
    float m  = dropMask(duv, t, density, trail);
    float mx = dropMask((uv + float2(e, 0.0)) * DROP_SCALE, t, density, tx);
    float my = dropMask((uv + float2(0.0, e)) * DROP_SCALE, t, density, ty);
    float2 nrm = float2(mx - m, my - m);       // slope of the wet surface (∂mask/∂uv)

    // refraction: bend the far-world sample by the drop slope → the lens. Work in
    // bottom-up uv, then flip the sample point back to real (top-down) pixels.
    float2 sUV = uv - nrm * (REFRACT * refraction) + gyro * PARALLAX_UV;
    float2 pbu = sUV * size.y;
    float2 px = clamp(float2(pbu.x, size.y - pbu.y), float2(0.0), size);
    half3 far = layer.sample(px).rgb;

    // differential focus: dry glass is fogged + dim, drops are clear windows.
    half3 fog = far * half(FOG_DIM) + half(FOG_MILK);
    float clarity = smoothstep(0.0, 0.18, m);
    half3 rgb = mix(fog, far, half(clarity));

    // catch-light: the upper-left slope of each bead catches the light.
    float spec = clamp((nrm.x + nrm.y) * SPEC_SCALE, 0.0, 1.0);
    rgb += half3(half(spec * spec * clarity * SPEC_BRIGHT));

    // faint wet sheen along the trails.
    rgb += half3(half(trail * TRAIL_SHEEN));

    return half4(rgb, 1.0h);
}
