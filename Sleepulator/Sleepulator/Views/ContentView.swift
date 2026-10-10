import SwiftUI
import Combine

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @AppStorage("autoNightDim") private var autoNightDim = true
    @State private var nightDimmed = false
    @State private var dimWorkItem: DispatchWorkItem?
    @State private var veilCaptionShown = true
    @State private var veilCaptionHide: DispatchWorkItem?
    /// Tracks the timer's active/idle state so the dim side-effect fires only on the transition,
    /// not on every per-second `timerRemaining` publish (which would reschedule the 60 s dim work
    /// item forever and it would never fire).
    @State private var timerWasActive = false
    /// The mini-player's full Now Playing sheet. Lifted here so HomeView can count it as a
    /// presentation (no screensaver fade behind it), alongside its own sheets.
    @State private var showNowPlaying = false
    /// Bumped on every mini-player tap — touching the mini-player is Home interaction too, so it
    /// pushes the screensaver countdown back.
    @State private var miniPlayerTouches = 0
    /// The mini-player bar's top edge (global Y), measured; each tab reserves room below it.
    @State private var miniPlayerTop: CGFloat?

    // Mode-aware: the tab bar tint (and everything it accents) follows Sleep / Focus. It stayed
    // Sleep amber in Focus while Home turned cyan.
    var pal: Palette { Palette(focusMode: audio.focusMode) }

    private var timerActive: Bool { audio.sleepTimer.timerRemaining > 0 }

    // The screensaver may only hide chrome while Home is the *active* tab. Without the
    // selectedTab guard, an idle-fade timer that fires after you've switched to Podcasts /
    // Settings would hide the whole TabView's tab bar (the modifier below propagates app-wide)
    // and the mini-player, leaving no way back to Home — the screensaver's tap-to-wake catcher
    // only exists on the Home screen.
    private var homeScreensaver: Bool { audio.ambientScreensaver && selectedTab == 0 }

    // On Sleep Home the mini-player shows only once an episode is loaded: idle, its "Up next" bar
    // put a second play button beside the orb, meaning something different. It stays everywhere
    // else (Podcasts, Settings, Focus), and the mixer's Podcast row is unchanged.
    // Keyed on a loaded episode, not on playing: pausing from the orb must not fade the bar out
    // (and move Home's controls) under the user's thumb.
    private var miniPlayerShownOnHome: Bool { audio.focusMode || audio.hasLoadedEpisode }
    private var miniPlayerHidden: Bool {
        homeScreensaver || (selectedTab == 0 && !miniPlayerShownOnHome)
    }

    // App-wide night-dim: ~60s into a sleep session, drop a black veil over the whole app
    // (tabs + mini-player) so a bedside screen goes dark. Tap to wake; re-arms after each
    // wake and on tab changes (navigating counts as interaction). When the timer ends we
    // only cancel the pending dim — never force the screen bright mid-night.
    // Only over a session that's actually playing (SessionGuards.mayNightDim): a timer counting
    // down over paused audio used to blank the screen on a silent room.
    private var mayDim: Bool {
        SessionGuards.mayNightDim(autoNightDim: autoNightDim, focusMode: audio.focusMode,
                                  timerActive: timerActive, playing: audio.isAnythingPlaying)
    }

    /// `timerActiveNow` is the value just published: `$timerRemaining` emits in willSet, so
    /// reading the property inside `onReceive` still sees the old value (0 on a fresh start) and
    /// the veil never armed. The work item re-reads the live state when it fires.
    private func scheduleDim(timerActiveNow: Bool? = nil) {
        dimWorkItem?.cancel()
        let armed = SessionGuards.mayNightDim(autoNightDim: autoNightDim, focusMode: audio.focusMode,
                                              timerActive: timerActiveNow ?? timerActive,
                                              playing: audio.isAnythingPlaying)
        guard armed else { return }
        let work = DispatchWorkItem {
            if self.mayDim {
                withAnimation(.easeInOut(duration: 0.8)) { self.nightDimmed = true }
            }
        }
        dimWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func wake() {
        // A slow ramp out of true black (dark-adapted eyes at 3am), not a 0.4 s flash to full
        // chrome. The veil stops taking taps at once; only the light eases back.
        withAnimation(.easeOut(duration: 1.6)) { nightDimmed = false }
        scheduleDim()
    }

    private func cancelDim() {
        dimWorkItem?.cancel()
        dimWorkItem = nil
    }

    // Show the veil's "Tap to wake" hint briefly each time the veil engages, then fade it out
    // so the occluded screen holds no lit pixels (see the burn-in note at the overlay).
    private func flashVeilCaption() {
        veilCaptionHide?.cancel()
        // Animated so re-engagements ride the veil's own fade-in rather than popping a frame in.
        withAnimation(.easeInOut(duration: 0.8)) { veilCaptionShown = true }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: 2)) { self.veilCaptionShown = false }
        }
        veilCaptionHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(audio: audio, mixStore: audio.mixStore, selectedTab: $selectedTab,
                         nowPlayingPresented: showNowPlaying, miniPlayerTouches: miniPlayerTouches)
                    // Home reserves the bar's room only when the bar shows on Home (not on Sleep
                    // Home at rest). The screensaver fade doesn't count: HomeView freezes it.
                    .environment(\.miniPlayerTop, miniPlayerShownOnHome ? miniPlayerTop : nil)
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
                    .environment(\.miniPlayerTop, miniPlayerTop)
                    .tabItem {
                        Label("Podcasts", systemImage: "music.note.list")
                    }
                    .tag(1)
                
                SettingsView(audio: audio, queue: audio.queueManager, settings: audio.settings)
                    .environment(\.miniPlayerTop, miniPlayerTop)
                    .tabItem {
                        Label("Settings", systemImage: "gear")
                    }
                    .tag(2)
            }
            .accentColor(pal.accent)

            // Mini-player floats above the tab bar (a ZStack overlay, not a TabView safe-area
            // inset — that docks it ON the UIKit tab bar). Tabs reserve room for it themselves from
            // its measured top edge (`miniPlayerTop`, MiniPlayerClearance).
            MiniPlayerView(audio: audio, progress: audio.playbackProgress, queue: audio.queueManager,
                           selectedTab: $selectedTab, showNowPlaying: $showNowPlaying,
                           onSheetInteraction: { if !nightDimmed { scheduleDim() } })
                .simultaneousGesture(TapGesture().onEnded { miniPlayerTouches &+= 1 })
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                    miniPlayerTop = top
                }
                .opacity(miniPlayerHidden ? 0 : 1)
                .allowsHitTesting(!miniPlayerHidden)
                .accessibilityHidden(miniPlayerHidden)
                .animation(.easeInOut(duration: 0.9), value: miniPlayerHidden)

            // Full-screen night veil — over the tabs and mini-player both.
            if nightDimmed {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { wake() }
                    .overlay(
                        // The caption fades out after a few seconds: under the veil it was the
                        // only lit element on screen — a fixed, dim-white string held for eight
                        // hours a night is a textbook OLED burn-in anchor, and fading it lets
                        // the panel go true black. VoiceOver keeps the label below regardless.
                        Text("Tap to wake")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.16))
                            .opacity(veilCaptionShown ? 1 : 0)
                    )
                    .transition(.opacity)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Screen dimmed for sleep. Tap to wake.")
                    .onAppear { flashVeilCaption() }
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
            if active { scheduleDim(timerActiveNow: true) } else { cancelDim() }
        }
        // Pausing drops the pending dim (never forces the screen bright); resuming re-arms it.
        .onChange(of: audio.isAnythingPlaying) { _, playing in
            if playing { if !nightDimmed { scheduleDim() } } else { cancelDim() }
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
            // The veil can't cover a presented sheet, so an open Now Playing stayed lit all
            // night above it. Touches in the sheet reset the countdown (onSheetInteraction), so
            // this only closes a player that's been left alone for the veil's minute.
            if dimmed && showNowPlaying { showNowPlaying = false }
        }
        .onChange(of: scenePhase) { _, phase in
            // Fail-safe: if iOS suspended us through a duration timer's deadline, the in-process
            // tick never fired. Reconcile the instant we're foregrounded so audio can't keep
            // playing past the timer. No-op when nothing expired.
            if phase == .active { audio.sleepTimer.reconcileIfExpired() }
        }
        // The resume widget's deep link (sleepulator://resume). Routed through the same
        // notification the "Start Sleepulator Mix" Siri intent posts (SleepulatorIntents.swift),
        // which AudioEngine already observes — one code path for every hands-off start.
        .onOpenURL { url in
            if url.scheme == "sleepulator" && url.host == "resume" {
                NotificationCenter.default.post(name: Notification.Name("StartSleepulatorMix"), object: nil)
            }
        }
    }
}
