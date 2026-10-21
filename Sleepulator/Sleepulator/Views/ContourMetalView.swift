import SwiftUI

/// "Contour" (Focus): a topographic map of a drifting mountain whose summit sits under the Focus
/// ring (`ContourShader.metal`, `contourField`), drawn as a layered relief model: each band between
/// two contour lines a sheet one step up, casting a short shadow on the one below. The lines drift
/// downhill, and light spreads down from the summit as a work interval goes on.
///
/// The look comes from the shared `FocusDrivers` mapping, sampled live each tick (never observed,
/// so the per-tick redraw can't trigger the `@Published` re-render storm CLAUDE.md warns about).
/// `ContourLight.light` is the reading: the share of the screen in light, which
/// `ContourLight.radius` turns into the light's radius. `look` sets the brightness, the tint and the
/// drift rate, which a `SceneClock` integrates (see `CurrentMetalView`). `paused` freezes the scene
/// to one static frame at the frozen pose; system Reduce Motion doesn't (SCREENSAVER-LIBRARY-SPEC §5).
struct ContourMetalView: View {
    var paused: Bool = false
    /// Read live (not observed) so phase/progress drive the look.
    let pomodoro: PomodoroService

    /// Random start so the map opens on fresh terrain each appearance.
    @State private var clock = SceneClock(start: .random(in: 0...2048))

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Unconditional TimelineView in the else branch: the `paused:` schedule variant stops
            // driving frames on ProMotion (see CurrentMetalView).
            if paused {
                field(size: size, now: nil)
            } else {
                // 30 fps, unlike Current's 60. The lines drift a few points a second, a fraction
                // of a pixel per frame even at 30, and the slope costs three terrain samples a
                // pixel, so the higher rate would buy nothing visible for twice the GPU time.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    field(size: size, now: tl.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func field(size: CGSize, now: TimeInterval?) -> some View {
        let running = pomodoro.isRunning
        let work = pomodoro.phase == .work
        // Read at this frame's time, as the Focus ring does. `progress` moves only on the
        // Pomodoro's 1 Hz tick, so the edge of the light stepped once a second (15–20 pt a step on
        // a one-minute break). A still frame reads the published value.
        let progress = now.map { pomodoro.progress(at: Date(timeIntervalSinceReferenceDate: $0)) }
            ?? pomodoro.progress
        let look = FocusDrivers.look(isRunning: running, isWork: work, progress: progress)
        let light = ContourLight.light(isRunning: running, isWork: work, progress: progress)
        let aspect = size.height > 0 ? Double(size.width / size.height) : 0
        let edge = ContourLight.radius(share: max(light, 0), aspect: aspect)
        if let now {
            clock.tick(now: now, rate: look.speed)
            SceneDiagnostics.shared.frame(now: now)
        }
        return Rectangle()
            .fill(.black)
            .colorEffect(
                ShaderLibrary.contourField(
                    .float(Float(clock.phase)),
                    .float2(size),
                    .float(Float(look.op)),
                    .float(Float(light)),
                    .float(Float(edge)),
                    .float(Float(ContourLight.reach(aspect: aspect))),
                    .float2(Float(ContourLight.summit.x), Float(ContourLight.summit.y)),
                    .float3(Float(look.tint.x), Float(look.tint.y), Float(look.tint.z))
                )
            )
    }
}

/// Where Contour's light reaches: the radius from the summit whose disc covers a given share of
/// the screen. The terrain is a cone peaking at the summit (plus noise that only wiggles the edge),
/// so lighting everything inside that radius lights that share of the screen, which is what makes
/// the light's extent a reading of the interval. Lengths are in screen heights; `aspect` is
/// width / height. Pure, so it's unit-tested.
enum ContourLight {
    /// The summit in unit screen coordinates (0…1, top-left origin): about where Focus's ring sits,
    /// so the light spreads out from under it.
    static let summit = SIMD2<Double>(0.5, 0.40)

    /// What the shader reads for a Pomodoro state: the share of the screen in light, or -1 with no
    /// session, which the shader draws as the even idle map, so the scene never implies a session
    /// that isn't running.
    static func light(isRunning: Bool, isWork: Bool, progress: Double) -> Double {
        FocusDrivers.fill(isRunning: isRunning, isWork: isWork, progress: progress) ?? -1
    }

    /// The summit's distance to the farthest corner: the radius that covers the whole screen.
    static func reach(aspect: Double) -> Double {
        let dx = max(summit.x, 1 - summit.x) * aspect
        let dy = max(summit.y, 1 - summit.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The share of the screen within `radius` of the summit, exactly: the disc split into four
    /// quarters at the summit, each clipped by its corner's rectangle in closed form. Cheap enough
    /// that the view bisects it every frame (~500 square roots and arcsines), so no lookup table.
    static func share(radius: Double, aspect: Double) -> Double {
        guard radius > 0, aspect > 0 else { return 0 }
        let cx = summit.x * aspect, cy = summit.y
        let area = quarter(width: cx, height: cy, radius: radius)
            + quarter(width: cx, height: 1 - cy, radius: radius)
            + quarter(width: aspect - cx, height: cy, radius: radius)
            + quarter(width: aspect - cx, height: 1 - cy, radius: radius)
        return min(1, area / aspect)
    }

    /// The area of a quarter disc (centred on the corner) inside a `width` × `height` rectangle:
    /// full height out to where the arc drops below the top, then the area under the arc.
    private static func quarter(width: Double, height: Double, radius r: Double) -> Double {
        // ∫₀ˣ √(r² − t²) dt
        func underArc(_ x: Double) -> Double {
            (x * (r * r - x * x).squareRoot() + r * r * asin(min(1, x / r))) / 2
        }
        let end = min(width, r)
        let fullHeight = min(end, max(0, r * r - height * height).squareRoot())
        return height * fullHeight + underArc(end) - underArc(fullHeight)
    }

    /// The radius whose disc covers `share` of the screen: 0 for none, `reach` for all.
    static func radius(share: Double, aspect: Double) -> Double {
        let far = reach(aspect: aspect)
        guard aspect > 0, share > 0 else { return 0 }
        guard share < 1 else { return far }
        var lo = 0.0, hi = far
        for _ in 0..<24 {   // bisection: 24 halvings of `reach` is far below a pixel
            let mid = (lo + hi) / 2
            if self.share(radius: mid, aspect: aspect) < share { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
