import Foundation
import AVFoundation

struct AudioRenderState {
    var carrier: Float = 180.0
    var beat: Float = 4.0
    var noiseGain: Float = 0
    var binGain: Float = 0
    var noiseType: Int = 0 // 0=brown, 1=white, 2=pink, 3=green, 4=fan, 5=rain, 6=ocean, 7=forest
    var duckMult: Float = 1.0
    var fadeMult: Float = 1.0 // Smoothed local variable for timer
    var targetFadeMult: Float = 1.0
    var sampleRate: Float = 48000.0
    
    var phaseL: Double = 0
    var phaseR: Double = 0
    
    var brownL: Float = 0
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    var rainB0: Float = 0, rainB1: Float = 0
    var forestPhase: Double = 0
    var globalFrameCount: UInt64 = 0
    var rng: UInt32 = 0x9E3779B9
}

final class GenerativeAudioEngine {
    private let engine = AVAudioEngine()
    private var noiseNode: AVAudioSourceNode!
    private var binauralNode: AVAudioSourceNode!
    
    // We allocate a C-compatible struct pointer to hold the render state lock-free.
    private var statePtr: UnsafeMutablePointer<AudioRenderState>
    
    init() {
        statePtr = UnsafeMutablePointer<AudioRenderState>.allocate(capacity: 1)
        statePtr.initialize(to: AudioRenderState())
        
        setupEngine()
    }
    
    deinit {
        statePtr.deinitialize(count: 1)
        statePtr.deallocate()
    }
    
    private func setupEngine() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        
        statePtr.pointee.sampleRate = Float(session.sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 2)!
        
        noiseNode = AVAudioSourceNode { [statePtr] _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            
            // Smooth the fade target locally to prevent zipper noise
            if statePtr.pointee.fadeMult > statePtr.pointee.targetFadeMult {
                statePtr.pointee.fadeMult -= 0.001
                if statePtr.pointee.fadeMult < statePtr.pointee.targetFadeMult {
                    statePtr.pointee.fadeMult = statePtr.pointee.targetFadeMult
                }
            } else if statePtr.pointee.fadeMult < statePtr.pointee.targetFadeMult {
                statePtr.pointee.fadeMult += 0.001
                if statePtr.pointee.fadeMult > statePtr.pointee.targetFadeMult {
                    statePtr.pointee.fadeMult = statePtr.pointee.targetFadeMult
                }
            }
            
            let g = statePtr.pointee.noiseGain * statePtr.pointee.duckMult * statePtr.pointee.fadeMult
            let type = statePtr.pointee.noiseType
            
            for f in 0..<Int(frameCount) {
                statePtr.pointee.rng ^= statePtr.pointee.rng << 13
                statePtr.pointee.rng ^= statePtr.pointee.rng >> 17
                statePtr.pointee.rng ^= statePtr.pointee.rng << 5
                let white = Float(Int32(bitPattern: statePtr.pointee.rng)) / Float(Int32.max)
                
                var sample: Float = 0
                statePtr.pointee.globalFrameCount += 1
                let t = Double(statePtr.pointee.globalFrameCount) / Double(statePtr.pointee.sampleRate)
                
                switch type {
                case 1: // white
                    sample = white * 0.1
                case 2: // pink
                    statePtr.pointee.b0 = 0.99886 * statePtr.pointee.b0 + white * 0.0555179
                    statePtr.pointee.b1 = 0.99332 * statePtr.pointee.b1 + white * 0.0750759
                    statePtr.pointee.b2 = 0.96900 * statePtr.pointee.b2 + white * 0.1538520
                    statePtr.pointee.b3 = 0.86650 * statePtr.pointee.b3 + white * 0.3104856
                    statePtr.pointee.b4 = 0.55000 * statePtr.pointee.b4 + white * 0.5329522
                    statePtr.pointee.b5 = -0.7616 * statePtr.pointee.b5 - white * 0.0168980
                    sample = (statePtr.pointee.b0 + statePtr.pointee.b1 + statePtr.pointee.b2 + statePtr.pointee.b3 + statePtr.pointee.b4 + statePtr.pointee.b5 + statePtr.pointee.b6 + white * 0.5362) * 0.02
                    statePtr.pointee.b6 = white * 0.115926
                case 3: // green
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.05 * white) / 1.05
                    sample = statePtr.pointee.brownL * 1.5
                case 4: // fan
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.015 * white) / 1.015
                    let hum = Float(sin(2 * .pi * 60 * t)) * 0.15
                    sample = statePtr.pointee.brownL * 4.5 + hum
                case 5: // rain
                    statePtr.pointee.rainB0 = 0.8 * statePtr.pointee.rainB0 + white * 0.12
                    sample = (white * 0.7 + statePtr.pointee.rainB0 * 0.2 + statePtr.pointee.rainB1 * 0.1) * 0.75
                    statePtr.pointee.rainB1 = white
                case 6: // ocean
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.022 * white) / 1.022
                    let lfo = Float(pow((sin(2 * .pi * 0.10 * t) + 1) / 2, 1.8))
                    sample = statePtr.pointee.brownL * 4.5 * lfo
                case 7: // forest
                    statePtr.pointee.rainB0 = 0.88 * statePtr.pointee.rainB0 + white * 0.2
                    sample = (white * 0.5 - statePtr.pointee.rainB0 * 0.5 + statePtr.pointee.rainB1 * 0.22) * 0.85
                    statePtr.pointee.rainB1 = white
                    
