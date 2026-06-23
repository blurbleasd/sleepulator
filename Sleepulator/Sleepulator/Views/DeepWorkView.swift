import SwiftUI

/// "Deep work" (Focus): a near-minimal cool field with a slow breath. Pomodoro-reactive — it's
/// crispest and brightest in the middle of a work interval and softens toward the boundaries, so
/// the rhythm of the session is *felt* rather than announced. The calmest, lowest-distraction
/// Focus backdrop. A couple of blurred gradients on one TimelineView loop; freezes when occluded.
struct DeepWorkView: View {
    var paused: Bool = false
    let pomodoro: PomodoroService

    private static let workTint = Color(red: 0.40, green: 0.64, blue: 0.98)  // cool blue
    private static let restTint = Color(red: 0.32, green: 0.74, blue: 0.68)  // teal (ease)
    private static let idleTint = Color(red: 0.42, green: 0.58, blue: 0.86)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.035, green: 0.05, blue: 0.11),
                                    Color(red: 0.015, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            if paused {
                field(at: 0)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                    field(at: tl.date.timeIntervalSinceReferenceDate)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func field(at t: Double) -> some View {
        let running = pomodoro.isRunning
        let work = pomodoro.phase == .work
        let prog = pomodoro.progress
        // Crispness peaks mid-session (sin is 0 at the ends, 1 at the middle), low + steady idle.
        let crisp = running ? sin(prog * .pi) : 0.4
        let tint = running ? (work ? Self.workTint : Self.restTint) : Self.idleTint
        // A slow breath keeps it alive without reading as motion you track.
        let pulse = 0.5 + 0.5 * sin(t * 0.10)
        let intensity = 0.16 + 0.34 * crisp

        return GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.22 * intensity / 0.5 + 0.04), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.6))
                    .frame(width: d * 1.5, height: d * 1.5)
                    .blur(radius: 60)
                Circle()
                    .fill(RadialGradient(colors: [tint.opacity(0.3 * intensity / 0.5), .clear],
                                         center: .center, startRadius: 0, endRadius: d * 0.32))
                    .frame(width: d * 0.7, height: d * 0.7)
                    .blur(radius: 26)
            }
            .scaleEffect(0.9 + 0.1 * pulse + 0.06 * crisp)
            .opacity(0.55 + 0.45 * pulse)
            .position(x: geo.size.width / 2, y: geo.size.height * 0.46)
        }
    }
}
