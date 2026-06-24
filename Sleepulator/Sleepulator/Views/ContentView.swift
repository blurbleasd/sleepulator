import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @AppStorage("bedtimeMode") private var bedtimeMode = false
    @AppStorage("autoNightDim") private var autoNightDim = true
    @State private var nightDimmed = false
    @State private var dimWorkItem: DispatchWorkItem?
    /// Tracks the timer's active/idle state so the dim side-effect fires only on the transition,
    /// not on every per-second `timerRemaining` publish (which would reschedule the 60 s dim work
    /// item forever and it would never fire).
    @State private var timerWasActive = false

    var pal: Palette { Palette(bedtime: bedtimeMode) }

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }

    // The screensaver may only hide chrome while Home is the *active* tab. Without the
    // selectedTab guard, an idle-fade timer that fires after you've switched to Podcasts /
    // Settings would hide the whole TabView's tab bar (the modifier below propagates app-wide)
    // and the mini-player, leaving no way back to Home — the screensaver's tap-to-wake catcher
    // only exists on the Home screen.
    private var homeScreensaver: Bool { audio.ambientScreensaver && selectedTab == 0 }

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
                HomeView(audio: audio, mixStore: audio.mixStore, selectedTab: $selectedTab)
                    .tabItem {
                        // Reflect the active mode — a cyan "Sleep/moon" tab while focusing
                        // was disorienting (the tab contradicted the screen).
                        Label(audio.focusMode ? "Focus" : "Sleep",
                              systemImage: audio.focusMode ? "bolt.fill" : "moon.stars.fill")
                    }
                    .tag(0)
                    // Ambient screensaver: drop the tab bar too, for a truly full-screen sky —
                    // but ONLY while Home is the active tab (see homeScreensaver).
                    .toolbar(homeScreensaver ? .hidden : .visible, for: .tabBar)
                
                LibraryView(audio: audio, queue: audio.queueManager, connectivity: audio.connectivity)
                    .tabItem {
                        Label("Podcasts", systemImage: "music.note.list")
                    }
                    .tag(1)
                
                SettingsView(audio: audio, queue: audio.queueManager, settings: audio.settings)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(2)
            }
            .accentColor(pal.accent)

            // Mini-player floats above the tab bar (a ZStack overlay, not a TabView safe-area
            // inset — that docks it ON the UIKit tab bar). Tabs reserve room for it themselves
            // (Home's bottom inset below, PodcastDetail's contentMargins).
            MiniPlayerView(audio: audio, progress: audio.playbackProgress, selectedTab: $selectedTab)
                .opacity(homeScreensaver ? 0 : 1)
                .allowsHitTesting(!homeScreensaver)
                .animation(.easeInOut(duration: 0.9), value: homeScreensaver)

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
        // Drive dim scheduling off the timer's published countdown, but only act on the
        // active↔idle transition (sleepTimer is no longer forwarded through `audio`, so the body
        // won't re-render each tick — and we must NOT reschedule the dim every second).
        .onReceive(audio.sleepTimer.$timerRemaining) { remaining in
            let active = remaining > 0
            guard active != timerWasActive else { return }
            timerWasActive = active
            if active { scheduleDim() } else { cancelDim() }
        }
        .onChange(of: audio.focusMode) { _, focus in
            if focus { cancelDim(); withAnimation(.easeInOut(duration: 0.4)) { nightDimmed = false } }
        }
        .onChange(of: selectedTab) { _, _ in
            // Navigating is interaction — reset the dim countdown and drop the screensaver
            // so it can never hide another tab's tab bar.
            if audio.ambientScreensaver { audio.ambientScreensaver = false }
            if nightDimmed { wake() } else { scheduleDim() }
        }
        .onChange(of: nightDimmed) { _, dimmed in
            // Freeze the backdrop scene only when the veil actually occludes the screen —
            // it keeps animating through the lighter controls-faded screensaver.
            audio.screenDimmed = dimmed
        }
        .onChange(of: scenePhase) { _, phase in
            // Fail-safe: if iOS suspended us through a duration timer's deadline, the in-process
            // tick never fired. Reconcile the instant we're foregrounded so audio can't keep
            // playing past the timer. No-op when nothing expired.
            if phase == .active { audio.sleepTimer.reconcileIfExpired() }
        }
    }
}
