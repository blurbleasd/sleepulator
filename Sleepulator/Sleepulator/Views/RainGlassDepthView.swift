import SwiftUI

/// Rain on Glass — **Depth Edition**. The depth evolution of `RainGlassView`: a near-black
/// window whose droplets are real lenses, each bending an inverted, magnified pinch of the
/// bright lights behind the glass. Plan of record: RAIN-ON-GLASS-DEPTH-SPEC.md.
///
/// Composition (far → near), per spec §6.1:
///   0. near-black sky/glass gradient (OLED-dark base),
///   1. a BRIGHT, soft bokeh field — brightened + densified from the old 5 dim blobs so most
///      drops have a light to refract (§6.1 prerequisite, not polish),
///   2. a low band of distant windows/streetlights + faint haze,
///   3+4. condensation + droplets — generated in the `RainGlass.metal` lens shader, which is
///      attached as a `.layerEffect` to the composited far world (the one layer it may sample).
///
/// The far world is drawn once with radial-gradient falloff (no per-frame `.blur`) and flattened
/// via `drawingGroup()`, so the background blur is **baked once**, not a Gaussian per pixel per
/// frame (§6.2 battery trap). The only animated cost is the shader, driven by one `TimelineView`.
///
/// Settle (§6.1): when `paused` the `TimelineView` is **dropped entirely** — one static render
/// pass, no redraw loop on the all-night occluded screen. Not a `settle=1` uniform.
///
/// A/B: registered alongside the shipping `RainOnGlassScene` (DEBUG only) so it can be compared
/// on device. Tune `refraction` / `density` here, the rest in `RainGlass.metal`.
struct RainGlassDepthView: View {
    /// True only when the deep night-dim veil has occluded the screen — freeze for battery.
    var paused: Bool = false
    /// Warm key for Sleep; a cool key is possible later for a Focus "rain (day)" variant.
    var warm: Bool = true

    // ---- on-device A/B knobs (edit + rebuild — spec §10 step 4) ----------------------
    // refraction 0 → flat tinted beads (proves the shader seam, §10 step 2);
    //            1 → full droplet-as-lens (the "whoa", §10 step 3).
    // density       → fraction of grid cells carrying a clinger bead.
    private let refraction: Double = 1.0
    private let density: Double = 0.55

    @State private var motion = RainGlassMotion()
    @State private var t0 = Date().timeIntervalSinceReferenceDate   // elapsed stays Float-precise all night

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Settle = stop the loop, not a frozen uniform (§6.1): no TimelineView when paused.
            if paused {
                lensed(size: size, t: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    lensed(size: size, t: tl.date.timeIntervalSinceReferenceDate - t0)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
        .onAppear { if !paused { motion.start() } }
        .onDisappear { motion.stop() }
        .onChange(of: paused) { _, nowPaused in
            if nowPaused { motion.stop() } else { motion.start() }
        }
    }

    /// The far world with the droplet-as-lens shader attached. `maxSampleOffset` must cover the
    /// farthest the lens reaches from a pixel (rim bend + magnify across the bead + gyro shift).
    @ViewBuilder
    private func lensed(size: CGSize, t: Double) -> some View {
        let g = motion.tilt
        farWorld(size: size)
            .layerEffect(
                ShaderLibrary.rainGlassLens(
                    .float(t),
                    .float2(size),
                    .float2(g.x, g.y),
                    .float(refraction),
                    .float(density)
                ),
                maxSampleOffset: CGSize(width: 64, height: 64)
            )
    }

    // MARK: - The far world (static; blur baked into the gradient falloff, flattened once)

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
        .frame(width: size.width, height: size.height)
        .drawingGroup()   // flatten the far world to one cached texture (bake the blur once)
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
