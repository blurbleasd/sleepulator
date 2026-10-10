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
        let buildMix = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Build mix")).firstMatch
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
        app.buttons["Sleep mode"].tap()
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

        let buildMix = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Build mix")).firstMatch
        let miniPlayer = app.descendants(matching: .any)["miniPlayer"]
        XCTAssertTrue(buildMix.waitForExistence(timeout: 5), "No Build mix button")
        // Coming from Focus, the bar fades out over ~1 s.
        XCTAssertTrue(waitUntil(timeout: 5) { !miniPlayer.exists },
                      "The hidden mini-player is still in the accessibility tree on Sleep Home")
        XCTAssertTrue(buildMix.isHittable, "Build mix is covered")
        XCTAssertTrue(sleepMode.isHittable, "The mode switcher is clipped out of Home's hit test")

        // Off Home it comes back: Podcasts always shows it.
        app.tabBars.buttons["Podcasts"].tap()
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 5), "No mini-player on Podcasts")
        app.tabBars.buttons["Sleep"].tap()
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
