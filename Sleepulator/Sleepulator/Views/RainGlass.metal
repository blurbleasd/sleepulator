#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Rain on Glass — Depth Edition · droplet-as-lens layer effect (v2)
// ----------------------------------------------------------------------------
// Plan of record: RAIN-ON-GLASS-DEPTH-SPEC.md (§6.0 / §6.1 / §6.2).
//
// Attached (via SwiftUI `.layerEffect`) to a STATIC composited "far world":
// near-black gradient + bright bokeh + a low band of distant windows (see
// RainGlassDepthView). That single layer is all the shader may sample (§6.0).
//
// -- ATTRIBUTION / LICENSE ---------------------------------------------------
// Original implementation (2026-07): replaces the earlier port of a CC BY-NC-SA
// Shadertoy ("Heartfelt"), written so the app carries no share-alike baggage.
// Built from the same public-domain construction kit as the repo's other
// shaders (hash21 / value-noise style hashing; see AuroraShader.metal). The
// drop lifecycle, lens model, wake model, and all constants are this file's
// own. NOTE for the log: the author of this rewrite had read the old port —
// if lawyer-grade clean-room provenance ever matters, have someone diff the
// two and confirm no expression carried over (the structure is deliberately
// different: per-cycle reseeded drops vs a scrolled grid; a true inverted
// lens vs slope-smear; an analytic spherical-cap normal vs 3-tap gradient).
//
// What sells the depth (§6.1 / §6.2), in order:
//   1. THE LENS — inside each near drop the far world appears INVERTED and
//      compressed (a water droplet is a strong wide-angle lens). This is the
//      photographed look; the old slope-smear never inverted anything.
//   2. FOCUS GAP — dry glass shows a small 5-tap BLUR of the far world (plus
//      dim + milk); drops are sharp. The eye reads sharp-inside-blurry as
//      depth far better than dim-vs-bright.
//   3. Wakes — a drop leaves a semi-clear drying streak with beads behind it.
//
// Swift owns time, size, gyro, and the two A/B uniforms: `refraction`
// (0 = clear flat beads, 1 = full lens) and `density` (mist amount). All else
// is a `constant` below — edit + rebuild (§10 step 4).
//
// Precision: per-drop cycles use fract/floor of (time * rate) — at 8 h that's
// O(10³), where float still has ~2e-4 of fract resolution: drops stay smooth
// all night. Hash inputs are cell/cycle indices (small integers), so hashing
// never degrades the way an unwrapped continuous coordinate would.
// ============================================================================

