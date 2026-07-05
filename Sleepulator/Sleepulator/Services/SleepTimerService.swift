import Foundation
import UIKit
import Combine
import AVFoundation
import UserNotifications
import os
#if canImport(ActivityKit)
import ActivityKit
#endif

/// A redundant, out-of-process backstop for the sleep timer's terminal stop. The in-process
/// fade + stop (GCD timer + RMS/AVPlayer keep-alive) is the primary path; this only exists so
/// that if iOS suspends the app *through* the deadline, there is still (a) a user-visible signal
/// in Notification Center, and (b) a launch hook that lets `reconcileIfExpired` stop audio the
/// instant the app is foregrounded again. Injected so it can be spied in unit tests.
protocol SleepTimerBackstopScheduling {
    /// Schedule the backstop to fire `seconds` from now, replacing any previously scheduled one.
    func schedule(after seconds: TimeInterval)
    /// Remove any pending/delivered backstop (the in-process stop fired, or the timer was cancelled).
    func cancel()
}

/// Default backstop: a single local notification. Uses *provisional* authorization, which is
/// granted silently (no permission prompt) and delivers quietly to Notification Center — a net
/// that never nags a user whose timer ended normally (we cancel it on the in-process fire).
final class NotificationBackstopScheduler: SleepTimerBackstopScheduling {
    static let identifier = "app.sleepulator.sleeptimer.backstop"
    private var requestedAuth = false

    func schedule(after seconds: TimeInterval) {
        guard seconds > 0 else { return }
        let center = UNUserNotificationCenter.current()
        requestProvisionalAuthIfNeeded(center)

        let content = UNMutableNotificationContent()
        content.title = "Sleep timer finished"
        content.body = "Sleepulator stopped playback."
        content.sound = nil   // quiet — the point is to stop sound, not make more

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let req = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: trigger)
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.add(req)
    }

    func cancel() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
    }

    private func requestProvisionalAuthIfNeeded(_ center: UNUserNotificationCenter) {
        guard !requestedAuth else { return }
        requestedAuth = true
        center.requestAuthorization(options: [.alert, .provisional]) { _, _ in }
    }
}

/// Terminal-stop guarantee, layered (know the boundary before "fixing" any one layer):
/// 1. GCD wall-clock timer (1 Hz) — primary, but iOS may curtail it when backgrounded.
/// 2. `backgroundTick()` — driven ~20×/s off the limiter RMS tap / AVPlayer observer; as long
///    as audio is actually playing the app isn't suspended, so this is what really carries the
///    fade + stop through a locked night.
/// 3. `reconcileIfExpired()` on foreground — catches a deadline that passed while suspended.
/// 4. `NotificationBackstopScheduler` — out-of-process, quiet notification; last resort.
/// The unguarded case: iOS suspends the app *with audio somehow still owed a stop* and the user
/// never foregrounds it. That requires the audio path to already be dead (no tap ticks), so
/// there is nothing left to stop — accepted. Verify on device per TESTING.md §3C.
final class SleepTimerService: ObservableObject {
    /// What kind of timer is running. `.endOfEpisode` is driven by the podcast playback clock
    /// (via `externalTick`) rather than the wall-clock GCD timer, so it tracks pauses/seeks/speed.
    enum TimerKind { case none, duration, endOfEpisode }
    @Published private(set) var kind: TimerKind = .none
    /// True while the active timer follows the current episode rather than a fixed duration.
    var isEndOfEpisode: Bool { kind == .endOfEpisode }

    @Published var timerRemaining: TimeInterval = 0
    /// The timer's original length — denominator for `nightProgress` so the moon knows
    /// how far through the night it should be. 0 when no timer is running.
    @Published var timerTotal: TimeInterval = 0

    /// 0 at the start of a sleep timer, →1 as it runs out; 0 when idle. Drives the
    /// setting-moon position and the sky-darkening overlay.
    var nightProgress: Double {
        guard timerTotal > 0 else { return 0 }
        return min(1, max(0, 1 - timerRemaining / timerTotal))
    }

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

