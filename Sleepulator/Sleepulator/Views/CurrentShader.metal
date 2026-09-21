#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Current (Focus) — bright cool filaments streaming across a near-black field.
// ----------------------------------------------------------------------------
// v3 "bold" rewrite (2026-09-21). v2 read as flat pale-grey smears on device and
// in sim capture — interchangeable with Tide, no structure, no depth. Three
// concrete faults, all fixed here:
//
//  1. TONEMAP CRUSH. `col/(col + 0.85)` maps a full-intensity feature (1.0) to
//     0.54 — mid grey. Nothing could ever approach white, so the whole scene sat
//     in one narrow mid band. Replaced with an exposure curve,
//     `1 - exp(-col·EXPOSURE)`, which leaves darks alone and drives highlights
//     to near-white, so the image finally has a real luminance range.
//  2. NO CORE. Streams were a single broad `smoothstep` lobe up to ~7% of screen
//     height — soft all the way through, so seven of them washed together. Each
//     stream is now a THIN near-white core (`cw`, sub-1% tall) inside a soft
//     tinted halo: crisp structure that still glows.
//  3. NO CONTRAST ALONG THE STREAM. Brightness rode a raw fbm in [0.35,1.0] —
//     always lit. It is now gamma-shaped with a floor subtracted, so a stream
//     goes genuinely dark between bright runs and the eye can track the runs.
//
// Depth comes from streams being deliberately UNEQUAL (per-stream brightness
// spans ~0.3…1.0) rather than a uniform stack. Motion is translation: every
// pattern is sampled in the stream's moving frame (`xl`), never re-rolled per
// frame — the standing rule from the 2026-07-11 device pass.
//
// Swift owns the live values (shared FocusDrivers mapping):
//   flow — SceneClock phase (Reduce Motion feeds rate 0 → frozen field)
//   driveOp — stream opacity · driveAmp — vertical sway · tint — work/rest/idle
// ============================================================================

namespace cur {

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant int   STREAMS  = 6;      // fewer than v2's 7, but each one actually reads
constant int   FBM_OCT  = 4;      // FBM detail for the fold — the battery knob
constant float DRIFT    = 1.25;   // maps SceneClock phase → advection distance
constant float SWAY     = 0.16;   // vertical undulation amplitude (× driveAmp)
constant float EXPOSURE = 1.7;    // highlight drive for the exposure tonemap

// Near-black indigo. v2 started at 0.04–0.12 and the old tonemap lifted it further,
// so the scene had no true blacks to contrast against.
constant float3 BASE_TOP = float3(0.014, 0.020, 0.048);
constant float3 BASE_BOT = float3(0.004, 0.007, 0.020);

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

    float3 col = mix(BASE_TOP, BASE_BOT, y);

    float t   = flow * DRIFT;                              // advection distance
    float amp = SWAY * (0.6 + clamp(driveAmp, 0.0, 1.5));  // vertical sway
    float op  = 0.30 + 0.70 * clamp(driveOp, 0.0, 1.0);    // stream opacity

    // A near-white core colour: the filament reads as light, the halo carries the hue.
    float3 coreCol = mix(tint, float3(1.0), 0.72);

    for (int i = 0; i < STREAMS; i++) {
        float fi = float(i);
        float baseY = 0.12 + fi / float(STREAMS) * 0.76;
        float r1    = fract(sin(fi * 12.9898) * 43758.5453);
        float r2    = fract(sin(fi * 41.113) * 24634.6345);
        float speed = 0.55 + 0.5 * r1;

        // Advect — sample everything in the stream's MOVING frame so patterns TRANSLATE
        // with the flow instead of boiling in place (device 2026-07-11).
        float xl = x + t * speed;

        // Domain-warp the vertical position → folds that travel and gently evolve.
        float warp = fbm(float2(xl * 1.7, fi * 3.1 + t * 0.12), FBM_OCT);
        float cy   = baseY + (warp - 0.5) * amp;
        float d    = y - cy;

        // Brightness along the stream, gamma-shaped so the dark stretches go genuinely
        // dark (v2's raw fbm floor of 0.35 meant a stream was never off → uniform wash).
        float g    = fbm(float2(xl * 2.2, fi * 7.0), 3);
        float glow = pow(saturate(g * 1.45 - 0.22), 2.2);

        // A travelling brightness SWELL along each stream — the direction + energy cue.
        //
        // v3.2: this was an ASYMMETRIC gaussian (short bright front, long tail). On a thin
        // filament that silhouette is a bulbous head dragging a tail — which reads,
        // unmistakably and unfortunately, as a spermatozoon. Fixed by making the swell
        // SYMMETRIC and long: there is no discrete head to read as a nucleus, so it reads
        // as light running through a fibre instead of an organism swimming along it.
        float prate = 0.35 + 0.20 * speed;
        float xp    = fract(fract(sin(fi * 78.233) * 43758.5453) - t * prate);
        float pdist = fract(x - xp + 0.5) - 0.5;
        float pw    = 0.18;                                  // long + symmetric
        float pulse = exp(-(pdist * pdist) / (pw * pw));

        // Amplitudes are down accordingly: a long swell at the old peak would just be a
        // bright bar. The halo gets only a touch so the glow doesn't bloom into a blob.
        float energyHalo = glow + pulse * 0.45;
        float energyCore = glow + pulse * 1.30;

        // Thin core inside a soft halo — the structure v2 lacked entirely.
        float cw   = 0.0030 + 0.0035 * r2;
        float hw   = 0.020 + 0.028 * fbm(float2(xl * 3.0 + fi, t * 0.15), 3);
        float core = exp(-(d * d) / (cw * cw));
        float halo = exp(-(d * d) / (hw * hw));

        // Streams are deliberately UNEQUAL in brightness → depth without a fog layer.
        float depth = mix(0.30, 1.0, r2);

        col += tint    * halo * 0.42 * energyHalo * op * depth;
        col += coreCol * core * 2.10 * energyCore * op * depth;
    }

    // Faint floor glow the streams ride over.
    col += tint * smoothstep(1.0, 0.55, y) * 0.035 * op;

    // Vignette — pushes the edges to black so the centre reads as the subject.
    float2 vp = (uv - 0.5) * float2(1.0, 1.22);
    col *= 1.0 - 0.50 * dot(vp, vp);

    // Exposure tonemap: darks stay dark, highlights approach white (see header note 1).
    col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);

    // Hash dither kills OLED banding. Wrap the monotonic `flow` before hashing so its
    // internal fract() doesn't lose precision hours in (see AuroraShader).
    col += (hash21(pos + fmod(flow, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
