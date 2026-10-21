#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Fireflies: a meadow at the edge of a wood on a summer night. Warm points
// glow and fade among the trees and over the grass; mist lies along the
// wood's foot, and tall grass stands black against it in front.
// ----------------------------------------------------------------------------
// The night is in the structure, not just the brightness. At bedtime each
// firefly keeps its own time; through the night they fall into step (real
// fireflies do), and they go out one by one, the nearest first, until a few
// are left pulsing together. How far along both are is Swift's call
// (`FireflyNight`, unit-tested); this file draws it.
//
// Calm, not a strobe: a flash is a slow swell and fade (half a second up, a
// little over a second down, one every ~5 s at bedtime, slower as the night
// slows the clock), and nothing else blinks. Life without blinking:
// the mist drifts, the grass sways, each firefly wanders and lifts as it glows.
//
// Depth without a 3D engine:
//   - aerial perspective: a far wood paler than the near one, mist pooled at
//     the near wood's foot, the far fireflies smaller, dimmer and hazed;
//   - occlusion: the grass in front of the meadow's fireflies, the nearest
//     ones out of focus in front of the grass;
//   - gyro parallax by layer while the phone is held.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation, from the same public-domain building blocks as
// NightSkyShader.metal (hash, value noise, FBM). No code copied from elsewhere.
//
// Driven from SwiftUI `.colorEffect` through ShaderBackdrop. Swift owns phase
// (night-slowed integrated seconds: the flashes, the wander, the drift, the
// sway), time (monotonic: the dither), size (points), night, sync and left
// (`FireflyNight`), gyro and scale (pixels per point). Everything else is a
// constant below (edit + rebuild).
// ============================================================================