    // MARK: Ambient tail — "keep the bed going after the podcast fades"
    /// Seconds of ambient-only playback appended after the podcast stops at expiry (0 = off).
    /// Read live from the owner so a Settings change applies to the running timer.
    var ambientTailFn: () -> TimeInterval = { 0 }
    /// True when a tail makes sense right now: a podcast is playing AND an ambient bed is on.
    var tailEligibleFn: () -> Bool = { false }
    /// Stops just the podcast at phase-1 expiry; the noise/binaural bed plays through the tail.
    var stopPodcastFn: (() -> Void)?

    /// Published (rare — flips at most twice a night) so in-app bump surfaces can hide with
    /// the Live Activity's "+15m": bumpTimer() drops the intent in-tail, and a visible button
    /// that haptics-then-does-nothing at the drowsiest moment of the night is worse than none.
    @Published private(set) var inTail = false
    private var tailDuration: TimeInterval = 1
    /// The fade level at the moment the tail began. The tail fade continues DOWN from here —
    /// never a jump back to full volume right as the podcast drops out (that's a wake-up).
    private var tailStartMult: Double = 1.0
    /// Last multiplier handed to `updateFadeMultFn` — the tail's starting point.
    private var lastFadeMult: Double = 1.0

    /// Phase 1 → 2 of the terminal stop: silence the podcast, extend the deadline by the tail,
    /// and let the (already partly faded) ambient bed carry on, easing to silence over the tail.
    /// Runs on the main queue (callers are tick()/externalTick() main-queue blocks).
    private func beginTail() {
        inTail = true
        tailDuration = max(60, ambientTailFn())
        tailStartMult = lastFadeMult
        stopPodcastFn?()
        let end = Date().addingTimeInterval(tailDuration)
        sleepTimerEnd = end
        timerTotal += tailDuration      // the moon keeps easing down, never snaps back up
        timerRemaining = tailDuration
        backstop.schedule(after: tailDuration)
        updateLiveActivity()
    }

    /// Out-of-process safety net for the terminal stop (see protocol doc). Injectable for tests.
    var backstop: SleepTimerBackstopScheduling = NotificationBackstopScheduler()

    func startSleepTimer(minutes: Int) {
        cancelTimer()
        kind = .duration
        let endDate = Date().addingTimeInterval(Double(minutes) * 60)
        sleepTimerEnd = endDate
        didFire = false
        self.timerRemaining = Double(minutes) * 60
        self.timerTotal = Double(minutes) * 60
        updateFadeMultFn?(1.0)

        backstop.schedule(after: Double(minutes) * 60)

        startLiveActivity()

        armTick()
    }

    /// Create + start the 1 Hz GCD wall-clock timer. Split out of `startSleepTimer` so the
    /// end-of-episode → ambient-tail handoff (which becomes a duration timer) can arm it too.
    private func armTick() {
        sleepTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
        t.schedule(deadline: .now() + 1.0, repeating: 1.0)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        t.resume()
        sleepTimer = t
    }

    /// Start an "until this episode ends" timer. There's no GCD timer — `AudioEngine` feeds the
    /// episode's remaining time through `externalTick(remaining:)` off the AVPlayer observer, so
    /// it naturally tracks pauses, seeks, and playback speed. The fade + terminal stop reuse the
    /// same machinery as the duration timer. `remaining` is the real-time seconds left.
    func startEndOfEpisode(remaining: TimeInterval) {
        cancelTimer()
        kind = .endOfEpisode
        didFire = false
        sleepTimerEnd = Date().addingTimeInterval(remaining)   // approx, for the Live Activity countdown
        self.timerRemaining = remaining
        self.timerTotal = remaining
        updateFadeMultFn?(1.0)
        // Approximate net only — the real episode end is driven by the playback clock via
        // externalTick, but if the app is suspended through it this still flags the deadline.
        backstop.schedule(after: remaining)
        startLiveActivity()
    }

