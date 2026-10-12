import SwiftUI
import StoreKit
import os

struct ContentView: View {
    @StateObject private var audio = AudioEngine()
    /// The tip jar's store, started in SleepulatorApp.
    @EnvironmentObject private var tips: TipStore
    @Environment(\.requestReview) private var requestReview
    // The asks' memory (docs/designs/APP-STORE-LAUNCH-1.0.md: RP-1, TJ-1; design D6, D10–D12).
    // Device-only: none of these is in Backup.kinds, so a backup never carries or replaces them.
    @AppStorage("tipCardSpent") private var tipCardSpent = false
    @AppStorage("ratingAskedVersion") private var ratingAskedVersion = ""
    @AppStorage("ratingAskedOn") private var ratingAskedOn: Double = 0
    @AppStorage("tipCardShownOn") private var tipCardShownOn: Double = 0
    @State private var tipCardDue = false
    @State private var showTipSheet = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @AppStorage("autoNightDim") private var autoNightDim = true
    @State private var nightDimmed = false
    @State private var veilCaptionShown = true
    @State private var veilCaptionHide: DispatchWorkItem?
    /// The 3am glance: the first tap on the veil shows only the ember and the night's line, dim
    /// on true black, for a few seconds; a second tap wakes the scene and the controls. One tap
    /// used to bring the whole scene back (and still no number) just to check the time. Timing
    /// rules live in `SessionGuards.veilTap`.
    @State private var veilGlanceShown = false
    /// When the glance showed, on the monotonic clock (`systemUptime`): a wall-clock step back
    /// would otherwise read as a fresh glance and swallow every tap.
    @State private var veilGlanceAt: TimeInterval?
    @State private var veilGlanceHide: DispatchWorkItem?
    /// The mini-player's full Now Playing sheet. Lifted here so HomeView can count it as a
    /// presentation (no screensaver fade behind it), alongside its own sheets.
    @State private var showNowPlaying = false
    /// Bumped on every mini-player tap — touching the mini-player is Home interaction too, so it
    /// pushes the screensaver countdown back.
    @State private var miniPlayerTouches = 0
    /// The mini-player bar's top edge (global Y), measured; each tab reserves room below it.
    @State private var miniPlayerTop: CGFloat?
    /// Every touch anywhere in the window, and whether something is presented: the veil's inputs.
    @State private var windowActivity = WindowActivity()
    /// The night ring's centre (global), measured by Home.
    @State private var orbCenter: CGPoint?

    // Mode-aware: the tab bar tint (and everything it accents) follows Sleep / Focus. It stayed
    // Sleep amber in Focus while Home turned cyan.
    var pal: Palette { Palette(focusMode: audio.focusMode) }

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
    // `loadedEpisode` (published, and what the bar itself shows), not `hasLoadedEpisode` (whether
    // the AVPlayer holds an item, false for a moment during a load or a pipeline rebuild).
    private var miniPlayerShownOnHome: Bool { audio.focusMode || audio.loadedEpisode != nil }
    private var miniPlayerHidden: Bool {
        homeScreensaver || (selectedTab == 0 && !miniPlayerShownOnHome)
    }

    private var hidesSystemOverlays: Bool {
        SessionGuards.hidesSystemOverlays(nightDimmed: nightDimmed, screensaver: homeScreensaver,
                                          focusMode: audio.focusMode)
    }

    // App-wide night-dim: ~60s after the last touch in a Sleep session (anywhere while a timer
    // runs, on Home or the Now Playing sheet for All night), drop a black veil over the whole app (tabs + mini-player) so a
    // bedside screen goes dark. Tap to wake. Any touch anywhere (Home, the mixer, any sheet)
    // re-arms it (`WindowActivity`), as do tab changes. When the sound stops we only cancel the
    // pending dim, never force the screen bright mid-night. Only over a session that's actually
    // playing (SessionGuards.mayNightDim): a timer counting down over paused audio used to blank
    // the screen on a silent room.
    /// `timerActive` overrides the published value for the one caller that runs in its willSet.
    /// The Now Playing sheet counts as the bedside screen too: it's the brightest night surface,
    /// and an idle one closes so the veil can drop (`veilTimeout`).
    private func mayDim(timerActive: Bool? = nil) -> Bool {
        SessionGuards.mayNightDim(autoNightDim: autoNightDim, focusMode: audio.focusMode,
                                  playing: audio.isAnythingPlaying,
                                  timerActive: timerActive ?? (audio.sleepTimer.timerRemaining > 0),
                                  onBedsideScreen: selectedTab == 0 || showNowPlaying)
    }

