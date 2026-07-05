import SwiftUI

/// An optional ~1-minute breathing wind-down shown before a Sleep session begins
/// (Settings → "Start with a minute of breathing"). It reuses the entrainment bloom
/// (`BreathingBloomView`) and auto-starts the mix when the countdown elapses, or immediately on
/// "Start now". "Skip" dismisses without starting.
///
/// The countdown runs on `.task`, which SwiftUI cancels when the cover is dismissed — so once the
/// user has started or skipped, the timer can't fire a second `onBegin`. Turning two existing
/// features (the breathing bloom + the play flow) into one bedtime ritual.
struct BreathingOnRampView: View {
    /// Length of the wind-down before the mix auto-starts.
    var seconds: Int = 60
    /// Begin the Sleep mix — the countdown elapsed, or the user tapped "Start now".
    let onBegin: () -> Void
    /// Dismiss without starting — the user tapped "Skip".
    let onCancel: () -> Void

    @State private var remaining: Int
    /// Guards the one-shot outcome: whichever of begin/cancel/background happens first wins, the
    /// rest are no-ops (the parent also nils `pendingStart`, but keep it honest here too).
    @State private var settled = false
    @Environment(\.scenePhase) private var scenePhase

    init(seconds: Int = 60, onBegin: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.seconds = seconds
        self.onBegin = onBegin
        self.onCancel = onCancel
        _remaining = State(initialValue: seconds)
    }

    private func begin() {
        guard !settled else { return }
        settled = true
        onBegin()
    }

    private func cancel() {
        guard !settled else { return }
        settled = true
        onCancel()
    }

    var body: some View {
        ZStack {
            BreathingBloomView()   // the entrainment glow (allowsHitTesting false → controls win)

            VStack {
                HStack {
                    Spacer()
                    Button(action: cancel) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(12)
                            .background(Circle().fill(.white.opacity(0.08)))
                    }
                    .accessibilityLabel("Skip breathing and start now")
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 10) {
                    Text("Breathe")
                        .font(.system(.title2, design: .rounded).weight(.medium))
                        .foregroundColor(.white.opacity(0.9))
                    Text("Follow the glow — in, and slowly out")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 32)

                Spacer()

                VStack(spacing: 16) {
                    Text("Your mix starts in \(remaining)s")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                        .monospacedDigit()
                        .accessibilityLabel("Your mix starts in \(remaining) seconds")

                    Button(action: begin) {
                        Text("Start now")
                            .font(.system(.headline, design: .rounded))
                            .foregroundColor(.black)
                            .padding(.horizontal, 36)
                            .padding(.vertical, 14)
                            .background(Capsule().fill(.white.opacity(0.92)))
                    }
                    .accessibilityLabel("Start mix now")
                }
                .padding(.bottom, 48)
            }
        }
        .preferredColorScheme(.dark)
        // Locking the phone mid-wind-down would suspend the countdown Task below with no audio
        // session alive, so the mix would never start — silence all night, the exact failure the
        // app exists to prevent. Treat backgrounding as "start now": the mix begins (and its audio
        // keeps the app alive) before we suspend. A false positive (an app-switch instead of a
        // lock) merely starts the mix a beat early — cheap next to never starting at all.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { begin() }
        }
        .task {
            var r = seconds
            while r > 0 {
                remaining = r
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }   // dismissed (started or skipped) — don't fire again
                r -= 1
            }
            begin()
        }
    }
}