    /// Called when the app returns to the foreground. If a fixed-duration timer's deadline already
    /// passed while the app was suspended (so neither the GCD tick nor the keep-alive could fire),
    /// run the terminal stop immediately. The end-of-episode timer needs no equivalent: its stop is
    /// driven by the playback clock, which resumes ticking — and fires `onQueueAdvance` at the true
    /// episode end — as soon as the player is foregrounded.
    func reconcileIfExpired() {
        guard kind == .duration, !didFire, let end = sleepTimerEnd else { return }
        guard Date() >= end else { return }
        if timerRemaining != 0 { timerRemaining = 0 }
        didFire = true
        stopAllFn?()
        cancelTimer(resetMoon: false)
    }

    /// Drive the end-of-episode timer from the podcast clock. Runs on the main queue (its caller
    /// dispatches there). Fades over the final stretch and fires the terminal stop once.
    func externalTick(remaining: TimeInterval) {
        guard kind == .endOfEpisode, !didFire else { return }
        if remaining <= 0.4 {
            // Ambient tail: the episode is over — hand off to a duration timer for the tail
            // span so the bed eases you the rest of the way down instead of cutting with the
            // episode. beginTail() pauses the podcast before AVPlayer would auto-advance.
            if !inTail, ambientTailFn() > 0, tailEligibleFn() {
                kind = .duration
                beginTail()
                armTick()   // end-of-episode had no wall-clock timer; the tail needs one
                return
            }
            if self.timerRemaining != 0 { self.timerRemaining = 0 }
            didFire = true
            stopAllFn?()
            cancelTimer(resetMoon: false)
            return
        }
        if Int(remaining) != Int(self.timerRemaining) { self.timerRemaining = remaining }
        // Carry the ambient bed gently down to silence as the episode ends. Fade only over the
        // final 90 s (or the whole episode if it's shorter than that), full volume before then.
        let fadeDur = min(90.0, max(1.0, self.timerTotal))
        let mult = Double(AudioMath.getFadeMultiplier(timerRemaining: remaining, fadeDuration: fadeDur))
        lastFadeMult = mult
        updateFadeMultFn?(mult)
    }

    func backgroundTick() {
        tick()
    }
    
    private func tick() {
        // tick() runs on the GCD timer's global queue AND from backgroundTick() (RMS tap / AVPlayer
        // observer). Read all timer state on the main queue to avoid racing the main-thread writers
        // (start/cancel); only the fire time is captured off-main here.
        let now = Date()

        DispatchQueue.main.async {
            // Only the wall-clock duration timer ticks here. The end-of-episode timer is driven by
            // externalTick() off the playback clock; backgroundTick() still calls this ~20×/sec, so
            // without this guard the (approximate) wall-clock end would race the real episode end.
            guard self.kind == .duration, let end = self.sleepTimerEnd else { return }
            let remaining = end.timeIntervalSince(now)
            if remaining <= 0 {
                // Ambient tail (phase 1 → 2): with a tail configured and a podcast still in the
                // mix, stop only the podcast and extend the deadline — the bed plays on, fading
                // from its current level over the tail. The final stop fires at the new deadline.
                if !self.inTail, !self.didFire, self.ambientTailFn() > 0, self.tailEligibleFn() {
                    self.beginTail()
                    return
                }
                // Publish the terminal value once, then fire exactly once.
                if self.timerRemaining != 0 { self.timerRemaining = 0 }
                guard !self.didFire else { return }
                self.didFire = true
                self.stopAllFn?()
                self.cancelTimer(resetMoon: false)
                return
            }

            // Coalesce the @Published write to ~1Hz. backgroundTick() fires ~20×/sec from the
            // limiter RMS tap (the all-night keep-alive that drives the fade + terminal stop
            // even when iOS curtails the GCD timer), but publishing `timerRemaining` 20×/sec
            // re-rendered every view observing the engine — the podcast-list scroll storm.
            // Only the SwiftUI publish is throttled to whole-second changes (the display is in
            // minutes anyway); the fade update + expiry check below still run on every tick.
            if Int(remaining) != Int(self.timerRemaining) {
                self.timerRemaining = remaining
            }
            // During the tail, continue DOWN from the level the fade had already reached
            // (tailStartMult) across the tail span — never back up to full volume.
            let mult: Double = self.inTail
                ? self.tailStartMult * Double(AudioMath.getFadeMultiplier(timerRemaining: remaining, fadeDuration: self.tailDuration))
                : Double(AudioMath.getFadeMultiplier(timerRemaining: remaining))
            self.lastFadeMult = mult
            self.updateFadeMultFn?(mult)
            // Update live activity periodically (e.g., every 15 mins or when a bump occurs)
            // ActivityKit doesn't recommend updating every second.
        }
    }