    /// Tracks the timer's active/idle state so the veil re-arms only on that transition, not on
    /// every per-second `timerRemaining` publish (which would reschedule the 60 s work item forever).
    @State private var timerWasActive = false

    /// Restarts the veil's minute. `timerActiveNow` is the value just published: `$timerRemaining`
    /// emits in willSet, so the property still reads the old value inside `onReceive`. The work
    /// item re-reads the live state when it fires.
    private func scheduleDim(timerActiveNow: Bool? = nil) {
        windowActivity.pendingDim?.cancel()
        guard mayDim(timerActive: timerActiveNow) else { return }
        let work = DispatchWorkItem {
            let assistive = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
            switch SessionGuards.veilTimeout(mayDim: self.mayDim(), presenting: self.windowActivity.isPresenting,
                                             nowPlayingUp: self.showNowPlaying, assistiveTech: assistive) {
            case .closeNowPlaying:
                self.showNowPlaying = false
                withAnimation(.easeInOut(duration: 0.8)) { self.nightDimmed = true }
            case .drop: withAnimation(.easeInOut(duration: 0.8)) { self.nightDimmed = true }
            case .wait: self.scheduleDim()   // a sheet or dialog is up: it would stay lit on black
            case .stand: break
            }
        }
        windowActivity.pendingDim = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }

    private func wake() {
        // A slow ramp out of true black (dark-adapted eyes at 3am), not a 0.4 s flash to full
        // chrome. The veil stops taking taps at once; only the light eases back.
        withAnimation(.easeOut(duration: 1.6)) { nightDimmed = false }
        scheduleDim()
    }

    /// A tap on the veil: the glance first, then the wake (`SessionGuards.veilTap`).
    private func veilTapped() {
        let assistive = UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        let uptime = ProcessInfo.processInfo.systemUptime
        switch SessionGuards.veilTap(sinceGlance: veilGlanceAt.map { uptime - $0 }, assistiveTech: assistive) {
        case .ignore: return
        case .glance: showGlance()
        case .wake:
            endGlance()
            wake()
            // Straight to the controls: the glance already showed the night, so the second tap
            // shouldn't land on a bare scene that needs a third.
            if audio.ambientScreensaver {
                withAnimation(.easeOut(duration: 1.0)) { audio.ambientScreensaver = false }
            }
        }
    }

