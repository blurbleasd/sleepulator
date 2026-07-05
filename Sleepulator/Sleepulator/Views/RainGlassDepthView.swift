import SwiftUI

/// Rain on Glass — **Depth Edition**. The depth evolution of `RainGlassView`: a near-black window
/// whose droplets are real lenses, each bending an inverted, magnified pinch of the bright lights
/// behind the glass. Plan of record: RAIN-ON-GLASS-DEPTH-SPEC.md.
///
/// A thin wrapper over `DepthBackdrop` (the `.layerEffect` sibling of `ShaderBackdrop`), which owns
/// the redraw loop, the `SceneClock` night-slowdown, the `sleepTimer` reactive seam, and the settle.
/// This view supplies only the composited far world + the two on-device A/B knobs — the same
/// wrapper shape as `AuroraMetalView` over `ShaderBackdrop`.
///
/// Composition (far → near), per spec §6.1:
///   0. near-black sky/glass gradient (OLED-dark base),
///   1. a BRIGHT, soft bokeh field — brightened + densified from the old 5 dim blobs so most drops
///      have a light to refract (§6.1 prerequisite, not polish),
///   2. a low band of distant windows/streetlights + faint haze,
///   3+4. condensation + droplets — generated in the `RainGlass.metal` lens shader, attached by the
///      host as a `.layerEffect` to this composited far world (the one layer it may sample, §6.0).
///
/// The far world is drawn once with radial-gradient falloff (no per-frame `.blur`); the host flattens
/// it via `drawingGroup()`, so the background blur is **baked once**, not a Gaussian per pixel per
/// frame (§6.2 battery trap). The only animated cost is the shader, driven by the host's `TimelineView`.
///
/// Settle (§6.1): the host's `TimelineView(paused:)` stops the loop when `paused` and renders one
/// static pass at the frozen `SceneClock` pose — no redraw loop on the occluded all-night screen, and
/// no `t: 0` snap back to birth pose (the bug the depth-host was built to fix).
///
/// Reactive depth (P2): as `nightProgress` rises the rain eases to half speed (`nightSlowdown: 0.5`,
/// applied via the host's `SceneClock` rate), the mist thins, the dry glass fogs, and the far world
/// defocuses further. The shared `DepthReactivity` (F1) maps night → those knobs; the `makeShader`
/// closure hands them to `RainGlass.metal` as the `density` / `fogAmt` / `defocus` uniforms. The
/// curves are tunable + unit-tested off-device; the *look* is on-device A/B (P1 gate).
struct RainGlassDepthView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Warm key for Sleep; a cool key is possible later for a Focus "rain (day)" variant.
    var warm: Bool = true
    /// Read live (not observed) inside the redraw so the rain settles as the night progresses (P2).
    var sleepTimer: SleepTimerService? = nil
    /// Smoothed gyro tilt (x = roll, y = pitch), sampled live for the far-world parallax bonus.
    var tilt: (() -> SIMD2<Float>)? = nil

    // ---- on-device A/B knobs (edit + rebuild — spec §10 step 4) ----------------------
    // refraction 0 → flat tinted beads (proves the shader seam, §10 step 2);
    //            1 → full droplet-as-lens (the "whoa", §10 step 3).
    // density       → fraction of grid cells carrying a clinger bead.
    private let refraction: Double = 1.0
    private let density: Double = 0.55

    var body: some View {
        // maxSampleOffset must cover the farthest the lens reaches from a pixel: the shader's
        // inverted-lens interior samples up to `LENS_VIEW` (0.20 × layer height ≈ 175 pt on a 6.7")
        // away, plus rim bend + gyro shift — 220 covers it with margin.
        DepthBackdrop(
            paused: paused,
            nightSlowdown: 0.5,        // rain eases to half speed by timer end (matches Aurora)
            sleepTimer: sleepTimer,
            tilt: tilt,
            maxSampleOffset: CGSize(width: 220, height: 220),
            farWorld: { size in farWorld(size: size) }
        ) { s in
            // Reactive depth (P2): the shared DepthReactivity vocabulary (F1) maps nightProgress →
            // thinned mist + fogged glass + defocused far world. Bedtime base = the A/B `density`
            // knob, clear glass (fog 0), no extra blur (defocus 1).
            let r = DepthReactivity.at(
                night: s.night,
                base: DepthReactivity.Base(density: Float(density), fog: 0, defocus: 1))
            return ShaderLibrary.rainGlassLens(
                .float(s.phase),
                .float2(s.size),
                .float2(s.gyro.x, s.gyro.y),
                .float(refraction),
                .float(r.density),
                .float(r.fog),
                .float(r.defocus)
            )
        }
    }

    // MARK: - The far world (static; blur baked into the gradient falloff, flattened by the host)

    private func farWorld(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [Self.skyTop, Self.skyBottom],
                           startPoint: .top, endPoint: .bottom)

            // Bright, soft bokeh + a low band of distant windows — drawn as radial gradients
            // (inherently soft, no separable blur pass). `.screen` so the lights glow over the
            // dark glass. Static → SwiftUI caches it; the shader samples it every frame.
            Canvas { ctx, csize in Self.drawBokeh(ctx, csize, warm: warm) }
                .blendMode(.screen)

            // A faint volumetric haze band (one baked blur, drawn once).
            Ellipse()
                .fill(Color.white.opacity(0.022))
                .frame(width: size.width * 1.4, height: size.height * 0.30)
                .blur(radius: 60)
                .position(x: size.width * 0.5, y: size.height * 0.62)
                .blendMode(.screen)
        }
    }

    // MARK: - Deterministic bokeh field (fixed seed → stable across launches)

    private struct Blob { let x, y, r, op: Double; let warmish: Bool }

    private static let warmLight = Color(red: 1.0,  green: 0.80, blue: 0.52)
    private static let coolLight = Color(red: 0.62, green: 0.80, blue: 1.0)
    private static let skyTop    = Color(red: 0.015, green: 0.020, blue: 0.035)
    private static let skyBottom = Color(red: 0.030, green: 0.035, blue: 0.060)

    private static func rng(_ seed: UInt64) -> () -> Double {
        var s = seed
        return {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s % 1_000_000) / 1_000_000.0
        }
    }

    private static let blobs: [Blob] = {
        let n = rng(0xB0BACAFE_12345678)
        var out: [Blob] = []
        // A NIGHT window: mostly black, with brightness living in small, bright, distant
        // lights — not a full bokeh wash (that read like a backlit glass of soda, and an
        // all-night-bright screen is wrong for OLED). A few faint, larger far glows give
        // depth without lighting the room…
        for _ in 0..<5 {
            out.append(Blob(x: 0.10 + n() * 0.80, y: 0.16 + n() * 0.44,
                            r: 34 + n() * 56, op: 0.07 + n() * 0.09, warmish: n() < 0.7))
        }
        // …and small, bright streetlight/window points, concentrated low in the frame, so
        // every drop that crosses one bends a vivid light (the lens), while the rest of the
        // glass stays dark. Brightness is in tiny spots, never spread across the pane.
        for _ in 0..<18 {
            out.append(Blob(x: 0.05 + n() * 0.90, y: 0.46 + n() * 0.50,
                            r: 6 + n() * 24, op: 0.50 + n() * 0.42, warmish: n() < 0.82))
        }
        return out
    }()

    private static func drawBokeh(_ ctx: GraphicsContext, _ size: CGSize, warm: Bool) {
        for b in blobs {
            // In the warm (Sleep) key, warm-ish blobs are amber and the rest cool; a cool key
            // would swap them. Keeps the field mostly warm with a few cool lights for depth.
            let base: Color = (b.warmish == warm) ? warmLight : coolLight
            let cx = b.x * size.width, cy = b.y * size.height
            let rect = CGRect(x: cx - b.r, y: cy - b.r, width: b.r * 2, height: b.r * 2)
            ctx.fill(Path(ellipseIn: rect),
                     with: .radialGradient(
                        Gradient(colors: [base.opacity(b.op), base.opacity(0)]),
                        center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: b.r))
        }
    }
}