namespace rgv2 {

// ---- tunables (edit + rebuild) ---------------------------------------------------
constant float FALL        = 0.055;  // base fall rate, cycles/s (smaller = calmer rain)
constant float COLW        = 0.075;  // column width, uv units → ~6 near lanes on a portrait phone
constant float R_DROP      = 0.030;  // near-layer drop radius, uv units
constant float LENS_VIEW   = 0.20;   // half-width of world seen through a drop, uv units.
                                     // MUST stay <= maxSampleOffset/size.y (Swift side: 220px).
constant float RIM_BEND    = 0.10;   // meniscus refraction at the drop rim, uv units
constant float FOG_DIM     = 0.52;   // how dark the dry (fogged) glass is vs a clear drop
constant float FOG_MILK    = 0.014;  // faint milky lift on the fogged glass
constant float BLUR_PX     = 2.6;    // fog blur tap radius, px — the §6.1 focus gap
constant float WAKE_LEN    = 0.38;   // how far above a drop its drying streak reaches, uv
constant float WAKE_CLEAR  = 0.42;   // how much of the sharp world shows through a fresh wake
constant float MIST_CELLS  = 42.0;   // condensation grid density
constant float MIST_AMT    = 0.55;   // mist clarity contribution (× the density uniform)
constant float SPEC_POW    = 3.0;    // catch-light falloff (higher = tighter glints)
constant float SPEC_BRIGHT = 0.20;   // catch-light brightness
constant float PARALLAX_UV = 0.02;   // max gyro far-world shift (held-in-hand bonus)

// House hash (same public construction as the repo's other shaders).
inline float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

// Everything the composite needs to know about the nearest running drop.
struct Drops {
    float  core;     // 1 inside the drop body (lens region), soft edge
    float  rim;      // rim weight (meniscus band, where the bend lives)
    float2 nrm;      // spherical-cap surface normal, xy projection
    float2 center;   // drop centre, uv
    float  radius;   // drop radius, uv
    float  wake;     // drying-streak weight above the drop
};

// The running-drop layer. Columns of independent drops; each fall re-seeds its
// x-offset, size, and meander from (column, cycle-index), so no two passes down
// the pane repeat — the old port replayed the identical path every cycle.
inline Drops dropLayer(float2 uv, float time) {
    Drops o = { 0.0, 0.0, float2(0.0), float2(0.0), R_DROP, 0.0 };

    float ci = floor(uv.x / COLW);              // column index
    float cx = (ci + 0.5) * COLW;               // column centre

    // Column personality (fixed): fall rate + phase.
    float h1 = hash21(float2(ci, 3.7));
    float h2 = hash21(float2(ci, 17.9));
    float rate = FALL * (0.65 + 0.8 * h1);
    float cyc  = time * rate + h2 * 9.0;
    float k    = floor(cyc);                    // cycle index — reseeds each pass
    float f    = fract(cyc);

    // Per-cycle personality: some cycles are dry (no drop), the rest vary.
    float r1 = hash21(float2(ci * 7.31, k));
    float r2 = hash21(float2(ci * 3.17, k + 13.0));
    float r3 = hash21(float2(ci * 9.73, k + 41.0));
    float active = step(0.25, r1);              // ~75% of cycles carry a drop

    // Fall path: eased (gravity), entering above the top edge and exiting below.
    float y = (pow(f, 1.55) * 1.25 - 0.10);
    // Meander: a gentle S-curve whose shape is re-seeded per cycle.
    float mx = cx + (r2 - 0.5) * COLW * 0.55
             + sin(y * (7.0 + r3 * 6.0) + r3 * 6.2831) * COLW * 0.16;

    float r = R_DROP * (0.65 + 0.7 * r2);
    float2 c = float2(mx, y);

    // Slightly tall drop: squash x a touch so it reads as a running bead.
    float2 d2 = (uv - c) * float2(1.15, 0.9);
    float d = length(d2);

    float body = smoothstep(r, r * 0.86, d) * active;          // soft-edged body
    float q    = clamp(d / max(r, 1e-4), 0.0, 1.0);
    float cap  = sqrt(max(0.0, 1.0 - q * q));                  // spherical-cap height
    o.core   = body * smoothstep(0.95, 0.72, q);               // interior (lens)
    o.rim    = body * (1.0 - smoothstep(0.95, 0.72, q));       // meniscus band
    o.nrm    = (d > 1e-5 ? d2 / d : float2(0.0)) * (1.0 - cap); // strongest at the rim
    o.center = c;
    o.radius = r;

    // Wake: a drying streak above the drop along the same meander path.
    float above = y - uv.y;                                    // >0 where the drop passed
    if (active > 0.5 && above > 0.0) {
        float pathX = cx + (r2 - 0.5) * COLW * 0.55
                    + sin(uv.y * (7.0 + r3 * 6.0) + r3 * 6.2831) * COLW * 0.16;
        float lat = abs(uv.x - pathX);
        float streak = smoothstep(r * 0.7, r * 0.25, lat)
                     * smoothstep(WAKE_LEN, 0.02, above);      // dries with distance
        // Beads left along the wake — small clarity dots that also catch light.
        float bcell = floor(uv.y * 34.0);
        float bh = hash21(float2(ci * 13.7 + k, bcell));
        float bead = step(0.72, bh) * smoothstep(r * 0.5, r * 0.15, lat)
                   * smoothstep(WAKE_LEN, 0.05, above);
        // Fade the wake out over the last stretch of the cycle so it doesn't vanish in a
        // visible pop when the cycle (and its per-cycle seeds) resets.
        o.wake = clamp(streak * 0.7 + bead * 0.9, 0.0, 1.0) * (1.0 - smoothstep(0.88, 1.0, f));
    }
    return o;
}

// Condensation mist: static micro-droplets that condense and evaporate on slow,
// per-cell cycles — clarity specks, no lensing (too small to resolve an image).
inline float mist(float2 uv, float time) {
    float2 g  = uv * MIST_CELLS;
    float2 id = floor(g);
    float2 fp = fract(g) - 0.5;
    float  h  = hash21(id);
    float  hb = hash21(id + 57.0);
    float2 p  = (float2(h, hb) - 0.5) * 0.6;
    float  d  = length(fp - p);
    // Slow condense→hold→evaporate cycle, phase-offset per cell.
    float ph = fract(time * 0.045 + h * 11.0);
    float life = smoothstep(0.00, 0.15, ph) * smoothstep(1.0, 0.55, ph);
    return smoothstep(0.16, 0.03, d) * life * step(0.35, hb);
}

} // namespace rgv2