    private func showGlance() {
        veilCaptionHide?.cancel()
        withAnimation(.easeInOut(duration: 0.4)) { veilCaptionShown = false }
        veilGlanceAt = ProcessInfo.processInfo.systemUptime
        // It answers the tap at once but arrives softly (dim text, a short ease-out), so a
        // dark-adapted eye isn't left wondering whether the tap landed.
        withAnimation(.easeOut(duration: 0.6)) { veilGlanceShown = true }
        let work = DispatchWorkItem {
            withAnimation(.easeInOut(duration: SessionGuards.glanceFade)) { self.veilGlanceShown = false }
        }
        veilGlanceHide?.cancel()
        veilGlanceHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SessionGuards.glanceHold, execute: work)
    }

    private func endGlance() {
        veilGlanceHide?.cancel()
        veilGlanceHide = nil
        veilGlanceAt = nil
        veilGlanceShown = false
    }

    private func cancelDim() {
        windowActivity.pendingDim?.cancel()
        windowActivity.pendingDim = nil
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
                         nowPlayingPresented: showNowPlaying, miniPlayerTouches: miniPlayerTouches,
                         orbCenter: $orbCenter, tipCardDue: tipCardDue,
                         onLeaveTip: { showTipSheet = true },
                         onTipCardDeclined: { tipCardSpent = true; refreshAsks() })
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
                
                LibraryView(audio: audio, queue: audio.queueManager, connectivity: audio.connectivity,
                            mixStore: audio.mixStore)
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
            // Under the veil only the veil answers VoiceOver and Voice Control: Home's screensaver
            // catcher also answers "Wake", and woke the hidden chrome under the black.
            .accessibilityHidden(nightDimmed)

            // Mini-player floats above the tab bar (a ZStack overlay, not a TabView safe-area
            // inset — that docks it ON the UIKit tab bar). Tabs reserve room for it themselves from
            // its measured top edge (`miniPlayerTop`, MiniPlayerClearance).
            // Hidden means not rendered. On iOS 26 a rendered view stays in the accessibility tree
            // XCUITest reads through opacity 0, .allowsHitTesting(false) and
            // .accessibilityHidden(true) alike: the invisible bar sat in it over Sleep Home's Build
            // mix. While it's out, `miniPlayerTop` keeps its last measurement.
            ZStack {
                if !miniPlayerHidden {
                    MiniPlayerView(audio: audio, progress: audio.playbackProgress, queue: audio.queueManager,
                                   selectedTab: $selectedTab, showNowPlaying: $showNowPlaying)
                        .simultaneousGesture(TapGesture().onEnded { miniPlayerTouches &+= 1 })
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                            miniPlayerTop = top
                        }
                        .transition(.opacity)
                }
            }
            // The removal fade still renders the bar, for 0.9 s, over Sleep Home's Build mix. These
            // gates stop real taps and VoiceOver on it the moment it hides; XCUITest's tree still
            // lists it until the fade ends. Keep them. Under the veil only the veil answers
            // VoiceOver, so the bar stays hidden from it there too.
            .allowsHitTesting(!miniPlayerHidden)
            .accessibilityHidden(miniPlayerHidden || nightDimmed)
            .animation(.easeInOut(duration: 0.9), value: miniPlayerHidden)

            // Full-screen night veil — over the tabs and mini-player both.
            if nightDimmed {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { veilTapped() }
                    .overlay {
                        if veilGlanceShown {
                            // "Playing" includes an episode that's loading between episodes: a
                            // podcast night isn't "Sounds off" for the second before the next starts.
                            VeilGlance(sleepTimer: audio.sleepTimer, center: orbCenter,
                                       playing: audio.isAnythingPlaying || audio.podcastIsPlayingOrStarting,
                                       pal: pal)
                                .transition(.opacity)
                        }
                    }
                    .overlay(
                        // The caption fades out after a few seconds: under the veil it was the
                        // only lit element on screen — a fixed, dim-white string held for eight
                        // hours a night is a textbook OLED burn-in anchor, and fading it lets
                        // the panel go true black. VoiceOver keeps the label below regardless.
                        Text("Tap to wake")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.16))
                            .opacity(veilCaptionShown ? 1 : 0)
                            .allowsHitTesting(false)   // a tap on the words is a tap on the veil
                    )
                    .transition(.opacity)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Screen dimmed for sleep. Tap to wake.")
                    // Voice Control: "Tap Wake" (the first shows the glance, the second wakes).
                    .accessibilityInputLabels(["Wake", "Tap to wake", "Show controls"])
                    .onAppear { flashVeilCaption() }
            }
        }
        // The mini-player's full player. Presented here, not from the bar, so it never depends on
        // the bar being rendered.
        .sheet(isPresented: $showNowPlaying, onDismiss: naturalBreak) {
            NowPlayingSheet(audio: audio, queue: audio.queueManager, progress: audio.playbackProgress,
                            isPresented: $showNowPlaying, pal: pal,
                            onInteraction: { if !nightDimmed { scheduleDim() } })
                // The system grabber (the hand-drawn one scrolled away with the content).
                .presentationDragIndicator(.visible)
                .presentationBackground(pal.bg)
        }
        // The tip card's sheet. Closing it any way spends the card (design D6) and is a natural
        // break; leaving it ends the visit's "Waiting for approval" (design D7).
        .sheet(isPresented: $showTipSheet, onDismiss: {
            tips.screenClosed()
            tipCardSpent = true
            naturalBreak()
        }) {
            TipSheet(tips: tips, pal: pal)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(pal.bg)
        }
        .environment(\.naturalBreak, naturalBreak)
        // Force dark mode for bedtime aesthetic
        .preferredColorScheme(.dark)
        // No lit clock, battery or home indicator over the veil or the Sleep screensaver.
        .statusBarHidden(hidesSystemOverlays)
        .persistentSystemOverlays(hidesSystemOverlays ? .hidden : .automatic)
        .background(WindowActivityProbe(activity: windowActivity))
        .onAppear {
            // Any touch is interaction: restart the countdown. On the veil itself, its own tap
            // wakes (and re-arms) instead.
            windowActivity.onTouch = { if !nightDimmed { scheduleDim() } }
        }
        // Pausing drops the pending dim (never forces the screen bright); resuming re-arms it.
        .onChange(of: audio.isAnythingPlaying) { _, playing in
            if playing { if !nightDimmed { scheduleDim() } } else { cancelDim() }
            refreshAsks()
        }
        .onReceive(tips.$products) { _ in refreshAsks() }
        .onReceive(tips.$hasTipped) { _ in refreshAsks() }
        // A timer starting or ending changes where the veil may drop (everywhere vs Home only).
        .onReceive(audio.sleepTimer.$timerRemaining) { remaining in
            let active = remaining > 0
            guard active != timerWasActive else { return }
            timerWasActive = active
            if !nightDimmed { scheduleDim(timerActiveNow: active) }
        }
        // Opening the full player is a bedside screen on an untimed night: arm the veil. The tap
        // that opened it ran before the sheet was up, while the veil wasn't allowed.
        .onChange(of: showNowPlaying) { _, up in
            if up, !nightDimmed { scheduleDim() }
        }
        .onChange(of: audio.focusMode) { _, _ in refreshAsks() }
        .onChange(of: audio.focusMode) { _, focus in
            if focus { cancelDim(); withAnimation(.easeInOut(duration: 0.4)) { nightDimmed = false } }
            // Into Sleep with the sound still going: that's a night starting, so arm the veil.
            else if !nightDimmed { scheduleDim() }
        }
        .onChange(of: selectedTab) { old, _ in
            // Navigating is interaction — reset the dim countdown and drop the screensaver
            // so it can never hide another tab's tab bar.
            if audio.ambientScreensaver { audio.ambientScreensaver = false }
            if nightDimmed { wake() } else { scheduleDim() }
            // Leaving Settings is the one tab switch that counts as a natural break (design D12).
            if old == 2 { naturalBreak() }
        }
        .onChange(of: nightDimmed) { _, dimmed in
            // Freeze the backdrop scene only when the veil actually occludes the screen —
            // it keeps animating through the lighter controls-faded screensaver.
            audio.screenDimmed = dimmed
            if !dimmed { endGlance() }
        }
        .onChange(of: scenePhase) { _, phase in
            // Fail-safe: if iOS suspended us through a duration timer's deadline, the in-process
            // tick never fired. Reconcile the instant we're foregrounded so audio can't keep
            // playing past the timer. No-op when nothing expired.
            if phase == .active {
                audio.sleepTimer.reconcileIfExpired()
                refreshAsks()
            }
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

    // MARK: The asks (eng run 2, R1)

    /// When the last night ended: the open night's pause, else the newest closed night.
    private var lastNightEnd: Date? {
        audio.nightJournal.open?.pausedAt ?? audio.nightJournal.verdicts.last?.end
    }

    private func sameDay(_ stamp: Double, _ now: Date) -> Bool {
        stamp > 0 && Calendar.current.isDate(Date(timeIntervalSince1970: stamp), inSameDayAs: now)
    }

    /// Whether the tip card is due, re-read at scene activation, natural breaks and when the
    /// store, the mode or the session changes. A plain value to Home, never @Published on
    /// AudioEngine (eng run 2, Section 1 #2).
    private func refreshAsks() {
        let now = Date()
        var due = SessionGuards.tipCardDue(
            cleanNights: audio.nightJournal.cleanNightCount, tipped: tips.hasTipped, spent: tipCardSpent,
            productsReady: !tips.products.isEmpty && tips.canMakePayments, focusMode: audio.focusMode,
            playing: audio.isAnythingPlaying, ratingAskedToday: sameDay(ratingAskedOn, now), now: now,
            lastNightEnd: lastNightEnd)
        #if DEBUG
        // The card's UI test (TS-2, EV-2): due regardless of nights and the clock, with the
        // DEBUG-only test products. Compiled out of release builds.
        if UserDefaults.standard.bool(forKey: "uiTestTipCardDue") {
            due = !tipCardSpent && !tips.hasTipped && !tips.products.isEmpty && !audio.focusMode
        }
        #endif
        if due, !sameDay(tipCardShownOn, now) { tipCardShownOn = now.timeIntervalSince1970 }
        if due != tipCardDue { tipCardDue = due }
    }

    /// A sheet just closed or the person just left Settings: maybe Apple's rating prompt
    /// (design D10–D12). Once per version; Apple decides whether it actually shows.
    private func naturalBreak() {
        refreshAsks()
        let now = Date()
        guard SessionGuards.mayAskForRating(
            cleanNights: audio.nightJournal.cleanNightCount, askedThisVersion: ratingAskedVersion == AppInfo.version,
            tipCardShownToday: sameDay(tipCardShownOn, now), playing: audio.isAnythingPlaying,
            veilDown: nightDimmed, now: now, lastNightEnd: lastNightEnd) else { return }
        ratingAskedVersion = AppInfo.version
        ratingAskedOn = now.timeIntervalSince1970
        Log.storage.notice("asked for a rating (\(audio.nightJournal.cleanNightCount, privacy: .public) clean nights)")
        requestReview()
    }
}

