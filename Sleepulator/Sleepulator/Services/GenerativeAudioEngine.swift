import Foundation
import AVFoundation
import AudioToolbox
import os

@inline(__always)
func softClip(_ x: Float) -> Float {
    let ax = abs(x)
    if ax < 0.8 { return x }
    let sign: Float = x < 0 ? -1.0 : 1.0
    let excess = ax - 0.8
    // Asymptotic compression above 0.8
    return sign * (0.8 + (excess / (1.0 + excess * 5.0)))
}

/// Up to this many noise generators can play at once (rain + brown + fan, etc). Each is a
/// separate `AVAudioSourceNode` summed by the main mixer, so the proven single-type DSP is
/// reused verbatim per layer; inactive layers early-out to near-zero cost (battery).
let kMaxNoiseLayers = 3

struct AudioRenderParams {
    var carrier: Float = 180.0
    var beat: Float = 4.0
    var binGain: Float = 0
    var targetFadeMult: Float = 1.0   // sleep-timer fade only (slow ramp)
    var masterMult: Float = 1.0       // master volume (fast, per-sample smoothed)
    var stereoWidth: Float = 1.0 // user width multiplier on the per-type base width
    var binMode: Int = 0 // 0 = true binaural (needs headphones), 1 = isochronic (speaker-safe)
    // Per-layer noise: gain already folds in volume × ceiling; gain 0 = inactive layer.
    // type: 0=brown,1=white,2=pink,3=green,4=fan,5=rain,6=ocean,7=forest,8=gray
    var layerGain0: Float = 0, layerType0: Int32 = 0
    var layerGain1: Float = 0, layerType1: Int32 = 0
    var layerGain2: Float = 0, layerType2: Int32 = 0
}

@inline(__always)
private func noiseLayerParam(_ p: AudioRenderParams, _ i: Int) -> (gain: Float, type: Int) {
    switch i {
    case 0:  return (p.layerGain0, Int(p.layerType0))
    case 1:  return (p.layerGain1, Int(p.layerType1))
    default: return (p.layerGain2, Int(p.layerType2))
    }
}

@inline(__always)
private func setNoiseLayerParam(_ p: inout AudioRenderParams, _ i: Int, gain: Float, type: Int32) {
    switch i {
    case 0:  p.layerGain0 = gain; p.layerType0 = type
    case 1:  p.layerGain1 = gain; p.layerType1 = type
    default: p.layerGain2 = gain; p.layerType2 = type
    }
}

/// Per-noise-layer render memory. One per layer, so stacked layers don't share filter state.
/// Each layer also carries its own RNG + frame counter, so layers are decorrelated and
/// order-independent on the (sequential, single audio-thread) render pass.
struct NoiseLayerState {
    var fadeMult: Float = 1.0
    var sampleRate: Float = 48000.0
    var brownL: Float = 0, brownR: Float = 0
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    var pB0: Float = 0, pB1: Float = 0, pB2: Float = 0, pB3: Float = 0, pB4: Float = 0, pB5: Float = 0, pB6: Float = 0
    var rainB0L: Float = 0, rainB1L: Float = 0
    var rainB0R: Float = 0, rainB1R: Float = 0
    var rainBedL: Float = 0, rainBedR: Float = 0
    var rainBed2L: Float = 0, rainBed2R: Float = 0 // rain 2nd low-pass pole
    var rainLowL: Float = 0, rainLowR: Float = 0 // rain low-rumble bed
    var greenAL: Float = 0, greenAR: Float = 0, greenBL: Float = 0, greenBR: Float = 0 // green mid-band poles
    var forestMidL: Float = 0, forestMidR: Float = 0 // forest soft-body low-pass
    var grayLowL: Float = 0, grayLowR: Float = 0 // gray low-boost low-pass
    var noiseGCur: Float = 0 // smoothed gain (declick)
    var globalFrameCount: UInt64 = 0
    var rng: UInt32 = 0x9E3779B9
    var rngR: UInt32 = 0x1A2B3C4D
}

