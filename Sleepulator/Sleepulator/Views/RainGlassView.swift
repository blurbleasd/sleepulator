import SwiftUI

/// A stylized "rain on glass" backdrop for Sleep mode: soft blurred lights behind a misted
/// window, with droplets sliding down the glass leaving faint trails. Generative + cheap —
/// the moving drops are one `TimelineView`/`Canvas` redraw loop (capped ~30 fps). It keeps
/// raining the whole time you're watching (right through the controls-faded screensaver) and
/// freezes to the still misted glass only once the deep night-dim veil has occluded the screen
/// (`paused`), so it's never a wasted redraw. Gentle by design; runs regardless of system
/// Reduce Motion.
struct RainGlassView: View {
    /// True only when the screen is occluded by the deep night-dim veil — freeze for battery.
    var paused: Bool = false
    /// The sleep timer, read *live* (not observed) inside the redraw so the rain eases off as
    /// the night progresses. Plain property on purpose — observing it here would re-render the
    /// whole scene every tick (the `rmsPower`/`@Published` storm CLAUDE.md warns about).
    var sleepTimer: SleepTimerService? = nil

    private var active: Bool { !paused }

    // MARK: deterministic fields (fixed seeds → stable across launches)

    private struct Drop {
        let x: Double          // column, 0…1
        let speed: Double      // fraction of a full fall per second
        let phase: Double      // 0…1 start offset
        let r: Double          // head radius, pt
        let len: Double        // trail length, pt
        let wobAmp: Double     // sideways meander, pt
        let wobFreq: Double
        let opacity: Double
    }
    private struct Speck { let x, y, r, opacity: Double }
    private struct Bokeh { let x, y, r: Double; let color: Color }

    private static let warm = Color(red: 1.0, green: 0.82, blue: 0.55)
    private static let cool = Color(red: 0.6, green: 0.78, blue: 1.0)

    private static func rng(_ seed: UInt64) -> () -> Double {
        var s = seed
        return {
            s ^= s << 13; s ^= s >> 7; s ^= s << 17
            return Double(s % 1_000_000) / 1_000_000.0
        }
    }

    // ~16 drops: mostly slow clingers, a few quicker runners (pow biases toward slow).
    private static let drops: [Drop] = {
        let n = rng(0x2A11DEADBEEF0042)
        return (0..<16).map { _ in
            Drop(x: n(),
                 speed: 0.035 + pow(n(), 2.0) * 0.16,   // ~6–28s to fall
                 phase: n(),
                 r: 1.5 + n() * 2.5,
                 len: 24 + n() * 84,
                 wobAmp: 1.5 + n() * 5.0,
                 wobFreq: 0.15 + n() * 0.4,
                 opacity: 0.16 + n() * 0.30)
        }
    }()

    // Fine static droplets clinging to the glass — the misted-window texture.
    private static let specks: [Speck] = {
        let n = rng(0x5EED0FFEE5C0FFEE)
        return (0..<72).map { _ in
            Speck(x: n(), y: n(), r: 0.5 + n() * 1.3, opacity: 0.03 + n() * 0.10)
        }
    }()

    // Out-of-focus lights behind the window, low and dim.
    private static let bokeh: [Bokeh] = {
        let n = rng(0xB0BACAFE12345678)
        return (0..<5).map { _ in
            Bokeh(x: 0.12 + n() * 0.76,
                  y: 0.42 + n() * 0.46,
                  r: 56 + n() * 120,
                  color: n() < 0.5 ? warm : cool)
        }
    }()

    var body: some View {
        ZStack {
            // Cold near-black glass.
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.03, blue: 0.05),
                         Color(red: 0.04, green: 0.05, blue: 0.09)],
                startPoint: .top, endPoint: .bottom)

            // Blurred lights behind the glass — they dim out as the night settles, leaving a
            // dark fogged pane (isolated 1 Hz leaf; the animating drops dim separately, live).
            if let timer = sleepTimer {
                NightFade(timer: timer, maxDim: 0.9) { bokehLights }
            } else {
                bokehLights
            }

            // Static misted-glass specks (drawn once, not per frame).
            Canvas { ctx, size in
                for s in Self.specks {
                    let rect = CGRect(x: s.x * size.width - s.r, y: s.y * size.height - s.r,
                                      width: s.r * 2, height: s.r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(.white.opacity(s.opacity)))
                }
            }

            // Running drops — the only animated layer; removed (not just hidden) when it
            // settles, so there's no redraw loop on an all-night screen.
            if active {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    // Sample nightProgress fresh each tick — live read, no observation.
                    let night = sleepTimer?.nightProgress ?? 0
                    Canvas { ctx, size in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        for d in Self.drops { Self.draw(d, ctx: ctx, size: size, t: t, night: night) }
                    }
                }
                .blur(radius: 0.4)                 // a touch of wet-glass softness
                .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: active)
    }

    /// Out-of-focus warm/cool lights behind the pane. Extracted so the night-fade leaf can dim
    /// them without observing the timer from the parent.
    private var bokehLights: some View {
        GeometryReader { geo in
            ForEach(0..<Self.bokeh.count, id: \.self) { i in
                let b = Self.bokeh[i]
                Circle()
                    .fill(b.color)
                    .frame(width: b.r, height: b.r)
                    .blur(radius: b.r * 0.5)
                    .opacity(0.20)
                    .position(x: b.x * geo.size.width, y: b.y * geo.size.height)
            }
        }
    }

    /// - Parameter night: `nightProgress` (0 at the start of a sleep timer, →1 as it expires;
    ///   0 when idle). As it rises the rain eases off — each drop fades over a window, with
    ///   higher-`phase` drops retiring first, so the glass thins gradually to a still pane.
    ///   The fall *rate* is left untouched (scaling absolute `t` would jump the drop) — the
    ///   thinning alone reads as the rain letting up.
    private static func draw(_ d: Drop, ctx: GraphicsContext, size: CGSize, t: Double, night: Double = 0) {
        let p = min(1, max(0, night))
        // Per-drop fade window (~0.3 wide); larger-phase drops stop sooner. 0 → fully retired.
        let fade = max(0.0, min(1.0, (1.0 - p - d.phase * 0.7) / 0.3))
        if fade <= 0.001 { return }
        let op = d.opacity * fade

        let fall = size.height + 80
        let cycle = (t * d.speed + d.phase).truncatingRemainder(dividingBy: 1.0)
        let y = pow(cycle, 1.3) * fall - 40          // accelerate as it slides (off-screen wrap)
        let x = d.x * size.width + sin(t * d.wobFreq + d.phase * 6.283) * d.wobAmp

        // Trail: a fading capsule above the head.
        let trail = Path(roundedRect: CGRect(x: x - d.r * 0.5, y: y - d.len, width: d.r, height: d.len),
                         cornerRadius: d.r * 0.5)
        ctx.fill(trail, with: .linearGradient(
            Gradient(colors: [.white.opacity(0), .white.opacity(op * 0.5)]),
            startPoint: CGPoint(x: x, y: y - d.len), endPoint: CGPoint(x: x, y: y)))

        // Head + a small catch-light.
        ctx.fill(Path(ellipseIn: CGRect(x: x - d.r, y: y - d.r, width: d.r * 2, height: d.r * 2)),
                 with: .color(.white.opacity(op)))
        ctx.fill(Path(ellipseIn: CGRect(x: x - d.r * 0.4, y: y - d.r * 0.7,
                                        width: d.r * 0.6, height: d.r * 0.6)),
                 with: .color(.white.opacity(op * 0.7)))
    }
}
