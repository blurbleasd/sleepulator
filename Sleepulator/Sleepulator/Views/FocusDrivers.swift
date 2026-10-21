import SwiftUI

/// The single source of truth for how a Focus scene reads the Pomodoro.
///
/// Every Focus scene takes its progress position from `fill`, so Current, Tide, Sandfall and Contour
/// can't disagree about how far through the interval you are; Current and Contour also take their
/// look from `look`, while Tide and Sandfall shade their own energy and tint. Pure, so it's unit-tested (the shaders
/// and thermals are device-verified). `FocusStillFrame`, below, is how their still frames keep
/// reading it with Moving scenes off.
///
/// The numbers came from the retired Canvas `CurrentView`, so the Metal port was a true A/B:
///   work:  opacity/amplitude/speed ramp up with `progress`  → momentum
///   rest:  eased, cooler                                    → recovery
///   idle:  calm middle ground                               → not running
/// `speed` is a flow *rate* (integrated into a `SceneClock` phase by the view, per the
/// integrate-the-rate contract in ShaderBackdrop.swift), not an absolute-time multiplier.
enum FocusDrivers {
    /// Cool blue — a work interval.
    static let workTint = SIMD3<Double>(0.36, 0.62, 0.96)
    /// Teal — a break (ease).
    static let restTint = SIMD3<Double>(0.30, 0.72, 0.66)
    /// Muted blue — Pomodoro idle / not running.
    static let idleTint = SIMD3<Double>(0.40, 0.56, 0.84)

    /// The resolved look for a given Pomodoro state.
    struct Look: Equatable {
        /// Base opacity multiplier for the streams (0…1).
        var op: Double
        /// Vertical amplitude multiplier (0…1).
        var amp: Double
        /// Flow-*rate* multiplier (feed to a SceneClock, don't multiply absolute time).
        var speed: Double
        /// Stream tint, linear RGB in 0…1.
        var tint: SIMD3<Double>
    }

    /// Where the scene's POSITIONAL progress cue should sit: 0 = start of the travel, 1 = end;
    /// `nil` when there's no session and the scene should show no reading at all.
    ///
    /// This exists because the Focus scenes used to encode the Pomodoro almost entirely in
    /// *intensity* and *rate* — opacity, sway, brightness, fall speed, comet density. Those are
    /// RELATIVE channels: with no side-by-side reference the eye cannot tell 60 % bright from
    /// 80 %, so the scenes never actually told you anything about the session ("they don't speak
    /// to focus"). Position and extent are absolute and readable at a glance, so progress now
    /// rides one positional channel per scene — the waterline's height, the hourglass's fill,
    /// the front's x, the reach of Contour's light — and intensity is demoted to mere shading.
    ///
    /// A work interval FILLS (0 → 1); a break DRAINS it back (1 → 0), so a glance says both how
    /// far through you are and which kind of interval you're in. Pure, so it's unit-tested.
    static func fill(isRunning: Bool, isWork: Bool, progress: Double) -> Double? {
        guard isRunning else { return nil }
        let p = min(max(progress, 0), 1)
        return isWork ? p : 1 - p
    }

    /// Map raw Pomodoro state to the scene look. `progress` is clamped 0…1 defensively.
    static func look(isRunning: Bool, isWork: Bool, progress: Double) -> Look {
        let p = min(max(progress, 0), 1)
        if isRunning {
            if isWork {
                return Look(op: 0.55 + 0.45 * p,
                            amp: 0.70 + 0.50 * p,
                            speed: 0.85 + 0.55 * p,
                            tint: workTint)
            }
            return Look(op: 0.34, amp: 0.55, speed: 0.55, tint: restTint)
        }
        return Look(op: 0.45, amp: 0.65, speed: 0.65, tint: idleTint)
    }
}

/// A Focus scene's still frame while the screen is in sight ("Moving scenes" off, not
/// `SceneContext.occluded`). The scenes read the Pomodoro live inside their own redraw and never
/// observe it, so a bare still frame was drawn once, when Focus came up, and kept that look for the
/// whole session: the idle look, with no reading at all (simulator, 2026-10-13). This view observes
/// the Pomodoro instead, so the frame is drawn again on each of its publishes: once a second while
/// a session runs, and at once on a start, a phase change or a stop; never while idle. The pose
/// holds: the scene draws with `now: nil`, so its `SceneClock` never ticks. Isolated, like
/// `NightFade`: a publish redraws only the scene's own frame, never Home.
///
/// `content` is a closure, called in this body, so each redraw reads the Pomodoro afresh. Built in
/// the caller's body (`NightFade`'s `content: Content`), the frame would keep the caller's reading.
struct FocusStillFrame<Content: View>: View {
    @ObservedObject var pomodoro: PomodoroService
    @ViewBuilder var content: () -> Content

    var body: some View { content() }
}
