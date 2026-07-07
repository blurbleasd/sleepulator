#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// ============================================================================
// Sandfall (Focus) — a minimal hourglass whose sand level maps to the Pomodoro.
// ----------------------------------------------------------------------------
// The Metal edition of the CPU `SandfallView` (14 stiff drawn grains + flat
// triangle fills). Here the sand is per-pixel FBM granularity in both bulbs, the
// top draining and the bottom mounding as `prog` runs 0→1, a turbulent falling
// column through the neck while the interval runs, and a faint procedural frame.
// Geometry is in PIXELS (via `size`) so the hourglass keeps its shape regardless
// of aspect. `phase` (a SceneClock time) drives the fall; frozen under Reduce
// Motion / occlusion. Helpers are local (namespace `sf`).
// ============================================================================

namespace sf {

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
    for (int i = 0; i < 4; i++) { v += amp * vnoise(p); p = p * 2.0 + float2(11.3, 7.7); amp *= 0.5; }
    return v;
}

} // namespace sf

// ----------------------------------------------------------------------------------
[[ stitchable ]]
half4 sandField(float2 pos, half4 color,
                float phase, float2 size,
                float prog, float3 sand) {
    using namespace sf;

    float W = size.x, H = size.y;
    float2 uv = pos / size;

    // Deep base.
    float3 col = mix(float3(0.04, 0.05, 0.11), float3(0.015, 0.02, 0.05), uv.y);

    float px = pos.x, py = pos.y;
    float cx = 0.5 * W;
    float yTop = 0.18 * H, yNeck = 0.50 * H, yBot = 0.82 * H;
    float hw = 0.24 * W;                                   // half-width at the bulb mouths
    float dx = abs(px - cx);

    float p = clamp(prog, 0.0, 1.0);

    // Bulb edge half-widths at this height (hw at the mouth → 0 at the neck).
    float topHW = hw * (yNeck - py) / (yNeck - yTop);
    float botHW = hw * (py - yNeck) / (yBot - yNeck);

    // Sand surfaces: top drains toward the neck, bottom mounds up from the base, as `p` rises.
    float surfaceY = yNeck - (1.0 - p) * (yNeck - yTop);
    float fillY    = yBot  - p * (yBot - yNeck);

    // --- sand fills (FBM-granular) ---
    float sandMask = 0.0;
    if (py >= yTop && py <= yNeck && dx <= topHW && py >= surfaceY) sandMask = 1.0;   // top bulb
    if (py >= yNeck && py <= yBot && dx <= botHW && py >= fillY)    sandMask = 1.0;   // bottom mound
    float grain = 0.72 + 0.56 * fbm(pos * 0.06);          // granular texture, not a flat fill
    // Animated sparkle so the settled sand shimmers with life instead of sitting dead-flat — Focus
    // wants energy, so the piles glint rather than lie static.
    float sparkle = pow(fbm(pos * 0.14 + float2(0.0, phase * 6.0)), 4.0);
    col += sand * sandMask * (0.40 * grain + 0.9 * sparkle);

    // --- falling column through the neck (running & mid-interval) ---
    if (p > 0.02 && p < 0.98) {
        float streamTop = yNeck;
        float streamBot = max(fillY, yNeck + 2.0);
        if (py > streamTop && py < streamBot && dx < W * 0.03) {
            // Faster, denser, brighter cascade — the most kinetic part of the scene should read.
            float nz = fbm(float2(px * 0.6, (py - phase * 190.0) * 0.10));
            float centre = smoothstep(W * 0.03, 0.0, dx);
            col += (sand + float3(0.10)) * smoothstep(0.35, 0.85, nz) * centre * 0.85;
        }
    }

    // --- faint hourglass frame (procedural triangle outline) ---
    float fw = 1.2;                                        // frame line half-width, px
    float edgeTop = (py >= yTop && py <= yNeck) ? smoothstep(fw, 0.0, abs(dx - topHW)) : 0.0;
    float edgeBot = (py >= yNeck && py <= yBot) ? smoothstep(fw, 0.0, abs(dx - botHW)) : 0.0;
    float capTop  = (abs(py - yTop) < fw && dx <= hw) ? 1.0 : 0.0;
    float capBot  = (abs(py - yBot) < fw && dx <= hw) ? 1.0 : 0.0;
    float frame = max(max(edgeTop, edgeBot), max(capTop, capBot));
    col += float3(0.55, 0.62, 0.80) * frame * 0.30;

    col = col / (col + 0.85);                              // filmic roll-off
    col += (hash21(pos + fmod(phase, 64.0)) - 0.5) / 255.0;   // dither
    return half4(half3(saturate(col)), 1.0h);
}
