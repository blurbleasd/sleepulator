import SwiftUI

/// The single source of truth for how a Focus scene reads the Pomodoro.
///
/// Both the CPU `CurrentView` (Canvas) and the GPU `CurrentMetalView` (Metal A/B sibling) derive
/// their look from the *same* mapping here, so during the A/B the two can only differ in how they
/// render — never in how they read the session. Because it's a pure function it's also the one
/// off-device-testable seam of the Focus port (the shader + thermals are device-verified).
///
/// Numbers are lifted verbatim from `CurrentView` so the port is a true visual A/B, not a redesign:
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

        /// The tint as a SwiftUI `Color`, for the Canvas scene.
        var color: Color { Color(red: tint.x, green: tint.y, blue: tint.z) }
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