namespace ffly {

// ---- tunables --------------------------------------------------------------------
constant float PERIOD     = 5.0;    // seconds between one firefly's flashes at bedtime
constant float RISE       = 0.10;   // share of its cycle a glow takes to swell...
constant float FADE       = 0.36;   // ...and by when it has faded again
constant float WAVE       = 0.14;   // in step, a flash rolls across the screen over this much of a cycle
constant float JITTER     = 0.25;   // out of step, how far each one's timing wanders (cycles)
constant float FAR_BASE   = 0.40;   // the far wood's foot behind the near one (fraction of the height)
constant float NEAR_BASE  = 0.47;   // the line the near wood's crowns rise from
constant float FOOT       = 0.63;   // where the near wood meets the meadow
constant float MIST_SPEED = 4.0;    // the mist's drift at bedtime, points per second
constant float LAST       = 0.10;   // a layer that keeps survivors: where the others' ranks start
                                    // (`FireflyNight.meadowAtEnd` sits between 0.06 and this)

inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
// Integer-bit cell hash (see NightSkyShader.metal). `salt` picks an independent stream per use.
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

// A wood's skyline: one tree per cell, mostly rounded crowns with a conifer's spire standing
// above them here and there (`spires`: the share of spires). Crowns overlap, so neighbours are
// checked too; the edge is ragged with leaves. Returns its height above the wood's base line at
// `x`, in points.
inline float canopy(float x, float cell, float2 heights, float spires, uint salt) {
    float id = floor(x / cell);
    float top = 0.0;
    for (int k = -3; k <= 3; k++) {
        float c = id + float(k);
        float2 key = float2(c, 9.0);
        float height = mix(heights.x, heights.y, hashCell(key, salt));
        float cx = (c + 0.5 + (hashCell(key, salt + 2u) - 0.5) * 0.6) * cell;
        float dx = x - cx;
        if (hashCell(key, salt + 3u) < spires) {
            top = max(top, height * 1.3 - abs(dx) * 2.6);
        } else {
            // A round top flaring out below into the crown's lower branches, so a crown never stands
            // as a column. Its reach, r + (height - r) / 1.8, stays within the three cells checked
            // either side for both woods drawn below (a spire's, half its height, too).
            float r = cell * mix(0.6, 1.2, hashCell(key, salt + 1u));
            float side = abs(dx);
            top = max(top, side < r ? height - r + sqrt(r * r - dx * dx) : height - r - (side - r) * 1.8);
        }
    }
    float leaves = 5.0 * (fbm(float2(x / 6.0, float(salt)), 3) - 0.5)
                 + 2.0 * (vnoise(float2(x / 1.8, float(salt) + 3.0)) - 0.5);
    return max(top + leaves, 0.0);
}

// Grass along the bottom edge, one blade per cell: leaning, tapering to a point, bending more
// toward its tip, and swaying a little in a slow breeze that travels along the row. Returns
// coverage (0…1). `reach` is how many cells either side a blade can lean into: it must cover the
// widest bend, `lean / 2 + 0.03` of the tallest blade, in cells.
inline float grass(float2 pos, float bottom, float cell, float presence, float2 heights, float lean,
                   float width, int reach, uint salt, float phase, float px) {
    float h = bottom - pos.y;
    if (h < 0.0 || h > heights.y) return 0.0;
    float id = floor(pos.x / cell);
    float cover = 0.0;
    for (int k = -reach; k <= reach; k++) {
        float c = id + float(k);
        float2 key = float2(c, 5.0);
        if (hashCell(key, salt) > presence) continue;
        float tall = mix(heights.x, heights.y, pow(hashCell(key, salt + 1u), 2.0));
        if (h > tall) continue;
        float t = h / tall;
        float bx = (c + hashCell(key, salt + 2u)) * cell;
        float sway = 3.0 * (tall / 100.0) * sin(phase * 0.34 + bx * 0.012 + hashCell(key, salt + 3u));
        float bend = (hashCell(key, salt + 4u) - 0.5) * lean * tall + sway;
        float x = bx + bend * t * t;
        float halfW = width * pow(1.0 - t, 0.8) + 0.12;
        cover = max(cover, smoothstep(halfW + px, halfW - px, abs(pos.x - x)));
    }
    return cover;
}

// Pale warm stars, sparse and faint, fixed (no twinkle: nothing blinks but the fireflies).
inline float stars(float2 q, float cell, float presence, float minSigma) {
    float2 id = floor(q / cell);
    if (hashCell(id, 61u) > presence) return 0.0;
    float m = pow(hashCell(id, 62u), 2.2);
    float2 centre = (id + 0.2 + 0.6 * float2(hashCell(id, 63u), hashCell(id, 64u))) * cell;
    float d = length(q - centre);
    float sigma = max(0.35, minSigma);
    return mix(0.08, 0.30, m) * exp(-0.5 * d * d / (sigma * sigma));
}

// One layer of fireflies, at most one per cell, each wandering about its cell (the 3×3 cells
// around the pixel are checked; a firefly's light never reaches past its neighbours).
//   band:     the layer's span down the screen (fractions of the height), thinning at its edges
//   core:     the glow's core radius (points); halo: its soft falloff (points)
//   bokeh:    > 0 draws an out-of-focus disc of this radius instead (the nearest layer)
//   left:     the share of the layer still flashing (`FireflyNight.remaining`)
//   keep:     > 0 keeps survivors: one per patch of 3×2 cells, patch rows staggered like brickwork,
//             always present and the last to go out, so the few left at the end of the night are
//             spread over the screen on any phone instead of left to chance (1-3 on an SE, with
//             independent ranks). Their rank is 0; everyone else's starts at LAST.
//   sync:     how far they've fallen into step (`FireflyNight.sync`)
// Each firefly's cycle is its own phase plus a wandering jitter; in step, everyone's offset
// becomes one wave rolling across the screen, so a flash ripples left to right.
inline float3 fireflies(float2 pos, float2 size, float cell, float2 band, float presence,
                        float core, float halo, float bokeh, float peak, float wander, float lift,
                        uint salt, float left, float keep, float sync, float phase, float px) {
    float3 sum = float3(0.0);
    if (left <= 0.0) return sum;
    float2 id0 = floor(pos / cell);
    const float3 coreTint = float3(1.00, 0.96, 0.66);
    const float3 haloTint = float3(0.70, 0.85, 0.26);   // the yellow-green of firefly light
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 id = id0 + float2(float(i), float(j));
            float2 centre = (id + 0.5) * cell;
            float y = centre.y / size.y;
            float weight = smoothstep(band.x, band.x + 0.05, y) * (1.0 - smoothstep(band.y - 0.05, band.y, y));
            bool survivor = false;
            if (keep > 0.0) {
                float row = floor(id.y / 2.0);
                float sx = id.x + (row - 3.0 * floor(row / 3.0));
                float patch = floor(sx / 3.0);
                float pick = floor(hashCell(float2(patch, row), salt + 7u) * 6.0);
                survivor = weight > 0.5 && sx - patch * 3.0 == pick - 3.0 * floor(pick / 3.0)
                                        && id.y - row * 2.0 == floor(pick / 3.0);
            }
            if (!survivor && hashCell(id, salt) >= presence * weight) continue;
            // Going out: each has a rank; it fades over a short stretch of the night as `left`
            // falls past it, so they leave one at a time and none pops off.
            float rank = survivor ? 0.0
                       : keep > 0.0 ? LAST + (0.94 - LAST) * hashCell(id, salt + 1u)
                                    : 0.94 * hashCell(id, salt + 1u);
            float alive = smoothstep(rank, rank + 0.06, left);
            if (alive <= 0.0) continue;
            float h2 = hashCell(id, salt + 2u);
            float h3 = hashCell(id, salt + 3u);
            float h4 = hashCell(id, salt + 4u);
            float h5 = hashCell(id, salt + 5u);
            // When it flashes. The jitter wanders over a minute or so (bounded, so its own rhythm
            // drifts ±10% without ever racing), and both it and the spread shrink as sync rises.
            float own = hashCell(id, salt + 6u)
                      + JITTER * (0.6 * sin(phase * 0.105 + h2 * 40.0) + 0.4 * sin(phase * 0.065 + h3 * 40.0));
            float offset = mix(own, WAVE * centre.x / size.x, sync);
            float u = fract(phase / PERIOD - offset);
            float glow = smoothstep(0.0, RISE, u) * (1.0 - smoothstep(RISE, FADE, u));
            if (glow <= 0.0) continue;
            // Where it is: a slow wander about the cell, lifting as it glows (dark, it's unseen,
            // so the drop back between flashes never shows).
            float w = phase * (0.22 + 0.16 * h3);
            float2 drift = wander * float2(sin(w + h4 * 6.2832) + 0.4 * sin(1.73 * w + h5 * 6.2832),
                                           0.6 * sin(0.81 * w + h5 * 6.2832) + 0.3 * sin(2.11 * w + h2 * 6.2832));
            float2 at = centre + (float2(h4, h5) - 0.5) * cell * 0.5 + drift
                      - float2(0.0, lift * smoothstep(0.0, FADE, u));
            float d = length(pos - at);
            float bright = peak * mix(0.55, 1.0, h2) * glow * alive;
            // In the mist its glow spreads, as light does in fog (the mist's height profile only:
            // its texture would cost an FBM per firefly per pixel).
            float below = (at.y / size.y - FOOT) / 0.16;
            float fog = exp(-below * below);
            if (bokeh > 0.0) {
                // Out of focus: a soft disc, a touch brighter toward its rim, like a lens's bokeh.
                float disc = smoothstep(bokeh + 2.5, bokeh - 2.5, d) * (0.8 + 0.2 * smoothstep(0.0, bokeh, d));
                sum += mix(haloTint, coreTint, 0.35) * disc * bright;
            } else {
                float sigma = max(core, px);
                sum += coreTint * exp(-0.5 * d * d / (sigma * sigma)) * bright
                     + haloTint * exp(-d / (halo * (1.0 + 0.8 * fog))) * bright * 0.30;
            }
        }
    }
    return sum;
}

} // namespace ffly

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 fireflyField(float2 pos, half4 color,
                   float phase, float time, float2 size,
                   float night, float sync, float3 left, float2 gyro, float scale) {
    using namespace ffly;

    float2 uv = pos / size;
    float p = clamp(night, 0.0, 1.0);
    float s = clamp(sync, 0.0, 1.0);
    float px = 1.0 / max(scale, 1.0);            // one pixel, in points (silhouette edges)

    // Gyro parallax by depth: the nearer the layer, the further it shifts.
    float2 tiltBy = float2(gyro.x, gyro.y * 0.35);

    // --- the sky: warm near-black, lifting toward the treetops; a few faint fixed stars ---
    float low = smoothstep(0.0, FAR_BASE, uv.y);
    float3 col = mix(float3(0.006, 0.005, 0.005), float3(0.075, 0.058, 0.040), low * low);
    float2 skyPos = pos + tiltBy * 3.0;
    col += float3(1.0, 0.92, 0.80) * stars(skyPos, 23.0, 0.14, px) * (1.0 - 0.8 * low);
    col *= 1.0 - 0.5 * p;

    // --- the far wood: smaller crowns, dark against the sky, hazier toward its foot where mist
    // rises between the two woods (graded by height, not from each column's own top, which
    // streaked it) ---
    float farX = pos.x + tiltBy.x * 7.0;
    float farTop = FAR_BASE * size.y + tiltBy.y * 7.0 - canopy(farX, 13.0, float2(6.0, 26.0), 0.12, 11u);
    float farMask = smoothstep(farTop - px, farTop + px, pos.y);
    float farFoot = FAR_BASE * size.y + tiltBy.y * 7.0;
    float3 farWood = mix(float3(0.026, 0.020, 0.014), float3(0.064, 0.051, 0.037),
                         smoothstep(farFoot - 34.0, farFoot + 12.0, pos.y)) * (1.0 - 0.4 * p);
    col = mix(col, farWood, farMask);

    // --- the near wood: big rounded crowns, black down to the meadow ---
    float nearX = pos.x + tiltBy.x * 12.0;
    float nearTop = NEAR_BASE * size.y + tiltBy.y * 12.0 - canopy(nearX, 22.0, float2(16.0, 64.0), 0.18, 23u);
    float nearMask = smoothstep(nearTop - px, nearTop + px, pos.y);
    col = mix(col, float3(0.005, 0.004, 0.003), nearMask);

    // --- the meadow: from the wood's uneven foot toward you, darkening as it nears ---
    float footY = FOOT * size.y + tiltBy.y * 14.0 + 8.0 * (fbm(float2(nearX / 70.0, 3.3), 3) - 0.5);
    float meadow = smoothstep(footY - 2.0, footY + 2.0, pos.y);
    float nearness = smoothstep(footY, size.y, pos.y);
    float3 ground = mix(float3(0.030, 0.024, 0.016), float3(0.004, 0.003, 0.002), sqrt(nearness));
    col = mix(col, ground * (1.0 - 0.4 * p), meadow);

    // --- the far fireflies: among the trees and at the meadow's far edge ---
    float2 farPos = pos + tiltBy * 10.0;
    float3 fireflyLight = fireflies(farPos, size, 30.0, float2(0.42, 0.70), 0.42,
                                    0.8, 3.2, 0.0, 0.40, 5.0, 2.0, 101u, left.x, 0.0, s, phase, px);
    // Hazed: the far ones' light warms and softens through the air.
    col += mix(fireflyLight, float3(dot(fireflyLight, float3(0.4, 0.4, 0.2))) * float3(1.0, 0.85, 0.55), 0.3);

    // --- mist pooled along the wood's foot, thinning toward you; drifting with the air ---
    float2 mistPos = pos + tiltBy * 14.0;
    float above = (footY - mistPos.y) / size.y;           // > 0 up into the wood
    float shape = above > 0.0 ? exp(-above * above / (0.035 * 0.035))
                              : exp(-above * above / (0.16 * 0.16));
    float drift = fmod(phase * MIST_SPEED, 40000.0);
    float2 m = float2((mistPos.x + drift) / 230.0, mistPos.y / 34.0);
    float2 warp = float2(fbm(m * 0.7 + float2(0.0, phase * 0.004), 3), fbm(m * 0.7 + float2(5.2, 1.7), 3));
    float tex = fbm(m + (warp - 0.5) * 1.2, 4);
    float mist = shape * mix(0.35, 1.0, smoothstep(0.30, 0.78, tex));
    col = col * (1.0 - 0.35 * mist) + float3(0.080, 0.064, 0.046) * mist * (1.0 - 0.45 * p);

    // --- the meadow's fireflies, behind the grass ---
    float2 midPos = pos + tiltBy * 18.0;
    col += fireflies(midPos, size, 62.0, float2(0.47, 0.93), 0.36,
                     1.3, 7.0, 0.0, 0.78, 14.0, 5.0, 211u, left.y, 1.0, s, phase, px) * (1.0 - 0.2 * p);

    // --- grass in front: a dense low row and a few tall stems that rise into the mist ---
    float2 grassPos = pos + tiltBy * 30.0;
    float bottom = size.y + 6.0;
    float blades = max(grass(grassPos, bottom, 5.0, 0.95, float2(0.06, 0.22) * size.y, 0.25, 1.6, 7, 301u, phase, px),
                       grass(grassPos, bottom, 15.0, 0.35, float2(0.12, 0.40) * size.y, 0.22, 2.2, 4, 401u, phase, px));
    col = mix(col, float3(0.002, 0.0015, 0.001), blades);

    // --- the nearest fireflies: out of focus, in front of everything ---
    float2 nearPos = pos + tiltBy * 36.0;
    col += fireflies(nearPos, size, 130.0, float2(0.50, 1.04), 0.30,
                     0.0, 1.0, 13.0, 0.12, 30.0, 9.0, 307u, left.z, 0.0, s, phase, px) * (1.0 - 0.2 * p);

    // Soft roll-off for the brightest glow, then a hash dither against OLED banding (time wrapped:
    // hours in, the hash's fract() would otherwise lose precision and freeze the dither).
    col = 1.0 - exp(-col * 1.08);
    col += (hash21(pos + fmod(time, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
