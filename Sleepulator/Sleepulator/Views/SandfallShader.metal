#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Sandfall (Focus) — an hourglass. The bottom bulb's fill IS the interval.
// ----------------------------------------------------------------------------
// v4 (2026-09-26): back to the hourglass, because it is the one genuinely
// time-meaningful metaphor in the app — "how full is the bottom bulb" answers
// "how far through am I" with no numbers and no learning.
//
// v3 turned this into a comet downpour. It looked better than the 14 stiff
// Canvas grains it replaced, but it was semantically empty: progress rode only
// on comet speed / density / brightness. Those are RELATIVE channels — with no
// reference you cannot read 60% from 80% — so the scene never actually said
// anything about the session ("they don't speak to focus"). Progress now rides
// the one absolute channel the eye reads instantly: POSITION. Two sand surfaces,
// travelling ~40% of the field each, in opposite directions.
//
//   fill (0…1) — drained fraction, computed Swift-side (FocusDrivers.fill):
//                a work interval runs 0→1, a break runs it back 1→0.
//   energy     — shading only now (brightness / grain), never the reading.
//   `phase` is a SceneClock time, frozen by occlusion / the Ambient-motion
//   toggle — NOT by Reduce Motion.
// ============================================================================

namespace sf {

constant float EXPOSURE = 1.7;
constant float3 BASE_TOP = float3(0.012, 0.018, 0.044);
constant float3 BASE_BOT = float3(0.004, 0.006, 0.018);

// Hourglass geometry, in uv (y: 0 top → 1 bottom). The neck sits at y = 0.5.
constant float NECK_Y   = 0.5;
constant float NECK_HW  = 0.045;   // half-width at the neck
constant float BULB_HW  = 0.34;    // half-width at the extremes
constant float TOP_Y    = 0.10;    // top of the upper bulb
constant float BOT_Y    = 0.90;    // bottom of the lower bulb

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
    for (int i = 0; i < 3; i++) { v += amp * vnoise(p); p = p * 2.0 + float2(11.3, 7.7); amp *= 0.5; }
    return v;
}

/// Compact-support bump — a cheap stand-in for `exp(-(d/w)^2)`; pass d² and 1/r² with r = 1.6w.
inline float bump(float d2, float invR2) {
    float t = max(0.0, 1.0 - d2 * invR2);
    return t * t;
}

