import SwiftUI

// MARK: - Glass Panel Modifier
struct GlassPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding()
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark) // Forces the glass to be dark
            .cornerRadius(24)
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
    }
}

extension View {
    func glassPanel() -> some View {
        self.modifier(GlassPanel())
    }
}

// MARK: - Breathing Orb
struct BreathingOrb: View {
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    @State private var timer: Timer?
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            Circle()
                .fill(
                    RadialGradient(gradient: Gradient(colors: [
                        Color(red: 0.9, green: 0.6, blue: 0.3).opacity(opacity),
                        Color.clear
                    ]), center: .center, startRadius: 10, endRadius: 250)
                )
                .scaleEffect(scale)
                .frame(width: 400, height: 400)
                .blur(radius: 50)
                .onAppear { start478Breathing() }
                .onDisappear { timer?.invalidate() }
        }
    }
    
    func start478Breathing() {
        runCycle()
        timer = Timer.scheduledTimer(withTimeInterval: 19.0, repeats: true) { _ in
            runCycle()
        }
    }
    
    func runCycle() {
        // 4s Inhale
        withAnimation(.easeInOut(duration: 4.0)) {
            scale = 1.3
            opacity = 0.8
        }
        // 7s Hold
        // 8s Exhale
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            withAnimation(.easeInOut(duration: 8.0)) {
                scale = 1.0
                opacity = 0.5
            }
        }
    }
}

// MARK: - Warm Custom Slider
struct WarmSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let percent = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            
            ZStack(alignment: .leading) {
                // Track
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 12)
                
                // Fill
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [Color(red: 0.7, green: 0.3, blue: 0.1), Color(red: 0.9, green: 0.7, blue: 0.4)]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, width * percent), height: 12)
                
                // Thumb
                Circle()
                    .fill(Color(red: 0.9, green: 0.7, blue: 0.4))
                    .frame(width: 24, height: 24)
                    .shadow(color: Color(red: 0.9, green: 0.7, blue: 0.4).opacity(0.5), radius: 5)
                    .offset(x: max(0, min(width - 24, (width * percent) - 12)))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                let newValue = range.lowerBound + Double(gesture.location.x / width) * (range.upperBound - range.lowerBound)
                                value = max(range.lowerBound, min(range.upperBound, newValue))
                            }
                    )
            }
            .frame(height: 24)
        }
        .frame(height: 24)
    }
}
