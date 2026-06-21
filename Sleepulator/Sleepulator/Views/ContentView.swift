import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    @State private var selectedTab = 0
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    
    var pal: Palette { Palette(bedtime: bedtimeMode) }
    
    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(audio: audio)
                    .tabItem {
                        Label("Sleep", systemImage: "moon.stars.fill")
                    }
                    .tag(0)
                
                LibraryView(audio: audio)
                    .tabItem {
                        Label("Podcasts", systemImage: "music.note.list")
                    }
                    .tag(1)
                
                SettingsView(audio: audio)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(2)
            }
            .accentColor(pal.accent)
            
            MiniPlayerView(audio: audio, selectedTab: $selectedTab)
        }
        // Force dark mode for bedtime aesthetic
        .preferredColorScheme(.dark)
    }
}