/// Binaural render memory (carrier/beat phase + gain smoothing). Split out from the noise
/// layers so the beat generator keeps its own fade/gain state regardless of how many noise
/// layers are active.
struct AudioRenderState {
    var fadeMult: Float = 1.0 // Smoothed local for the sleep-timer fade
    var sampleRate: Float = 48000.0
    var phaseL: Double = 0
    var phaseR: Double = 0
    var binGCur: Float = 0 // smoothed gain (declick)
    var carrierCur: Float = 180.0, beatCur: Float = 4.0 // glided binaural carrier/beat
    var modPhase: Double = 0 // isochronic AM-envelope phase (advances at the beat rate)
}

final class GenerativeAudioEngine {
    private let engine = AVAudioEngine()
    private var noiseNodes: [AVAudioSourceNode] = []
    private var binauralNode: AVAudioSourceNode!
    private var limiterNode: AVAudioUnitEffect!

    private var paramsBuffer: UnsafeMutablePointer<AudioRenderParams>
    // Which slot of paramsBuffer the render thread should read. Published with release
    // ordering by the main thread (updateParams) and read with acquire ordering by the audio
    // render block, so the param-struct write always lands before the index that points at it.
    // Plain-Int before; the missing barrier let the render thread briefly pair a new index
    // with stale params. SLPAtomicIndex is a lock-free C cell (see Sleepulator-Bridging-Header.h).
    private let readIdx: OpaquePointer
    private var writeIdx: Int = 0
    /// One NoiseLayerState per layer (capacity kMaxNoiseLayers); the binaural node has its own.
    private var noiseStatePtr: UnsafeMutablePointer<NoiseLayerState>
    private var statePtr: UnsafeMutablePointer<AudioRenderState>

    var onRMSUpdate: ((Double) -> Void)?
    /// Fired when the engine can't be started even after a retry — lets the owner surface a
    /// non-destructive note instead of the bed silently failing to play all night.
    var onEngineError: ((String) -> Void)?


