import Foundation
import AVFoundation
import AudioToolbox

@inline(__always)
func softClip(_ x: Float) -> Float {
    let ax = abs(x)
    if ax < 0.8 { return x }
    let sign: Float = x < 0 ? -1.0 : 1.0
    let excess = ax - 0.8
    // Asymptotic compression above 0.8
    return sign * (0.8 + (excess / (1.0 + excess * 5.0)))
}

struct AudioRenderParams {
    var carrier: Float = 180.0
    var beat: Float = 4.0
    var noiseGain: Float = 0
    var binGain: Float = 0
    var noiseType: Int = 0 // 0=brown, 1=white, 2=pink, 3=green, 4=fan, 5=rain, 6=ocean, 7=forest
    var targetFadeMult: Float = 1.0   // sleep-timer fade only (slow ramp)
    var masterMult: Float = 1.0       // master volume (fast, per-sample smoothed)
    var stereoWidth: Float = 1.0 // user width multiplier on the per-type base width
}

struct AudioRenderState {
    var fadeMult: Float = 1.0 // Smoothed local variable for timer
    var sampleRate: Float = 48000.0
    var phaseL: Double = 0
    var phaseR: Double = 0
    var brownL: Float = 0
    var brownR: Float = 0
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    var pB0: Float = 0, pB1: Float = 0, pB2: Float = 0, pB3: Float = 0, pB4: Float = 0, pB5: Float = 0, pB6: Float = 0
    var rainB0L: Float = 0, rainB1L: Float = 0
    var rainB0R: Float = 0, rainB1R: Float = 0
    var rainBedL: Float = 0, rainBedR: Float = 0
    var rainBed2L: Float = 0, rainBed2R: Float = 0 // rain 2nd low-pass pole
    var rainLowL: Float = 0, rainLowR: Float = 0 // rain low-rumble bed
    var noiseGCur: Float = 0, binGCur: Float = 0 // smoothed gains (declick)
    var carrierCur: Float = 180.0, beatCur: Float = 4.0 // glided binaural carrier/beat
    var globalFrameCount: UInt64 = 0
    var rng: UInt32 = 0x9E3779B9
    var rngR: UInt32 = 0x1A2B3C4D
}

final class GenerativeAudioEngine {
    private let engine = AVAudioEngine()
    private var noiseNode: AVAudioSourceNode!
    private var binauralNode: AVAudioSourceNode!
    private var limiterNode: AVAudioUnitEffect!
    
    private var paramsBuffer: UnsafeMutablePointer<AudioRenderParams>
    private var readIdxPtr: UnsafeMutablePointer<Int>
    private var writeIdx: Int = 0
    private var statePtr: UnsafeMutablePointer<AudioRenderState>
    
