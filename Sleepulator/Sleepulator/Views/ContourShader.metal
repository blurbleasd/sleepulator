#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Contour (Focus) — a topographic map of a drifting mountain whose summit sits
// under the Focus ring, lit from the summit outward as a work interval goes on.
// ----------------------------------------------------------------------------
// The one Focus scene built on line work rather than a soft field: thin contour
// lines at an even height interval, every fifth an index contour (as on a real
// survey map), drawn as a layered relief model: each band a sheet one step up,
// casting a short shadow on the one below. The other Focus scenes each move one way
// (Current sideways, Tide up, Sandfall down); this one reads by radius.
//
// The terrain is a broad cone peaking at `summit` (where the Focus ring sits)
// with domain-warped FBM over it, so the screen always holds both high and low
// ground. An earlier cut was FBM alone, thresholded by its global height
// distribution: with only a few hills on screen at once, the lit share of the
// SCREEN didn't follow `light` (23% of an interval lit ~70% of the screen in
// sim capture), so the reading failed.
//
// THE reading: light spreads down the mountain from the summit. Swift passes
// `edge`, the radius from the summit whose disc covers the `light` share of the
// screen (ContourLight, unit-tested), and the shader lights the ground above the
// height that radius has on the cone. The noise bends that edge but, kept weak
// enough against the cone (see RISE), leaves the lit share of the screen within
// about ±0.07 of the interval's. A work interval starts with the
// summit lit and ends with the whole map lit; a break pulls the light back up.
// The edge of the light is one bright, still contour, so position reads at a
// glance. `light < 0` is no session: every line sits at one even, middling
// brightness and there is no edge, so the scene never implies a session that
// isn't running.
//
// Motion: the contour lines drift steadily downhill, out from the summit (their
// rate is the Pomodoro's `driveSpeed`), and the FBM terrain pans and slowly
// re-forms over the fixed cone, so a 25-minute block never shows the same map
// twice. The light's edge is pinned to a height, not to the drifting lines, so
// it holds still while they pass through it.
//
// Line widths come from the field's own slope (finite differences, one point
// apart), so every line is ~1 pt wide whatever the terrain does. Where lines
// crowd closer than a few points they fade out rather than bead into moiré.
//
// Swift owns the live values (shared FocusDrivers mapping + ContourLight):
//   flow  — SceneClock phase at the Pomodoro's speed (frozen by `paused`)
//   driveOp — overall brightness · light — the reading · edge — its radius
//   summit — the cone's peak, unit screen coordinates · tint — work/rest/idle
// ============================================================================