/// What the first tap on the veil shows: the ember in the ring's place and the night said the way
/// the line under the ring says it ("38m left", "All night"), dim on true black. Observes the
/// timer, so the minutes stay live while it shows.
private struct VeilGlance: View {
    @ObservedObject var sleepTimer: SleepTimerService
    /// The night ring's centre (global), measured by Home.
    let center: CGPoint?
    let playing: Bool
    let pal: Palette

    private var text: String {
        guard playing else { return "Sounds off" }
        return NightLine.timerText(remaining: sleepTimer.timerRemaining, inTail: sleepTimer.inTail,
                                   endOfEpisode: sleepTimer.isEndOfEpisode, playing: true,
                                   lengthMinutes: 0)
    }

    /// Where Home lays out the night line under the ring: half the ring's frame, the orb stack's
    /// spacing, and half the line's minimum height.
    private static let lineBelowRingCentre: CGFloat =
        NightRing.frameSize / 2 + HomeView.heroSpacing + NightLine.minHeight / 2

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let measured = center.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            // Home's measurement can be stale (rotated or resized while another tab showed):
            // only trust it when the line would land on screen.
            let c = measured.flatMap { p in
                p.x >= 0 && p.x <= geo.size.width && p.y >= 0
                    && p.y + Self.lineBelowRingCentre <= geo.size.height ? p : nil
            } ?? CGPoint(x: geo.size.width / 2, y: geo.size.height * 0.42)
            NightEmber(sleepTimer: sleepTimer, pal: pal, screensaver: true, focusMode: false)
                .position(c)
            Text(text)
                .font(.system(.callout, design: .rounded).weight(.medium))
                .monospacedDigit()
                .foregroundColor(pal.dim.opacity(0.55))
                .position(x: c.x, y: c.y + Self.lineBelowRingCentre)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
