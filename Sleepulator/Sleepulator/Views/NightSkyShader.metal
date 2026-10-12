#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Night sky: the sky from a dark field. A dome of stars turning slowly about a
// pole near the top of the screen, the Milky Way arching through it with a dark
// rift, thin cloud drifting across in front, a warm airglow at the horizon, and
// a far ridge and a near treeline in silhouette.
// ----------------------------------------------------------------------------
// Depth without a 3D engine:
//   - aerial perspective: the far ridge hazier than the treeline; stars low in
//     the sky dimmed, warmed and shimmering through the thicker air;
//   - occlusion: cloud passes in front of the stars and the Milky Way;
//   - motion parallax: the cloud drifts faster than the sky turns;
//   - gyro parallax by layer while the phone is held (sky, ridge, trees).
// Life without blinking: the turn and the drift are continuous and slow; the
// only fast term is a faint scintillation near the horizon.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation. The same public-domain building blocks as
// DeepSpaceShader.metal (hash, value noise, FBM). No code copied from elsewhere.
//
// Driven from SwiftUI `.colorEffect` through ShaderBackdrop. Swift owns phase
// (night-slowed integrated seconds: the turn and the drift), time (monotonic:
// scintillation and dither), size (points), night, gyro and scale (pixels per
// point). Everything else is a constant below (edit + rebuild).
// ============================================================================

