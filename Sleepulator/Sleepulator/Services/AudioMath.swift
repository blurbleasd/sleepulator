import Foundation

public struct AudioMath {

    /// Perceptual (audio) taper for the mixer's volume sliders: gain = position². A linear
    /// position→gain map crams the useful bedtime range into the bottom fifth of the track;
    /// squaring gives fine control at the low levels sleep mixes actually live at.
    /// NOTE: applied where volumes are handed to the engines — persisted slider values are
    /// unchanged, but any given position now plays quieter than before (the safe direction).
    public static func perceptualGain(_ position: Double) -> Double {
        let p = min(max(position, 0), 1)
        return p * p
    }

    public static func getCarrierAndBeat(for preset: String) -> (carrier: Float, beat: Float) {
        switch preset {
        case "theta": return (200.0, 6.0)
        case "alpha": return (220.0, 10.0)
        case "smr":   return (220.0, 10.0) // RETIRED → aliased to alpha so a legacy saved preset
                                           // doesn't fall through to the delta default. Not offered.
        case "beta":  return (220.0, 16.0) // concentration band
        case "gamma": return (220.0, 40.0)
        default: return (180.0, 4.0) // delta
        }
    }
    
    public static func getBinauralPhaseDeltas(carrier: Float, beat: Float, sampleRate: Float) -> (dL: Double, dR: Double) {
        let dL = Double(2.0 * .pi * (carrier - beat / 2.0) / sampleRate)
        let dR = Double(2.0 * .pi * (carrier + beat / 2.0) / sampleRate)
        return (dL, dR)
    }
    
    /// Maps a scrubber position (0…1) to a seek time, clamped to the track and snapped to the exact
    /// start when within `snapWithin` seconds. On a long episode, one pixel of slider travel is tens
    /// of seconds, so dragging "back to the start" can't land on 0:00 — the snap makes it reliable.
    /// Returns nil for an unknown / non-finite duration (seeking to a NaN time is silently ignored
    /// by AVPlayer, which reads as "the seek did nothing"). Pure + static so it's unit-testable.
    public static func scrubTargetSeconds(progress: Double, duration: Double, snapWithin: Double = 2.0) -> Double? {
        guard duration.isFinite, duration > 0 else { return nil }
        let seconds = min(max(progress, 0), 1) * duration
        return seconds < snapWithin ? 0 : seconds
    }

    public static func getFadeMultiplier(timerRemaining: Double, fadeDuration: Double = 600.0) -> Float {
        if timerRemaining <= 0 {
            return 0.0   // hard stop fires here; fully silent
        } else if timerRemaining <= fadeDuration {
            let linear = timerRemaining / fadeDuration
            // Floor above zero while the timer is still running: a fully-silent engine lets
            // iOS curtail background execution, which can stop the GCD timer that fires the
            // terminal stop in noise-only mode. Staying barely audible keeps the app alive
            // through the fade; the hard stop at timerRemaining<=0 cuts it.
            return max(Float(pow(linear, 2.0)), 0.03)
        } else {
            return 1.0
        }
    }
}
