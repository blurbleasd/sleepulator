#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Deep space — a slow nebula of domain-warped FBM cloud over a parallax star
// field, with a rare drifting comet. The "wow" sleep scene.
// ----------------------------------------------------------------------------
// A new generative showpiece (the catalog's "Deep space" entry). Volumetric feel
// from layered, colour-ramped FBM; depth from multiple star tiers that parallax
// by the gyro; a comet sweeps every two minutes instead of the night-sky meteor.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation. Standard hash + value-noise + FBM (public domain) and
// a plain mix/smoothstep colour ramp. No code copied. Clean to ship with credit
// to the techniques.
//
// Driven from SwiftUI `.colorEffect`. Swift owns phase, time, size,
// nightProgress, audioLevel, gyro; everything else is a `constant` below
// (edit + rebuild). `phase` is night-slowed integrated time for motion terms,
// `time` is monotonic elapsed for cyclic terms (twinkle, breath, the comet
// cycle, dither) — see the time contract in AuroraShader.metal / SceneClock in
// ShaderBackdrop.swift. COMET_SEC/COMET_WIN are mirrored in DeepSpaceMetalView
// (the frozen-frame comet dodge) — keep them in sync.
// ============================================================================

namespace neb {

// ---- tunables --------------------------------------------------------------------
constant int   OCTAVES   = 5;      // nebula detail — the battery knob (drop to 4 if warm).
constant float DRIFT      = 0.012; // nebula drift speed
// One comet every two minutes, ~6 s on screen. At 40 s apart it was a white streak across a
// sleeping partner's peripheral vision every few breaths, not a rare delight.
constant float COMET_SEC  = 120.0; // seconds between comets
constant float COMET_WIN  = 0.05;  // fraction of the cycle a comet is visible (6 s)

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
// Star-cell hash on the cell's integer bits. `hash21` above is fine for noise, but on integer
// cell ids it repeats: 345.45 × 20 and 123.34 × 50 are whole numbers, so the star field came out
// as the same strip of stars every 20 cells down (thirds of the screen in Deep space, every 80 pt
// in Aurora and Still water). `salt` picks an independent stream per use.
inline float hashCell(float2 cell, uint salt) {
    uint2 q = uint2(int2(cell));
    uint h = q.x * 1597334677u ^ q.y * 3812015801u ^ salt * 2654435761u;
    h ^= h >> 16; h *= 2246822519u;
    h ^= h >> 13; h *= 3266489917u;
    h ^= h >> 16;
    return float(h) * (1.0 / 4294967296.0);
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

// Nebula ramp: dusky plum → rust → amber dust, so the showpiece keeps Sleep's warm dusk. (It was
// a cosine palette meant as violet→blue→magenta→cyan; over the density range actually used it
// rendered a muddy olive-khaki.)
inline float3 palette(float d) {
    float3 c = mix(float3(0.34, 0.10, 0.18), float3(0.70, 0.25, 0.13), smoothstep(0.35, 0.65, d));
    return mix(c, float3(0.80, 0.48, 0.20), smoothstep(0.65, 0.95, d));
}

// One parallax star tier: a scrolling, gyro-shifted grid where rare cells hold a twinkling star.
// Positional drift rides `drift` (the night-slowed phase — the tiers settle with the nebula, and
// the frozen-frame comet dodge can shift only twinkle pose, never star positions); twinkle rides
// `twinkle` (monotonic elapsed) so its frequency holds through the night.
inline float3 starTier(float2 uv, float drift, float twinkle, float depth, float2 gyro, float thresh) {
    float2 p = uv;
    p += gyro * (0.01 + depth * 0.04);          // nearer tiers shift more with tilt
    p.y += drift * (0.002 + depth * 0.004);      // a slow downward drift
    float2 g = p * (60.0 + depth * 120.0);
    float2 id = floor(g);
    float h = hashCell(id, 1u + uint(depth * 2.0));   // one stream per tier
    if (h < thresh) return float3(0.0);
    float2 st = fract(g) - 0.5;
    float d = length(st);
    float core = smoothstep(0.18, 0.0, d);
    float tw = 0.5 + 0.5 * sin(twinkle * (1.0 + h * 2.0) + h * 100.0);
    float3 tint = mix(float3(0.96, 0.90, 0.84), float3(1.0, 0.82, 0.62), fract(h * 7.0));   // warm whites
    return tint * core * tw * (0.4 + depth * 0.8);
}

} // namespace neb

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 nebulaField(float2 pos, half4 color,
                  float phase, float time, float2 size,
                  float night, float audio, float2 gyro) {
    using namespace neb;

    float2 uv = pos / size;
    float aspect = size.x / size.y;
    float2 auv = float2(uv.x * aspect, uv.y);     // aspect-corrected for round shapes
    float p = clamp(night, 0.0, 1.0);
    float a = clamp(audio, 0.0, 1.0);
    float dim = (1.0 - 0.45 * p);
    float t = phase * DRIFT;                     // drift rate slowdown lives in phase

    float3 col = float3(0.008, 0.005, 0.004);     // deep space black, a faint warm lift

    // --- nebula: two domain-warped FBM layers at different scales/colours for depth ---
    for (int L = 0; L < 2; L++) {
        float fl = float(L);
        float scale = 1.6 + fl * 1.4;
        float2 q = auv * scale + float2(t * (1.0 + fl), -t * 0.6) + gyro * (0.02 + fl * 0.03);
        float warp = fbm(q * 1.3 + float2(0.0, t * 2.0));
        float d = fbm(q + float2(warp * 0.8, warp * 0.5));
        // Sparse, soft clouds: push the low end to black so most of the sky stays dark (OLED).
        float density = pow(smoothstep(0.45, 0.95, d), 1.6);
        float3 c = palette(d * 0.8 + fl * 0.15 + 0.1 * p);  // hue drifts a touch over the night
        col += c * density * (0.6 - fl * 0.18) * dim * (1.0 + 0.35 * a);
    }

    // Collective ~13s breath.
    float breath = 0.85 + 0.15 * (1.0 - 0.4 * p) * (0.5 - 0.5 * cos(time * 6.28318530718 / 13.0));
    col *= breath;

    // --- parallax star field (three tiers: far/dim → near/bright) ---
    col += starTier(auv, phase, time, 0.0, gyro, 0.985);
    col += starTier(auv, phase, time, 0.5, gyro, 0.990);
    col += starTier(auv, phase, time, 1.0, gyro, 0.994);

    // --- a rare comet, sweeping diagonally every COMET_SEC ---
    // Transients sleep too: the comet fades out as the night deepens and is gone past
    // p ≈ 0.4 (about 18 minutes into an untimed night) — a bright streak at 4am is a wake risk,
    // not a delight.
    float idx = floor(time / COMET_SEC);
    float ph  = fract(time / COMET_SEC);
    float win = smoothstep(0.0, 0.006, ph) * smoothstep(COMET_WIN, COMET_WIN - 0.015, ph);
    win *= 1.0 - smoothstep(0.15, 0.40, p);
    if (win > 0.001) {
        float seg = ph / COMET_WIN;
        float2 s = float2(-0.15 * aspect, 0.12 + hash21(float2(idx, 1.0)) * 0.30);
        float2 e = float2(1.15 * aspect, 0.45 + hash21(float2(idx, 2.0)) * 0.30);
        float2 head = mix(s, e, seg);
        float2 dir = normalize(e - s);
        float2 rel = auv - head;
        float along = dot(rel, -dir);                       // >0 = behind the head (the tail)
        float perp  = abs(dot(rel, float2(-dir.y, dir.x)));
        float tail = smoothstep(0.22, 0.0, along) * step(0.0, along) * smoothstep(0.010, 0.0, perp);
        float core = smoothstep(0.012, 0.0, length(rel));
        col += float3(1.0, 0.84, 0.62) * (tail * 0.5 + core * 0.7) * win * dim;
    }

    // Filmic roll-off + hash dither (kills OLED banding). Wrap `time` small before the hash: hours
    // into a session `time` reaches tens of thousands and the hash's internal fract() overflows
    // float precision, freezing the dither and letting banding return. 64 s period, invisible
    // because the dither is pure noise. (See AuroraShader.metal for the full rationale.)
    col = col / (col + 0.9);
    col += (hash21(pos + fmod(time, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
