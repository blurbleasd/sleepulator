import Foundation

public struct AudioMath {
    
    public static func getCarrierAndBeat(for preset: String) -> (carrier: Float, beat: Float) {
        switch preset {
        case "theta": return (200.0, 6.0)
        case "alpha": return (220.0, 10.0)
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
            return 0.0
        } else if timerRemaining <= fadeDuration {
            let linear = timerRemaining / fadeDuration
            return Float(pow(linear, 2.0))
        } else {
            return 1.0
        }
    }
}
