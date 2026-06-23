import SwiftUI

struct BreathingView: View {
    @Binding var isPresented: Bool
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    @State private var timer: Timer?
    /// Pending phase changes (Hold/Exhale), held so a mode switch or dismiss can cancel them —
    /// otherwise a previous pattern's queued closures fire over the new one (out-of-order phases).
    @State private var pending: [DispatchWorkItem] = []
    @State private var mode: String = "478"
    @State private var instruction: String = "Inhale"
    @State private var instructionColor: Color = Color(red: 0.9, green: 0.7, blue: 0.4)
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            // Pulsing Orb
            Circle()
                .fill(
                    RadialGradient(gradient: Gradient(colors: [
                        instructionColor.opacity(opacity),
                        Color.clear
                    ]), center: .center, startRadius: 10, endRadius: 250)
                )
                .scaleEffect(scale)   // the breathing pacer must move even under Reduce Motion
                .frame(width: 400, height: 400)
                .blur(radius: 50)
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        timer?.invalidate()
                        cancelPending()
                        isPresented = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.title)
                            .foregroundColor(.gray)
                            .padding()
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Close breathing exercise")
                }

                HStack(spacing: 20) {
                    Button("4-7-8") {
                        mode = "478"
                        startBreathing()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(mode == "478" ? Color(red: 0.9, green: 0.7, blue: 0.4) : Color.white.opacity(0.1))
                    .foregroundColor(mode == "478" ? .black : .gray)
                    .clipShape(Capsule())
                    .font(.system(.headline, design: .rounded))
                    .accessibilityLabel("4-7-8 breathing")
                    .accessibilityAddTraits(mode == "478" ? .isSelected : [])

                    Button("Box 4-4-4-4") {
                        mode = "box"
                        startBreathing()
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44)
                    .background(mode == "box" ? Color(red: 0.9, green: 0.7, blue: 0.4) : Color.white.opacity(0.1))
                    .foregroundColor(mode == "box" ? .black : .gray)
                    .clipShape(Capsule())
                    .font(.system(.headline, design: .rounded))
                    .accessibilityLabel("Box breathing")
                    .accessibilityAddTraits(mode == "box" ? .isSelected : [])
                }
                .padding(.top, 20)

                Spacer()

                Text(instruction)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundColor(instructionColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .animation(reduceMotion ? nil : .easeInOut, value: instruction)
                    .accessibilityLabel(instruction)
                
                Spacer()
            }
        }
        .onAppear {
            startBreathing()
        }
        .onDisappear {
            timer?.invalidate()
            cancelPending()
        }
    }

    func startBreathing() {
        timer?.invalidate()
        cancelPending()
        if mode == "478" {
            run478()
            timer = Timer.scheduledTimer(withTimeInterval: 19.0, repeats: true) { _ in run478() }
        } else {
            runBox()
            timer = Timer.scheduledTimer(withTimeInterval: 16.0, repeats: true) { _ in runBox() }
        }
    }
    
    func run478() {
        cancelPending()
        // Inhale (4s)
        instruction = "Inhale"
        instructionColor = Color(red: 0.9, green: 0.7, blue: 0.4)
        withAnimation(.easeInOut(duration: 4.0)) { scale = 1.3; opacity = 0.8 }

        // Hold (7s)
        schedule(after: 4.0) {
            instruction = "Hold"
            instructionColor = .white
        }

        // Exhale (8s)
        schedule(after: 11.0) {
            instruction = "Exhale"
            instructionColor = Color(red: 0.4, green: 0.6, blue: 0.9)
            withAnimation(.easeInOut(duration: 8.0)) { scale = 1.0; opacity = 0.3 }
        }
    }

    func runBox() {
        cancelPending()
        // Inhale (4s)
        instruction = "Inhale"
        instructionColor = Color(red: 0.9, green: 0.7, blue: 0.4)
        withAnimation(.easeInOut(duration: 4.0)) { scale = 1.3; opacity = 0.8 }

        // Hold (4s)
        schedule(after: 4.0) {
            instruction = "Hold"
            instructionColor = .white
        }

        // Exhale (4s)
        schedule(after: 8.0) {
            instruction = "Exhale"
            instructionColor = Color(red: 0.4, green: 0.6, blue: 0.9)
            withAnimation(.easeInOut(duration: 4.0)) { scale = 1.0; opacity = 0.3 }
        }

        // Hold (4s)
        schedule(after: 12.0) {
            instruction = "Hold"
            instructionColor = .white
        }
    }

    /// Schedule a phase change that can be cancelled (mode switch / dismiss), so a previous
    /// pattern's queued Hold/Exhale can't fire over the new one.
    private func schedule(after delay: Double, _ block: @escaping () -> Void) {
        let work = DispatchWorkItem(block: block)
        pending.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPending() {
        pending.forEach { $0.cancel() }
        pending.removeAll()
    }
}