                    statePtr.pointee.rng ^= statePtr.pointee.rng << 13
                    statePtr.pointee.rng ^= statePtr.pointee.rng >> 17
                    statePtr.pointee.rng ^= statePtr.pointee.rng << 5
                    let white2 = Float(Int32(bitPattern: statePtr.pointee.rng)) / Float(Int32.max)
                    
                    statePtr.pointee.forestPhase += 2 * .pi * 4.2 * (1 + (Double(white2) * 0.15)) / Double(statePtr.pointee.sampleRate)
                    if statePtr.pointee.forestPhase > 2 * .pi { statePtr.pointee.forestPhase -= 2 * .pi }
                    let e = Float(0.35 + 0.65 * abs(sin(statePtr.pointee.forestPhase)))
                    sample *= e
                default: // 0 = brown
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.02 * white) / 1.02
                    sample = statePtr.pointee.brownL * 3.5
                }
                
                ch0[f] = max(-1, min(1, sample * g))
                ch1[f] = ch0[f]
            }
            return noErr
        }
        
        binauralNode = AVAudioSourceNode { [statePtr] _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            
            let g = statePtr.pointee.binGain * statePtr.pointee.duckMult * statePtr.pointee.fadeMult
            let sr = statePtr.pointee.sampleRate
            
            let deltas = AudioMath.getBinauralPhaseDeltas(carrier: statePtr.pointee.carrier, beat: statePtr.pointee.beat, sampleRate: sr)
            let dL = deltas.dL
            let dR = deltas.dR
            
            for f in 0..<Int(frameCount) {
                // Fix: Left and Right channels get separate phases to create the binaural interference
                ch0[f] = Float(sin(statePtr.pointee.phaseL)) * g
                ch1[f] = Float(sin(statePtr.pointee.phaseR)) * g
                
                statePtr.pointee.phaseL += dL
                statePtr.pointee.phaseR += dR
            }
            return noErr
        }
        
        engine.attach(noiseNode)
        engine.attach(binauralNode)
        let mainMixer = engine.mainMixerNode
        
        engine.connect(noiseNode, to: mainMixer, format: format)
        engine.connect(binauralNode, to: mainMixer, format: format)
        
        engine.prepare()
        try? engine.start()
    }
    
    // MARK: - Thread-Safe Updaters
    
    func setNoise(on: Bool, volume: Double, type: String) {
        statePtr.pointee.noiseGain = on ? Float(volume) : 0.0
        statePtr.pointee.noiseType = mapNoiseType(type)
    }
    
    func setBinaural(on: Bool, volume: Double, preset: String) {
        statePtr.pointee.binGain = on ? Float(volume) : 0.0
        
        let params = AudioMath.getCarrierAndBeat(for: preset)
        statePtr.pointee.carrier = params.carrier
        statePtr.pointee.beat = params.beat
    }
    
    func setDucking(enabled: Bool, isPodPlaying: Bool) {
        statePtr.pointee.duckMult = (isPodPlaying && enabled) ? 0.2 : 1.0
    }
    
    func setFade(multiplier: Double) {
        statePtr.pointee.targetFadeMult = Float(multiplier)
    }
    
    func stopAll() {
        statePtr.pointee.noiseGain = 0.0
        statePtr.pointee.binGain = 0.0
    }
    
    private func mapNoiseType(_ type: String) -> Int {
        switch type {
        case "white": return 1
        case "pink": return 2
        case "green": return 3
        case "fan": return 4
        case "rain": return 5
        case "ocean": return 6
        case "forest": return 7
        default: return 0 // brown
        }
    }
    
    func handleInterruption(shouldResume: Bool) {
        if shouldResume {
            try? engine.start()
        } else {
            engine.pause()
        }
    }
}
