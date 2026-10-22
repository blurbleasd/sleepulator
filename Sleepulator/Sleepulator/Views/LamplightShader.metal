#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Lamplight: snow falling through a street lamp's light on a winter night,
// seen from an upstairs window. Outside the light the snow is unseen; inside
// the lamp's cone every flake is lit, and the cone itself glows faintly in the
// snow-filled air. Further lamps recede down the street into the snowfall.
// ----------------------------------------------------------------------------
// The night is in the structure, not just the brightness. At bedtime the snow
// falls steadily and a line of footprints crosses the lamp's pool of light;
// through the night the snowfall thins and slows, the footprints fill in, and
// snow builds on the lamp, until a few big flakes drift through the light over
// unbroken snow. How far along each is is Swift's call (`SnowNight`,
// unit-tested); this file draws it.
//
// Calm, not busy: the snow falls at the pace real snow falls (a little over
// half a metre a second, slower as the night slows the clock), drifts with a
// slow breeze, and nothing blinks.
//
// Depth without a 3D engine: the scene is a small world in metres, seen
// through a pinhole camera looking a little down. The lamps' cones, their
// light on the snow and the flakes they light are computed in that world, so
//   - the flakes nearer the window are bigger and softer, and fall faster
//     across the screen than the far ones;
//   - each cone's glow is the light it scatters along the view ray (in closed
//     form), so a cone is brighter where the eye looks through more of it;
//   - the far lamps fade into the falling snow (aerial perspective);
//   - holding the phone moves the window, so everything parallaxes by its
//     real depth.
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation, from the same public-domain building blocks as
// NightSkyShader.metal (hash, value noise, FBM) and textbook geometry (a ray
// through a cone, the inverse-square in-scatter integral). No code copied from
// elsewhere.
//
// Driven from SwiftUI `.colorEffect` through ShaderBackdrop. Swift owns phase
// (night-slowed integrated seconds: the fall, the breeze, the flutter), time
// (monotonic: the dither), size (points), night, snow and settled
// (`SnowNight`, on the eased night), gyro and scale (pixels per point).
// Everything else is a constant below (edit + rebuild).
// ============================================================================

