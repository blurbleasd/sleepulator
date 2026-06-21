import Foundation
import UIKit
import Combine
import AVFoundation
#if canImport(ActivityKit)
import ActivityKit
#endif

final class SleepTimerService: ObservableObject {
    @Published var timerRemaining: TimeInterval = 0
    private var sleepTimer: DispatchSourceTimer?
    private var sleepTimerEnd: Date?
    // tick() runs from the GCD timer AND from backgroundTick() (RMS tap + AVPlayer observer),
    // so several threads can hit expiry at once. This guards the terminal stop to fire exactly
    // once. Checked/set only on the main queue, so no extra locking is needed.
    private var didFire = false

    
    #if canImport(ActivityKit)
    private var currentActivity: Activity<SleepTimerAttributes>?
    #endif
    
    var stopAllFn: (() -> Void)?
    var updateFadeMultFn: ((Double) -> Void)?
    
    func startSleepTimer(minutes: Int) {
        cancelTimer()
        let endDate = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = endDate
        didFire = false
        self.timerRemaining = Double(minutes) * 60
        updateFadeMultFn?(1.0)
        

        
        startLiveActivity()
        
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        sleepTimer = t
    }
    
    func backgroundTick() {
        tick()
    }
    
    private func tick() {
        guard let end = self.sleepTimerEnd else { return }
        let remaining = end.timeIntervalSince(Date())
        
        DispatchQueue.main.async {
            self.timerRemaining = remaining
            if remaining <= 0 {
                guard !self.didFire else { return }
                self.didFire = true
                self.stopAllFn?()
                self.cancelTimer()
            } else {
                self.updateFadeMultFn?(Double(AudioMath.getFadeMultiplier(timerRemaining: remaining)))
                // Update live activity periodically (e.g., every 15 mins or when a bump occurs)
                // ActivityKit doesn't recommend updating every second.
            }
        }
    }

    func bumpTimer() {
        if let currentEnd = sleepTimerEnd {
            let newEnd = currentEnd.addingTimeInterval(15 * 60)
            sleepTimerEnd = newEnd
            self.timerRemaining += 15 * 60
            
            if self.timerRemaining > 600 {
                self.updateFadeMultFn?(1.0)
            }
            
            updateLiveActivity()
        }
    }

    func cancelTimer() {
        sleepTimer?.cancel()
        sleepTimer = nil
        sleepTimerEnd = nil
        timerRemaining = 0
        updateFadeMultFn?(1.0)
        
        endLiveActivity()
        

    }
    
    // MARK: - Live Activity
    private func startLiveActivity() {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        let attributes = SleepTimerAttributes()
        let contentState = SleepTimerAttributes.ContentState(timerRemaining: timerRemaining, endDate: sleepTimerEnd)
        let content = ActivityContent(state: contentState, staleDate: sleepTimerEnd)
        
        do {
            currentActivity = try Activity.request(attributes: attributes, content: content)
        } catch {
            print("Failed to start activity: \(error)")
        }
        #endif
    }
    
    private func updateLiveActivity() {
        #if canImport(ActivityKit)
        guard let activity = currentActivity else { return }
        let contentState = SleepTimerAttributes.ContentState(timerRemaining: timerRemaining, endDate: sleepTimerEnd)
        let content = ActivityContent(state: contentState, staleDate: sleepTimerEnd)
        
        Task {
            await activity.update(content)
        }
        #endif
    }
    
    private func endLiveActivity() {
        #if canImport(ActivityKit)
        guard let activity = currentActivity else { return }
        let contentState = SleepTimerAttributes.ContentState(timerRemaining: 0, endDate: nil)
        let content = ActivityContent(state: contentState, staleDate: nil)
        
        Task {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        currentActivity = nil
        #endif
    }
}

// MARK: - Pomodoro (focus mode timer)

/// A looping work/break timer for Focus mode. Unlike the sleep timer it never fades
/// or stops the audio — it just marks interval boundaries with a chime. Ambient and
/// binaural keep playing the whole time.
final class PomodoroService: ObservableObject {
    enum Phase { case work, rest }