    func bumpTimer() {
        // Only meaningful for the fixed-duration timer; you can't extend an episode.
        guard kind == .duration else { return }
        // Never during the ambient tail: the snap to full volume below would blast an
        // already-faded bed to 100% mid-drift-off — the exact wake-up the tail exists to
        // prevent — and the tail fade math would then freeze near-silent for the added span.
        // The Live Activity hides "+15m" while in-tail (ContentState.isInTail), but the
        // notification can still arrive from a stale render or a Shortcut; drop it here too.
        guard !inTail else { return }
        if let currentEnd = sleepTimerEnd {
            let newEnd = currentEnd.addingTimeInterval(15 * 60)
            sleepTimerEnd = newEnd
            self.timerRemaining += 15 * 60
            // Grow the total too, so the moon eases back up the arc proportionally.
            self.timerTotal += 15 * 60

            if self.timerRemaining > 600 {
                self.updateFadeMultFn?(1.0)
            }

            // Move the out-of-process net to the new, later deadline.
            backstop.schedule(after: self.timerRemaining)

            updateLiveActivity()
        }
    }

    func cancelTimer(resetMoon: Bool = true) {
        sleepTimer?.cancel()
        sleepTimer = nil
        sleepTimerEnd = nil
        kind = .none
        timerRemaining = 0
        inTail = false
        tailStartMult = 1.0
        lastFadeMult = 1.0
        // Tear down the out-of-process net too: the in-process stop fired, or the user/mode
        // switch cancelled the timer. (Also fires on the terminal stop, which calls this.)
        backstop.cancel()
        // On a natural finish, keep timerTotal so nightProgress stays 1 and the moon stays
        // set at the horizon instead of gliding back up the instant the night ends. A fresh
        // startSleepTimer resets it; an explicit cancel (mode switch / UI) resets it here.
        if resetMoon { timerTotal = 0 }
        updateFadeMultFn?(1.0)
        
        endLiveActivity()
        

    }
    
    // MARK: - Live Activity
    private func startLiveActivity() {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        
        let attributes = SleepTimerAttributes()
        let contentState = SleepTimerAttributes.ContentState(timerRemaining: timerRemaining, endDate: sleepTimerEnd, isEndOfEpisode: kind == .endOfEpisode, isInTail: inTail)
        let content = ActivityContent(state: contentState, staleDate: sleepTimerEnd)

        do {
            currentActivity = try Activity.request(attributes: attributes, content: content)
        } catch {
            Log.audio.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
        }
        #endif
    }

