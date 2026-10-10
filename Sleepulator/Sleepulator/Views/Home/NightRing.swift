import SwiftUI

/// Pure geometry and rules for the night ring (unit-tested). The dial is 120 minutes around:
/// 12 o'clock is 0 ("All night", no timer), lengths run clockwise and snap to 5.
enum NightRingMath {
    static let dialMinutes = 120
    static let step = 5

    /// Minutes for a touch `angle` radians clockwise from 12 o'clock, snapped to 5. Under 5 is 0.
    static func minutes(forAngle angle: Double) -> Int {
        var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        let raw = a / (2 * .pi) * Double(dialMinutes)
        let snapped = Int((raw / Double(step)).rounded()) * step
        return snapped < step ? 0 : min(dialMinutes, snapped)
    }

    /// How much of the ring a length fills. Lengths past the dial (a bumped timer) pin to full.
    static func fraction(forMinutes m: Double) -> Double { max(0, min(1, m / Double(dialMinutes))) }

    /// Keeps a drag from wrapping across 12 o'clock: sweeping past the top pins to the end you came
    /// from instead of jumping between All night and two hours. Once pinned, it stays pinned until
    /// the finger comes back round on the near half of the dial (no jump to 85 or 35 from overshoot).
    static func continuous(previous: Int, raw: Int) -> Int {
        if previous == 0 && raw > dialMinutes / 2 { return 0 }
        if previous == dialMinutes && raw < dialMinutes / 2 { return dialMinutes }
        if previous >= 90 && raw <= 30 { return dialMinutes }
        if previous <= 30 && raw >= 90 { return 0 }
        return raw
    }

    /// Angle of `p` around `center`, clockwise from 12 o'clock, in [0, 2π).
    static func angle(of p: CGPoint, center c: CGPoint) -> Double {
        let a = atan2(Double(p.x - c.x), Double(c.y - p.y))
        return a < 0 ? a + 2 * .pi : a
    }

    enum Commit: Equatable { case none, start(Int), cancel }

    /// What letting go of the ring does. At rest it only sets the length, which Play then honours.
    /// Over a live session (playing, or a countdown running while paused) it restarts the timer at
    /// the new length, or turns it off at All night.
    static func commit(minutes: Int, playing: Bool, timerActive: Bool) -> Commit {
        guard playing || timerActive else { return .none }
        if minutes == 0 { return timerActive ? .cancel : .none }
        return .start(minutes)
    }

    /// The fade-out window (AudioMath.getFadeMultiplier fades over the last 600 s).
    static let fadeWindow: TimeInterval = 600

    /// The ring holds still once the night is fading (the last 10 minutes, either timer kind) and
    /// through the ambient tail. A restart there would snap a fading bed back up to full volume —
    /// the wake-up this app exists to prevent. "+15m" is the control in the last two minutes.
    static func locked(remaining: TimeInterval, inTail: Bool, endOfEpisode: Bool) -> Bool {
        inTail || (remaining > 0 && remaining <= fadeWindow)
    }

    /// A remembered length read back from storage, made safe to use: a hand-edited backup could
    /// restore anything, and `Int(1e300)` traps at launch.
    static func sanitized(_ minutes: Double) -> Double {
        minutes.isFinite ? max(0, min(Double(dialMinutes), minutes)) : 0
    }

    /// One VoiceOver adjustment, on the 5-minute grid: up goes to the next mark (43 → 45), down to
    /// the one below (43 → 40, 5 → All night). Never past the dial, and "up" never shortens a night
    /// that is already longer than the dial (an end-of-episode timer with 150 min left stays 150).
    static func adjusted(_ minutes: Int, up: Bool) -> Int {
        if up {
            guard minutes < dialMinutes else { return minutes }
            return min(dialMinutes, (max(0, minutes) / step + 1) * step)
        }
        guard minutes > 0 else { return 0 }
        return ((minutes - 1) / step) * step
    }

