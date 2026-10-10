import SwiftUI

/// Pure rules for the night ember (unit-tested).
enum NightEmberMath {
    /// Farthest the ember wanders from the ring's place, in points.
    static let driftRadius: CGFloat = 3

    /// Only the Sleep screensaver, and only over a countdown: "All night" has no time left to show,
    /// and Focus's scenes carry the Pomodoro themselves.
    static func visible(screensaver: Bool, focusMode: Bool, timerActive: Bool) -> Bool {
        screensaver && !focusMode && timerActive
    }

    /// A slow, aperiodic wander within `driftRadius`, so the one lit shape left on the screen never
    /// sits on the same pixels for long (OLED burn-in). Two primes of seconds per cycle (≈5 and
    /// ≈7 minutes): the path takes hours to repeat, and moves a few hundredths of a point a second.
    static func drift(at t: TimeInterval) -> CGSize {
        CGSize(width: driftRadius * CGFloat(sin(2 * .pi * t / 317)),
               height: driftRadius * CGFloat(sin(2 * .pi * t / 431)))
    }
}

/// What's left of the night ring once the Sleep chrome fades: the night still to run, as a faint
/// ember arc in the ring's own place, so a half-open eye can read "on, about this long left"
/// without a tap that lights the room. ~8% amber, with a slightly brighter ember at its tip.
/// Observes the timer itself (like NightRing), so the 1 Hz countdown re-renders only this leaf.
struct NightEmber: View {
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette
    /// Home's screensaver is on, in Sleep (HomeView passes the mode in with it).
    let screensaver: Bool
    let focusMode: Bool

    private var shown: Bool {
        NightEmberMath.visible(screensaver: screensaver, focusMode: focusMode,
                               timerActive: sleepTimer.timerRemaining > 0)
    }

    var body: some View {
        let frac = NightRingMath.fraction(forMinutes: sleepTimer.timerRemaining / 60)
        let theta = frac * 2 * .pi
        let radius = (NightRing.ringSize - NightRing.line) / 2
        ZStack {
            Circle()
                .trim(from: 0, to: CGFloat(frac))
                .stroke(pal.accent.opacity(0.08), style: StrokeStyle(lineWidth: NightRing.line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: NightRing.ringSize, height: NightRing.ringSize)
            Circle()
                .fill(pal.accent.opacity(0.16))
                .frame(width: 6, height: 6)
                .blur(radius: 1.5)
                .offset(x: radius * sin(theta), y: -radius * cos(theta))
        }
        .offset(NightEmberMath.drift(at: Date().timeIntervalSinceReferenceDate))
        .opacity(shown ? 1 : 0)
        .animation(.easeInOut(duration: 0.9), value: shown)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