// ----------------------------------------------------------------------------------
[[ stitchable ]]
// `fogAmt` / `defocus` are the night reaction, computed on the Swift side by `DepthReactivity`
// (F1) from `nightProgress`: as the night settles, the dry glass fogs (fogAmt 0 → 1) and the far
// world defocuses further (defocus 1 → ~2.4). Motion slowdown is applied upstream via the host's
// SceneClock rate, so `time` already arrives night-slowed — nothing to do for it here.
half4 rainGlassLens(float2 pos, SwiftUI::Layer layer,
                    float time, float2 size, float2 gyro,
                    float refraction, float density,
                    float fogAmt, float defocus) {
    using namespace rgv2;

    float2 uv = pos / size.y;                    // top-down uv; v grows downward (drops fall +v)
    float2 par = gyro * PARALLAX_UV;             // far-world parallax (0 on a nightstand)

    // Clamped layer tap helper coords (SwiftUI::Layer samples in pixels, top-down).
    #define RG_SAMPLE(u) layer.sample(clamp((u) * size.y, float2(0.0), size)).rgb

    // --- the wet surface -----------------------------------------------------------
    // Near layer: full lens treatment. Far layer: smaller/faster, slope-bend only
    // (cheaper, and far drops are too small to read an image through anyway).
    Drops near = dropLayer(uv, time);
    Drops far  = dropLayer(uv * 1.8 + float2(0.37, 0.0), time * 1.35);
    float mistM = mist(uv, time) * MIST_AMT * density;

    // --- far-world samples (the §6.1 focus gap) -------------------------------------
    // Dry glass = blurred + dimmed + milky. Drops/wakes = progressively sharp.
    // `defocus` widens the blur tap as the night deepens (1 = bedtime, ~2.4 = full night) — still
    // the same 5 taps, only spread wider, so no new per-frame cost (the §6.2 battery trap).
    float e = BLUR_PX / size.y * defocus;
    half3 blurred = ( RG_SAMPLE(uv + par)
                    + RG_SAMPLE(uv + par + float2( e,  e))
                    + RG_SAMPLE(uv + par + float2(-e,  e))
                    + RG_SAMPLE(uv + par + float2( e, -e))
                    + RG_SAMPLE(uv + par + float2(-e, -e)) ) / 5.0h;
    half3 sharp = RG_SAMPLE(uv + par);

    // Dry glass fogs up as the night settles: dimmer far world + a milkier lift (`fogAmt` 0 at
    // bedtime → 1 at timer end). Drops/wakes below stay sharp — the fog is the *dry* glass.
    half3 fog = blurred * half(FOG_DIM * (1.0 - 0.30 * fogAmt))
              + half(FOG_MILK) + half(0.05 * fogAmt);
    half3 rgb = fog;

    // Wake: recently wiped glass — part-way back to sharp, slightly dim (wet film).
    rgb = mix(rgb, sharp * 0.9h, half(near.wake * WAKE_CLEAR));

    // Mist specks: tiny clear points.
    rgb = mix(rgb, sharp, half(clamp(mistM, 0.0, 1.0) * 0.6));

    // Far drops: clear + slope-bent sample (no inversion at that size).
    if (far.core + far.rim > 0.003) {
        float2 bent = uv + par - far.nrm * (RIM_BEND * 0.7 * refraction);
        half3 farCol = RG_SAMPLE(bent);
        rgb = mix(rgb, farCol, half(clamp((far.core + far.rim) * 0.85, 0.0, 1.0)));
    }

    // Near drop: THE LENS. Interior shows the far world inverted + compressed about
    // the drop centre; the rim band does meniscus bending. `refraction` fades the
    // whole optic down to "clear flat bead" for the A/B (§10 step 2).
    if (near.core + near.rim > 0.003) {
        float2 local = (uv - near.center) / max(near.radius, 1e-4);   // [-1, 1] across the drop
        float2 lensUV = near.center + par - local * (LENS_VIEW * refraction)
                                    + local * near.radius * (1.0 - refraction);
        half3 lensCol = RG_SAMPLE(lensUV);

        float2 bent = uv + par - near.nrm * (RIM_BEND * refraction);
        half3 rimCol = RG_SAMPLE(bent);

        rgb = mix(rgb, rimCol, half(clamp(near.rim, 0.0, 1.0)));
        rgb = mix(rgb, lensCol, half(clamp(near.core, 0.0, 1.0)));

        // Catch-light: a tight powered glint on the upper-left of the cap — reads as
        // the room's light on the meniscus (the old linear ramp made flat combs).
        float2 L = normalize(float2(-0.55, -0.84));                    // upper-left
        float s = pow(clamp(dot(normalize(near.nrm + float2(1e-5, 0.0)), L), 0.0, 1.0), SPEC_POW);
        rgb += half3(half(s * near.rim * SPEC_BRIGHT));
    }

    // Faint sheen so wakes read wet even over dark sky.
    rgb += half3(half(near.wake * 0.02));

    #undef RG_SAMPLE
    return half4(rgb, 1.0h);
}
