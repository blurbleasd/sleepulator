import SwiftUI

/// "Contour" (Focus): a topographic map of a drifting mountain whose summit sits under the Focus
/// ring (`ContourShader.metal`, `contourField`). Thin contour lines drift downhill over hillshading,
/// and light spreads down from the summit as a work interval goes on.
///
/// The look comes from the shared `FocusDrivers` mapping, sampled live each tick (never observed,
/// so the per-tick redraw can't trigger the `@Published` re-render storm CLAUDE.md warns about).
/// `fill` is the reading: the share of the screen in light, which `ContourLight` turns into the
/// light's radius. `look` sets the brightness, the tint and the drift rate, which a `SceneClock`
/// integrates (see `CurrentMetalView`). `paused` freezes the scene to one static frame at the
/// frozen pose; system Reduce Motion doesn't (SCREENSAVER-LIBRARY-SPEC §5).
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
        let look = FocusDrivers.look(isRunning: running, isWork: work, progress: pomodoro.progress)
        // -1: no session, so no light and no edge (the shader's idle look).
        let light = FocusDrivers.fill(isRunning: running, isWork: work, progress: pomodoro.progress) ?? -1
        let aspect = size.height > 0 ? Double(size.width / size.height) : 0
        let edge = ContourLight.radius(share: max(light, 0), aspect: aspect)
        let summit = ContourLight.summit
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
                    .float2(Float(summit.x), Float(summit.y)),
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

    /// The summit's distance to the farthest corner: the radius that covers the whole screen.
    static func reach(aspect: Double, summit: SIMD2<Double> = summit) -> Double {
        let dx = max(summit.x, 1 - summit.x) * aspect
        let dy = max(summit.y, 1 - summit.y)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The share of the screen within `radius` of the summit (midpoint rule over columns).
    static func share(radius: Double, aspect: Double, summit: SIMD2<Double> = summit) -> Double {
        guard radius > 0, aspect > 0 else { return 0 }
        let columns = 256
        let width = aspect / Double(columns)
        let cx = summit.x * aspect, cy = summit.y
        var area = 0.0
        for i in 0..<columns {
            let off = (Double(i) + 0.5) * width - cx
            let half2 = radius * radius - off * off
            guard half2 > 0 else { continue }
            let half = half2.squareRoot()
            area += (min(1, cy + half) - max(0, cy - half)) * width
        }
        return min(1, area / aspect)
    }

    /// The radius whose disc covers `share` of the screen: 0 for none, `reach` for all.
    static func radius(share: Double, aspect: Double, summit: SIMD2<Double> = summit) -> Double {
        let far = reach(aspect: aspect, summit: summit)
        guard aspect > 0, share > 0 else { return 0 }
        guard share < 1 else { return far }
        var lo = 0.0, hi = far
        for _ in 0..<24 {   // bisection: 24 halvings of `reach` is far below a pixel
            let mid = (lo + hi) / 2
            if self.share(radius: mid, aspect: aspect, summit: summit) < share { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }
}