namespace sky {

// ---- tunables --------------------------------------------------------------------
constant float TURN_SEC    = 1800.0;  // one turn of the sky at bedtime (night slows it, via phase)
constant float CLOUD_SPEED = 3.5;     // cloud drift at bedtime, points per second
constant float HORIZON     = 0.80;    // the horizon, as a fraction of the height
constant float2 POLE       = float2(0.58, 0.11);  // the pole the sky turns about (fractions)
constant float MW_ANGLE    = 0.42;    // the Milky Way's direction in the sky's frame (radians)
constant float MW_OFFSET   = 46.0;    // how far it passes from the pole (points)
constant float MW_WIDTH    = 64.0;    // its half-width (points)

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
// Integer-bit cell hash (see DeepSpaceShader.metal: `hash21` repeats on integer cell ids, which
// tiled the star fields). `salt` picks an independent stream per use.
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
inline float fbm(float2 p, int octaves) {
    float v = 0.0, amp = 0.5, norm = 0.0;
    for (int i = 0; i < octaves; i++) {
        v += amp * vnoise(p);
        norm += amp;
        p = p * 2.03 + float2(11.3, 7.7);
        amp *= 0.5;
    }
    return v / norm;
}

// Pale, warm and amber whites: Sleep's low-blue palette. Never bluer than neutral.
inline float3 starTint(float h) {
    if (h < 0.58) return float3(1.0, 0.96, 0.90);
    if (h < 0.90) return float3(1.0, 0.86, 0.69);
    return float3(1.0, 0.76, 0.54);
}

// One tier of stars fixed in the turning sky. `q` is the point in the sky's own frame, in points.
// A cell holds at most one star, jittered within it but kept clear of its edges so the glow is
// never clipped. Brightness follows a power law (most faint, a few bright).
inline float3 starTier(float2 q, float cell, float presence, float2 bright, float2 radius,
                       float halo, uint salt, float scint, float time, float minSigma) {
    float2 id = floor(q / cell);
    float h = hashCell(id, salt);
    if (h > presence) return float3(0.0);
    float m  = pow(hashCell(id, salt + 101u), 2.4);
    float jx = hashCell(id, salt + 202u);
    float jy = hashCell(id, salt + 303u);
    float r = mix(radius.x, radius.y, m);
    float reach = (halo > 0.0 ? r * 9.0 : r * 4.0) / cell;
    float2 centre = (id + 0.5 + (float2(jx, jy) - 0.5) * 2.0 * max(0.5 - reach, 0.0)) * cell;
    float d = length(q - centre);
    float sigma = max(r, minSigma);
    float light = exp(-0.5 * d * d / (sigma * sigma));
    if (halo > 0.0) light += halo * exp(-d / (r * 2.6));
    // Scintillation: two incommensurate sines, so it reads as air, not a pulse.
    float tw = 1.0 + scint * (0.6 * sin(time * (2.1 + jx * 2.4) + jy * 61.0)
                            + 0.4 * sin(time * (3.7 + jy * 2.9) + jx * 43.0));
    return starTint(fract(h * 13.7 + jx)) * mix(bright.x, bright.y, m) * light * tw;
}

// The Milky Way in the sky's frame: a broad band passing near the pole, its centre wandering and
// its width breathing along its length, brighter in billowing star clouds and split by a dark rift
// a little off its centre. Returns (glow, resolved-star density).
inline float2 milkyWay(float2 q) {
    float2 n = float2(cos(MW_ANGLE), sin(MW_ANGLE));
    float2 tangent = float2(-n.y, n.x);
    float s = dot(q, tangent);
    float wander = (vnoise(float2(s / 260.0, 3.7)) - 0.5) * 70.0;
    float u = dot(q, n) - MW_OFFSET - wander;
    float width = MW_WIDTH * (0.72 + 0.56 * vnoise(float2(s / 190.0, 8.1)));
    float band = exp(-(u * u) / (width * width));
    // Star clouds: fine-grained, so they read as unresolved stars rather than vapour.
    float clouds = fbm(q / 19.0, 5);
    float glow = band * (0.40 + 0.80 * smoothstep(0.32, 0.80, clouds));
    float riftU = u - width * 0.20 - (vnoise(float2(s / 95.0, 1.3)) - 0.5) * 24.0;
    float riftW = width * (0.11 + 0.09 * vnoise(float2(s / 130.0, 5.5)));
    float rift = exp(-(riftU * riftU) / (riftW * riftW));
    float block = rift * (0.55 + 0.45 * fbm(q / 20.0 + 7.0, 3));
    glow *= 1.0 - 0.82 * block;
    glow *= 0.55 + 0.8 * smoothstep(0.25, 0.85, vnoise(float2(s / 430.0, 2.2)));
    return float2(glow, band * (1.0 - 0.75 * block));
}

// Thin cloud in screen space, drifting with the wind: stretched wide like high stratus, its
// coverage coming and going slowly so the sky sometimes clears.
inline float cloudCover(float2 pts, float drift, float slow) {
    float2 c = float2((pts.x + drift) / 170.0, pts.y / 46.0);
    float2 w = float2(fbm(c * 0.6 + float2(0.0, slow), 3), fbm(c * 0.6 + float2(5.2, slow * 1.3), 3));
    float d = fbm(c + (w - 0.5) * 1.3, 5);
    float cover = 0.60 + 0.07 * (2.0 * vnoise(float2(slow * 0.5, 9.9)) - 1.0);
    return smoothstep(cover, cover + 0.17, d);
}

// A conifer treeline: one tree per cell, in groves and gaps; a tree's profile is a narrow triangle,
// so neighbours are checked too (a wide tree spills over its cell). Returns the line's height above
// `base` at `x`, in points.
inline float treeline(float x) {
    const float w = 11.0;
    float id = floor(x / w);
    float top = 0.0;
    for (int k = -1; k <= 1; k++) {
        float c = id + float(k);
        float grove = smoothstep(0.30, 0.62, vnoise(float2(c * w / 130.0, 6.6)));
        if (hashCell(float2(c, 3.0), 77u) > 0.18 + 0.78 * grove) continue;
        float height = 9.0 + 25.0 * hashCell(float2(c, 3.0), 78u) * (0.5 + 0.5 * grove);
        float cx = (c + 0.5 + (hashCell(float2(c, 3.0), 79u) - 0.5) * 0.5) * w;
        top = max(top, height - abs(x - cx) * 3.2);
    }
    return max(top, 0.0);
}

} // namespace sky

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 nightSkyField(float2 pos, half4 color,
                    float phase, float time, float2 size,
                    float night, float2 gyro, float scale) {
    using namespace sky;

    float2 uv = pos / size;
    float p = clamp(night, 0.0, 1.0);
    float pxPt = max(scale, 1.0);
    float minSigma = 1.0 / pxPt;                 // a star is never narrower than a pixel
    float px = 1.0 / pxPt;                       // one pixel, in points (silhouette edges)
    float t = fmod(time, 600.0);                 // keep the cyclic terms precise all night

    // --- the sky itself: warm near-black, lifting a little toward the horizon ---
    float low = smoothstep(0.15, HORIZON, uv.y);
    float3 col = mix(float3(0.012, 0.009, 0.007), float3(0.036, 0.025, 0.017), low) * (1.0 - 0.6 * p);

    // Airglow: a faint warm band along the horizon, uneven along its length.
    float above = max(HORIZON - uv.y, 0.0);
    float glow = exp(-above / 0.075) * (0.7 + 0.6 * vnoise(float2(pos.x / 150.0 + phase * 0.0004, 4.4)));
    col += float3(0.100, 0.053, 0.028) * glow * (1.0 - 0.75 * p);

    // --- the turning sky: everything fixed to it lives in its own frame `q`, in points ---
    float theta = fmod(phase, TURN_SEC) / TURN_SEC * 6.28318530718;
    float2 rel = pos - POLE * size + gyro * 5.0;
    float cs = cos(theta), sn = sin(theta);
    float2 q = float2(rel.x * cs - rel.y * sn, rel.x * sn + rel.y * cs);

    // The air near the horizon: stars dim, warm and shimmer there.
    float air = smoothstep(0.30, HORIZON, uv.y);
    float extinction = 1.0 - 0.62 * air;
    float3 airTint = mix(float3(1.0), float3(1.0, 0.82, 0.62), air);
    float scint = (0.06 + 0.24 * air) * (1.0 - 0.7 * p);

    float2 mw = milkyWay(q);
    float3 skyLight = float3(0.075, 0.060, 0.045) * mw.x;
    float3 starLight = float3(0.0);
    starLight += starTier(q, 7.0,  0.13 + 0.40 * mw.y, float2(0.035, 0.11), float2(0.30, 0.40), 0.0, 11u, 0.0,   t, minSigma);
    starLight += starTier(q, 4.0,  0.55 * mw.y,        float2(0.028, 0.09), float2(0.28, 0.34), 0.0, 23u, 0.0,   t, minSigma);
    starLight += starTier(q, 17.0, 0.17,               float2(0.12, 0.40),  float2(0.40, 0.62), 0.0, 37u, scint, t, minSigma);
    starLight += starTier(q, 48.0, 0.16,               float2(0.40, 0.95),  float2(0.62, 0.95), 0.14, 53u, scint, t, minSigma);
    skyLight += starLight * extinction * airTint;
    skyLight *= 1.0 - 0.55 * p;

    // --- cloud, in front of the sky: it hides what's behind and is lit faintly from below ---
    float drift = fmod(phase * CLOUD_SPEED, 40000.0);
    float cloud = cloudCover(pos + gyro * 9.0, drift, fmod(phase * 0.003, 400.0)) * smoothstep(0.02, 0.30, uv.y);
    col += skyLight * (1.0 - 0.88 * cloud);
    float underLight = 0.016 + 0.050 * smoothstep(0.25, HORIZON, uv.y);
    col += float3(0.85, 0.62, 0.44) * cloud * underLight * (1.0 - 0.6 * p);

    // --- the land: a hazy far ridge, then a black treeline in front ---
    float hy = HORIZON * size.y;
    float farX = pos.x + gyro.x * 10.0;
    float farTop = hy - (14.0 + 30.0 * fbm(float2(farX / 150.0, 2.0), 4)) + gyro.y * 3.0;
    float farMask = smoothstep(farTop - px, farTop + px, pos.y);
    float mist = exp(-max(pos.y - farTop, 0.0) / 10.0);           // haze along the ridge's crest
    float3 farColor = (float3(0.022, 0.015, 0.011) + float3(0.028, 0.016, 0.009) * mist) * (1.0 - 0.6 * p);
    col = mix(col, farColor, farMask);

    float nearX = pos.x + gyro.x * 24.0;
    float nearBase = hy + 18.0 - 10.0 * fbm(float2(nearX / 90.0, 11.0), 3) + gyro.y * 7.0;
    float nearTop = nearBase - treeline(nearX);
    float nearMask = smoothstep(nearTop - px, nearTop + px, pos.y);
    col = mix(col, float3(0.004, 0.003, 0.002), nearMask);

    // Soft roll-off for the bright stars, then a hash dither against OLED banding (time wrapped:
    // hours in, the hash's fract() would otherwise lose precision and freeze the dither).
    col = 1.0 - exp(-col * 1.08);
    col += (hash21(pos + fmod(time, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