    /// The remembered length is kept on the dial (the timer sheet's slider is 5…120).
    static func storable(_ minutes: Int) -> Double { Double(max(0, min(dialMinutes, minutes))) }

    static func spoken(minutes: Int) -> String { minutes == 0 ? "All night" : "\(minutes) minutes" }
}

/// The night ring around the Sleep orb: the night-length setting and, while a timer runs, the
/// night left. Drag the handle to set it; Play honours it (HomeView). A dim ember arc on a faint
/// track, never brighter than the orb it circles. Observes the timer itself (like BumpTimerButton)
/// so the 1 Hz countdown re-renders only this leaf, never HomeView.
struct NightRing: View {
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette
    let playing: Bool
    /// The remembered night length (0 = All night). Persisted by HomeView.
    @Binding var lengthMinutes: Double
    /// True while a ring drag is live, so Home's left/right scene swipe stands down.
    @Binding var dragging: Bool
    let openOptions: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragMinutes: Int?
    /// Where the drag picked the ring up, so a wobble that ends where it began changes nothing
    /// (no timer restart, no Live Activity churn).
    @State private var dragStart: Int?
    /// A drag that began away from the handle (a scene swipe crossing the ring) is ignored whole.
    @State private var rejected = false
    /// Live for exactly as long as the touch: resets on its own when the gesture is cancelled
    /// (an incoming call, a system gesture, the chrome losing hit testing), when `onEnded` never
    /// runs. Its reset is where the drag state is cleared, so a cancel can't leave the ring stuck.
    @GestureState private var touchLive = false
    /// VoiceOver steps settle before they restart the timer: each restart re-requests the Live
    /// Activity, and a run of swipes shouldn't churn it.
    @State private var pendingMinutes: Int?
    @State private var pendingCommit: DispatchWorkItem?

    /// The drawn ring; the frame adds touch slop around it for the handle.
    static let ringSize: CGFloat = 214
    static let frameSize: CGFloat = 250
    static let line: CGFloat = 4
    private static let handleSlop: CGFloat = 34
    private var radius: CGFloat { (Self.ringSize - Self.line) / 2 }

    private var timerActive: Bool { sleepTimer.timerRemaining > 0 }
    private var locked: Bool {
        NightRingMath.locked(remaining: sleepTimer.timerRemaining, inTail: sleepTimer.inTail,
                             endOfEpisode: sleepTimer.isEndOfEpisode)
    }

    /// What the ring shows: the drag, else the running timer, else (at rest) the remembered
    /// length. Playing with no timer is honestly All night, whatever length is remembered.
    private var shownMinutes: Double {
        if let d = dragMinutes ?? pendingMinutes { return Double(d) }
        if timerActive { return sleepTimer.timerRemaining / 60 }
        return playing ? 0 : lengthMinutes
    }

    /// What VoiceOver steps from: what the ring shows, on the 5-minute grid. (Playing with no timer
    /// is All night, so the first swipe up is 5 min, not the remembered length + 5.)
    private var gridMinutes: Int {
        if let p = pendingMinutes { return p }
        let m = shownMinutes
        if timerActive && m > Double(NightRingMath.dialMinutes) { return Int(m.rounded()) }
        return Int((m / Double(NightRingMath.step)).rounded()) * NightRingMath.step
    }

    private var spokenValue: String {
        if pendingMinutes == nil && timerActive {
            return sleepTimer.isEndOfEpisode ? "Ends with the episode"
                : "\(Int((sleepTimer.timerRemaining / 60).rounded(.up))) minutes left"
        }
        return NightRingMath.spoken(minutes: gridMinutes)
    }

    private func handlePoint(fraction: Double, center: CGPoint) -> CGPoint {
        let theta = fraction * 2 * .pi
        return CGPoint(x: center.x + radius * sin(theta), y: center.y - radius * cos(theta))
    }

