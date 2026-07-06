import SwiftUI

/// Still Water — **Depth Edition**. The ocean generalization of the rain-glass depth recipe
/// (RAIN-ON-GLASS-DEPTH-SPEC §2 named ocean — "near swell / hazy horizon" — as the recipe's first
/// generalization). Proves the depth toolkit is a toolkit, not a one-off: it reuses the shared
/// `.layerEffect` host (`DepthBackdrop`) and the shared reactivity vocabulary (`DepthReactivity`, F1)
/// that the rain-depth scene uses — a second consumer, exactly the trigger that justified the host.
///
/// A thin wrapper over `DepthBackdrop` (same shape as `AuroraMetalView` over `ShaderBackdrop`). This
/// view supplies the composited FAR WORLD — a night sky: dark gradient, a soft moon glow, a hazy
/// horizon band — and the A/B knobs. `StillWaterLens.metal` builds the water as a wave-distorted
/// **reflection** of that sky: near-sharp swell in the foreground, a soft near-mirror at the horizon
/// (the focus gap = depth), the moon rippling inverted in the water.
///
/// Reactive depth (P2/F1): as `nightProgress` rises the swell calms, the horizon fogs, and the
/// reflection softens; motion eases to half speed via the host's `SceneClock` rate (`nightSlowdown`).
/// The curves are unit-tested off-device; the *look* is on-device A/B (P1 gate) — start from
/// `refraction`/`swellBase` here, the rest in `StillWaterLens.metal`.
///
/// Registered as a DEBUG-only A/B sibling of `StillWaterScene`; retire the flat `.colorEffect` still
/// water if the depth version wins on look + power over a full timer run (§10).
struct StillWaterDepthView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Read live (not observed) so the pond stills as the night progresses.
    var sleepTimer: SleepTimerService? = nil

    // ---- on-device A/B knobs (edit + rebuild — spec §10 step 4) ----------------------
    // refraction 0 → flat mirror (proves the reflection seam, §10 step 2);
    //            1 → full swell distortion (the "whoa", §10 step 3).
    // swellBase     → bedtime wave amplitude; F1 calms it toward night.
    private let refraction: Double = 1.0
    private let swellBase: Double = 0.6

    var body: some View {
        // The reflection reaches across the horizon (a foreground water pixel samples the high sky),
        // so maxSampleOffset must cover the full frame height. Horizontal displacement is tiny.
        DepthBackdrop(
            paused: paused,
            nightSlowdown: 0.5,        // pond drift eases to half speed by timer end (matches still water)
            sleepTimer: sleepTimer,
            maxSampleOffset: CGSize(width: 100, height: 1000),
            shaderName: "stillWaterLens",
            farWorld: { size in farWorld(size: size) }
        ) { s in
            // Reactive depth (P2): DepthReactivity (F1) maps nightProgress → swell (density) / fog /
            // defocus. Bedtime base = the swell knob, clear horizon (fog 0), sharp reflection (defocus 1).
            let r = DepthReactivity.at(
                night: s.night,
                base: DepthReactivity.Base(density: Float(swellBase), fog: 0, defocus: 1))
            return ShaderLibrary.stillWaterLens(
                .float(s.phase),
                .float2(s.size),
                .float(refraction),
                .float(r.density),      // swell amplitude
                .float(r.fog),
                .float(r.defocus)
            )
        }
    }

    // MARK: - The far world: a night sky the water reflects (static; baked once by the host)

    private func farWorld(size: CGSize) -> some View {
        ZStack {
            // Sky gradient: near-black at the top, faintly lifted toward the horizon.
            LinearGradient(colors: [Self.skyTop, Self.skyHorizon],
                           startPoint: .top, endPoint: .bottom)

            // Moon: a soft disc + a wide halo — the bright thing the water reflects. Positioned to
            // match the shader's MOONX column; y matches the old still-water moon (high in the sky).
            RadialGradient(colors: [Self.moon, Self.moon.opacity(0)],
                           center: UnitPoint(x: 0.5, y: 0.16),
                           startRadius: 0, endRadius: size.width * 0.05)
                .blendMode(.screen)
            RadialGradient(colors: [Self.moonHalo.opacity(0.16), .clear],
                           center: UnitPoint(x: 0.5, y: 0.16),
                           startRadius: 0, endRadius: size.width * 0.5)
                .blendMode(.screen)

            // A faint hazy band just above the horizon line — the distance glow the reflection catches.
            Ellipse()
                .fill(Color.white.opacity(0.03))
                .frame(width: size.width * 1.5, height: size.height * 0.10)
                .blur(radius: 40)
                .position(x: size.width * 0.5, y: size.height * 0.40)
                .blendMode(.screen)
        }
    }

    // MARK: - Palette (cool night)

    private static let skyTop     = Color(red: 0.02,  green: 0.03,  blue: 0.06)
    private static let skyHorizon = Color(red: 0.05,  green: 0.07,  blue: 0.12)
    private static let moon       = Color(red: 0.85,  green: 0.90,  blue: 1.0)
    private static let moonHalo   = Color(red: 0.40,  green: 0.55,  blue: 0.85)
}
