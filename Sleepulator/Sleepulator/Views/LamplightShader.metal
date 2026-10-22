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
// through the night the snowfall thins to a quarter and slows, the footprints
// fill in, and snow builds on the lamp, until the light falls on unbroken snow.
// How far along each is is Swift's call (`SnowNight`, unit-tested); this file
// draws it. The lamp's bowl, the brightest thing and the one that holds still
// but for the window's slow wander, dims most.
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
// Original implementation, from the same public-domain hashes as
// NightSkyShader.metal and textbook geometry (a ray through a cone, the
// inverse-square in-scatter integral). No code copied from elsewhere.
//
// Driven from SwiftUI `.colorEffect` through ShaderBackdrop. Swift owns phase
// (night-slowed integrated seconds: the fall, the breeze, the flutter, the
// window's wander), time (monotonic: the dither), size (points), night, snow
// and settled (`SnowNight`, on the eased night), gyro and scale (pixels per
// point).
// Everything else is a constant below (edit + rebuild).
// ============================================================================

namespace lamp {

// ---- tunables --------------------------------------------------------------------
constant float CAM_H    = 3.0;    // the window's height above the street (m)
constant float COS_P    = 0.980066578;   // how far it looks down, 0.20 rad (~11°): its cosine,
constant float SIN_P    = 0.198669331;   // sine and tangent, written out so they aren't
constant float TAN_P    = 0.202710036;   // recomputed for every pixel
constant float TAN_HALF = 0.50;   // tan of half the horizontal field of view (~53°)
constant float LAMP_H   = 4.4;    // a lamp's light above the street (m)
constant float CONE     = 0.45;   // tan of a lamp's cone half-angle (~24°)...
constant float CONE_EDGE = 1.04;  // ...and past this share of its radius its light is exactly 0
                                  // (the early-outs rely on it)
constant float ARM      = 0.75;   // a lamp hangs this far left of its post (m)...
constant float CROOK_H  = 0.55;   // ...from a crook this far above its light (m)...
constant float CROOK_W  = 0.03;   // ...this thick (half-width, m)
constant float HOOD_Y   = 0.02;   // the hood's rim above the light (m)...
constant float HOOD_H   = 0.26;   // ...its height...
constant float HOOD_R   = 0.24;   // ...its rim's half-width...
constant float HOOD_TIP = 0.05;   // ...and its top's (m)
constant float POST_FOOT = 0.055; // the post's half-width at its foot...
constant float POST_TOP  = 0.03;  // ...and at its top (m)
constant float HANGER_W = 0.015;  // the rod the lamp hangs from (half-width, m)
constant float BOWL_Y   = -0.02;  // the frosted bowl under the hood: its centre below the light...
constant float BOWL_W   = 0.17;   // ...its half-width...
constant float BOWL_H   = 0.075;  // ...its half-height (m)...
constant float BOWL     = 1.6;    // ...and its light, before the fog and the night's dim
constant float FALL     = 0.55;   // the snow's fall at bedtime (m/s)
constant float VIS      = 25.0;   // how far you see through the falling snow (m, to 1/e)
constant float GOING    = 0.06;   // the stretch of `snow` a flake takes to stop falling (its fade)
constant int   NEAR_LAYERS = 6;      // the first lamp's snow: this many layers of flakes...
constant float NEAR_FIRST  = 3.3;    // ...the nearest this far ahead of the window (m)...
constant float NEAR_STEP   = 0.95;   // ...each this much further; each layer's slab is a step deep,
                                     // so together they fill the cone through. Over LAMP_H x SIN_P
                                     // (0.874 m), the depth the first post spans: at most one layer
                                     // runs through it (see snowMid)
constant float2 SWAY    = float2(0.40, 0.32);   // the most a flake strays from its cell's centre
                                                // (cells): its place (±0.28) plus its flutter
constant float3 LIGHT   = float3(1.00, 0.68, 0.38);    // the lamps' warm light
constant float3 GLOW    = float3(0.026, 0.021, 0.018); // the town's glow on the clouds, and the snow-fog
constant float3 SNOW    = float3(0.040, 0.038, 0.037); // the snow on the street in that glow: lighter than
                                                       // the sky, about 10 levels, clear of OLED's black crush
constant float3 SNOW_CAP = float3(0.060, 0.056, 0.054); // the snow building on the lamp's iron
constant float DRIFT    = 0.04;   // the window's slow wander (m): a few points over minutes, so the
                                  // lamp doesn't hold the same pixels all night (OLED burn-in). It
                                  // runs on the scene's clock, so with Moving scenes off the frame,
                                  // like every scene's, holds still (the bowl still dims)
// A footprint: its half-length and half-width (m), how much wider it is at the toe, how far out its
// shape reaches (a share of its size) and where its lip of pushed-aside snow peaks.
constant float PRINT_L  = 0.15;
constant float PRINT_W  = 0.058;
constant float PRINT_FLARE = 0.15;
constant float PRINT_REACH = 1.6;
constant float PRINT_LIP   = 1.12;
// A step: its print set this far along (half a jog either way), to the side of the walk, wandering
// across it, and turned out (rad; sin x < x, so it bounds its own sine too).
constant float PRINT_JOG    = 0.04;
constant float PRINT_SIDE   = 0.13;
constant float PRINT_WANDER = 0.18;
constant float PRINT_TOE    = 0.14;
// The window's fixed tilt: which way is up on the screen, and which way is ahead.
constant float3 UP      = float3(0.0, COS_P, SIN_P);
constant float3 FWD     = float3(0.0, -SIN_P, COS_P);

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

// The window: where it is (it moves with the phone's tilt and the slow wander), the focal length
// (points) and the screen's centre. It always faces UP and FWD.
struct Cam {
    float3 o;
    float f;
    float2 c;
};

// The world point on the plane `depth` metres ahead of the window, under a pixel.
inline float3 onPlane(Cam cam, float2 plane, float depth) {
    return cam.o + float3(plane.x, 0.0, 0.0) + UP * plane.y + FWD * depth;
}
// A world point on the screen (points), and how far ahead of the window it is (m).
inline float3 project(Cam cam, float3 w) {
    float3 v = w - cam.o;
    float depth = dot(v, FWD);
    return float3(cam.c + cam.f * float2(v.x, -dot(v, UP)) / depth, depth);
}

// A lamp's light reaching `w` (the lamp's light at `at`): inside its cone, softening toward the
// cone's edge, falling off with the square of the distance.
inline float spot(float3 w, float3 at) {
    float3 v = w - at;
    float below = -v.y;
    if (below <= 0.0) return 0.0;
    // Past CONE_EDGE of the cone's radius the edge below is exactly 0.
    float rr = dot(v.xz, v.xz), lim = CONE_EDGE * CONE * below;
    if (rr >= lim * lim) return 0.0;
    float r = sqrt(rr) / (below * CONE);         // 0 on the axis, 1 at the cone's edge
    float edge = 1.0 - smoothstep(0.62, CONE_EDGE, r);
    return edge * (1.0 - 0.35 * r * r) / (dot(v, v) + 0.05);
}

// The bowl's glare, its light scattering in the snow about it, `r` metres from the bowl's centre (a
// share of its light).
inline float glare(float r) {
    return 0.10 * exp(-r / 0.22) + 0.04 * exp(-r / 0.9);
}

// Where a view ray (from `m`, its origin relative to the lamp, in unit direction `d`) runs through
// the lamp's cone (tan of its half-angle `k`), the lower one below the lamp: `span`, clamped to the
// ray's own [0, tEnd]. Returns 1 if it does, 0 if not.
inline float coneChord(float3 m, float3 d, float k, float tEnd, thread float2 &span) {
    float c2 = 1.0 / (1.0 + k * k);              // cos² of the half-angle
    // Inside the cone (axis straight down) where (w·down)² ≥ cos² |w|², w = m + t d.
    float A = d.y * d.y - c2;
    float B = 2.0 * (m.y * d.y - c2 * dot(m, d));
    float C = m.y * m.y - c2 * dot(m, m);
    float disc = B * B - 4.0 * A * C;
    if (A >= 0.0 || disc <= 0.0) return 0.0;     // A < 0 for every ray on screen (none that steep)
    float sq = sqrt(disc);
    float t1 = (-B + sq) / (2.0 * A), t2 = (-B - sq) / (2.0 * A);
    if (m.y + 0.5 * (t1 + t2) * d.y >= 0.0) return 0.0;   // through the cone's mirror, above the lamp
    span = float2(max(t1, 0.0), min(t2, tEnd));
    return span.y > span.x ? 1.0 : 0.0;
}
// The light a lamp's cone scatters toward the eye along a view ray from `o` in unit direction `d`
// that ends at `tEnd`: the inverse-square in-scatter over the ray's chord through the cone,
// integrated in closed form, through the cone and (to soften its edge) a narrower one inside it.
// The inner cone shares the apex and the axis, so a ray that misses the outer one misses both.
inline float coneGlow(float3 o, float3 d, float3 at, float tEnd) {
    float3 m = o - at;
    float2 outer, inner;
    if (coneChord(m, d, CONE, tEnd, outer) <= 0.0) return 0.0;
    float t0 = -dot(m, d);
    float h = sqrt(max(dot(m, m) - t0 * t0, 0.0) + 0.02);
    // ∫ dt / (h² + (t - t0)²) over the span: (atan((span.y - t0)/h) - atan((span.x - t0)/h)) / h, as
    // one atan2.
    float glow = 0.6 * atan2((outer.y - outer.x) * h, h * h + (outer.y - t0) * (outer.x - t0));
    if (coneChord(m, d, CONE * 0.7, tEnd, inner) > 0.0) {
        glow += 0.4 * atan2((inner.y - inner.x) * h, h * h + (inner.y - t0) * (inner.x - t0));
    }
    return glow / h;
}

// Footprints across the first lamp's pool: someone walked past before bedtime, in from off screen at
// the left and out past the bottom right. Each is a boot-sized hollow with a flat floor and steep
// walls; as snow fills it (`fill` 0 → 1) it grows shallower and its walls soften, until it's gone.
// Returns how deep the pixel is in a print (0…1 of a fresh one's depth) and the snow's slope there
// (x, z).
inline float3 footprints(float2 g, float2 lampAt, float fill) {
    const float2 start = lampAt + float2(-5.74, 3.75);   // off screen at any width and tilt
    const float2 dir = normalize(float2(5.4, -3.9));
    const float2 side = float2(-dir.y, dir.x);
    const float stride = 0.72, depth = 0.05, steps = 15.0;   // the last print is off screen too
    float3 out = float3(0.0);
    float2 rel = g - start;
    float along = dot(rel, dir);
    // How far a print's shape reaches from the walk's line: its centre is PRINT_JOG along its step and
    // PRINT_SIDE + PRINT_WANDER across at most, its shape PRINT_REACH of its size, turned out by
    // PRINT_TOE at most.
    float wide = PRINT_W * (1.0 + PRINT_FLARE);
    float alongReach = PRINT_JOG + PRINT_REACH * (PRINT_L + wide * PRINT_TOE);
    float acrossReach = PRINT_SIDE + PRINT_WANDER + PRINT_REACH * (PRINT_L * PRINT_TOE + wide);
    if (along < -alongReach || along > steps * stride + alongReach) return out;
    if (abs(dot(rel, side)) > acrossReach) return out;
    float k0 = floor(along / stride);
    float sink = pow(1.0 - fill, 1.3);                   // its depth left
    float wall = mix(0.22, 0.85, fill);                  // its walls' width, a share of its radius
    for (int i = 0; i <= 1; i++) {
        float k = k0 + float(i);
        if (k < 0.0 || k > steps) continue;
        float foot = k - 2.0 * floor(0.5 * k) < 0.5 ? 1.0 : -1.0;   // left, right, left...
        float wander = PRINT_WANDER * sin(k * 0.55);
        float toe = PRINT_TOE * foot;                    // toes turned out a little
        float2 centre = start + dir * (k * stride + PRINT_JOG * foot) + side * (PRINT_SIDE * foot + wander);
        float2 fdir = dir * cos(toe) + side * sin(toe), fside = float2(-fdir.y, fdir.x);
        float2 l = g - centre;
        float a = dot(l, fdir) / PRINT_L;
        float halfW = PRINT_W * (1.0 + PRINT_FLARE * clamp(a, -1.0, 1.0));   // wider toward the toe
        float c = dot(l, fside) / halfW;
        float r = length(float2(a, c));
        if (r > PRINT_REACH) continue;
        float x = clamp((r - (1.0 - wall)) / wall, 0.0, 1.0);
        float hollow = 1.0 - x * x * (3.0 - 2.0 * x);    // 1 on its floor, 0 outside
        float lip = 0.18 * exp(-(r - PRINT_LIP) * (r - PRINT_LIP) / 0.05);
        // Its slope: d/dr, then along and across.
        float dr = depth * sink * (6.0 * x * (1.0 - x) / wall - lip * 2.0 * (r - PRINT_LIP) / 0.05);
        float2 dAC = r > 1e-4 ? dr * float2(a / PRINT_L, c / halfW) / r : float2(0.0);
        out += float3(hollow * sink, fdir * dAC.x + fside * dAC.y);
    }
    return out;
}

// Whether no flake in the box [lo, hi] on the plane `depth` ahead (anywhere in its slab, `slab`
// metres deep) can be lit by the lamp at `at`: all landed, all above the lamp, or all past the
// cone's CONE_EDGE, where its light is exactly 0. UP points up and a little ahead, FWD ahead and a
// little down (the window looks down: SIN_P > 0), so y grows with the box and falls with depth, and
// z grows with both: the box's corners bound it, and its lowest point has the widest cone.
inline bool unlit(Cam cam, float2 lo, float2 hi, float depth, float slab, float3 at) {
    float yLo = cam.o.y + UP.y * lo.y + FWD.y * (depth + 0.5 * slab);
    float yHi = cam.o.y + UP.y * hi.y + FWD.y * (depth - 0.5 * slab);
    if (yHi < 0.0 || yLo >= at.y) return true;
    float zLo = cam.o.z + UP.z * lo.y + FWD.z * (depth - 0.5 * slab);
    float zHi = cam.o.z + UP.z * hi.y + FWD.z * (depth + 0.5 * slab);
    float bx = max(max(cam.o.x + lo.x - at.x, at.x - cam.o.x - hi.x), 0.0);
    float bz = max(max(zLo - at.z, at.z - zHi), 0.0);
    float reachR = CONE_EDGE * CONE * (at.y - yLo);
    return bx * bx + bz * bz >= reachR * reachR;
}

// One layer of snowflakes, on the plane `depth` metres ahead of the window, lit only inside the lamp
// at `at`. At most one flake per cell (`cell` metres), each fluttering about its place; the 2×2 cells
// whose centres bracket the pixel are checked (a flake strays at most SWAY of a cell from its
// centre, and its glow, cut at 5 sigma, stays within 1 − SWAY of a cell, to within a level). Each
// flake has its own depth in the layer's slab (`slab` metres) for its light, so the cone is filled
// through, not lit on a few sheets. Returns the light's share (the caller tints it LIGHT).
//   presence: the share of cells with a flake; rad: the flake's glow (points); gain: its brightness
//   cap:      the most a flake's light reaches (it closes on it smoothly; well under it a flake is as
//             lit as it is): set per pixel so a flake passing right by the first lamp's bowl never
//             outshines it (the far lamps' flakes borrow it, fogged)
//   snow:     the share still falling (`SnowNight.snowfall`): each flake stops (fades) at its rank
inline float flakes(Cam cam, float2 plane, float depth, float slab, float cell, float presence,
                     float rad, float gain, float cap, float3 at, uint salt, float2 travel, float snow,
                     float phase, float px) {
    float sum = 0.0;
    // Skip a layer whose plane can't hold a lit flake here: well outside the cone, or above the lamp.
    float3 w = onPlane(cam, plane, depth);
    float reach = 0.5 * cell + 0.5 * slab;
    if (w.y > at.y + reach || w.y < -reach) return sum;
    float dz = max(abs(w.z - at.z) - 0.5 * slab, 0.0);
    if (length(float2(w.x - at.x, dz)) - reach > (at.y - w.y + reach) * CONE) return sum;
    float2 g = (plane + travel) / cell;
    float2 id0 = floor(g - 0.5);
    // Skip the layer here if none of the four cells' flakes can be lit (the box holding all four).
    if (unlit(cam, (id0 + 0.5 - SWAY) * cell - travel, (id0 + 1.5 + SWAY) * cell - travel, depth, slab, at)) {
        return sum;
    }
    float scale = cam.f / depth;                         // points per metre on this plane
    for (int j = 0; j <= 1; j++) {
        for (int i = 0; i <= 1; i++) {
            float2 id = id0 + float2(float(i), float(j));
            if (hashCell(id, salt) >= presence) continue;
            // Skip a cell none of whose possible flakes (anywhere it can stray) is lit.
            if (unlit(cam, (id + 0.5 - SWAY) * cell - travel, (id + 0.5 + SWAY) * cell - travel, depth, slab, at)) {
                continue;
            }
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
            float2 d = (plane - centre) * scale;
            d.y *= 0.72;                                 // a touch of motion blur down its fall
            float sigma = max(rad * mix(0.75, 1.25, h3), px);
            float d2 = dot(d, d) / (sigma * sigma);
            if (d2 > 25.0) continue;                     // past 5 sigma: under a thousandth of a level
            float3 fw = onPlane(cam, centre, depth + (h4 - 0.5) * slab);
            if (fw.y < 0.0) continue;                    // landed: under the snow's surface
            float light = spot(fw, at);
            if (light <= 0.0) continue;
            // The flakes passing right by the bowl don't flare. tanh(10) is 1 in float; past about 44 the
            // GPU's tanh (built on exp(2x)) gives 0, then NaN, a black flake.
            float lit = cap * tanh(min(light * gain / cap, 10.0));
            sum += exp(-0.5 * d2) * lit * alive * mix(0.6, 1.0, h2);
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
    // The bowl and its glare, the brightest things on screen and still but for the window's slow
    // wander, dim further through the night (as Still water's moon does): less light, less burn-in.
    float bowlDim = 1.0 - 0.6 * p;

    // The window, moved a little by the phone's tilt (parallax by real depth) and by a slow wander,
    // looking a little down.
    float2 wander = DRIFT * float2(0.7 * sin(phase * 0.017) + 0.3 * sin(phase * 0.041 + 1.3),
                                   0.5 * sin(phase * 0.023 + 0.7));
    Cam cam;
    cam.o = float3(gyro.x * 0.30 + wander.x, CAM_H - gyro.y * 0.15 + wander.y, 0.0);
    cam.f = 0.5 * size.x / TAN_HALF;
    cam.c = 0.5 * size;

    float2 q = (pos - cam.c) / cam.f;
    float2 plane1 = float2(q.x, -q.y);                   // the pixel on the plane 1 m ahead
    float3 ray = normalize(float3(q.x, 0.0, 0.0) + UP * (-q.y) + FWD);
    float tGround = ray.y < 0.0 ? -cam.o.y / ray.y : 1e4;
    float fogAt = exp(-min(tGround, 1e3) / VIS);         // how much of the ground shows through the snow
    float fogL[4];                                       // how much of each lamp shows through it
    for (int i = 0; i < 4; i++) {
        fogL[i] = exp(-length(float3(LAMPS[i].x, LAMP_H, LAMPS[i].y) - cam.o) / VIS);
    }

    // --- the sky and the snow-fog: the town's glow on the clouds, lifting toward the horizon ---
    float horizon = cam.c.y - cam.f * TAN_P;
    float3 col = GLOW * mix(0.55, 1.0, smoothstep(horizon - 0.45 * size.y, horizon, pos.y));

    // --- the snow on the street: faintly lit by the glow everywhere, by the lamps in their pools ---
    if (ray.y < 0.0) {
        float3 g = cam.o + ray * tGround;
        float3 n = float3(0.0, 1.0, 0.0);
        float ao = 1.0;
        // The footprints, filling in through the night (only near the first pool).
        if (fill < 1.0) {
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
                float postW = mix(POST_FOOT, POST_TOP, 0.4);   // its width where it shades most
                shade = smoothstep(postW - 0.5 * pen, postW + 0.5 * pen, off);
            }
            float3 l = normalize(at - g);
            lit += s * max(dot(n, l), 0.0) * shade;
        }
        // The snow on the ground is a little lighter than the sky: it holds the town's glow.
        float3 street = SNOW * ao + LIGHT * 3.0 * lit * ao;
        col = mix(col, street, fogAt);
    }

    // --- the cones' glow in the falling snow ---
    float hazeK = 0.10 * mix(1.0, 0.75, 1.0 - snow);
    float haze0 = 0.0;                                   // the first lamp's, for the flakes' cap
    for (int i = 0; i < 4; i++) {
        float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
        float glow = coneGlow(cam.o, ray, at, tGround) * fogL[i] * hazeK;
        col += LIGHT * glow;
        if (i == 0) haze0 = glow;
    }

    // --- the falling snow, lit only inside the cones ---
    float fallen = FALL * phase;
    float breeze = 0.05 * phase - 0.08 / 0.031 * cos(phase * 0.031);   // drift: a slow breeze that comes and goes
    // The snow belongs to the street, not the screen: shift each plane's grid by the window's own
    // move (its tilt and wander, across and up the planes), so the flakes parallax with the lamps.
    float3 home = float3(0.0, CAM_H, 0.0);                // the window at rest
    float2 camOff = float2(cam.o.x, dot(cam.o - home, UP));
    float2 travel = float2(-breeze, fallen) + camOff;
    // A flake never outshines the bowl: it, and what it's laid over here (the first cone's glow and the
    // bowl's glare), stay under 0.85 of the bowl's light.
    float3 at0 = float3(LAMPS[0].x, LAMP_H, LAMPS[0].y);
    float3 a0 = project(cam, at0);
    float r0 = length(float2(pos.x - a0.x, a0.y - pos.y) * a0.z / cam.f - float2(0.0, BOWL_Y));
    float glare0 = glare(r0) * fogL[0] * bowlDim;
    float bowlLight0 = BOWL * fogL[0] * bowlDim;
    float cap = max(0.85 * bowlLight0 - haze0 - glare0, 0.05 * bowlLight0);
    // Layers nearer than the lamp are drawn after its post and hood, which they pass in front of; the
    // layer the post's depth runs through is drawn after them too, and hidden by the post only where
    // the post is nearer (its foot is further away than its top: the window looks down).
    float zLamp0 = a0.z;
    float zFoot0 = project(cam, float3(at0.x + ARM, 0.0, at0.z)).z;
    float snowFront = 0.0, snowMid = 0.0;
    float zMid = 0.0;
    // Unrolled: the compiler builds the loop's three accumulators far cheaper so (measured ~7%).
    #pragma unroll
    for (int k = 0; k < NEAR_LAYERS; k++) {
        float depth = NEAR_FIRST + NEAR_STEP * float(k);
        // Nearer the window: bigger, softer (out of focus) and dimmer at the core.
        float near = 1.0 - float(k) / float(NEAR_LAYERS - 1);
        float rad = mix(0.8, 2.0, near * near);
        float gain = mix(3.0, 1.6, near);
        float layer = flakes(cam, plane1 * depth, depth, NEAR_STEP, 0.22, 0.55, rad, gain, cap, at0,
                             1000u + uint(k) * 17u, travel, snow, phase, px);
        if (depth < zLamp0) snowFront += layer;
        else if (depth < zFoot0) { snowMid += layer; zMid = depth; }
        else col += LIGHT * layer;
    }
    // The far lamps' snow, its cells 8 points across on screen at the lamp's depth from the window at
    // rest (from the moving window they'd swell and shrink with the tilt, and the field with them):
    // smaller, and the 2x2 cells checked would cut a flake's glow off square.
    #pragma unroll
    for (int i = 1; i < 4; i++) {
        float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
        float depth = dot(at - home, FWD) + 0.6;
        col += LIGHT * fogL[i] * flakes(cam, plane1 * depth, depth, 3.0, 8.0 * depth / cam.f, 0.40, 0.6, 1.6,
                                        cap, at, 2000u + uint(i) * 17u, travel, snow, phase, px);
    }
    // What of the first lamp is in front of the middle layer here: its hood, crook, hanger, caps and
    // bowl always; its post where the post is nearer.
    float lampCover0 = 0.0, postCover0 = 0.0, zPost0 = 0.0;

    // --- the lamps: the post, its crook, the hood and the glowing bowl beneath it ---
    for (int i = 3; i >= 0; i--) {
        float3 at = float3(LAMPS[i].x, LAMP_H, LAMPS[i].y);
        float fog = fogL[i];
        float3 a = project(cam, at);
        float s = cam.f / a.z;                           // points per metre at the lamp
        float2 lp = float2(pos.x - a.x, a.y - pos.y) / s; // the pixel about the lamp (m, y up)
        // Glare: the frosted bowl's light scattering in the snow about it.
        float r = length(lp - float2(0.0, BOWL_Y));
        // Past 6 m the glare is under 0.05 of a level, and the lamp's shapes (within 4.9 m) are behind.
        if (r > 6.0) continue;
        col += LIGHT * glare(r) * fog * bowlDim;
        if (abs(lp.x) > 1.2 || lp.y > 1.2 || lp.y < -LAMP_H - 0.3) continue;
        float3 iron = mix(GLOW * 0.3, col, 1.0 - fog);   // dark iron, lost in the snow with distance
        float cover = 0.0;
        // The post: from the street up past the light, then hooked over to hang the lamp.
        float3 base = project(cam, float3(at.x + ARM, 0.0, at.z));
        float3 top = project(cam, float3(at.x + ARM, LAMP_H + CROOK_H, at.z));
        float2 ba = top.xy - base.xy, pa = pos - base.xy;
        float tt = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
        float halfW = mix(POST_FOOT, POST_TOP, tt) * s;
        float post = smoothstep(halfW + px, halfW - px, length(pa - ba * tt));
        float2 hookC = float2(0.5 * ARM, CROOK_H);
        float2 hp = lp - hookC;
        if (hp.y > 0.0) {
            float ring = abs(length(hp) - 0.5 * ARM);
            cover = max(cover, smoothstep(CROOK_W + px / s, CROOK_W - px / s, ring));
        }
        // The hanger, the hood and the bowl.
        float hanger = smoothstep(HANGER_W + px / s, HANGER_W - px / s, abs(lp.x))
                     * step(HOOD_Y + HOOD_H, lp.y) * step(lp.y, CROOK_H + 0.01);
        cover = max(cover, hanger);
        float hoodT = clamp((lp.y - HOOD_Y) / HOOD_H, 0.0, 1.0);
        float hoodW = mix(HOOD_R, HOOD_TIP, hoodT);
        float hood = lp.y > HOOD_Y && lp.y < HOOD_Y + HOOD_H
                   ? smoothstep(hoodW + px / s, hoodW - px / s, abs(lp.x)) : 0.0;
        // Snow building on the hood and the crook's top as the night goes on.
        float capH = mix(0.008, 0.035, fill);
        float2 cp = lp - hookC;
        float capCrook = cp.y > 0.0 ? smoothstep(CROOK_W + capH + px / s, CROOK_W + capH - px / s, length(cp) - 0.5 * ARM)
                                     * smoothstep(CROOK_W - px / s, CROOK_W + px / s, length(cp) - 0.5 * ARM)
                                     * smoothstep(0.0, 0.6, cp.y / (0.5 * ARM)) : 0.0;
        float hoodTop = lp.y - (HOOD_Y + HOOD_H * (1.0 - clamp((abs(lp.x) - HOOD_TIP) / (HOOD_R - HOOD_TIP), 0.0, 1.0)));
        float capHood = abs(lp.x) < HOOD_R ? smoothstep(capH + px / s, capH - px / s, hoodTop)
                                          * smoothstep(-px / s, px / s, hoodTop) : 0.0;
        // The bowl: an ellipse, its edge softened over a pixel all round (bowlR's gradient turns a pixel
        // into its own units), cut by the hood's rim.
        float2 bq = float2(lp.x / BOWL_W, (lp.y - BOWL_Y) / BOWL_H);
        float bowlR = length(bq);
        float aa = (px / s) * length(bq / float2(BOWL_W, BOWL_H)) / max(bowlR, 1e-4);
        float bowl = smoothstep(1.0 + aa, 1.0 - aa, bowlR) * smoothstep(HOOD_Y + px / s, HOOD_Y - px / s, lp.y);
        if (i == 0) {
            lampCover0 = max(max(cover, hood), max(max(capCrook, capHood), bowl));
            postCover0 = post;
            zPost0 = 1.0 / mix(1.0 / base.z, 1.0 / top.z, tt);   // 1/z runs straight on screen; z doesn't
        }
        col = mix(col, iron, max(max(cover, post), hood));
        col = mix(col, SNOW_CAP * fog + col * (1.0 - fog), max(capCrook, capHood));
        col = mix(col, LIGHT * BOWL * bowlDim * fog + col * (1.0 - fog), bowl);
    }
    col += LIGHT * (snowMid * (1.0 - max(lampCover0, zPost0 < zMid ? postCover0 : 0.0)));
    col += LIGHT * snowFront;

    col *= 1.0 - 0.30 * p;

    // Soft roll-off for the brightest light, then a hash dither against OLED banding (time wrapped:
    // hours in, the hash's fract() would otherwise lose precision and freeze the dither).
    col = 1.0 - exp(-col * 1.08);
    col += (hash21(pos + fmod(time, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
