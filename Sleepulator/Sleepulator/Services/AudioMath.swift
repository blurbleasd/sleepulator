import Foundation

public struct AudioMath {
    
    public static func getCarrierAndBeat(for preset: String) -> (carrier: Float, beat: Float) {
        switch preset {
        case "theta": return (200.0, 6.0)
        case "alpha": return (220.0, 10.0)
        case "smr":   return (220.0, 13.0) // sensorimotor rhythm — "calm-alert"
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
