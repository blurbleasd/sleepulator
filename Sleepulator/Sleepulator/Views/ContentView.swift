import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView(audio: audio)
                    .tabItem {
                        Label("Mixer", systemImage: "slider.vertical.3")
                    }
                
                LibraryView(audio: audio)
                    .tabItem {
                        Label("Podcasts", systemImage: "play.circle")
                    }
                
                SettingsView(audio: audio)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
            }
            .accentColor(Color(red: 0.9, green: 0.7, blue: 0.4))
            
            MiniPlayerView(audio: audio)
        }
        // Force dark mode for bedtime aesthetic
        .preferredColorScheme(.dark)
    }
}
