#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Rain on Glass — Depth Edition · droplet-as-lens layer effect
// ----------------------------------------------------------------------------
// Plan of record: RAIN-ON-GLASS-DEPTH-SPEC.md (§6.0 / §6.1 / §6.2).
//
// Attached (via SwiftUI `.layerEffect`) to a STATIC composited background — the
// "far world": near-black gradient + a BRIGHT, soft bokeh field + a low band of
// distant windows + faint haze (see RainGlassDepthView). This is the single layer
// the effect is allowed to sample (§6.0). The shader:
//   • outside drops → passes the far world through (with a faint condensation veil),
//   • inside each droplet → samples the SAME layer at a flipped + magnified offset,
//     a real lens showing an inverted, magnified pinch of the lights behind the glass.
// Plus a catch-light, a Fresnel rim, and gyro parallax that slides the far world
// behind the near beads. No second texture is needed: the far world is already in
// the layer, brightened so most beads have a light to bend (§6.1).
//
// Drops come from two procedural systems so locality holds for the hash-grid search:
//   • clingers — static beads on a 2D hash grid (the bulk of the texture),
//   • runners  — falling beads on a 1D column grid (the rain motion).
//
// Tunables are `constant`s below — edit + rebuild, no Swift change (§10 step 4).
// Swift owns only the live values: time, size, gyro, and two master strengths used
// for on-device A/B — `refraction` (0 = flat tinted beads → proves the seam, §10
// step 2; 1 = full lens, §10 step 3) and `density` (bead coverage).
// ============================================================================

