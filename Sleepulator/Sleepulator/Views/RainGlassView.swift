import SwiftUI

/// A stylized "rain on glass" backdrop for Sleep mode: soft blurred lights behind a misted
/// window, with droplets sliding down the glass leaving faint trails. Generative + cheap —
/// the moving drops are one `TimelineView`/`Canvas` redraw loop (capped ~30 fps). It keeps
/// raining the whole time you're watching (right through the controls-faded screensaver) and
/// freezes to the still misted glass only once the deep night-dim veil has occluded the screen
/// (`paused`), so it's never a wasted redraw. Gentle by design; runs regardless of system
/// Reduce Motion.
struct RainGlassView: View {
    /// Hold still: the screen is out of sight, or "Moving scenes" is off (`SceneContext.paused`).
    var paused: Bool = false
    /// The screen itself is out of sight (not just "Moving scenes" off): the bokeh's fade stops
    /// re-reading the night (see `SceneContext.occluded`).
    var occluded: Bool = false
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
        let wobAmp: Double     // sideways meander, pt (follows the drop's height)
        let opacity: Double
    }
    private struct Speck { let x, y, r, opacity: Double }
    private struct Bokeh { let x, y, r: Double; let color: Color }

    // Every light here is warm, Sleep's dusk: amber and a deeper ember behind the glass, cream water
    // on it. (Half the bokeh were a cool blue and the drops pure white, the coolest light in Sleep.)
    private static let warm = Color(red: 1.0, green: 0.82, blue: 0.55)
    private static let ember = Color(red: 0.95, green: 0.55, blue: 0.36)
    private static let water = Color(red: 1.0, green: 0.88, blue: 0.72)

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
            let x = n(), speed = 0.035 + pow(n(), 2.0) * 0.16   // ~6–28s to fall
            let phase = n(), r = 1.5 + n() * 2.5, len = 24 + n() * 84
            let wobAmp = 1.5 + n() * 5.0
            _ = n()   // a retired wobble-rate draw, kept so the seeded layout stays the same
            return Drop(x: x, speed: speed, phase: phase, r: r, len: len, wobAmp: wobAmp,
                        opacity: 0.12 + n() * 0.22)
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
                  color: n() < 0.5 ? warm : ember)
        }
    }()

    var body: some View {
        ZStack {
            // Warm near-black glass (Sleep's dusk, not a cold blue pane).
            LinearGradient(
                colors: [Color(red: 0.035, green: 0.026, blue: 0.022),
                         Color(red: 0.055, green: 0.040, blue: 0.030)],
                startPoint: .top, endPoint: .bottom)

            // Blurred lights behind the glass — they dim out as the night settles, leaving a
            // dark fogged pane (isolated 1 Hz leaf; the animating drops dim separately, live).
            if let timer = sleepTimer {
                NightFade(timer: timer, maxDim: 0.9, occluded: occluded) { bokehLights }
            } else {
                bokehLights
            }

            // Static misted-glass specks (drawn once, not per frame).
            Canvas { ctx, size in
                for s in Self.specks {
                    let rect = CGRect(x: s.x * size.width - s.r, y: s.y * size.height - s.r,
                                      width: s.r * 2, height: s.r * 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(Self.water.opacity(s.opacity)))
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

    /// Out-of-focus warm (amber / ember) lights behind the pane. Extracted so the night-fade leaf can dim
    /// them without observing the timer from the parent.
    private var bokehLights: some View {
        GeometryReader { geo in
            ForEach(0..<Self.bokeh.count, id: \.self) { i in
                let b = Self.bokeh[i]
                Circle()
                    .fill(b.color)
                    .frame(width: b.r, height: b.r)
                    .blur(radius: b.r * 0.5)
                    .opacity(0.17)
                    .position(x: b.x * geo.size.width, y: b.y * geo.size.height)
            }
        }
    }

    /// A drop on glass, not a streak through the air: it clings, slips a short way, and clings
    /// again, meandering only while it moves. The head is a lens (a mostly clear body, a bright
    /// meniscus along its lower edge, a pinpoint highlight up top) and behind it lies a faint wet
    /// path with a few beads left on the pane. The old drop slid continuously with a bright
    /// head and a fading tail, which read as meteors falling past a window.
    ///
    /// - Parameter night: `nightProgress` (0 at bedtime, →1 as the timer runs out or, with no
    ///   timer, as the untimed night settles; 0 in Focus). As it rises the rain eases off — each drop fades over a window, with
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
        // Stick-slip: five holds per fall, each slip taking the last 40% of its step, eased.
        let steps = 5.0
        let u = cycle * steps
        let step = u.rounded(.down)
        let s = max(0, min(1, (u - step - 0.6) / 0.4))
        let y = (step + s * s * (3 - 2 * s)) / steps * fall - 40
        // The meander follows the drop's height, so a clinging drop holds still.
        func xAt(_ yy: Double) -> Double {
            d.x * size.width + sin(yy / 60 + d.phase * 6.283) * d.wobAmp
        }
        let x = xAt(y)

        // The wet path: a hair-thin line where the drop cleared the pane, and beads it left.
        let len = min(d.len, y + 40)
        if len > 2 {
            let path = Path { pp in
                for i in 0...8 {
                    let yy = y - len * Double(i) / 8
                    let pt = CGPoint(x: xAt(yy), y: yy)
                    if i == 0 { pp.move(to: pt) } else { pp.addLine(to: pt) }
                }
            }
            ctx.stroke(path, with: .color(water.opacity(op * 0.14)), lineWidth: max(0.6, d.r * 0.35))
            for k in 1...3 {
                let by = y - len * Double(k) * 0.28
                let br = d.r * (0.45 - 0.1 * Double(k))
                ctx.fill(Path(ellipseIn: CGRect(x: xAt(by) - br, y: by - br, width: br * 2, height: br * 2)),
                         with: .color(water.opacity(op * (0.45 - 0.1 * Double(k)))))
            }
        }

        // The head, a lens: a sliding drop sags a little longer than it is wide.
        let h = d.r * 2.3
        ctx.fill(Path(ellipseIn: CGRect(x: x - d.r, y: y - h * 0.5, width: d.r * 2, height: h)),
                 with: .color(water.opacity(op * 0.22)))
        ctx.fill(Path(ellipseIn: CGRect(x: x - d.r * 0.8, y: y + h * 0.12, width: d.r * 1.6, height: h * 0.32)),
                 with: .color(water.opacity(op * 0.8)))                       // meniscus
        ctx.fill(Path(ellipseIn: CGRect(x: x - d.r * 0.55, y: y - h * 0.36, width: d.r * 0.45, height: d.r * 0.45)),
                 with: .color(water.opacity(op * 0.7)))                       // highlight
    }
}
