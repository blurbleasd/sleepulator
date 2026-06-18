import SwiftUI

struct BreathingView: View {
    @Binding var isPresented: Bool
    
    @State private var scale: CGFloat = 1.0
    @State private var opacity: Double = 0.5
    @State private var timer: Timer?
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
                .scaleEffect(scale)
                .frame(width: 400, height: 400)
                .blur(radius: 50)
            
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        timer?.invalidate()
                        isPresented = false
                    }) {
                        Image(systemName: "xmark")
                            .font(.title)
                            .foregroundColor(.gray)
                            .padding()
                    }
                }
                
                HStack(spacing: 20) {
                    Button("4-7-8") {
                        mode = "478"
                        startBreathing()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(mode == "478" ? Color(red: 0.9, green: 0.7, blue: 0.4) : Color.white.opacity(0.1))
                    .foregroundColor(mode == "478" ? .black : .gray)
                    .cornerRadius(20)
                    .font(.system(.headline, design: .rounded))
                    
                    Button("Box 4-4-4-4") {
                        mode = "box"
                        startBreathing()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(mode == "box" ? Color(red: 0.9, green: 0.7, blue: 0.4) : Color.white.opacity(0.1))
                    .foregroundColor(mode == "box" ? .black : .gray)
                    .cornerRadius(20)
                    .font(.system(.headline, design: .rounded))
                }
                .padding(.top, 20)
                
                Spacer()
                
                Text(instruction)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(instructionColor)
                    .animation(.easeInOut, value: instruction)
                
                Spacer()
            }
        }
        .onAppear {
            startBreathing()
        }
        .onDisappear {
            timer?.invalidate()
        }
    }
    
    func startBreathing() {
        timer?.invalidate()
        if mode == "478" {
            run478()
            timer = Timer.scheduledTimer(withTimeInterval: 19.0, repeats: true) { _ in run478() }
        } else {
            runBox()
            timer = Timer.scheduledTimer(withTimeInterval: 16.0, repeats: true) { _ in runBox() }
        }
    }
    
    func run478() {
        // Inhale (4s)
        instruction = "Inhale"
        instructionColor = Color(red: 0.9, green: 0.7, blue: 0.4)
        withAnimation(.easeInOut(duration: 4.0)) { scale = 1.3; opacity = 0.8 }
        
        // Hold (7s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            instruction = "Hold"
            instructionColor = .white
        }
        
        // Exhale (8s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 11.0) {
            instruction = "Exhale"
            instructionColor = Color(red: 0.4, green: 0.6, blue: 0.9)
            withAnimation(.easeInOut(duration: 8.0)) { scale = 1.0; opacity = 0.3 }
        }
    }
    
    func runBox() {
        // Inhale (4s)
        instruction = "Inhale"
        instructionColor = Color(red: 0.9, green: 0.7, blue: 0.4)
        withAnimation(.easeInOut(duration: 4.0)) { scale = 1.3; opacity = 0.8 }
        
        // Hold (4s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            instruction = "Hold"
            instructionColor = .white
        }
        
        // Exhale (4s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) {
            instruction = "Exhale"
            instructionColor = Color(red: 0.4, green: 0.6, blue: 0.9)
            withAnimation(.easeInOut(duration: 4.0)) { scale = 1.0; opacity = 0.3 }
        }
        
        // Hold (4s)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12.0) {
            instruction = "Hold"
            instructionColor = .white
        }
    }
}