    init() {
        paramsBuffer = UnsafeMutablePointer<AudioRenderParams>.allocate(capacity: 2)
        paramsBuffer.initialize(repeating: AudioRenderParams(), count: 2)

        readIdx = SLPAtomicIndexCreate(0)

        noiseStatePtr = UnsafeMutablePointer<NoiseLayerState>.allocate(capacity: kMaxNoiseLayers)
        for i in 0..<kMaxNoiseLayers {
            var s = NoiseLayerState()
            // Layer 0 keeps the original seeds, so a single-layer bed sounds byte-identical to
            // before this change. Layers 1/2 get distinct seeds so stacking two of the same
            // type produces decorrelated noise instead of a phase-locked, +6 dB copy.
            if i == 1 { s.rng = 0x2545F491; s.rngR = 0x6C8E944D }
            if i == 2 { s.rng = 0xB7E15163; s.rngR = 0x9E3779B1 }
            (noiseStatePtr + i).initialize(to: s)
        }

        statePtr = UnsafeMutablePointer<AudioRenderState>.allocate(capacity: 1)
        statePtr.initialize(to: AudioRenderState())

        setupEngine()
        NotificationCenter.default.addObserver(self, selector: #selector(handleConfigurationChange), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Quiesce the render thread BEFORE freeing the buffers it reads. The source-node
        // render blocks capture the param/state pointers as raw pointers (not self), so without
        // an explicit stop a callback can still fire after these are freed — a use-after-free.
        // stop() ends audio I/O so no render callback runs past this point.
        engine.stop()
        paramsBuffer.deinitialize(count: 2)
        paramsBuffer.deallocate()
        SLPAtomicIndexDestroy(readIdx)
        noiseStatePtr.deinitialize(count: kMaxNoiseLayers)
        noiseStatePtr.deallocate()
        statePtr.deinitialize(count: 1)
        statePtr.deallocate()
    }

    @objc private func handleConfigurationChange(notification: Notification) {
        let wasRunning = engine.isRunning
        engine.stop()
        for node in noiseNodes { engine.detach(node) }
        noiseNodes.removeAll()
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

    /// Build one noise source node bound to layer `index` (its own NoiseLayerState slot and its
    /// own gain/type in the shared param struct). The per-sample DSP is identical to the original
    /// single-noise node; only the state/param source is parameterized.
    private func makeNoiseNode(index: Int) -> AVAudioSourceNode {
        return AVAudioSourceNode { [noiseStatePtr, paramsBuffer, readIdx] _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0
            let isStereo = abl.count > 1

            let ns = noiseStatePtr + index
            let p = paramsBuffer[SLPAtomicIndexLoadAcquire(readIdx)]
            // Per-layer gain/type, selected inline on the render thread (index is a captured
            // constant). gain already folds in volume × ceiling; type indexes the switch below.
            let layerGain: Float
            let type: Int
            switch index {
            case 0:  layerGain = p.layerGain0; type = Int(p.layerType0)
            case 1:  layerGain = p.layerGain1; type = Int(p.layerType1)
            default: layerGain = p.layerGain2; type = Int(p.layerType2)
            }

            // Smooth the fade target locally to prevent zipper noise
            if ns.pointee.fadeMult > p.targetFadeMult {
                ns.pointee.fadeMult -= 0.001
                if ns.pointee.fadeMult < p.targetFadeMult { ns.pointee.fadeMult = p.targetFadeMult }
            } else if ns.pointee.fadeMult < p.targetFadeMult {
                ns.pointee.fadeMult += 0.001
                if ns.pointee.fadeMult > p.targetFadeMult { ns.pointee.fadeMult = p.targetFadeMult }
            }

            let targetG = layerGain * ns.pointee.fadeMult * p.masterMult

            // Inactive-layer early-out: when this layer is off AND its smoothed gain has already
            // flushed to zero, write silence and return without running the per-sample DSP. This
            // is what keeps unused layers (the common case — most users run one) near-free for
            // all-night battery. The fade smoothing above still ran, so the layer re-enters
            // correctly when it turns back on (and the gain ramp from 0 masks any restart).
            if targetG <= 0 && ns.pointee.noiseGCur <= 1e-7 {
                for f in 0..<Int(frameCount) {
                    ch0[f] = 0
                    if isStereo { ch1[f] = 0 }
                }
                return noErr
            }

            for f in 0..<Int(frameCount) {
                // Left RNG
                ns.pointee.rng ^= ns.pointee.rng << 13
                ns.pointee.rng ^= ns.pointee.rng >> 17
                ns.pointee.rng ^= ns.pointee.rng << 5
                let whiteL = Float(Int32(bitPattern: ns.pointee.rng)) / Float(Int32.max)

                // Right RNG
                ns.pointee.rngR ^= ns.pointee.rngR << 13
                ns.pointee.rngR ^= ns.pointee.rngR >> 17
                ns.pointee.rngR ^= ns.pointee.rngR << 5
                let whiteR = Float(Int32(bitPattern: ns.pointee.rngR)) / Float(Int32.max)

                var sampleL: Float = 0
                var sampleR: Float = 0
                ns.pointee.globalFrameCount += 1
                let t = Double(ns.pointee.globalFrameCount) / Double(ns.pointee.sampleRate)

                switch type {
                case 1: // white
                    sampleL = whiteL * 0.22   // loudness-matched (full-spectrum, perceptually hot — tune by ear)
                    sampleR = whiteR * 0.22
                case 2: // pink
                    ns.pointee.b0 = 0.99886 * ns.pointee.b0 + whiteL * 0.0555179
                    ns.pointee.b1 = 0.99332 * ns.pointee.b1 + whiteL * 0.0750759
                    ns.pointee.b2 = 0.96900 * ns.pointee.b2 + whiteL * 0.1538520
                    ns.pointee.b3 = 0.86650 * ns.pointee.b3 + whiteL * 0.3104856
                    ns.pointee.b4 = 0.55000 * ns.pointee.b4 + whiteL * 0.5329522
                    ns.pointee.b5 = -0.7616 * ns.pointee.b5 - whiteL * 0.0168980
                    sampleL = (ns.pointee.b0 + ns.pointee.b1 + ns.pointee.b2 + ns.pointee.b3 + ns.pointee.b4 + ns.pointee.b5 + ns.pointee.b6 + whiteL * 0.5362) * 0.068
                    ns.pointee.b6 = whiteL * 0.115926

                    ns.pointee.pB0 = 0.99886 * ns.pointee.pB0 + whiteR * 0.0555179
                    ns.pointee.pB1 = 0.99332 * ns.pointee.pB1 + whiteR * 0.0750759
                    ns.pointee.pB2 = 0.96900 * ns.pointee.pB2 + whiteR * 0.1538520
                    ns.pointee.pB3 = 0.86650 * ns.pointee.pB3 + whiteR * 0.3104856
                    ns.pointee.pB4 = 0.55000 * ns.pointee.pB4 + whiteR * 0.5329522
                    ns.pointee.pB5 = -0.7616 * ns.pointee.pB5 - whiteR * 0.0168980
                    sampleR = (ns.pointee.pB0 + ns.pointee.pB1 + ns.pointee.pB2 + ns.pointee.pB3 + ns.pointee.pB4 + ns.pointee.pB5 + ns.pointee.pB6 + whiteR * 0.5362) * 0.068
                    ns.pointee.pB6 = whiteR * 0.115926

                case 4: // fan
                    ns.pointee.brownL = (ns.pointee.brownL + 0.015 * whiteL) / 1.015
                    ns.pointee.brownR = (ns.pointee.brownR + 0.015 * whiteR) / 1.015
                    let hum = Float(sin(2 * .pi * 60 * t)) * 0.072
                    sampleL = ns.pointee.brownL * 2.15 + hum   // loudness-matched (was 4.5 + 0.15 hum)
                    sampleR = ns.pointee.brownR * 2.15 + hum

                case 5: // rain
                    // Soft filtered noise: deep rumble + a 2-pole low-passed body + a gentle
                    // mid band for texture. No raw high-frequency white (that read as harsh
                    // static) and no tonal droplets. Knobs: *2.6 rumble, *1.9 body, *0.7 mid.
                    ns.pointee.rainLowL  = ns.pointee.rainLowL  * 0.985 + whiteL * 0.015
                    ns.pointee.rainBedL  = ns.pointee.rainBedL  * 0.65  + whiteL * 0.35   // LP pole 1
                    ns.pointee.rainBed2L = ns.pointee.rainBed2L * 0.65  + ns.pointee.rainBedL * 0.35 // LP pole 2
                    let midL = ns.pointee.rainBedL - ns.pointee.rainBed2L  // gentle mid band (no harsh top)
                    sampleL = ns.pointee.rainLowL * 0.66 + ns.pointee.rainBed2L * 0.48 + midL * 0.18  // loudness-matched

                    ns.pointee.rainLowR  = ns.pointee.rainLowR  * 0.985 + whiteR * 0.015
                    ns.pointee.rainBedR  = ns.pointee.rainBedR  * 0.65  + whiteR * 0.35
                    ns.pointee.rainBed2R = ns.pointee.rainBed2R * 0.65  + ns.pointee.rainBedR * 0.35
                    let midR = ns.pointee.rainBedR - ns.pointee.rainBed2R
                    sampleR = ns.pointee.rainLowR * 0.66 + ns.pointee.rainBed2R * 0.48 + midR * 0.18  // loudness-matched

                case 6: // ocean
                    ns.pointee.brownL = (ns.pointee.brownL + 0.022 * whiteL) / 1.022
                    ns.pointee.brownR = (ns.pointee.brownR + 0.022 * whiteR) / 1.022
                    // Two detuned slow LFOs (~10s and ~15s, phase-offset) so the swell
                    // breathes irregularly like real surf instead of a metronomic pulse.
                    let lfoA = (sin(2 * .pi * 0.100 * t) + 1) / 2
                    let lfoB = (sin(2 * .pi * 0.067 * t + 1.3) + 1) / 2
                    let lfo = Float(pow(lfoA * 0.6 + lfoB * 0.4, 1.8))
                    sampleL = ns.pointee.brownL * 3.6 * lfo   // loudness-matched (was 4.5)
                    sampleR = ns.pointee.brownR * 3.6 * lfo

                case 3: // green (Sleep): mid-band emphasis — a "natural", centred-mids bed.
                    // Two cascaded one-pole low-passes; their difference is a band (~470Hz–1.7k).
                    ns.pointee.greenAL = ns.pointee.greenAL * 0.80 + whiteL * 0.20  // LP ~1.7k
                    ns.pointee.greenBL = ns.pointee.greenBL * 0.94 + ns.pointee.greenAL * 0.06 // LP ~470
                    let gMidL = ns.pointee.greenAL - ns.pointee.greenBL
                    sampleL = (gMidL * 1.7 + ns.pointee.greenBL * 0.55) * 1.25
                    ns.pointee.greenAR = ns.pointee.greenAR * 0.80 + whiteR * 0.20
                    ns.pointee.greenBR = ns.pointee.greenBR * 0.94 + ns.pointee.greenAR * 0.06
                    let gMidR = ns.pointee.greenAR - ns.pointee.greenBR
                    sampleR = (gMidR * 1.7 + ns.pointee.greenBR * 0.55) * 1.25

                case 7: // forest (Sleep): soft broadband outdoors bed with a faint slow breeze swell.
                    ns.pointee.brownL = (ns.pointee.brownL + 0.02 * whiteL) / 1.02
                    ns.pointee.brownR = (ns.pointee.brownR + 0.02 * whiteR) / 1.02
                    ns.pointee.forestMidL = ns.pointee.forestMidL * 0.86 + whiteL * 0.14 // soft body LP ~1.1k
                    ns.pointee.forestMidR = ns.pointee.forestMidR * 0.86 + whiteR * 0.14
                    let breeze = Float((sin(2 * .pi * 0.05 * t) + 1) / 2) * 0.35 + 0.65 // very slow swell, 0.65…1.0
                    sampleL = (ns.pointee.brownL * 1.7 + ns.pointee.forestMidL * 0.45) * breeze * 1.2
                    sampleR = (ns.pointee.brownR * 1.7 + ns.pointee.forestMidR * 0.45) * breeze * 1.2

                case 8: // gray (Focus): approx equal-loudness masking — white with boosted lows.
                    ns.pointee.grayLowL = ns.pointee.grayLowL * 0.95 + whiteL * 0.05 // low boost LP ~390
                    ns.pointee.grayLowR = ns.pointee.grayLowR * 0.95 + whiteR * 0.05
                    sampleL = whiteL * 0.13 + ns.pointee.grayLowL * 1.7
                    sampleR = whiteR * 0.13 + ns.pointee.grayLowR * 1.7

                default: // 0 = brown
                    ns.pointee.brownL = (ns.pointee.brownL + 0.02 * whiteL) / 1.02
                    ns.pointee.brownR = (ns.pointee.brownR + 0.02 * whiteR) / 1.02
                    sampleL = ns.pointee.brownL * 2.1   // loudness-matched (was 3.5)
                    sampleR = ns.pointee.brownR * 2.1
                }

                // Stereo-width control with mono-bass safety (see original notes): blend each
                // channel toward the mid (mono) signal so a summed mono speaker keeps its level.
                if isStereo {
                    let base: Float = (type == 2 || type == 5) ? 0.85 : 0.6
                    let width = min(base * p.stereoWidth, 1.0)
                    let mid  = (sampleL + sampleR) * 0.5
                    let side = (sampleL - sampleR) * 0.5
                    sampleL = mid + side * width
                    sampleR = mid - side * width
                }

                // Per-sample gain smoothing → no zipper/click on volume drag or toggle.
                // Flush to exact zero once inaudible (denormal guard).
                ns.pointee.noiseGCur += (targetG - ns.pointee.noiseGCur) * 0.0015
                if ns.pointee.noiseGCur < 1e-8 { ns.pointee.noiseGCur = 0 }
                let g = ns.pointee.noiseGCur

                ch0[f] = softClip(sampleL * g)
                if isStereo { ch1[f] = softClip(sampleR * g) }
            }
            return noErr
        }
    }

    private func setupEngine(startEngine: Bool = true) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [])
        try? session.setActive(true)

        let sr = Float(session.sampleRate)
        for i in 0..<kMaxNoiseLayers { (noiseStatePtr + i).pointee.sampleRate = sr }
        statePtr.pointee.sampleRate = sr
        let format = AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: 2)!