    @Published var isRunning = false
    @Published var phase: Phase = .work
    @Published var remaining: TimeInterval = 0

    var workMinutes: Int { didSet { UserDefaults.standard.set(workMinutes, forKey: "pomoWork") } }
    var restMinutes: Int { didSet { UserDefaults.standard.set(restMinutes, forKey: "pomoRest") } }

    /// Called at every phase boundary so the owner can play a chime.
    var chimeFn: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var phaseEnd: Date?

    init() {
        workMinutes = UserDefaults.standard.object(forKey: "pomoWork") as? Int ?? 25
        restMinutes = UserDefaults.standard.object(forKey: "pomoRest") as? Int ?? 5
    }

    deinit { timer?.cancel() }

    func start() {
        stop()
        phase = .work
        beginPhase(minutes: workMinutes)
        isRunning = true

        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    func stop() {
        timer?.cancel()
        timer = nil
        phaseEnd = nil
        isRunning = false
        remaining = 0
    }

    private func beginPhase(minutes: Int) {
        phaseEnd = Date().addingTimeInterval(Double(minutes) * 60)
        remaining = Double(minutes) * 60
    }

    private func tick() {
        guard let end = phaseEnd else { return }
        let r = end.timeIntervalSince(Date())
        DispatchQueue.main.async {
            guard self.isRunning else { return }
            if r <= 0 {
                self.chimeFn?()
                if self.phase == .work {
                    self.phase = .rest
                    self.beginPhase(minutes: self.restMinutes)
                } else {
                    self.phase = .work
                    self.beginPhase(minutes: self.workMinutes)
                }
            } else {
                self.remaining = r
            }
        }
    }
}

// MARK: - Chime

/// Plays a soft synthesized bell at Pomodoro boundaries. Built once in memory as a
/// WAV and played through AVAudioPlayer, which mixes with the engine and AVPlayer.
final class ChimePlayer {
    private var player: AVAudioPlayer?

    init() {
        guard let data = ChimePlayer.makeBell() else { return }
        player = try? AVAudioPlayer(data: data)
        player?.volume = 0.6
        player?.prepareToPlay()
    }

    func play() {
        player?.currentTime = 0
        player?.play()
    }

    private static func makeBell() -> Data? {
        let sr = 44100.0
        let n = Int(sr * 1.1)
        var samples = [Int16](repeating: 0, count: n)
        let f0 = 587.33 // D5
        let partials: [(Double, Double)] = [(1.0, 1.0), (2.0, 0.5), (2.76, 0.25)]
        let ampSum = 1.75
        for i in 0..<n {
            let t = Double(i) / sr
            let env = exp(-t * 4.0)
            let attack = min(1.0, t / 0.005) // 5ms attack to avoid a click
            var s = 0.0
            for (ratio, amp) in partials { s += sin(2 * .pi * f0 * ratio * t) * amp }
            s *= env * attack * 0.28 / ampSum
            let v = max(-1.0, min(1.0, s))
            samples[i] = Int16(v * 32767)
        }
        return ChimePlayer.wav(samples: samples, sampleRate: Int(sr))
    }

    private static func wav(samples: [Int16], sampleRate: Int) -> Data {
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let dataSize = samples.count * 2
        var d = Data()
        d.append("RIFF".data(using: .ascii)!)
        d.append(u32(UInt32(36 + dataSize)))
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(u32(16))
        d.append(u16(1))                      // PCM
        d.append(u16(1))                      // mono
        d.append(u32(UInt32(sampleRate)))
        d.append(u32(UInt32(sampleRate * 2))) // byte rate
        d.append(u16(2))                      // block align
        d.append(u16(16))                     // bits per sample
        d.append("data".data(using: .ascii)!)
        d.append(u32(UInt32(dataSize)))
        for s in samples { d.append(u16(UInt16(bitPattern: s))) }
        return d
    }
}