    var onRMSUpdate: ((Double) -> Void)?
    /// Fired when the engine can't be started even after a retry — lets the owner surface a
    /// non-destructive note instead of the bed silently failing to play all night.
    var onEngineError: ((String) -> Void)?

    
    init() {
        paramsBuffer = UnsafeMutablePointer<AudioRenderParams>.allocate(capacity: 2)
        paramsBuffer.initialize(repeating: AudioRenderParams(), count: 2)
        
        readIdxPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        readIdxPtr.initialize(to: 0)
        
        statePtr = UnsafeMutablePointer<AudioRenderState>.allocate(capacity: 1)
        statePtr.initialize(to: AudioRenderState())
        
        setupEngine()
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigurationChange), name: .AVAudioEngineConfigurationChange, object: engine)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        paramsBuffer.deinitialize(count: 2)
        paramsBuffer.deallocate()
        readIdxPtr.deinitialize(count: 1)
        readIdxPtr.deallocate()
        statePtr.deinitialize(count: 1)
        statePtr.deallocate()
    }
    
    @objc private func handleConfigurationChange(notification: Notification) {
        let wasRunning = engine.isRunning
        engine.stop()
        if noiseNode != nil { engine.detach(noiseNode) }
        if binauralNode != nil { engine.detach(binauralNode) }
        // Detach the old limiter and remove its RMS tap too. Otherwise every config
        // change (each headphone plug/unplug) orphans a limiter node + an active tap
        // for the app's lifetime; setupEngine() builds a fresh one and reinstalls the tap.
        if limiterNode != nil {
            limiterNode.removeTap(onBus: 0)
            engine.detach(limiterNode)
        }
        setupEngine(startEngine: wasRunning)
    }
    
    private func setupEngine(startEngine: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)
        
        statePtr.pointee.sampleRate = Float(session.sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 2)!
        
        noiseNode = AVAudioSourceNode { [statePtr, paramsBuffer, readIdxPtr] _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            let isStereo = abl.count > 1
            
            let p = paramsBuffer[readIdxPtr.pointee]
            
            // Smooth the fade target locally to prevent zipper noise
            if statePtr.pointee.fadeMult > p.targetFadeMult {
                statePtr.pointee.fadeMult -= 0.001
                if statePtr.pointee.fadeMult < p.targetFadeMult {
                    statePtr.pointee.fadeMult = p.targetFadeMult
                }
            } else if statePtr.pointee.fadeMult < p.targetFadeMult {
                statePtr.pointee.fadeMult += 0.001
                if statePtr.pointee.fadeMult > p.targetFadeMult {
                    statePtr.pointee.fadeMult = p.targetFadeMult
                }
            }
            
            let targetG = p.noiseGain * statePtr.pointee.fadeMult * p.masterMult
            let type = p.noiseType
            
            for f in 0..<Int(frameCount) {
                // Left RNG
                statePtr.pointee.rng ^= statePtr.pointee.rng << 13
                statePtr.pointee.rng ^= statePtr.pointee.rng >> 17
                statePtr.pointee.rng ^= statePtr.pointee.rng << 5
                let whiteL = Float(Int32(bitPattern: statePtr.pointee.rng)) / Float(Int32.max)
                
                // Right RNG
                statePtr.pointee.rngR ^= statePtr.pointee.rngR << 13
                statePtr.pointee.rngR ^= statePtr.pointee.rngR >> 17
                statePtr.pointee.rngR ^= statePtr.pointee.rngR << 5
                let whiteR = Float(Int32(bitPattern: statePtr.pointee.rngR)) / Float(Int32.max)
                
                var sampleL: Float = 0
                var sampleR: Float = 0
                statePtr.pointee.globalFrameCount += 1
                let t = Double(statePtr.pointee.globalFrameCount) / Double(statePtr.pointee.sampleRate)
                
                switch type {
                case 1: // white
                    sampleL = whiteL * 0.22   // loudness-matched (full-spectrum, perceptually hot — tune by ear)
                    sampleR = whiteR * 0.22
                case 2: // pink
                    statePtr.pointee.b0 = 0.99886 * statePtr.pointee.b0 + whiteL * 0.0555179
                    statePtr.pointee.b1 = 0.99332 * statePtr.pointee.b1 + whiteL * 0.0750759
                    statePtr.pointee.b2 = 0.96900 * statePtr.pointee.b2 + whiteL * 0.1538520
                    statePtr.pointee.b3 = 0.86650 * statePtr.pointee.b3 + whiteL * 0.3104856
                    statePtr.pointee.b4 = 0.55000 * statePtr.pointee.b4 + whiteL * 0.5329522
                    statePtr.pointee.b5 = -0.7616 * statePtr.pointee.b5 - whiteL * 0.0168980
                    sampleL = (statePtr.pointee.b0 + statePtr.pointee.b1 + statePtr.pointee.b2 + statePtr.pointee.b3 + statePtr.pointee.b4 + statePtr.pointee.b5 + statePtr.pointee.b6 + whiteL * 0.5362) * 0.068
                    statePtr.pointee.b6 = whiteL * 0.115926
                    
                    statePtr.pointee.pB0 = 0.99886 * statePtr.pointee.pB0 + whiteR * 0.0555179
                    statePtr.pointee.pB1 = 0.99332 * statePtr.pointee.pB1 + whiteR * 0.0750759
                    statePtr.pointee.pB2 = 0.96900 * statePtr.pointee.pB2 + whiteR * 0.1538520
                    statePtr.pointee.pB3 = 0.86650 * statePtr.pointee.pB3 + whiteR * 0.3104856
                    statePtr.pointee.pB4 = 0.55000 * statePtr.pointee.pB4 + whiteR * 0.5329522
                    statePtr.pointee.pB5 = -0.7616 * statePtr.pointee.pB5 - whiteR * 0.0168980
                    sampleR = (statePtr.pointee.pB0 + statePtr.pointee.pB1 + statePtr.pointee.pB2 + statePtr.pointee.pB3 + statePtr.pointee.pB4 + statePtr.pointee.pB5 + statePtr.pointee.pB6 + whiteR * 0.5362) * 0.068
                    statePtr.pointee.pB6 = whiteR * 0.115926
                    
                case 4: // fan
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.015 * whiteL) / 1.015
                    statePtr.pointee.brownR = (statePtr.pointee.brownR + 0.015 * whiteR) / 1.015
                    let hum = Float(sin(2 * .pi * 60 * t)) * 0.072
                    sampleL = statePtr.pointee.brownL * 2.15 + hum   // loudness-matched (was 4.5 + 0.15 hum)
                    sampleR = statePtr.pointee.brownR * 2.15 + hum
                    
                case 5: // rain
                    // Soft filtered noise: deep rumble + a 2-pole low-passed body + a gentle
                    // mid band for texture. No raw high-frequency white (that read as harsh
                    // static) and no tonal droplets. Knobs: *2.6 rumble, *1.9 body, *0.7 mid.
                    statePtr.pointee.rainLowL  = statePtr.pointee.rainLowL  * 0.985 + whiteL * 0.015
                    statePtr.pointee.rainBedL  = statePtr.pointee.rainBedL  * 0.65  + whiteL * 0.35   // LP pole 1
                    statePtr.pointee.rainBed2L = statePtr.pointee.rainBed2L * 0.65  + statePtr.pointee.rainBedL * 0.35 // LP pole 2
                    let midL = statePtr.pointee.rainBedL - statePtr.pointee.rainBed2L  // gentle mid band (no harsh top)
                    sampleL = statePtr.pointee.rainLowL * 0.66 + statePtr.pointee.rainBed2L * 0.48 + midL * 0.18  // loudness-matched

                    statePtr.pointee.rainLowR  = statePtr.pointee.rainLowR  * 0.985 + whiteR * 0.015
                    statePtr.pointee.rainBedR  = statePtr.pointee.rainBedR  * 0.65  + whiteR * 0.35
                    statePtr.pointee.rainBed2R = statePtr.pointee.rainBed2R * 0.65  + statePtr.pointee.rainBedR * 0.35
                    let midR = statePtr.pointee.rainBedR - statePtr.pointee.rainBed2R
                    sampleR = statePtr.pointee.rainLowR * 0.66 + statePtr.pointee.rainBed2R * 0.48 + midR * 0.18  // loudness-matched
                    
                case 6: // ocean
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.022 * whiteL) / 1.022
                    statePtr.pointee.brownR = (statePtr.pointee.brownR + 0.022 * whiteR) / 1.022
                    // Two detuned slow LFOs (~10s and ~15s, phase-offset) so the swell
                    // breathes irregularly like real surf instead of a metronomic pulse.
                    let lfoA = (sin(2 * .pi * 0.100 * t) + 1) / 2
                    let lfoB = (sin(2 * .pi * 0.067 * t + 1.3) + 1) / 2
                    let lfo = Float(pow(lfoA * 0.6 + lfoB * 0.4, 1.8))
                    sampleL = statePtr.pointee.brownL * 3.6 * lfo   // loudness-matched (was 4.5)
                    sampleR = statePtr.pointee.brownR * 3.6 * lfo
                    
                default: // 0 = brown
                    statePtr.pointee.brownL = (statePtr.pointee.brownL + 0.02 * whiteL) / 1.02
                    statePtr.pointee.brownR = (statePtr.pointee.brownR + 0.02 * whiteR) / 1.02
                    sampleL = statePtr.pointee.brownL * 2.1   // loudness-matched (was 3.5)
                    sampleR = statePtr.pointee.brownR * 2.1
                }
                
                // Stereo-width control with mono-bass safety. The generators above
                // produce fully independent L/R streams (wide on headphones), but
                // fully-decorrelated low frequencies partially cancel when summed to a
                // mono speaker (phone/laptop), thinning the bass. Blend each channel
                // toward the mid (mono) signal: the summed level is preserved while a
                // scaled side signal keeps width on headphones. Bass-heavy textures
                // stay more centered; brighter ones (pink/rain) can go wider.
                if isStereo {
                    // Per-type base width × user width slider (p.stereoWidth, default 1.0),
                    // clamped so we never exceed full decorrelation.
                    let base: Float = (type == 2 || type == 5) ? 0.85 : 0.6
                    let width = min(base * p.stereoWidth, 1.0)
                    let mid  = (sampleL + sampleR) * 0.5
                    let side = (sampleL - sampleR) * 0.5
                    sampleL = mid + side * width
                    sampleR = mid - side * width
                }

                // Per-sample gain smoothing → no zipper/click on volume drag or toggle.
                // Flush to exact zero once inaudible: an asymptotic decay would otherwise
                // settle in denormal float range and pin the audio thread (heat/overrun).
                statePtr.pointee.noiseGCur += (targetG - statePtr.pointee.noiseGCur) * 0.0015
                if statePtr.pointee.noiseGCur < 1e-8 { statePtr.pointee.noiseGCur = 0 }
                let g = statePtr.pointee.noiseGCur

                ch0[f] = softClip(sampleL * g)
                if isStereo { ch1[f] = softClip(sampleR * g) }
            }
            return noErr
        }
        
        binauralNode = AVAudioSourceNode { [statePtr, paramsBuffer, readIdxPtr] _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            
            let p = paramsBuffer[readIdxPtr.pointee]
            
            let targetG = p.binGain * statePtr.pointee.fadeMult * p.masterMult
            let sr = statePtr.pointee.sampleRate

            // Glide carrier + beat toward the selected preset so switching presets sweeps
            // smoothly (~0.2s) instead of jump-cutting the pitch. Phase stays continuous,
            // so there's no click either way; this just makes the transition musical.
            statePtr.pointee.carrierCur += (p.carrier - statePtr.pointee.carrierCur) * 0.05
            statePtr.pointee.beatCur    += (p.beat    - statePtr.pointee.beatCur)    * 0.05
            let deltas = AudioMath.getBinauralPhaseDeltas(carrier: statePtr.pointee.carrierCur, beat: statePtr.pointee.beatCur, sampleRate: sr)
            let dL = deltas.dL
            let dR = deltas.dR
            
            for f in 0..<Int(frameCount) {
                // Per-sample gain smoothing → no click when binaural toggles or its volume changes.
                // Flush to exact zero once inaudible (denormal guard — see noise node).
                statePtr.pointee.binGCur += (targetG - statePtr.pointee.binGCur) * 0.0015
                if statePtr.pointee.binGCur < 1e-8 { statePtr.pointee.binGCur = 0 }
                let g = statePtr.pointee.binGCur
                // Left and Right channels get separate phases to create the binaural interference
                ch0[f] = Float(sin(statePtr.pointee.phaseL)) * g
                ch1[f] = Float(sin(statePtr.pointee.phaseR)) * g
                
                statePtr.pointee.phaseL += dL
                statePtr.pointee.phaseR += dR
                
                if statePtr.pointee.phaseL > 2 * .pi { statePtr.pointee.phaseL -= 2 * .pi }
                if statePtr.pointee.phaseR > 2 * .pi { statePtr.pointee.phaseR -= 2 * .pi }
            }
            return noErr
        }
        
        engine.attach(noiseNode)
        engine.attach(binauralNode)
        
        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        limiterNode = AVAudioUnitEffect(audioComponentDescription: desc)
        engine.attach(limiterNode)

        // Configure as a transparent safety limiter, NOT a compressor. The default
        // DynamicsProcessor threshold is low enough that steady content keeps it in
        // gain reduction; when binaural is on, its inter-aural beat makes that gain
        // reduction pump at the beat rate and modulate the noise ("flutter"). A high
        // threshold means it only catches hot peaks near 0 dBFS and never pumps on
        // normal-level content.
        let limiterAU = limiterNode.audioUnit
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_Threshold,   kAudioUnitScope_Global, 0, -2.0, 0)
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_HeadRoom,    kAudioUnitScope_Global, 0, 2.0, 0)
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_AttackTime,  kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.10, 0)

        let mainMixer = engine.mainMixerNode
        
        engine.connect(noiseNode, to: mainMixer, format: format)
        engine.connect(binauralNode, to: mainMixer, format: format)
        engine.connect(mainMixer, to: limiterNode, format: format)
        engine.connect(limiterNode, to: engine.outputNode, format: format)
        
        var lastSampleTime: AVAudioFramePosition = 0
        limiterNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            guard let chData = buffer.floatChannelData?[0] else { return }
            
            // Throttle UI updates to ~20fps (approx 2400 frames at 48kHz)
            if time.sampleTime - lastSampleTime > 2400 {
                lastSampleTime = time.sampleTime
                let frames = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<frames {
                    sum += chData[i] * chData[i]
                }
                let rms = Double(sqrt(sum / Float(max(frames, 1))))
                
                DispatchQueue.main.async {
                    self?.onRMSUpdate?(rms)
                }
            }
        }
        
        engine.prepare()
        if startEngine {
            startEngineSafely("setup")
        }
    }
    
    // MARK: - Thread-Safe Updaters
    
    private func updateParams(_ closure: (inout AudioRenderParams) -> Void) {
        let nextIdx = (writeIdx + 1) % 2
        var nextParams = paramsBuffer[writeIdx]
        closure(&nextParams)
        paramsBuffer[nextIdx] = nextParams
        readIdxPtr.pointee = nextIdx
        writeIdx = nextIdx
    }
    
    // Ceilings cap how hard a full slider drives each generator, so ambient stays a
    // background bed that can't overpower a podcast. Tune these to taste.
    private static let noiseMaxGain: Float = 0.5
    private static let binauralMaxGain: Float = 0.15

    func setNoise(on: Bool, volume: Double, type: String) {
        updateParams { p in
            p.noiseGain = on ? Float(volume) * Self.noiseMaxGain : 0.0
            p.noiseType = mapNoiseType(type)
        }
    }

    func setBinaural(on: Bool, volume: Double, preset: String) {
        updateParams { p in
            p.binGain = on ? Float(volume) * Self.binauralMaxGain : 0.0
            let params = AudioMath.getCarrierAndBeat(for: preset)
            p.carrier = params.carrier
            p.beat = params.beat
        }
    }
    
    
    
    func setFade(multiplier: Double) {
        updateParams { p in
            p.targetFadeMult = Float(multiplier)
        }
    }

    func setWidth(_ width: Double) {
        updateParams { p in
            p.stereoWidth = Float(width)
        }
    }

    func setMaster(_ multiplier: Double) {
        updateParams { p in
            p.masterMult = Float(multiplier)
        }
    }

    /// Start the engine, retrying once after re-asserting the audio session (the usual cause
    /// of a failed start is the session losing activation in a race). Logs and reports on
    /// final failure rather than swallowing the error with `try?`.
    @discardableResult
    private func startEngineSafely(_ context: String) -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                try engine.start()
                return true
            } catch {
                print("GenerativeAudioEngine.start failed [\(context)]: \(error)")
                onEngineError?("Sound engine couldn't start — tap play to retry")
                return false
            }
        }
    }

    /// Start rendering if it isn't already (called before noise/binaural turn on).
    func resumeIfNeeded() {
        guard !engine.isRunning else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        startEngineSafely("resume")
    }

    /// Stop rendering to save power when nothing generative is playing. Does NOT
    /// deactivate the audio session, so a podcast on the separate AVPlayer keeps going.
    func suspendEngine() {
        if engine.isRunning { engine.pause() }
    }
    
    func stopAll() {
        updateParams { p in
            p.noiseGain = 0.0
            p.binGain = 0.0
        }
    }
    
    private func mapNoiseType(_ type: String) -> Int {
        switch type {
        case "white": return 1
        case "pink": return 2
        case "fan": return 4
        case "rain": return 5
        case "ocean": return 6
        default: return 0 // brown
        }
    }
    
    func handleInterruption(shouldResume: Bool) {
        if shouldResume {
            let session = AVAudioSession.sharedInstance()
            try? session.setActive(true)
            startEngineSafely("interruption")
        } else {
            engine.pause()
        }
    }
}