        // One source node per noise layer.
        noiseNodes = (0..<kMaxNoiseLayers).map { makeNoiseNode(index: $0) }

        binauralNode = AVAudioSourceNode { [statePtr, paramsBuffer, readIdx] _, _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            let ch0 = abl[0].mData!.assumingMemoryBound(to: Float.self)
            let ch1 = abl.count > 1 ? abl[1].mData!.assumingMemoryBound(to: Float.self) : ch0

            let p = paramsBuffer[SLPAtomicIndexLoadAcquire(readIdx)]

            // The beat node now owns its own fade smoothing (it used to read the noise node's,
            // which no longer exists once noise is split into independent layers).
            if statePtr.pointee.fadeMult > p.targetFadeMult {
                statePtr.pointee.fadeMult -= 0.001
                if statePtr.pointee.fadeMult < p.targetFadeMult { statePtr.pointee.fadeMult = p.targetFadeMult }
            } else if statePtr.pointee.fadeMult < p.targetFadeMult {
                statePtr.pointee.fadeMult += 0.001
                if statePtr.pointee.fadeMult > p.targetFadeMult { statePtr.pointee.fadeMult = p.targetFadeMult }
            }

            let targetG = p.binGain * statePtr.pointee.fadeMult * p.masterMult
            let sr = statePtr.pointee.sampleRate

            // Glide carrier + beat toward the selected preset so switching presets sweeps
            // smoothly (~0.2s) instead of jump-cutting the pitch. Phase stays continuous.
            statePtr.pointee.carrierCur += (p.carrier - statePtr.pointee.carrierCur) * 0.05
            statePtr.pointee.beatCur    += (p.beat    - statePtr.pointee.beatCur)    * 0.05
            if p.binMode == 1 {
                // Isochronic / speaker-safe: one MONO carrier tone, amplitude-modulated at the
                // beat rate, written to both channels.
                let twoPi = 2.0 * Double.pi
                let dC = twoPi * Double(statePtr.pointee.carrierCur) / Double(sr)
                let dM = twoPi * Double(statePtr.pointee.beatCur)    / Double(sr)
                for f in 0..<Int(frameCount) {
                    statePtr.pointee.binGCur += (targetG - statePtr.pointee.binGCur) * 0.0015
                    if statePtr.pointee.binGCur < 1e-8 { statePtr.pointee.binGCur = 0 }
                    let g = statePtr.pointee.binGCur
                    // Raised-cosine AM envelope (0…1): smooth pulse, click-free, gentle for sleep.
                    let env = Float(0.5 - 0.5 * cos(statePtr.pointee.modPhase))
                    let s = Float(sin(statePtr.pointee.phaseL)) * env * g * 1.4
                    ch0[f] = s
                    ch1[f] = s
                    statePtr.pointee.phaseL   += dC
                    statePtr.pointee.modPhase += dM
                    if statePtr.pointee.phaseL   > twoPi { statePtr.pointee.phaseL   -= twoPi }
                    if statePtr.pointee.modPhase > twoPi { statePtr.pointee.modPhase -= twoPi }
                }
            } else {
                // True binaural: separate L/R phases (carrier ∓ beat/2) create the inter-aural beat.
                let deltas = AudioMath.getBinauralPhaseDeltas(carrier: statePtr.pointee.carrierCur, beat: statePtr.pointee.beatCur, sampleRate: sr)
                let dL = deltas.dL
                let dR = deltas.dR
                for f in 0..<Int(frameCount) {
                    statePtr.pointee.binGCur += (targetG - statePtr.pointee.binGCur) * 0.0015
                    if statePtr.pointee.binGCur < 1e-8 { statePtr.pointee.binGCur = 0 }
                    let g = statePtr.pointee.binGCur
                    ch0[f] = Float(sin(statePtr.pointee.phaseL)) * g
                    ch1[f] = Float(sin(statePtr.pointee.phaseR)) * g

                    statePtr.pointee.phaseL += dL
                    statePtr.pointee.phaseR += dR

                    if statePtr.pointee.phaseL > 2 * .pi { statePtr.pointee.phaseL -= 2 * .pi }
                    if statePtr.pointee.phaseR > 2 * .pi { statePtr.pointee.phaseR -= 2 * .pi }
                }
            }
            return noErr
        }

