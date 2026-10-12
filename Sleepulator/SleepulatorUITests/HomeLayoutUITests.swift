import XCTest

/// Home's bottom row must sit above the floating mini-player and take taps. The clearance is
/// measured at runtime (`HomeView.homeClearance`), so only a real layout can catch it going wrong:
/// on iOS 26 the row once sat entirely under the "Nothing playing" bar in Focus, which left the
/// Pomodoro with no way to start (its only control is that row's "Focus session" button).
final class HomeLayoutUITests: XCTestCase {

    @MainActor
    func testFocusRowClearsTheMiniPlayerAndStartsASession() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Moving scenes off, for this launch only (the argument domain): with the scene, orb and
        // ring redrawing every frame the app never idles, and on a loaded CI runner XCUITest
        // waited up to 4 s before each tap, so Stop kept landing after the controls had faded.
        app.launchArguments = ["-ambientMotion", "<false/>", "-uiTestIsolated", "<true/>"]
        app.launch()
        // Back to Sleep even when an assertion stops the test mid-way in Focus.
        addTeardownBlock { @MainActor in Self.leaveInSleep(app) }

        // Focus from either start state: a no-op when the last run left the app in Focus.
        let focusMode = app.buttons["Focus mode"]
        XCTAssertTrue(focusMode.waitForExistence(timeout: 15), "No mode switcher on Home")
        focusMode.tap()