    var body: some View {
        let frac = NightRingMath.fraction(forMinutes: shownMinutes)
        let theta = frac * 2 * .pi
        ZStack {
            Circle()
                .stroke(pal.text.opacity(0.08), lineWidth: Self.line)
                .frame(width: Self.ringSize, height: Self.ringSize)
            Circle()
                .trim(from: 0, to: CGFloat(frac))
                .stroke(pal.accent.opacity(0.55), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: Self.ringSize, height: Self.ringSize)
            Circle()
                .fill(pal.text.opacity(locked ? 0.3 : (dragMinutes == nil ? 0.7 : 0.9)))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(pal.accent.opacity(0.5), lineWidth: 1))
                .offset(x: radius * sin(theta), y: -radius * cos(theta))
            if let d = dragMinutes {
                readout(d)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .frame(width: Self.frameSize, height: Self.frameSize)
        .animation(dragMinutes == nil && !reduceMotion ? .easeOut(duration: 0.35) : nil, value: frac)
        // Only the band around the ring takes touches: the orb's disc inside stays the play button.
        .contentShape(RingBand(inner: radius - 22, outer: radius + 20), eoFill: true)
        // …and only the band is the ring for VoiceOver touch exploration, so the orb inside still
        // reads as Play.
        .contentShape(.accessibility, RingBand(inner: radius - 22, outer: radius + 20), eoFill: true)
        .gesture(dragGesture)
        .onChange(of: touchLive) { _, live in
            if !live { endDrag() }
        }
        .accessibilityElement()
        .accessibilityLabel("Night length")
        .accessibilityValue(spokenValue)
        .accessibilityHint(locked ? "Locked while the night fades out."
                                  : "Swipe up or down to change. Play uses this length.")
        .accessibilityAdjustableAction { direction in
            guard !locked else { return }
            switch direction {
            case .increment: stage(NightRingMath.adjusted(gridMinutes, up: true))
            case .decrement: stage(NightRingMath.adjusted(gridMinutes, up: false))
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Timer options") { openOptions() }
    }

    /// A VoiceOver step: show it at once, commit once the swipes stop.
    private func stage(_ minutes: Int) {
        pendingMinutes = minutes
        pendingCommit?.cancel()
        let work = DispatchWorkItem {
            commit(minutes)
            pendingMinutes = nil
        }
        pendingCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    /// Clears the drag however it ended (released or cancelled). Idempotent.
    private func endDrag() {
        if dragMinutes != nil {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { dragMinutes = nil }
        }
        rejected = false
        dragStart = nil
        // Released after Home's swipe has read the flag for this same touch.
        DispatchQueue.main.async { dragging = false }
    }

    private func readout(_ minutes: Int) -> some View {
        ZStack {
            Circle().fill(Color(white: 0.09))
                .frame(width: OrbButton.discDiameter - 2, height: OrbButton.discDiameter - 2)
            if minutes == 0 {
                Text("All night")
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundColor(pal.text)
            } else {
                VStack(spacing: 0) {
                    Text("\(minutes)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("min")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(pal.dim)
                }
                .foregroundColor(pal.text)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .updating($touchLive) { _, live, _ in live = true }
            .onChanged { value in
                let center = CGPoint(x: Self.frameSize / 2, y: Self.frameSize / 2)
                if dragMinutes == nil {
                    guard !rejected else { return }
                    // Only a drag that starts on the handle sets the night: a scene swipe or a
                    // stray brush across the ring at 2am does nothing.
                    let handle = handlePoint(fraction: NightRingMath.fraction(forMinutes: shownMinutes), center: center)
                    let d = hypot(value.startLocation.x - handle.x, value.startLocation.y - handle.y)
                    guard !locked, d <= Self.handleSlop else { rejected = true; return }
                    dragging = true
                    let start = Int((shownMinutes / Double(NightRingMath.step)).rounded()) * NightRingMath.step
                    dragStart = start
                    dragMinutes = start
                }
                guard let previous = dragMinutes else { return }
                let raw = NightRingMath.minutes(forAngle: NightRingMath.angle(of: value.location, center: center))
                let next = NightRingMath.continuous(previous: previous, raw: raw)
                if next != previous {
                    // Calm haptics: a tick on the quarter hours and at either end, not every step.
                    if next % 15 == 0 || next == 0 || next == NightRingMath.dialMinutes {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    if reduceMotion { dragMinutes = next }
                    else { withAnimation(.snappy(duration: 0.12)) { dragMinutes = next } }
                }
            }
            .onEnded { _ in
                // Only a real release commits; a cancelled touch just clears (see touchLive). The
                // lock is re-checked: the night may have started fading while the finger was down.
                if let minutes = dragMinutes, minutes != dragStart, !locked { commit(minutes) }
                endDrag()
            }
    }

    private func commit(_ minutes: Int) {
        lengthMinutes = NightRingMath.storable(minutes)
        switch NightRingMath.commit(minutes: minutes, playing: playing, timerActive: timerActive) {
        case .start(let m):
            sleepTimer.startSleepTimer(minutes: m)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        case .cancel:
            sleepTimer.cancelTimer()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        case .none:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
    }
}

/// The touchable band around the ring.
private struct RingBand: Shape {
    let inner: CGFloat
    let outer: CGFloat
    func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        var p = Path()
        p.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        p.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        return p   // filled even-odd (see the contentShape call), so the inner disc is a hole
    }
}

/// The line under the Sleep orb: the night, said plainly ("Resume · Brown · 45m", "38m left",
/// "All night"). Tapping it opens the full timer options (ambient tail, end of episode). Observes
/// the timer so its countdown stays live without re-rendering HomeView.
struct NightLine: View {
    /// What Play would resume ("Resume · Brown", "Tap to begin"), shown only at rest — while
    /// playing, the layer pills already name the sounds.
    let resumeText: String
    let playing: Bool
    let lengthMinutes: Double
    @ObservedObject var sleepTimer: SleepTimerService
    let pal: Palette
    let openOptions: () -> Void

    static func timerText(remaining: TimeInterval, inTail: Bool, endOfEpisode: Bool,
                          playing: Bool, lengthMinutes: Double) -> String {
        if inTail { return "Sounds easing out" }
        if remaining > 0 {
            return endOfEpisode ? "Ends with the episode" : "\(Int((remaining / 60).rounded(.up)))m left"
        }
        if playing { return "All night" }
        return lengthMinutes >= 5 ? "\(Int(lengthMinutes))m" : "All night"
    }

    private var text: String {
        let t = Self.timerText(remaining: sleepTimer.timerRemaining, inTail: sleepTimer.inTail,
                               endOfEpisode: sleepTimer.isEndOfEpisode, playing: playing,
                               lengthMinutes: lengthMinutes)
        return playing ? t : "\(resumeText) · \(t)"
    }

    /// The same line in words for VoiceOver ("45m" reads as "45 meters").
    private var spokenText: String {
        let t = Self.timerText(remaining: sleepTimer.timerRemaining, inTail: sleepTimer.inTail,
                               endOfEpisode: sleepTimer.isEndOfEpisode, playing: playing,
                               lengthMinutes: lengthMinutes)
        let words = Self.spoken(t)
        return playing ? words : "\(resumeText.replacingOccurrences(of: " · ", with: ", ")), \(words)"
    }

    /// "38m left" → "38 minutes left", "45m" → "45 minutes"; other phrases pass through.
    static func spoken(_ timerText: String) -> String {
        guard let r = timerText.range(of: #"^\d+m"#, options: .regularExpression) else { return timerText }
        let n = timerText[r].dropLast()
        return "\(n) minutes" + timerText[r.upperBound...]
    }

    var body: some View {
        Button(action: openOptions) {
            HStack(spacing: 6) {
                Text(text)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.6)
                    .accessibilityHidden(true)
            }
            .font(.system(.callout, design: .rounded).weight(.medium))
            .foregroundColor(pal.dim)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 30)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(spokenText)
        .accessibilityHint("Opens timer options")
    }
}