        for node in noiseNodes { engine.attach(node) }
        engine.attach(binauralNode)

        let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                             componentSubType: kAudioUnitSubType_DynamicsProcessor,
                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                             componentFlags: 0, componentFlagsMask: 0)
        limiterNode = AVAudioUnitEffect(audioComponentDescription: desc)
        engine.attach(limiterNode)

        // Configure as a transparent safety limiter, NOT a compressor (high threshold so it only
        // catches hot peaks near 0 dBFS and never pumps on normal-level content). With multiple
        // noise layers summing, this is also the safety net that catches an over-hot stacked bed.
        let limiterAU = limiterNode.audioUnit
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_Threshold,   kAudioUnitScope_Global, 0, -2.0, 0)
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_HeadRoom,    kAudioUnitScope_Global, 0, 2.0, 0)
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_AttackTime,  kAudioUnitScope_Global, 0, 0.001, 0)
        AudioUnitSetParameter(limiterAU, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.10, 0)

        let mainMixer = engine.mainMixerNode

        for node in noiseNodes { engine.connect(node, to: mainMixer, format: format) }
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
        // Single-writer invariant: the writeIdx/readIdx double-buffer hand-off is only safe with
        // exactly one writer. Every caller reaches here on the main thread (UI didSets, intents,
        // and the sleep-timer fade which hops to main). Assert it in DEBUG so a future off-main
        // caller traps here instead of silently corrupting the buffer.
        #if DEBUG
        dispatchPrecondition(condition: .onQueue(.main))
        #endif
        let nextIdx = (writeIdx + 1) % 2
        var nextParams = paramsBuffer[writeIdx]
        closure(&nextParams)
        paramsBuffer[nextIdx] = nextParams
        SLPAtomicIndexStoreRelease(readIdx, nextIdx)
        writeIdx = nextIdx
    }

    // Ceilings cap how hard a full slider drives each generator, so ambient stays a
    // background bed that can't overpower a podcast.
    private static let noiseMaxGain: Float = 0.5
    private static let binauralMaxGain: Float = 0.15

    /// Set all noise layers at once. `layers` is ordered (layer 0 first); any slots beyond the
    /// supplied count are silenced. `on` is the bed master — when false, every layer is muted
    /// (types preserved so re-enabling doesn't cold-start a filter mid-night).
    func setNoiseLayers(_ layers: [(type: String, volume: Double)], on: Bool) {
        updateParams { p in
            for i in 0..<kMaxNoiseLayers {
                if i < layers.count {
                    let gain = on ? Float(layers[i].volume) * Self.noiseMaxGain : 0.0
                    setNoiseLayerParam(&p, i, gain: gain, type: Int32(mapNoiseType(layers[i].type)))
                } else {
                    // Unused slot: silence it but keep its last type for filter continuity.
                    let keepType = noiseLayerParam(p, i).type
                    setNoiseLayerParam(&p, i, gain: 0.0, type: Int32(keepType))
                }
            }
        }
    }

    /// Single-layer convenience (layer 0 only); clears the others. Kept so existing single-noise
    /// call sites compile unchanged.
    func setNoise(on: Bool, volume: Double, type: String) {
        setNoiseLayers([(type, volume)], on: on)
    }

    func setBinaural(on: Bool, volume: Double, preset: String) {
        updateParams { p in
            p.binGain = on ? Float(volume) * Self.binauralMaxGain : 0.0
            let params = AudioMath.getCarrierAndBeat(for: preset)
            p.carrier = params.carrier
            p.beat = params.beat
        }
    }

    /// Pick the beat render path: true binaural (headphones) or isochronic (speaker-safe).
    func setBeatMode(isochronic: Bool) {
        updateParams { p in p.binMode = isochronic ? 1 : 0 }
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

    /// Start the engine, retrying once after re-asserting the audio session. Logs and reports on
    /// final failure rather than swallowing the error.
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
                Log.audio.error("GenerativeAudioEngine.start failed [\(context, privacy: .public)]: \(error.localizedDescription, privacy: .public)")
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
            p.layerGain0 = 0.0
            p.layerGain1 = 0.0
            p.layerGain2 = 0.0
            p.binGain = 0.0
        }
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
        case "gray": return 8
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