namespace rg {

// -- hashing: stable per-cell randomness (same spirit as the Swift xorshift fields) --
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
inline float2 hash22(float2 p) {
    float n = hash21(p);
    return float2(n, hash21(p + n + 11.7));
}

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant float CELL        = 78.0;   // clinger grid cell, points (smaller = denser beads)
constant float DROP_MIN    = 0.08;   // min bead radius, fraction of CELL
constant float DROP_MAX    = 0.26;   // max bead radius, fraction of CELL
constant float MAGNIFY     = 1.5;    // lens magnification (spec §6.2: start ~1.5x)
constant float RIM_BEND    = 0.18;   // extra refraction crowding toward the rim (0 = none)
constant float CATCH       = 0.55;   // catch-light brightness
constant float RIM_LIGHT   = 0.10;   // Fresnel rim brightness
constant float PARALLAX    = 12.0;   // max gyro background shift, points (held-only bonus)
constant float COL_W       = 1.4;    // runner column width, in CELLs
constant float RUNNER_PROB = 0.5;    // fraction of columns carrying a runner
constant float RUNNER_VMIN = 40.0;   // runner fall speed, points/sec
constant float RUNNER_VMAX = 120.0;
constant float TRAIL_LEN   = 16.0;   // runner trail length, in bead radii
constant float CONDENSE    = 0.04;   // condensation veil strength between drops
constant half  LENS_GAIN   = 1.18h;  // lensed light reads a touch brighter than the soft far world

// sample the far-world layer, clamped into bounds, with the gyro parallax shift applied.
inline half4 sampleFar(SwiftUI::Layer layer, float2 p, float2 size, float2 par) {
    float2 q = clamp(p + par, float2(0.0), size);
    return layer.sample(q);
}

// Composite one droplet (centre `c`, radius `r`) over `behind`, as a lens onto the far world.
// Returns `behind` untouched outside the bead; a refracted + lit bead inside it.
inline half4 applyBead(SwiftUI::Layer layer, float2 size, float2 par,
                       float2 pos, float2 c, float r, half4 behind, float refraction) {
    float2 d = pos - c;
    float dist = length(d);
    if (dist > r) return behind;                       // outside the bead
    float u = dist / r;                                 // 0 centre … 1 rim
    float2 dir = (dist > 1e-4) ? d / dist : float2(0.0);

    // the lens: invert (minus) + magnify (/MAGNIFY) the pinch of far world behind the bead,
    // bending harder toward the rim so the edge warps light like a real meniscus.
    float2 lensOff = -d / MAGNIFY - dir * (RIM_BEND * r) * u * u;
    half4 lens = sampleFar(layer, c + lensOff, size, par);
    lens.rgb = min(half3(1.0h), lens.rgb * LENS_GAIN + 0.02h);

    // 0 = flat bead (= far world, the A/B identity); 1 = full lens.
    half4 col = mix(behind, lens, half(refraction));

    // catch-light: a small specular highlight toward the upper-left of the bead.
    float2 hp = c + float2(-r * 0.35, -r * 0.42);
    float hl = saturate(1.0 - distance(pos, hp) / (r * 0.5));
    col.rgb += half3(CATCH) * half(hl * hl);

    // Fresnel rim: a faint bright ring that sells the 3D bead.
    col.rgb += half3(RIM_LIGHT) * half(smoothstep(0.78, 1.0, u));

    // soft anti-aliased edge (1 inside → 0 at the rim; ascending edges for defined smoothstep).
    float edge = 1.0 - smoothstep(0.92, 1.0, u);
    return mix(behind, col, half(edge));
}

// A faint, weakly-refractive trail above a runner's head — garnish, not the star (§6.2).
inline half4 applyTrail(SwiftUI::Layer layer, float2 size, float2 par,
                        float2 pos, float2 c, float r, half4 behind, float refraction) {
    float above = c.y - pos.y;                          // > 0 above the head
    float maxAbove = r * TRAIL_LEN;
    if (above <= 0.0 || above > maxAbove) return behind;
    float dx = pos.x - c.x;
    float w = r * 0.5 * (1.0 - above / maxAbove);        // taper to a point
    float cov = (1.0 - smoothstep(w * 0.4, w, abs(dx))) * 0.45;  // soft, weak column (centre→edge)
    if (cov <= 0.0) return behind;
    half4 lens = sampleFar(layer, pos + float2(-dx * 0.4, 0.0), size, par); // weak horizontal pinch
    half4 wet = mix(behind, lens, half(refraction * 0.5));
    wet.rgb += half3(0.04h);                             // faint sheen
    return mix(behind, wet, half(cov));
}

} // namespace rg

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 rainGlassLens(float2 pos, SwiftUI::Layer layer,
                    float time, float2 size, float2 gyro,
                    float refraction, float density) {
    using namespace rg;

    float2 par = gyro * PARALLAX;                        // far world slides behind near beads
    half4 col = sampleFar(layer, pos, size, par);        // start from the far world

    // --- clingers: nearest static bead over a 3x3 hash-grid neighbourhood --------------
    float2 cell = floor(pos / CELL);
    float bestD = 1e9; float2 bestC = pos; float bestR = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            float2 ci = cell + float2(dx, dy);
            float2 h = hash22(ci);
            if (h.x > density) continue;                 // empty glass
            float2 hh = hash22(ci + 3.1);
            float r = CELL * mix(DROP_MIN, DROP_MAX, hh.x);
            float2 center = (ci + 0.25 + h * 0.5) * CELL; // jittered rest position in-cell
            float dd = distance(pos, center);
            if (dd < bestD) { bestD = dd; bestC = center; bestR = r; }
        }
    }
    if (bestR > 0.0) col = applyBead(layer, size, par, pos, bestC, bestR, col, refraction);

    // --- runners: falling beads on a 1D column grid (locality in x only) ---------------
    float colw = CELL * COL_W;
    float colI = floor(pos.x / colw);
    float span = size.y + 2.0 * CELL;
    for (int k = -1; k <= 1; k++) {
        float c = colI + float(k);
        float2 h = hash22(float2(c, 17.0));
        if (h.x > RUNNER_PROB) continue;                 // this column is dry
        float r = CELL * mix(DROP_MIN + 0.04, DROP_MAX, h.y);
        float speed = mix(RUNNER_VMIN, RUNNER_VMAX, hash21(float2(c, 5.0)));
        float yy = fmod(time * speed + h.x * span, span) - CELL;          // sweep top→bottom, wrap
        float meander = sin(time * 0.5 + h.x * 6.2832) * r * 0.5;
        float2 rc = float2((c + 0.5) * colw + meander, yy);
        col = applyTrail(layer, size, par, pos, rc, r, col, refraction);
        col = applyBead(layer, size, par, pos, rc, r, col, refraction);
    }

    // --- condensation veil: a faint mist on the dry glass between beads ----------------
    float veil = hash21(floor(pos / 2.0)) * CONDENSE;
    col.rgb += half3(veil);

    return col;
}
