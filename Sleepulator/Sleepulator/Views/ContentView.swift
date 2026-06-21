import SwiftUI

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    @State private var selectedTab = 0
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @AppStorage("autoNightDim") private var autoNightDim = true
    @State private var nightDimmed = false
    @State private var dimWorkItem: DispatchWorkItem?

    var pal: Palette { Palette(bedtime: bedtimeMode) }

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }

    // App-wide night-dim: ~60s into a sleep session, drop a black veil over the whole app
    // (tabs + mini-player) so a bedside screen goes dark. Tap to wake; re-arms after each
    // wake and on tab changes (navigating counts as interaction). When the timer ends we
    // only cancel the pending dim — never force the screen bright mid-night.
    private func scheduleDim() {
        dimWorkItem?.cancel()
        guard autoNightDim, !audio.focusMode, timerActive else { return }
        let work = DispatchWorkItem {
            if self.autoNightDim, !self.audio.focusMode, self.audio.sleepTimer.timerRemaining > 0 {
                withAnimation(.easeInOut(duration: 0.8)) { self.nightDimmed = true }
            }
        }
        dimWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func wake() {
        withAnimation(.easeInOut(duration: 0.4)) { nightDimmed = false }
        scheduleDim()
    }

    private func cancelDim() {
        dimWorkItem?.cancel()
        dimWorkItem = nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(audio: audio)
                    .tabItem {
                        // Reflect the active mode — a cyan "Sleep/moon" tab while focusing
                        // was disorienting (the tab contradicted the screen).
                        Label(audio.focusMode ? "Focus" : "Sleep",
                              systemImage: audio.focusMode ? "bolt.fill" : "moon.stars.fill")
                    }
                    .tag(0)
                    // Ambient screensaver: drop the tab bar too, for a truly full-screen sky.
                    .toolbar(audio.ambientScreensaver ? .hidden : .visible, for: .tabBar)
                
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
                .opacity(audio.ambientScreensaver ? 0 : 1)
                .allowsHitTesting(!audio.ambientScreensaver)
                .animation(.easeInOut(duration: 0.9), value: audio.ambientScreensaver)

            // Full-screen night veil — over the tabs and mini-player both.
            if nightDimmed {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { wake() }
                    .overlay(
                        Text("Tap to wake")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.16))
                    )
                    .transition(.opacity)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Screen dimmed for sleep. Tap to wake.")
            }
        }
        // Force dark mode for bedtime aesthetic
        .preferredColorScheme(.dark)
        .onChange(of: timerActive) { active in
            if active { scheduleDim() } else { cancelDim() }
        }
        .onChange(of: audio.focusMode) { focus in
            if focus { cancelDim(); withAnimation(.easeInOut(duration: 0.4)) { nightDimmed = false } }
        }
        .onChange(of: selectedTab) { _ in
            // Navigating is interaction — reset the dim countdown and drop the screensaver
            // so it can never hide another tab's tab bar.
            if audio.ambientScreensaver { audio.ambientScreensaver = false }
            if nightDimmed { wake() } else { scheduleDim() }
        }
    }
}