    private func updateLiveActivity() {
        #if canImport(ActivityKit)
        guard let activity = currentActivity else { return }
        let contentState = SleepTimerAttributes.ContentState(timerRemaining: timerRemaining, endDate: sleepTimerEnd, isEndOfEpisode: kind == .endOfEpisode, isInTail: inTail)
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
    /// Work intervals finished in the current set — drives the cycle dots.
    @Published var completedCycles = 0
    /// True while the active rest is a long break (every `cyclesBeforeLongBreak`th).
    @Published var restIsLong = false

    var workMinutes: Int { didSet { UserDefaults.standard.set(workMinutes, forKey: "pomoWork") } }
    var restMinutes: Int { didSet { UserDefaults.standard.set(restMinutes, forKey: "pomoRest") } }
    var longRestMinutes: Int { didSet { UserDefaults.standard.set(longRestMinutes, forKey: "pomoLongRest") } }
    var cyclesBeforeLongBreak: Int { didSet { UserDefaults.standard.set(cyclesBeforeLongBreak, forKey: "pomoCycles") } }

    /// Called at every phase boundary so the owner can play a chime.
    var chimeFn: (() -> Void)?
    /// Fired on start, every phase boundary, and stop — (newPhase, isRunning). AudioEngine
    /// uses it to soften the ambient bed during breaks (FOCUS-MODE-SPEC R6).
    var phaseChangedFn: ((Phase, Bool) -> Void)?

    private var timer: DispatchSourceTimer?
    private var phaseEnd: Date?
    private static let phaseNotifId = "app.sleepulator.pomodoro.phase"
    private var requestedNotifAuth = false
    #if canImport(ActivityKit)
    private var pomoActivity: Activity<PomodoroAttributes>?
    #endif
    /// Length of the phase currently counting down — denominator for `progress`.
    private var phaseTotal: TimeInterval = 0

    /// Fraction of the current phase already elapsed (0…1) — drives the ring fill.
    var progress: Double {
        guard phaseTotal > 0 else { return 0 }
        return min(1, max(0, 1 - remaining / phaseTotal))
    }

    /// Continuous elapsed fraction at `now`, computed from the phase end-date rather than the
    /// 1 Hz-published `remaining` — lets the Focus ring deplete smoothly between ticks instead of
    /// stepping once a second. Reads `phaseEnd`/`phaseTotal` (set on the main thread); call on the
    /// main thread. Falls back to the published `progress` when idle.
    func progress(at now: Date) -> Double {
        guard isRunning, phaseTotal > 0, let end = phaseEnd else { return progress }
        let remainingNow = max(0, end.timeIntervalSince(now))
        return min(1, max(0, 1 - remainingNow / phaseTotal))
    }

    /// Seconds since the current phase began (0 exactly at a boundary). Lets the ring ease its
    /// arc back in over the first moment of a new phase instead of snapping from empty to full.
    /// Same main-thread read discipline as `progress(at:)`; 0 when idle.
    func phaseElapsed(at now: Date) -> TimeInterval {
        guard isRunning, phaseTotal > 0, let end = phaseEnd else { return 0 }
        return max(0, phaseTotal - max(0, end.timeIntervalSince(now)))
    }

    init() {
        workMinutes = UserDefaults.standard.object(forKey: "pomoWork") as? Int ?? 25
        restMinutes = UserDefaults.standard.object(forKey: "pomoRest") as? Int ?? 5
        longRestMinutes = UserDefaults.standard.object(forKey: "pomoLongRest") as? Int ?? 15
        cyclesBeforeLongBreak = UserDefaults.standard.object(forKey: "pomoCycles") as? Int ?? 4
    }

    deinit { timer?.cancel() }

    func start() {
        stop()
        phase = .work
        completedCycles = 0
        restIsLong = false
        beginPhase(minutes: workMinutes)
        isRunning = true
        phaseChangedFn?(.work, true)
        schedulePhaseEndNotification()
        startLiveActivity()

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
        cancelPhaseEndNotification()
        endLiveActivity()
        phaseChangedFn?(phase, false)
    }

    /// Skip the rest of the current phase — end a break early, or bail out of a work interval
    /// (which still counts the cycle, matching the natural boundary's accounting).
    func skipPhase() {
        guard isRunning else { return }
        advancePhase()
    }

    private func beginPhase(minutes: Int) {
        let secs = Double(minutes) * 60
        phaseEnd = Date().addingTimeInterval(secs)
        phaseTotal = secs
        remaining = secs
    }

    private func tick() {
        // Runs on the GCD timer's global queue; read phaseEnd on main to avoid racing start/stop.
        let now = Date()
        DispatchQueue.main.async {
            guard self.isRunning, let end = self.phaseEnd else { return }
            let r = end.timeIntervalSince(now)
            if r <= 0 {
                self.advancePhase()
            } else {
                self.remaining = r
            }
        }
    }

    /// One phase boundary — natural (tick) or user skip: chime, flip work↔rest, notify the
    /// owner, and re-arm the backgrounded-phase-end notification + Live Activity.
    private func advancePhase() {
        chimeFn?()
        if phase == .work {
            // Finished a work interval. Every Nth one earns a long break.
            completedCycles += 1
            let longDue = completedCycles % max(1, cyclesBeforeLongBreak) == 0
            restIsLong = longDue
            phase = .rest
            beginPhase(minutes: longDue ? longRestMinutes : restMinutes)
        } else {
            restIsLong = false
            phase = .work
            beginPhase(minutes: workMinutes)
        }
        phaseChangedFn?(phase, true)
        schedulePhaseEndNotification()
        updateLiveActivity()
    }

    // MARK: Backgrounded phase-end notification (FOCUS-MODE-SPEC R5)
    // The chime only sounds while the app is rendering audio; pause the bed and background the
    // app and phase boundaries would pass silently. A local notification at each phase end
    // covers that — iOS suppresses it while the app is foreground (no delegate opts in), so
    // active users just hear the chime. Provisional auth: quiet, no permission prompt.

    private func schedulePhaseEndNotification() {
        let center = UNUserNotificationCenter.current()
        if !requestedNotifAuth {
            requestedNotifAuth = true
            center.requestAuthorization(options: [.alert, .provisional]) { _, _ in }
        }
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseNotifId])
        guard let end = phaseEnd else { return }
        let secs = end.timeIntervalSinceNow
        guard secs > 1 else { return }