        let session = app.buttons["Start focus session"]
        // An exact label: on a fresh install the first-run tip is a button that says "Build mix" too.
        let buildMix = app.buttons["Build mix"]
        let miniPlayer = app.descendants(matching: .any)["miniPlayer"]
        XCTAssertTrue(session.waitForExistence(timeout: 5), "No Focus session button")
        XCTAssertTrue(buildMix.exists, "No Build mix button")
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "No mini-player in Focus")

        // The bar fades in and the clearance eases over ~1 s after the switch: wait for it to land.
        let cleared = waitUntil(timeout: 5) {
            session.frame.maxY <= miniPlayer.frame.minY && buildMix.frame.maxY <= miniPlayer.frame.minY
        }
        XCTAssertTrue(cleared, """
            Home's row is under the mini-player: session \(session.frame), \
            Build mix \(buildMix.frame), bar \(miniPlayer.frame)
            """)

        // And a tap really lands on it (a covered button would hand the tap to the bar instead).
        XCTAssertTrue(session.isHittable)
        session.tap()
        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop focus session")).firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5), "Tapping Focus session didn't start the Pomodoro")
        // A running session lets Home's controls fade after 10 s (HomeScreensaverPolicy). A slow CI
        // runner can take that long between these steps, and then the tap lands on the faded
        // screen's wake layer instead of Stop, and the session runs on. Wake the controls first,
        // and go round again if the tap still woke them instead (CI's took 4 s to land, just as
        // the controls faded). Stop is re-checked before each tap, so a stopped session isn't
        // restarted by a tap on the "Focus session" button in its place.
        let wake = app.buttons["Show controls"]
        var stopped = false
        for _ in 0..<3 where !stopped {
            if wake.exists { wake.tap() }
            if stop.exists { stop.tap() }
            stopped = session.waitForExistence(timeout: 3)
        }

        // A live session would put the Sleep switch behind its confirm.
        XCTAssertTrue(stopped, "Couldn't stop the Focus session")

        // A tap on the shown bar reaches it. ContentView's wrapper switches the bar's hit testing
        // off while it's hidden; on the wrong side of that gate every bar control is dead while the
        // bar still exists and sits in place. "Nothing playing" leads to Podcasts; an "Up next" bar
        // (a queue an earlier run left behind) opens Now Playing. Over Focus Home a tap that falls
        // through lands on the backdrop, so a failure here changes nothing.
        // Value: protects=a tap on the shown mini-player acts through ContentView's hiding wrapper;
        // fails_when=the wrapper's hit-test gate is inverted or stuck off, so taps fall through the
        // bar; why_new=no test sends the bar a tap, the Podcasts check reads only its accessibility
        // hit point; seam=none
        // Recorded here, checked after the switch to Sleep, so a failure still leaves the app in Sleep.
        let podcastsTab = app.tabBars.buttons["Podcasts"]
        let nowPlayingDone = app.buttons["Done"]
        // CI sometimes drops a synthesized tap, so each tap that matters checks its effect and goes
        // round again; the effect is re-read before each tap, so a late one isn't doubled.
        var barTapActed = false
        if miniPlayer.waitForExistence(timeout: 5) {
            let acted = { podcastsTab.isSelected || nowPlayingDone.exists }
            for _ in 0..<3 where !barTapActed {
                if !acted(), miniPlayer.exists { miniPlayer.tap() }
                barTapActed = waitUntil(timeout: 3, acted)
            }
            // Back to Focus Home: close Now Playing, or leave Podcasts.
            for _ in 0..<3 where acted() {
                if nowPlayingDone.exists { nowPlayingDone.tap() } else { app.tabBars.buttons["Focus"].tap() }
                _ = waitUntil(timeout: 3) { !acted() }
            }
            _ = session.waitForExistence(timeout: 5)
        }

        // Leave the app in Sleep before any check below can stop the test: the unit tests run hosted
        // in this same app and read its persisted mode, so a run after this one must not start out
        // in Focus (the teardown is the fallback). So the bar's top is read before the switch and
        // checked after it.
        let barTop = miniPlayer.waitForExistence(timeout: 5) ? miniPlayer.frame.minY : nil
        app.buttons["Sleep mode"].tap()
        guard let barTop else { return XCTFail("No mini-player in Focus after the session") }
        XCTAssertTrue(barTapActed, "A tap on the mini-player in Focus did nothing: it didn't reach the bar")

        // Sleep Home at rest: the bar fades out and leaves the tree, and Build mix drops into the spot
        // it held. ContentView keeps the bar's last measurement while it's out; Home must not use it.
        // Value: protects=Sleep at rest drops the Focus bar and its room, Build mix takes its spot;
        // fails_when=the bar fades but stays in the tree, or Home keeps room for the held measurement;
        // why_new=no test checks Home's row once the bar is gone; seam=none
        XCTAssertTrue(waitUntil(timeout: 5) { !miniPlayer.exists && buildMix.frame.maxY > barTop }, """
            Sleep Home at rest kept the mini-player or its room: bar exists \(miniPlayer.exists), \
            Build mix \(buildMix.frame), the bar's top was \(barTop)
            """)
        XCTAssertTrue(buildMix.isHittable, "Build mix is covered where the mini-player was")
    }

    /// The tip card (TS-2; design D3, D13, D16). DEBUG-only seams (EV-2) supply three test products
    /// and make the card due, so the test never waits on StoreKit or the clock. It sits in the
    /// coachmark band above Build mix, its two answers are separate buttons, Home's controls stay
    /// hittable, and "No thanks" takes it out of the hierarchy.
    /// Value: protects=the card fits the band without blocking Home; fails_when=the card leaves the
    /// band or covers a control, or "No thanks" only hides it; why_new=no UI test shows the card;
    /// seam=uiTestTipProducts + uiTestTipCardDue (DEBUG-only); no_claim=real product loading (TS-1, TESTING §3U)
    @MainActor
    func testTipCardSitsInTheBandAndLeavesOnNoThanks() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ambientMotion", "<false/>", "-uiTestIsolated", "<true/>",
                               "-uiTestTipProducts", "<true/>", "-uiTestTipCardDue", "<true/>",
                               "-hasCompletedFirstRun", "<true/>", "-hasSeenNightRingTip", "<true/>",
                               "-tipCardSpent", "<false/>", "-tippedOnThisPhone", "<false/>"]
        app.launch()

        let sleepMode = app.buttons["Sleep mode"]
        XCTAssertTrue(sleepMode.waitForExistence(timeout: 15), "No mode switcher on Home")
        sleepMode.tap()

        let leaveTip = app.buttons["Leave a tip"]
        let noThanks = app.buttons["No thanks"]
        let buildMix = app.buttons["Build mix"]
        XCTAssertTrue(leaveTip.waitForExistence(timeout: 10), "The tip card didn't show on Sleep Home")
        XCTAssertTrue(noThanks.exists, "\"No thanks\" isn't its own button")
        XCTAssertTrue(buildMix.waitForExistence(timeout: 5), "No Build mix button")
        XCTAssertTrue(buildMix.isHittable, "The tip card covers Build mix")
        XCTAssertTrue(sleepMode.isHittable, "The tip card clipped the mode switcher out of the hit test")
        XCTAssertTrue(leaveTip.isHittable && noThanks.isHittable, "The card's answers aren't hittable")
        XCTAssertLessThanOrEqual(leaveTip.frame.maxY, buildMix.frame.minY,
                                 "The card isn't in the band above Build mix: \(leaveTip.frame) vs \(buildMix.frame)")

        // CI's simulators sometimes drop a synthesized tap: check the effect and go round again.
        for _ in 0..<3 where leaveTip.exists {
            noThanks.tap()
            if leaveTip.waitForNonExistence(timeout: 3) { break }
        }
        XCTAssertTrue(leaveTip.waitForNonExistence(timeout: 5),
                      "The tip card stayed in the hierarchy after \"No thanks\"")
        XCTAssertTrue(buildMix.isHittable, "Build mix is covered after the card left")
    }

    /// The card's main answer (design D5, D6): "Leave a tip" opens the sheet with the three tips,
    /// and closing the sheet spends the card, so it leaves the hierarchy and Build mix takes taps
    /// again. The same DEBUG-only seams as the test above; under them the spend stays in memory for
    /// this run, so nothing persists.
    /// Value: protects=the card's main answer opens the three tips and closing the sheet spends
    /// the card; fails_when=onLeaveTip is unwired, the sheet's onDismiss stops spending the card,
    /// or TipRows render nothing for ready products; why_new=the only UI test taps No thanks;
    /// seam=uiTestTipProducts + uiTestTipCardDue (DEBUG-only); no_claim=a real purchase (TESTING
    /// §3U.6), and the persisted tipCardSpent write (the seam spends in memory)
    @MainActor
    func testLeaveATipOpensTheTipsAndClosingSpendsTheCard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ambientMotion", "<false/>", "-uiTestIsolated", "<true/>",
                               "-uiTestTipProducts", "<true/>", "-uiTestTipCardDue", "<true/>",
                               "-hasCompletedFirstRun", "<true/>", "-hasSeenNightRingTip", "<true/>",
                               "-tipCardSpent", "<false/>", "-tippedOnThisPhone", "<false/>"]
        app.launch()

        let sleepMode = app.buttons["Sleep mode"]
        XCTAssertTrue(sleepMode.waitForExistence(timeout: 15), "No mode switcher on Home")
        sleepMode.tap()

        let leaveTip = app.buttons["Leave a tip"]
        let buildMix = app.buttons["Build mix"]
        XCTAssertTrue(leaveTip.waitForExistence(timeout: 10), "The tip card didn't show on Sleep Home")
        XCTAssertTrue(buildMix.waitForExistence(timeout: 5), "No Build mix button")

        // A tip row's label is its name and price ("Small tip, $0.99").
        func tipRow(_ name: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        }
        let smallTip = tipRow("Small tip")
        // CI's simulators sometimes drop a synthesized tap: check the effect and go round again. The
        // effect is re-read before each tap, so a late one isn't doubled.
        for _ in 0..<3 where !smallTip.exists {
            if leaveTip.exists { leaveTip.tap() }
            if smallTip.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(smallTip.waitForExistence(timeout: 5), "\"Leave a tip\" didn't open the tips")
        XCTAssertTrue(tipRow("Kind tip").exists && tipRow("Generous tip").exists,
                      "The tip sheet doesn't offer all three tips")

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5), "The tip sheet has no Close")
        for _ in 0..<3 where close.exists {
            close.tap()
            if close.waitForNonExistence(timeout: 3) { break }
        }
        XCTAssertTrue(smallTip.waitForNonExistence(timeout: 5), "Close didn't close the tip sheet")
        XCTAssertTrue(leaveTip.waitForNonExistence(timeout: 5),
                      "The tip card stayed in the hierarchy after its sheet closed")
        XCTAssertTrue(buildMix.isHittable, "Build mix is covered after the sheet closed")
    }

    /// Sleep Home at rest (nothing loaded) hides the mini-player, and hidden must mean gone from
    /// the accessibility tree: faded to opacity 0 it stayed there on iOS 26, over Build mix.
    /// And Home's controls must all take a tap: the night ring's accessibility shape once became
    /// Home's whole frame, and XCUITest called everything outside the ring unhittable.
    @MainActor
    func testSleepHomeAtRestHasNoMiniPlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // Moving scenes off, for this launch only: like the Focus test, so the app idles between
        // taps on a loaded runner (Sleep Home's orb and scene otherwise redraw every frame).
        app.launchArguments = ["-ambientMotion", "<false/>", "-uiTestIsolated", "<true/>"]
        app.launch()

        // Sleep from either start state. A fresh launch has no episode loaded.
        let sleepMode = app.buttons["Sleep mode"]
        XCTAssertTrue(sleepMode.waitForExistence(timeout: 15), "No mode switcher on Home")
        sleepMode.tap()

        // An exact label: on a fresh install the first-run tip is a button that says "Build mix" too.
        let buildMix = app.buttons["Build mix"]
        let miniPlayer = app.descendants(matching: .any)["miniPlayer"]
        XCTAssertTrue(buildMix.waitForExistence(timeout: 5), "No Build mix button")
        // Coming from Focus, the bar fades out over ~1 s.
        XCTAssertTrue(miniPlayer.waitForNonExistence(timeout: 5),
                      "The hidden mini-player is still in the accessibility tree on Sleep Home")
        XCTAssertTrue(buildMix.isHittable, "Build mix is covered")
        XCTAssertTrue(sleepMode.isHittable, "The mode switcher is clipped out of Home's hit test")

        // Off Home it comes back: Podcasts always shows it.
        app.tabBars.buttons["Podcasts"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "No mini-player on Podcasts")
        // Rendered where it floats, above the tab bar and uncovered: existence alone passes for a bar
        // inserted out of place or covered. (A real tap on the bar is the Focus test's check.)
        // Value: protects=on Podcasts the bar sits above the tab bar, uncovered at its hit point;
        // fails_when=the bar's wrapper or insertion misplaces it or something covers it;
        // why_new=only existence was checked; seam=none
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { miniPlayer.frame.maxY <= tabBar.frame.minY },
                      "The mini-player isn't above the tab bar: bar \(miniPlayer.frame), tab bar \(tabBar.frame)")
        XCTAssertTrue(miniPlayer.isHittable, "The mini-player on Podcasts is covered at its hit point")

        // Back on Sleep Home it goes again. This time the bar was rendered and has to be taken out;
        // a fresh launch in Sleep never renders it, so the checks above can't see a removal.
        // Value: protects=a shown bar leaves the a11y tree when Sleep Home at rest returns;
        // fails_when=the hide fades the bar instead of removing it; why_new=the cold-launch check
        // above never sees a rendered bar taken out; seam=none
        app.tabBars.buttons["Sleep"].tap()
        XCTAssertTrue(buildMix.waitForExistence(timeout: 5), "No Build mix button back on Sleep Home")
        XCTAssertTrue(miniPlayer.waitForNonExistence(timeout: 5),
                      "The mini-player stayed in the accessibility tree after returning to Sleep Home")
        XCTAssertTrue(buildMix.isHittable, "Build mix is covered after returning to Sleep Home")
    }

    /// Puts the app back in Sleep for the tests that follow (the unit tests hosted in this app read
    /// its persisted mode), from wherever an assertion stopped the Focus test: Now Playing up, on
    /// Podcasts, the controls faded, a session running. Goes round again like the test's own taps,
    /// and answers the "Switch to Sleep?" confirm a running session raises.
    @MainActor
    private static func leaveInSleep(_ app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let done = app.buttons["Done"]
        let homeTab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Focus", "Sleep"])).firstMatch
        let wake = app.buttons["Show controls"]
        let stop = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop focus session")).firstMatch
        let confirm = app.alerts.buttons["Switch to Sleep"]
        let sleep = app.buttons["Sleep mode"]
        for _ in 0..<3 where !(sleep.exists && sleep.isSelected) {
            if confirm.exists { confirm.tap(); _ = confirm.waitForNonExistence(timeout: 3); continue }
            if done.exists { done.tap(); _ = done.waitForNonExistence(timeout: 3) }
            if homeTab.exists, !homeTab.isSelected { homeTab.tap() }
            if wake.exists { wake.tap() }
            if stop.exists { stop.tap() }
            if sleep.waitForExistence(timeout: 3), !sleep.isSelected { sleep.tap() }
            _ = confirm.waitForExistence(timeout: 1)
        }
    }

    /// Polls `condition` on the main run loop until it holds or `timeout` passes.
    @MainActor
    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
