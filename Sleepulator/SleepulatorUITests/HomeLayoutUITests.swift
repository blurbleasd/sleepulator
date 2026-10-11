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
        app.launch()

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
        // screen's wake layer instead of Stop, and the session runs on. Wake the controls first.
        let wake = app.buttons["Show controls"]
        if wake.exists { wake.tap() }
        stop.tap()

        // Leave the app in Sleep: the unit tests run hosted in this same app and read its
        // persisted mode, so a run after this one must not start out in Focus.
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        // Read before the switch, checked after it, so a failure here still leaves the app in Sleep.
        let barTop = miniPlayer.waitForExistence(timeout: 5) ? miniPlayer.frame.minY : nil
        app.buttons["Sleep mode"].tap()
        guard let barTop else { return XCTFail("No mini-player in Focus after the session") }

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

    /// Sleep Home at rest (nothing loaded) hides the mini-player, and hidden must mean gone from
    /// the accessibility tree: faded to opacity 0 it stayed there on iOS 26, over Build mix.
    /// And Home's controls must all take a tap: the night ring's accessibility shape once became
    /// Home's whole frame, and XCUITest called everything outside the ring unhittable.
    @MainActor
    func testSleepHomeAtRestHasNoMiniPlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
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
        // Rendered where it floats, above the tab bar, and taking taps: existence alone passes for a
        // bar inserted out of place or covered.
        // Value: protects=on Podcasts the bar sits above the tab bar and takes taps;
        // fails_when=the bar's wrapper or insertion misplaces it or leaves it untappable;
        // why_new=only existence was checked; seam=none
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(waitUntil(timeout: 5) { miniPlayer.frame.maxY <= tabBar.frame.minY },
                      "The mini-player isn't above the tab bar: bar \(miniPlayer.frame), tab bar \(tabBar.frame)")
        XCTAssertTrue(miniPlayer.isHittable, "The mini-player on Podcasts doesn't take taps")

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