        let content = UNMutableNotificationContent()
        if phase == .work {
            content.title = "Focus interval finished"
            content.body = "Time for a \(restIsLongNext ? "long break" : "break")."
        } else {
            content.title = "Break's over"
            content.body = "Back to focus."
        }
        content.sound = nil   // the in-app chime covers foreground; keep the net quiet
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, secs), repeats: false)
        center.add(UNNotificationRequest(identifier: Self.phaseNotifId, content: content, trigger: trigger))
    }

    /// Whether the break that FOLLOWS the current work interval will be a long one.
    private var restIsLongNext: Bool {
        (completedCycles + 1) % max(1, cyclesBeforeLongBreak) == 0
    }

    private func cancelPhaseEndNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.phaseNotifId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.phaseNotifId])
    }

    // MARK: Live Activity (lock screen / Dynamic Island ring for the running session)
    // Updated only at phase boundaries — ActivityKit's own countdown text ticks per-second
    // for free via `endDate`, so no per-second updates are pushed.

    private func startLiveActivity() {
        #if canImport(ActivityKit)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let content = ActivityContent(state: pomoState(), staleDate: phaseEnd)
        pomoActivity = try? Activity.request(attributes: PomodoroAttributes(), content: content)
        #endif
    }

    private func updateLiveActivity() {
        #if canImport(ActivityKit)
        guard let activity = pomoActivity else { return }
        let content = ActivityContent(state: pomoState(), staleDate: phaseEnd)
        Task { await activity.update(content) }
        #endif
    }

    private func endLiveActivity() {
        #if canImport(ActivityKit)
        guard let activity = pomoActivity else { return }
        let content = ActivityContent(state: pomoState(), staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .immediate) }
        pomoActivity = nil
        #endif
    }

    #if canImport(ActivityKit)
    private func pomoState() -> PomodoroAttributes.ContentState {
        PomodoroAttributes.ContentState(
            isWork: phase == .work,
            isLongBreak: restIsLong,
            endDate: phaseEnd,
            cycle: min((completedCycles % max(1, cyclesBeforeLongBreak)) + 1, max(1, cyclesBeforeLongBreak)),
            totalCycles: max(1, cyclesBeforeLongBreak)
        )
    }
    #endif
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