namespace ctr {

// ---- tunables (edit + rebuild) ---------------------------------------------------
// The cone against the noise is the reading against the look. Simulating this terrain over 24
// random pans, the lit share of the screen tracks `light` with no bias and a spread of ±0.07
// (1 sd) at these values; at 0.60 / 0.85 / 3.0 it was ±0.16, and one capture lit half the
// screen 23% into an interval. A stronger cone tightens it further but draws a bullseye.
constant float FREQ     = 3.6;     // terrain features per screen height
constant float WARP     = 0.9;     // domain-warp strength (folds ridges into organic shapes)
constant float RISE     = 0.90;    // the cone's height, summit to the farthest corner
constant float NOISE    = 0.55;    // the FBM's weight over the cone
constant float STEP     = 0.038;   // contour interval, in height units (~25 pt apart, median)
constant float INDEX    = 5.0;     // every INDEX-th line is an index contour
// Contour intervals per second of drift at speed 1. A line covers an interval faster where the
// ground is flatter (distance = height / slope), so plateaus churned at 0.28; this keeps them a
// drift.
constant float FLOW     = 0.15;
constant float PAN      = 0.010;   // terrain pan per second at speed 1 (in FREQ units)
constant float MORPH    = 0.016;   // warp evolution per second at speed 1
constant float RELIEF   = 1.6;     // hillshade slope exaggeration (the mountain's broad form)
constant float SHADOW_LEN = 14.0;  // how far a sheet's shadow reaches onto the one below, in points
constant float EXPOSURE = 1.7;     // highlight drive for the exposure tonemap

// The FBM's mean and spread (measured over 60k samples of `height`: 0.475, sd 0.122).
constant float H_MEAN   = 0.475;
// ~2.5 sd of the noise, in height units: how far past the cone's own range the light's height
// has to go before nothing (light 0) or everything (light 1) is lit.
constant float MARGIN   = 0.17;

// Light from the upper left (screen y runs down).
constant float3 SUN = float3(-0.497, -0.596, 0.630);

// Near-black indigo, the same ground as Current.
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

/// The FBM terrain: domain-warped. A two-octave warp keeps the cost down (the terrain is
/// sampled three times per pixel for the slope); the folds it adds make ridges and spurs
/// instead of round blobs.
inline float height(float2 q, float morph) {
    float2 w = float2(fbm(q + float2(0.0, morph), 2),
                      fbm(q + float2(5.2, 1.3) - morph, 2));
    return fbm(q + WARP * (w - 0.5), 4);
}

/// The full terrain at `p` (in screen heights from the top-left): the cone under the FBM.
/// `peak` is the summit and `reach` the summit's distance to the farthest corner, both in
/// screen heights too.
inline float terrain(float2 p, float2 peak, float reach, float2 drift, float morph) {
    float cone = 1.0 - length(p - peak) / reach;
    return RISE * cone + NOISE * (height(p * FREQ + drift, morph) - H_MEAN);
}

/// Compact-support bump, a drop-in for `exp(-(d/w)^2)` (see CurrentShader.metal). Pass d² and
/// 1/r² with r = 1.6w.
inline float bump(float d2, float invR2) {
    float t = max(0.0, 1.0 - d2 * invR2);
    return t * t;
}

/// An anti-aliased line `hw` points either side of centre, `d` points away, ~0.65 pt soft edge.
inline float stroke(float d, float hw) {
    return saturate(1.0 - (d - hw) / 0.65);
}

} // namespace ctr

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 contourField(float2 pos, half4 color,
                   float flow, float2 size,
                   float driveOp, float light, float edge, float2 summit, float3 tint) {
    using namespace ctr;

    float2 uv = pos / size;

    // Everything below is in screen heights, so the cone is round and the terrain isotropic.
    float  aspect = size.x / size.y;
    float  pt     = 1.0 / size.y;                       // one point, in screen heights
    float2 p      = pos * pt;
    float2 peak   = summit * float2(aspect, 1.0);
    float  reach  = length(max(summit, 1.0 - summit) * float2(aspect, 1.0));
    float2 drift  = float2(0.62, -0.38) * flow * PAN;
    float  morph  = flow * MORPH;

    float h  = terrain(p, peak, reach, drift, morph);
    float hx = terrain(p + float2(pt, 0.0), peak, reach, drift, morph);
    float hy = terrain(p + float2(0.0, pt), peak, reach, drift, morph);
    float2 g  = float2(hx - h, hy - h);                 // height change per point
    float  gl = max(length(g), 1e-6);

    float3 col = mix(BASE_TOP, BASE_BOT, uv.y);
    float  op  = 0.30 + 0.70 * clamp(driveOp, 0.0, 1.0);

    // ---- the light (THE reading) -----------------------------------------------------
    bool  session = light >= 0.0;
    float ht  = 0.0;     // the light's edge, as a height
    float lit = 0.45;    // idle: one even, middling level everywhere
    if (session) {
        // The cone's height at radius `edge`, pushed past the noise at the two ends so that
        // nothing is lit as an interval starts and everything is lit as it ends.
        ht  = RISE * (1.0 - edge / reach)
            + MARGIN * (1.0 - smoothstep(0.0, 0.15, light))
            - MARGIN * smoothstep(0.85, 1.0, light);
        lit = smoothstep(ht - 0.005, ht + 0.005, h);
    }

    // ---- contour bands ---------------------------------------------------------------
    // + phase: a line's height falls as the phase grows, so the lines drift downhill, out
    // from the summit. The phase wraps every INDEX intervals (not every one) so the index
    // contours keep their identity across the wrap instead of jumping a line.
    float ph  = fmod(flow * FLOW, INDEX);
    float v   = h / STEP + ph;
    float gv  = gl / STEP;                              // contour intervals per point
    float fv  = fract(v);
    float dpt = min(fv, 1.0 - fv) / gv;                 // points to the nearest line
    bool  idx = fmod(floor(v + 0.5), INDEX) < 0.5;
    // Lines closer than ~3 pt bead into moiré on a steep slope: fade them out by ~6 pt apart.
    float legible = smoothstep(2.5, 6.0, 1.0 / gv);

    // ---- depth: a layered relief model -----------------------------------------------
    // The plain hillshaded map read flat on the phone ("a mountain map, but 1-dimensional").
    // Each band between two lines is now a flat sheet one step above the band below, like a
    // laser-cut paper model, with three cues worked out from values already in hand (no extra
    // terrain samples):
    //  · higher sheets are lighter, so the summit sits near and the valleys fall away;
    //  · each sheet casts a short shadow onto the one below, on the side away from the light;
    //  · a line is a sheet's cut edge: bright where it faces the light, dim where it doesn't.
    float2 sunDir = normalize(SUN.xy);                  // on screen, toward the light
    float  facing = dot(g / gl, sunDir);                // > 0: uphill runs toward the light
    // Where the ground climbs toward the light, the next sheet up (its edge `(1 - fv) / gv`
    // points uphill) stands between this point and the light. In shadow within SHADOW_LEN of
    // that edge, measured along the light; darkest at its foot.
    float toEdge = (1.0 - fv) / gv / max(facing, 0.05);
    float shadow = smoothstep(0.0, 1.0, 1.0 - toEdge / SHADOW_LEN);
    shadow *= smoothstep(0.0, 0.3, facing) * legible;

    // Sheets are flat, so (as on a real paper model) they're all lit about evenly and the shadows
    // carry the depth. A first cut kept the full hillshade under them: it darkened exactly the
    // flank the shadows fall on, and they vanished. Only a trace of it is left, for the broad form.
    float sheet  = saturate((floor(v) - ph) * STEP / RISE);   // this sheet's height, ~0…1
    float ground = (0.030 + 0.110 * sheet) * (0.40 + 0.60 * lit);
    float3 n     = normalize(float3(-(g / (pt * FREQ)) * RELIEF, 1.0));
    float  shade = dot(n, SUN) - SUN.z;                 // 0 on flat ground, + facing the light
    ground *= max(0.0, 1.0 + 0.5 * shade);
    col += tint * ground * (1.0 - 0.85 * shadow) * op;

    // ---- contour lines: the sheets' cut edges ----------------------------------------
    // A survey map's hierarchy: index contours carry the structure, the lines between are lighter.
    // In the dark, the index lines are most of what's left, so the map still runs on through it.
    float rim   = 0.90 - 0.45 * facing;                 // an edge faces downhill: lit when that's the light's way
    float line  = stroke(dpt, idx ? 0.95 : 0.38) * legible;
    float level = mix(0.075, 0.42, lit) * (idx ? 1.8 : 1.0) * rim;
    float3 ink  = mix(tint, float3(1.0), 0.32 + 0.28 * lit);
    col += ink  * line * level * op;
    // A soft glow hugs the lines the light has reached, but not over a shadow's dark foot.
    col += tint * bump(dpt * dpt, 1.0 / (2.56 * 2.2 * 2.2)) * legible * lit * 0.10 * rim
         * (1.0 - shadow) * op;

    // ---- the light's edge: one still, bright contour ---------------------------------
    if (session && light > 0.0 && light < 1.0) {
        float dt = abs(h - ht) / gl;                    // points from the edge
        float3 hot = mix(tint, float3(1.0), 0.80);
        col += hot  * stroke(dt, 1.25) * op;
        col += tint * bump(dt * dt, 1.0 / (2.56 * 16.0 * 16.0)) * 0.20 * op;
    }

    // Vignette — pushes the edges to black so the centre reads as the subject.
    float2 vp = (uv - 0.5) * float2(1.0, 1.22);
    col *= 1.0 - 0.50 * dot(vp, vp);

    // Exposure tonemap: darks stay dark, highlights approach white.
    col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);

    // Hash dither kills OLED banding. Wrap the monotonic `flow` before hashing so its
    // internal fract() doesn't lose precision hours in (see AuroraShader).
    col += (hash21(pos + fmod(flow, 64.0)) - 0.5) / 255.0;
    return half4(half3(saturate(col)), 1.0h);
}