namespace lamp {

// ---- tunables --------------------------------------------------------------------
constant float CAM_H    = 3.0;    // the window's height above the street (m)
constant float PITCH    = 0.20;   // how far it looks down (radians, ~11°)
constant float TAN_HALF = 0.50;   // tan of half the horizontal field of view (~53°)
constant float LAMP_H   = 4.4;    // a lamp's light above the street (m)
constant float CONE     = 0.45;   // tan of a lamp's cone half-angle (~24°)
constant float ARM      = 0.75;   // a lamp hangs this far left of its post (m)
constant float FALL     = 0.55;   // the snow's fall at bedtime (m/s)
constant float VIS      = 25.0;   // how far you see through the falling snow (m, to 1/e)
constant float GOING    = 0.06;   // the stretch of `snow` a flake takes to stop falling (its fade)
constant float3 LIGHT   = float3(1.00, 0.68, 0.38);    // the lamps' warm light
constant float3 GLOW    = float3(0.020, 0.016, 0.014); // the town's glow on the clouds, and the snow-fog

// The lamps, down the street: x (m, right), z (m, away). The first is the one outside the window.
constant float2 LAMPS[4] = { float2(0.5, 5.2), float2(-2.6, 17.0), float2(-7.5, 28.0), float2(-14.0, 42.0) };

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

// The window: where it is, which way is up and ahead on the screen, the focal length (points) and
// the screen's centre.
struct Cam {
    float3 o;
    float3 up;
    float3 fwd;
    float f;
    float2 c;
};

// The world point on the plane `depth` metres ahead of the window, under a pixel.
inline float3 onPlane(Cam cam, float2 plane, float depth) {
    return cam.o + float3(plane.x, 0.0, 0.0) + cam.up * plane.y + cam.fwd * depth;
}
inline float2 project(Cam cam, float3 w, thread float &depth) {
    float3 v = w - cam.o;
    depth = dot(v, cam.fwd);
    return cam.c + cam.f * float2(v.x, -dot(v, cam.up)) / depth;
}

// A lamp's light reaching `w` (the lamp's light at `at`): inside its cone, softening toward the
// cone's edge, falling off with the square of the distance.
inline float spot(float3 w, float3 at) {
    float3 v = w - at;
    float below = -v.y;
    if (below <= 0.0) return 0.0;
    float r = length(v.xz) / (below * CONE);   // 0 on the axis, 1 at the cone's edge
    float edge = 1.0 - smoothstep(0.62, 1.04, r);
    return edge * (1.0 - 0.35 * r * r) / (dot(v, v) + 0.05);
}

// The light a lamp's cone (tan of its half-angle `k`) scatters toward the eye along a view ray
// from `o` in unit direction `d` that ends at `tEnd`: the inverse-square in-scatter over the ray's
// chord through the cone, integrated in closed form.
inline float coneGlow(float3 o, float3 d, float3 at, float k, float tEnd) {
    float c2 = 1.0 / (1.0 + k * k);              // cos² of the half-angle
    float3 m = o - at;
    // Inside the cone (axis straight down) where (w·down)² ≥ cos² |w|², w = m + t d.
    float A = d.y * d.y - c2;
    float B = 2.0 * (m.y * d.y - c2 * dot(m, d));
    float C = m.y * m.y - c2 * dot(m, m);
    float disc = B * B - 4.0 * A * C;
    if (A >= 0.0 || disc <= 0.0) return 0.0;     // A < 0 for every ray on screen (none that steep)
    float sq = sqrt(disc);
    float t1 = (-B + sq) / (2.0 * A), t2 = (-B - sq) / (2.0 * A);
    if (m.y + 0.5 * (t1 + t2) * d.y >= 0.0) return 0.0;   // through the cone's mirror, above the lamp
    t1 = max(t1, 0.0);
    t2 = min(t2, tEnd);
    if (t2 <= t1) return 0.0;
    float t0 = -dot(m, d);
    float h = sqrt(max(dot(m, m) - t0 * t0, 0.0) + 0.02);
    return (atan((t2 - t0) / h) - atan((t1 - t0) / h)) / h;
}

// Footprints across the first lamp's pool: someone walked past before bedtime. Each is a boot-sized
// hollow with a flat floor and steep walls; as snow fills it (`fill` 0 → 1) it grows shallower and its
// walls soften, until it's gone. Returns how deep the pixel is in a print (0…1 of a fresh one's
// depth) and the snow's slope there (x, z).
inline float3 footprints(float2 g, float2 lampAt, float fill) {
    const float2 start = lampAt + float2(-2.9, 1.7);
    const float2 dir = normalize(float2(5.4, -3.9));
    const float2 side = float2(-dir.y, dir.x);
    const float stride = 0.72, depth = 0.05;
    float2 rel = g - start;
    float along = dot(rel, dir);
    float3 out = float3(0.0);
    if (along < -0.5 || along > 7.2) return out;
    float k0 = floor(along / stride);
    float sink = pow(1.0 - fill, 1.3);                   // its depth left
    float wall = mix(0.22, 0.85, fill);                  // its walls' width, a share of its radius
    for (int i = 0; i <= 1; i++) {
        float k = k0 + float(i);
        float foot = fmod(k, 2.0) < 0.5 ? 1.0 : -1.0;
        float wander = 0.18 * sin(k * 0.55);
        float toe = 0.14 * foot;                         // toes turned out a little
        float2 centre = start + dir * (k * stride + 0.04 * foot) + side * (0.13 * foot + wander);
        float2 fdir = dir * cos(toe) + side * sin(toe), fside = float2(-fdir.y, fdir.x);
        float2 l = g - centre;
        float a = dot(l, fdir) / 0.15, c = dot(l, fside) / (0.058 * (1.0 + 0.15 * clamp(a, -1.0, 1.0)));
        float r = length(float2(a, c));
        if (r > 1.6) continue;
        float x = clamp((r - (1.0 - wall)) / wall, 0.0, 1.0);
        float hollow = 1.0 - x * x * (3.0 - 2.0 * x);    // 1 on its floor, 0 outside
        float lip = 0.18 * exp(-(r - 1.12) * (r - 1.12) / 0.05);
        // Its slope: d/dr, then along and across.
        float dr = depth * sink * (6.0 * x * (1.0 - x) / wall - lip * 2.0 * (r - 1.12) / 0.05);
        float2 dAC = r > 1e-4 ? dr * float2(a / 0.15, c / 0.058) / r : float2(0.0);
        out += float3(hollow * sink, fdir * dAC.x + fside * dAC.y);
    }
    return out;
}

// One layer of snowflakes, on the plane `depth` metres ahead of the window, lit only inside the lamp
// at `at`. At most one flake per cell (`cell` metres), each fluttering about its place; the 2×2 cells
// whose centres bracket the pixel are checked (a flake strays at most 0.42 of a cell from its
// centre and its glow under half a cell). Each flake has its own depth in the layer's slab
// (`slab` metres) for its light, so the cone is filled through, not lit on a few sheets.
//   presence: the share of cells with a flake; rad: the flake's glow (points); gain: its brightness
//   snow:     the share still falling (`SnowNight.snowfall`): each flake stops (fades) at its rank
inline float3 flakes(Cam cam, float2 plane, float depth, float slab, float cell, float presence,
                     float rad, float gain, float3 at, uint salt, float2 travel, float snow,
                     float phase, float px) {
    float3 sum = float3(0.0);
    // Skip a layer whose plane can't hold a lit flake here: well outside the cone, or above the lamp.
    float3 w = onPlane(cam, plane, depth);
    float reach = 0.5 * cell + 0.5 * slab;
    if (w.y > at.y + reach || w.y < -reach) return sum;
    float dz = max(abs(w.z - at.z) - 0.5 * slab, 0.0);
    if (length(float2(w.x - at.x, dz)) - reach > (at.y - w.y + reach) * CONE) return sum;
    float2 g = (plane + travel) / cell;
    float2 id0 = floor(g - 0.5);
    float scale = cam.f / depth;                         // points per metre on this plane
    for (int j = 0; j <= 1; j++) {
        for (int i = 0; i <= 1; i++) {
            float2 id = id0 + float2(float(i), float(j));
            if (hashCell(id, salt) >= presence) continue;
            float rank = (1.0 - GOING) * hashCell(id, salt + 1u);
            float alive = smoothstep(rank, rank + GOING, snow);
            if (alive <= 0.0) continue;
            float h2 = hashCell(id, salt + 2u);
            float h3 = hashCell(id, salt + 3u);
            float h4 = hashCell(id, salt + 4u);
            float h5 = hashCell(id, salt + 5u);
            // Flutter: a slow sideways swing and a little bob, each flake at its own pace.
            float wf = phase * (1.6 + 1.4 * h3) + h4 * 6.2832;
            float2 off = (float2(h2, h5) - 0.5) * 0.56 + float2(0.12 * sin(wf), 0.04 * sin(1.7 * wf + h2 * 6.0));
            float2 centre = (id + 0.5 + off) * cell - travel;
            float3 fw = onPlane(cam, centre, depth + (h4 - 0.5) * slab);
            if (fw.y < 0.0) continue;                    // landed: under the snow's surface
            float light = spot(fw, at);
            if (light <= 0.0) continue;
            light /= 1.0 + 0.4 * light;                  // the flakes passing right by the bowl don't flare
            float2 d = (plane - centre) * scale;
            d.y *= 0.72;                                 // a touch of motion blur down its fall
            float sigma = max(rad * mix(0.75, 1.25, h3), px);
            sum += LIGHT * (exp(-0.5 * dot(d, d) / (sigma * sigma)) * light * gain * alive * mix(0.6, 1.0, h2));
        }
    }
    return sum;
}

} // namespace lamp

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 lampSnowField(float2 pos, half4 color,
                    float phase, float time, float2 size,
                    float night, float snow, float settled, float2 gyro, float scale) {
    using namespace lamp;

    float p = clamp(night, 0.0, 1.0);
    float fill = clamp(settled, 0.0, 1.0);
    float px = 1.0 / max(scale, 1.0);

    // The window, moved a little by the phone's tilt (parallax by real depth), looking a little down.
    Cam cam;
    cam.o = float3(gyro.x * 0.30, CAM_H - gyro.y * 0.15, 0.0);
    cam.up = float3(0.0, cos(PITCH), sin(PITCH));
    cam.fwd = float3(0.0, -sin(PITCH), cos(PITCH));
    cam.f = 0.5 * size.x / TAN_HALF;
    cam.c = 0.5 * size;

    float2 q = (pos - cam.c) / cam.f;
    float2 plane1 = float2(q.x, -q.y);                   // the pixel on the plane 1 m ahead
    float3 ray = normalize(float3(q.x, 0.0, 0.0) + cam.up * (-q.y) + cam.fwd);
    float tGround = ray.y < 0.0 ? -cam.o.y / ray.y : 1e4;
    float fogAt = exp(-min(tGround, 1e3) / VIS);         // how much of the ground shows through the snow

    // --- the sky and the snow-fog: the town's glow on the clouds, lifting toward the horizon ---
    float horizon = cam.c.y - cam.f * tan(PITCH);
    float3 col = GLOW * mix(0.30, 1.0, smoothstep(horizon - 0.45 * size.y, horizon, pos.y));
    // The snow on the ground is a little lighter than the sky: it holds the town's glow.

    // --- the snow on the street: faintly lit by the glow everywhere, by the lamps in their pools ---
    if (ray.y < 0.0) {
        float3 g = cam.o + ray * tGround;
        float3 n = float3(0.0, 1.0, 0.0);
        float ao = 1.0;
        float3 at0 = float3(LAMPS[0].x, LAMP_H, LAMPS[0].y);
        // The footprints, filling in through the night (only near the first pool).
        if (fill < 1.0 && abs(g.z - at0.z) < 4.0 && abs(g.x - at0.x) < 4.5) {
            float3 fp = footprints(g.xz, LAMPS[0], fill);
            n = normalize(float3(-fp.y, 1.0, -fp.z));
            ao = 1.0 - 0.3 * fp.x;
        }
        float lit = 0.0;
        for (int i = 0; i < 4; i++) {
            float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
            float s = spot(g, at);
            if (s <= 0.0) continue;
            // The post's shadow: sharp at its foot, blurring away from it.
            float2 post = float2(at.x + ARM, at.z);
            float2 u = g.xz - at.xz;
            float t = dot(post - at.xz, u) / max(dot(u, u), 1e-4);
            float shade = 1.0;
            if (t > 0.0 && t < 1.0) {
                float off = length(at.xz + t * u - post);
                float pen = min(0.04 + 0.17 * length(g.xz - post) / ARM, 0.4);
                shade = smoothstep(0.045 - 0.5 * pen, 0.045 + 0.5 * pen, off);
            }
            float3 l = normalize(at - g);
            lit += s * max(dot(n, l), 0.0) * shade;
        }
        float3 street = 0.030 * float3(1.0, 0.95, 0.92) * ao + LIGHT * 3.0 * lit * ao;
        col = mix(col, street, fogAt);
    }

    // --- the cones' glow in the falling snow ---
    float3 haze = float3(0.0);
    for (int i = 0; i < 4; i++) {
        float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
        float fog = exp(-length(at - cam.o) / VIS);
        haze += LIGHT * (0.6 * coneGlow(cam.o, ray, at, CONE, tGround)
                       + 0.4 * coneGlow(cam.o, ray, at, CONE * 0.7, tGround)) * fog;
    }
    col += haze * 0.10 * mix(1.0, 0.75, 1.0 - snow);

    // --- the falling snow, lit only inside the cones ---
    float fallen = FALL * phase;
    float breeze = 0.05 * phase - 0.08 / 0.031 * cos(phase * 0.031);   // drift: a slow breeze that comes and goes
    float2 travel = float2(-breeze, fallen);
    float3 at0 = float3(LAMPS[0].x, LAMP_H, LAMPS[0].y);
    for (int k = 0; k < 6; k++) {
        float depth = 3.3 + 0.95 * float(k);
        // Nearer the window: bigger, softer (out of focus) and dimmer at the core.
        float near = 1.0 - float(k) / 5.0;
        float rad = mix(0.8, 2.0, near * near);
        float gain = mix(2.4, 1.3, near);
        col += flakes(cam, plane1 * depth, depth, 0.95, 0.22, 0.55, rad, gain, at0,
                      1000u + uint(k) * 17u, travel, snow, phase, px);
    }
    for (int i = 1; i < 4; i++) {
        float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
        float3 v = at - cam.o;
        float depth = dot(v, cam.fwd) + 0.6;
        float fog = exp(-length(v) / VIS);
        col += flakes(cam, plane1 * depth, depth, 3.0, 0.22, 0.16, 0.6, 1.6, at,
                      2000u + uint(i) * 17u, travel, snow, phase, px) * fog;
    }

    // --- the lamps: the post, its crook, the hood and the glowing bowl beneath it ---
    for (int i = 3; i >= 0; i--) {
        float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
        float fog = exp(-length(at - cam.o) / VIS);
        float zl;
        float2 a = project(cam, at, zl);
        float s = cam.f / zl;                            // points per metre at the lamp
        float2 lp = float2(pos.x - a.x, a.y - pos.y) / s; // the pixel about the lamp (m, y up)
        // Glare: the frosted bowl's light scattering in the snow about it.
        float r = length(lp - float2(0.0, -0.02));
        col += LIGHT * (0.10 * exp(-r / 0.22) + 0.04 * exp(-r / 0.9)) * fog;
        if (abs(lp.x) > 1.2 || lp.y > 1.2 || lp.y < -LAMP_H - 0.3) continue;
        float3 iron = mix(GLOW * 0.3, col, 1.0 - fog);   // dark iron, lost in the snow with distance
        float cover = 0.0;
        // The post: from the street up past the light, then hooked over to hang the lamp.
        float zb, zt;
        float2 base = project(cam, float3(at.x + ARM, 0.0, at.z), zb);
        float2 top = project(cam, float3(at.x + ARM, LAMP_H + 0.55, at.z), zt);
        float2 ba = top - base, pa = pos - base;
        float tt = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float halfW = mix(0.055, 0.03, tt) * s;
        cover = max(cover, smoothstep(halfW + px, halfW - px, length(pa - ba * tt)));
        float2 hookC = float2(0.5 * ARM, 0.55);
        float2 hp = lp - hookC;
        if (hp.y > 0.0) {
            float ring = abs(length(hp) - 0.5 * ARM);
            cover = max(cover, smoothstep(0.03 + px / s, 0.03 - px / s, ring));
        }
        // The hanger, the hood and the bowl.
        float hanger = abs(lp.x) < 0.015 + px / s && lp.y > 0.26 && lp.y < 0.56 ? 1.0 : 0.0;
        cover = max(cover, hanger);
        float hoodT = clamp((lp.y - 0.02) / 0.26, 0.0, 1.0);
        float hoodW = mix(0.24, 0.05, hoodT);
        float hood = lp.y > 0.02 && lp.y < 0.28
                   ? smoothstep(hoodW + px / s, hoodW - px / s, abs(lp.x)) : 0.0;
        // Snow building on the hood and the crook's top as the night goes on.
        float capH = mix(0.008, 0.035, fill);
        float2 cp = lp - hookC;
        float capCrook = cp.y > 0.0 ? smoothstep(0.03 + capH + px / s, 0.03 + capH - px / s, length(cp) - 0.5 * ARM)
                                     * smoothstep(0.03 - px / s, 0.03 + px / s, length(cp) - 0.5 * ARM)
                                     * smoothstep(0.0, 0.6, cp.y / (0.5 * ARM)) : 0.0;
        float hoodTop = lp.y - (0.02 + 0.26 * (1.0 - clamp((abs(lp.x) - 0.05) / 0.19, 0.0, 1.0)));
        float capHood = abs(lp.x) < 0.24 ? smoothstep(capH + px / s, capH - px / s, hoodTop)
                                          * smoothstep(-px / s, px / s, hoodTop) : 0.0;
        float bowlR = length(float2(lp.x / 0.17, (lp.y + 0.02) / 0.075));
        float bowl = lp.y < 0.03 ? smoothstep(1.0 + 2.0 * px / s, 1.0 - 2.0 * px / s, bowlR) : 0.0;
        col = mix(col, iron, max(cover, hood) * fog);
        col = mix(col, float3(0.060, 0.056, 0.054) * fog + col * (1.0 - fog), max(capCrook, capHood));
        col = mix(col, LIGHT * 1.6 * fog + col * (1.0 - fog), bowl);
    }

    col *= 1.0 - 0.30 * p;

    // Soft roll-off for the brightest light, then a hash dither against OLED banding (time wrapped:
    // hours in, the hash's fract() would otherwise lose precision and freeze the dither).
    col = 1.0 - exp(-col * 1.08);
    col += (hash21(pos + fmod(time, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
