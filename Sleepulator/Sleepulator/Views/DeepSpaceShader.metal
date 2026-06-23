#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Deep space — a slow nebula of domain-warped FBM cloud over a parallax star
// field, with a rare drifting comet. The "wow" sleep scene.
// ----------------------------------------------------------------------------
// A new generative showpiece (the catalog's "Deep space" entry). Volumetric feel
// from layered, colour-ramped FBM; depth from multiple star tiers that parallax
// by the gyro; a comet sweeps every ~40s instead of the night-sky meteor.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation. Standard hash + value-noise + FBM (public domain) and
// the cosine-palette *technique* (a + b·cos(2π(c·t+d)) — a well-known shaping
// trick, reimplemented here, no code copied). Clean to ship with credit to the
// techniques.
//
// Driven from SwiftUI `.colorEffect`. Swift owns time, size, nightProgress,
// audioLevel, gyro; everything else is a `constant` below (edit + rebuild).
// ============================================================================

namespace neb {

// ---- tunables --------------------------------------------------------------------
constant int   OCTAVES   = 5;      // nebula detail — the battery knob (drop to 4 if warm).
constant float DRIFT      = 0.012; // nebula drift speed
constant float COMET_SEC  = 40.0;  // seconds between comets
constant float COMET_WIN  = 0.16;  // fraction of the cycle a comet is visible

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

// Cosine palette (iq-style technique): smooth violet→blue→magenta→cyan ramp.
inline float3 palette(float d) {
    float3 a = float3(0.16, 0.10, 0.22);
    float3 b = float3(0.32, 0.22, 0.42);
    float3 c = float3(1.0, 1.0, 1.0);
    float3 e = float3(0.20, 0.45, 0.78);
    return a + b * cos(6.28318530718 * (c * d + e));
}

// One parallax star tier: a scrolling, gyro-shifted grid where rare cells hold a twinkling star.
inline float3 starTier(float2 uv, float time, float depth, float2 gyro, float thresh) {
    float2 p = uv;
    p += gyro * (0.01 + depth * 0.04);          // nearer tiers shift more with tilt
    p.y += time * (0.002 + depth * 0.004);       // a slow downward drift
    float2 g = p * (60.0 + depth * 120.0);
    float2 id = floor(g);
    float h = hash21(id + depth * 17.0);
    if (h < thresh) return float3(0.0);
    float2 st = fract(g) - 0.5;
    float d = length(st);
    float core = smoothstep(0.18, 0.0, d);
    float tw = 0.5 + 0.5 * sin(time * (1.0 + h * 2.0) + h * 100.0);
    float3 tint = mix(float3(0.75, 0.82, 1.0), float3(1.0, 0.9, 0.8), fract(h * 7.0));
    return tint * core * tw * (0.4 + depth * 0.8);
}

} // namespace neb

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 nebulaField(float2 pos, half4 color,
                  float time, float2 size,
                  float night, float audio, float2 gyro) {
    using namespace neb;

    float2 uv = pos / size;
    float aspect = size.x / size.y;
    float2 auv = float2(uv.x * aspect, uv.y);     // aspect-corrected for round shapes
    float p = clamp(night, 0.0, 1.0);
    float a = clamp(audio, 0.0, 1.0);
    float dim = (1.0 - 0.45 * p);
    float t = time * DRIFT * (1.0 - 0.4 * p);

    float3 col = float3(0.004, 0.005, 0.012);     // deep space black, faint blue lift

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
    col += starTier(auv, time, 0.0, gyro, 0.985);
    col += starTier(auv, time, 0.5, gyro, 0.990);
    col += starTier(auv, time, 1.0, gyro, 0.994);

    // --- a rare comet, sweeping diagonally every COMET_SEC ---
    float idx = floor(time / COMET_SEC);
    float ph  = fract(time / COMET_SEC);
    float win = smoothstep(0.0, 0.02, ph) * smoothstep(COMET_WIN, COMET_WIN - 0.05, ph);
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
        col += float3(0.85, 0.92, 1.0) * (tail * 0.6 + core) * win * dim;
    }

    // Filmic roll-off + hash dither (kills OLED banding).
    col = col / (col + 0.9);
    col += (hash21(pos + time) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
