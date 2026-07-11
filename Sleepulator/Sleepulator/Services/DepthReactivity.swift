import Foundation

/// The shared "depth reactivity" vocabulary — one pure mapping from the sleep timeline
/// (`nightProgress`, 0 at bedtime → 1 at timer end) to the depth knobs every reactive depth
/// scene interprets. Pure + `Equatable` so the curves are unit-tested off-device (the one thing
/// the device ritual can't give); a scene passes its bedtime `Base`, reads the eased result each
/// frame, and hands the values to its lens shader as uniforms.
///
/// The *shape* is shared so the catalog (rain, ocean, …) reads authored, not assembled: as the
/// night deepens, every depth scene thins, fogs, and defocuses on the same curve. The exact
/// coefficients are art direction — tune them on device (they're the `static let`s below).
///
/// The fourth axis, **motion slowdown**, is deliberately NOT a per-frame output here: it's a scene
/// constant fed to the host as `DepthBackdrop.nightSlowdown` and applied via the `SceneClock` rate
/// (`1 − nightSlowdown × night`), because it modulates the animation clock, not a shader uniform.
/// Documented here so the vocabulary is complete in one place.
///
/// ```
///  nightProgress 0 ───────────────────────────────────▶ 1
///   density   base ──────── thins (× 1 − densityThin·e) ──▶ ~45% base
///   fog       base ──────── rises (+ fogRise·e, ≤ 1) ─────▶ fogged glass
///   defocus   base ──────── widens (+ defocusRise·e) ─────▶ softer far world
///   motion    full ──────── eases (host rate) ────────────▶ slowed   (via nightSlowdown)
///   (e = smoothstep(night): gentle early, settled late)
/// ```
struct DepthReactivity: Equatable {
    /// Bedtime (night = 0) parameters a scene hands in; the reaction eases away from these.
    struct Base: Equatable {
        /// Rain / mist / particle amount at bedtime (the scene's A/B density knob).
        var density: Float
        /// Condensation / haze opacity at bedtime (0 = clear glass).
        var fog: Float
        /// Far-world blur multiplier at bedtime (1 = the baked base blur, no extra defocus).
        var defocus: Float
    }

    // ---- night-varying outputs (uniforms for the lens shader) ------------------------
    /// Thinned rain / mist amount.
    var density: Float
    /// Risen glass fog opacity, clamped to 0…1.
    var fog: Float
    /// Widened far-world blur multiplier (≥ `base.defocus`).
    var defocus: Float

    // ---- tunables (edit here or on device) -------------------------------------------
    /// How far the rain thins by full night (0.55 → down to ~45% of bedtime density).
    static let densityThin: Float = 0.55
    /// How much fog the full night adds on top of the bedtime base.
    static let fogRise: Float = 0.55
    /// How much extra blur the full night adds to the far world.
    static let defocusRise: Float = 1.4

    /// The mapping. `rawNight` is clamped to 0…1; every output is monotonic in night. The ease is
    /// `smoothstep` so the change is gentle early (you're just settling) and only fully arrives late
    /// (you're under), rather than ramping linearly through the middle of the run.
    static func at(night rawNight: Float, base: Base) -> DepthReactivity {
        let n = min(max(rawNight, 0), 1)
        let e = n * n * (3 - 2 * n)                       // smoothstep(0, 1, n)
        return DepthReactivity(
            density: base.density * (1 - densityThin * e),
            fog: min(base.fog + fogRise * e, 1),
            defocus: base.defocus + defocusRise * e)
    }
}