/// Half-width of the hourglass silhouette at height `y`: widest at the two ends, pinched to
/// `NECK_HW` at the neck. The exponent makes the taper funnel-like rather than conical.
inline float silhouette(float y) {
    float d = clamp(abs(y - NECK_Y) / NECK_Y, 0.0, 1.0);
    // Exponent < 1 bulges the walls out near the neck, so the bulbs read as rounded glass.
    // At 1.45 the taper was straight-sided and the silhouette looked like a funnel, not an
    // hourglass — and the shape is the whole metaphor.
    return NECK_HW + (BULB_HW - NECK_HW) * pow(d, 0.62);
}

} // namespace sf

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 sandField(float2 pos, half4 color,
                float phase, float2 size,
                float fill, float energy, float3 tint) {
    using namespace sf;

    float2 uv = pos / size;
    float x = uv.x, y = uv.y;
    float3 col = mix(BASE_TOP, BASE_BOT, y);

    float e = clamp(energy, 0.0, 1.0);
    float f = clamp(fill, 0.0, 1.0);
    float3 sandCol = mix(tint, float3(1.0), 0.45);   // sand reads warm-bright against the glass

    float hw   = silhouette(y);
    float dx   = abs(x - 0.5);
    // Soft edge in uv-x; ~1.5 px at this scale, so the glass has a clean rim without aliasing.
    // Ascending smoothstep then inverted. A DESCENDING smoothstep (edge0 > edge1) is undefined
    // in Metal — it happened to work for the soft x-edge but silently did nothing for the body
    // clip below, which is why the silhouette ran off the screen as two long diagonals.
    float inside = 1.0 - smoothstep(hw - 0.006, hw, dx);
    // Clip EVERYTHING to the glass's vertical extent. Without this the silhouette keeps being
    // evaluated above TOP_Y and below BOT_Y, and the rim term runs off as two long diagonals
    // across the whole screen (sim capture 2026-09-26).
    float inBody = step(TOP_Y, y) * step(y, BOT_Y);

    // ---- the two sand surfaces — THE reading -----------------------------------------
    // Upper bulb drains: its surface descends from TOP_Y to the neck as f: 0 → 1.
    // Lower bulb mounds: its surface rises from BOT_Y to the neck over the same span.
    // Each travels ~40% of the field, so the pair is legible at a glance from across a desk.
    float topSurf = mix(TOP_Y, NECK_Y, f);
    float botSurf = mix(BOT_Y, NECK_Y, f);

    // Sand bodies, clipped to the silhouette.
    // Both are ASCENDING edges: sand lies BELOW its surface (larger y). The bottom one was
    // written descending, which piled the mound above its own surface — the lower bulb read as
    // empty with a lit band floating over it.
    float topSand = smoothstep(topSurf - 0.004, topSurf + 0.004, y) * step(y, NECK_Y);
    float botSand = smoothstep(botSurf - 0.004, botSurf + 0.004, y) * step(NECK_Y, y);
    float sand    = (topSand + botSand) * inside * inBody;

    // Granular texture, scrolling slowly so the mass reads as material rather than paint. The
    // top body settles downward; the mound below creeps up.
    float grain = fbm(float2(x * 38.0, y * 26.0 - phase * 0.35));
    col += sandCol * sand * (0.26 + 0.30 * e) * (0.72 + 0.55 * grain);

    // Bright meniscus on each surface — the crisp line the eye actually locks onto.
    float dTop = (y - topSurf);
    float dBot = (y - botSurf);
    float mTop = bump(dTop * dTop, 1.0 / (2.56 * 0.0035 * 0.0035)) * step(y, NECK_Y + 0.02);
    float mBot = bump(dBot * dBot, 1.0 / (2.56 * 0.0035 * 0.0035)) * step(NECK_Y - 0.02, y);
    col += mix(tint, float3(1.0), 0.85) * (mTop + mBot) * inside * inBody * (0.75 + 0.65 * e);

    // ---- the falling stream ------------------------------------------------------------
    // A thin column from the neck down to the mound, only while there is sand left to fall.
    float running = step(0.001, f) * step(f, 0.999);
    float inStream = step(NECK_Y, y) * step(y, botSurf);
    float streamX  = bump((x - 0.5) * (x - 0.5), 1.0 / (2.56 * 0.010 * 0.010));
    // Pure translation: the speckle travels DOWN the column (y·k − phase·k' = const).
    float speckle  = fbm(float2(x * 60.0, y * 30.0 - phase * 3.2));
    col += sandCol * streamX * inStream * running * inBody * (0.55 + 0.75 * e) * (0.55 + 0.75 * speckle);

    // Splash where the stream lands on the mound.
    float land = bump((y - botSurf) * (y - botSurf), 1.0 / (2.56 * 0.02 * 0.02))
               * bump((x - 0.5) * (x - 0.5), 1.0 / (2.56 * 0.05 * 0.05));
    col += sandCol * land * running * inBody * (0.35 + 0.5 * e);

    // ---- the glass ----------------------------------------------------------------------
    // A faint rim so the silhouette is legible even where there is no sand behind it.
    float rim = bump((dx - hw) * (dx - hw), 1.0 / (2.56 * 0.004 * 0.004));
    col += tint * rim * 0.22 * inBody;

    // Vignette — edges to black so the hourglass reads as the subject.
    float2 vp = (uv - 0.5) * float2(1.0, 1.22);
    col *= 1.0 - 0.48 * dot(vp, vp);

    col = 1.0 - exp(-max(col, 0.0) * EXPOSURE);
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
