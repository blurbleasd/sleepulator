import XCTest

/// The night veil and Focus's readout are view wiring with no pure rule behind them
/// (`SessionGuards` holds the rules, ContentView / FocusSessionReadout the wiring), so only a
/// running app shows them working: the veil dropping over an untimed night, the 3am glance on the
/// first tap, the second tap bringing Home's controls back, and the readout naming the sounds once.
///
/// Settings ride the launch arguments (the argument domain), so the veil test changes no persisted
/// mode or night length (the unit tests run hosted in this same app and read both). The Focus test
/// switches modes through the switcher, which persists, so a teardown block puts it back in Sleep.
final class NightVeilUITests: XCTestCase {

    /// Skips the first-run and "the timer moved" cards and the breathing on-ramp, whatever the
    /// simulator last saw. Plist literals: the app reads some of these with `as? Bool`.
    private static let quietHome = [
        "-hasCompletedFirstRun", "<true/>",
        "-hasSeenNightRingTip", "<true/>",
        "-hasStartedFirstSession", "<true/>",
        "-breathingOnRamp", "<false/>",
    ]

    private static let veilLabel = "Screen dimmed for sleep. Tap to wake."

    /// The noise bed's switch in the mixer is labelled with the noise's name (Sleep's and Focus's
    /// palettes, as `WarmMixerRow` titles them).
    private static let noiseNames = ["Brown", "Rain", "Ocean", "Pink", "Green", "Forest",
                                     "Fan", "White", "Gray"]

    // Value: protects=an All-night Sleep session gets the veil ~60 s after the last touch, tap 1 is a glance, tap 2 brings Home's controls back and restarts their fade; fails_when=the veil only drops under a timer, the 1st tap wakes outright, or the 2nd leaves the "Show controls" layer over hidden controls; why_new=ContentView's scheduleDim/veilTapped wiring had no test (SessionGuardsTests pin the rules, not the overlay or the tap sequence); seam=none
    @MainActor
    func testAllNightVeilThenGlanceThenWake() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // An untimed night in Sleep with the veil on, for this launch only.
        app.launchArguments = Self.quietHome + [
            "-nightLengthMinutes", "<real>0</real>",
            "-focusMode", "<false/>",
            "-autoNightDim", "<true/>",
        ]
        app.launch()

        let wake = app.buttons["Show controls"]
        let pause = app.buttons["Pause all audio"]
        let veil = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", Self.veilLabel)).firstMatch

        XCTAssertTrue(app.buttons["Sleep mode"].waitForExistence(timeout: 15), "No Sleep Home")
        // The last touch is the mixer's close: the veil's minute runs from there.
        startNoiseFromTheMixer(app)

        // Sleep's controls fade 3 s into a session: that wake layer proves the session is live
        // (the screensaver only engages over one) and that the query below can see it.
        XCTAssertTrue(wake.waitForExistence(timeout: 10), "No screensaver over the session")

        // No timer runs (All night), yet the veil still drops ~60 s after the last touch.
        XCTAssertTrue(veil.waitForExistence(timeout: 80), "No veil over an untimed night")
        // (Not asserted: that only the veil answers "Wake" under it. XCUITest on iOS 26 still lists
        // SwiftUI elements hidden from accessibility, even Home's opacity-0 chrome, so it can't
        // tell; TESTING.md §Q.5 checks it with Voice Control on a device.)

        // A sleepy tap anywhere on the black.
        let tapPoint = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))

        // First tap: the glance. The veil stays (the glance itself is hidden from accessibility).
        // Held past the veil's 1.6 s fade-out, so a wake in progress can't pass for a glance.
        tapPoint.tap()
        let firstTap = Date()
        XCTAssertTrue(holds(for: 2) { veil.exists }, "The first tap woke the screen instead of a glance")

        // Second tap, while the glance shows or fades (8 s, SessionGuards.veilTap): the veil lifts
        // and Home's controls are back and take taps (the orb, still offering Pause), not a bare
        // scene behind the screensaver's "Show controls" layer that needs a third tap.
        let gap = Date().timeIntervalSince(firstTap)
        XCTAssertLessThan(gap, 7.5, "Runner too slow: the second tap would land after the glance (\(gap) s)")
        tapPoint.tap()
        let woke = waitUntil(timeout: 5) {
            !veil.exists && !wake.exists && pause.exists && pause.isHittable
        }
        XCTAssertTrue(woke, "The second tap didn't bring Home's controls back (veil \(veil.exists), "
                      + "wake layer \(wake.exists), orb \(pause.exists))")

        // And the controls' idle fade restarted: they settle back to the scene 3 s later.
        XCTAssertTrue(wake.waitForExistence(timeout: 8), "Home's idle fade didn't restart after the wake")

        pauseAudio(app)
    }

    // Value: protects=Focus's readout says what Play resumes at rest and, while sound plays, names the sounds once in the pills with no status line under the orb; fails_when=the readout shows the status line again while playing ("Pink" over a "Pink" pill), or drops the at-rest "Tap to begin"/"Resume" line; why_new=FocusSessionReadout's branches are view code with no pure seam, and HomeLayoutUITests never plays sound in Focus; seam=none
    @MainActor
    func testFocusReadoutShowsPillsNotADuplicateStatusWhilePlaying() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = Self.quietHome
        app.launch()
        // Back to Sleep even when an assertion stops the test mid-way in Focus.
        addTeardownBlock { @MainActor in Self.leaveInSleep(app) }

        // Focus from either start state, as HomeLayoutUITests does (and back to Sleep at the end).
        let focusMode = app.buttons["Focus mode"]
        XCTAssertTrue(focusMode.waitForExistence(timeout: 15), "No mode switcher on Home")
        focusMode.tap()
        XCTAssertTrue(app.buttons["Start focus session"].waitForExistence(timeout: 5), "Not in Focus")

        let status = app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Tap to begin", "Resume")).firstMatch
        let pills = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Active sounds: ")).firstMatch

        // At rest: the status line says what Play would bring back, and there are no pills.
        XCTAssertTrue(status.waitForExistence(timeout: 5), "Focus at rest shows no status line")
        XCTAssertFalse(pills.exists, "Pills at rest, with nothing playing")

        startNoiseFromTheMixer(app)

        // Playing: the pills name the sounds...
        XCTAssertTrue(pills.waitForExistence(timeout: 5), "No active-sound pills while Focus plays")
        let names = String(pills.label.dropFirst("Active sounds: ".count)).components(separatedBy: ", ")
        XCTAssertFalse(names.isEmpty || names == [""], "The pills name no sound: \(pills.label)")
        // ...and the status line doesn't say them again. Playing, it read the layers joined
        // ("Pink", "Pink + Focus") right above the pills naming the same sounds. The pills' own
        // texts sit inside the pills element in XCUITest's tree (VoiceOver reads the row as one
        // phrase), so only a text outside it is the status line.
        let duplicate = NSPredicate(format: "label == %@", names.joined(separator: " + "))
        XCTAssertEqual(app.staticTexts.matching(duplicate).count, pills.staticTexts.matching(duplicate).count,
                       "The status line repeats the pills (\"\(names.joined(separator: " + "))\")")
        XCTAssertFalse(status.exists, "The at-rest status line stayed up while sound plays")

        // Paused again, the readout goes back to the status line.
        pauseAudio(app)
        XCTAssertTrue(status.waitForExistence(timeout: 5), "No status line once the sound stops")
        XCTAssertFalse(pills.exists, "Pills stayed up after the sound stopped")

        // Leave the app in Sleep: the unit tests run hosted in this same app and read its
        // persisted mode, so a run after this one must not start out in Focus.
        app.buttons["Sleep mode"].tap()
        XCTAssertTrue(app.buttons["Play"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Start focus session"].exists, "Still in Focus at the end")
    }

    /// Back to Sleep, even after a failure in Focus: the unit tests run hosted in this same app
    /// and read its persisted mode, so a run after this one must not start out in Focus.
    @MainActor
    private static func leaveInSleep(_ app: XCUIApplication) {
        guard app.state == .runningForeground else { return }
        let wake = app.buttons["Show controls"]
        if wake.exists { wake.tap() }
        let sleep = app.buttons["Sleep mode"]
        if sleep.waitForExistence(timeout: 3), !sleep.isSelected { sleep.tap() }
    }

    /// Starts sound from the mixer's noise switch, then closes the mixer. Not the orb: the orb
    /// resumes the saved "Last Night" mix, which on a test simulator can be a podcast episode that
    /// won't load (then nothing plays). The switch always starts the generative bed.
    @MainActor
    private func startNoiseFromTheMixer(_ app: XCUIApplication) {
        let buildMix = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Build mix")).firstMatch
        XCTAssertTrue(buildMix.waitForExistence(timeout: 5), "No Build mix button")
        buildMix.tap()

        let noise = app.switches.matching(NSPredicate(format: "label IN %@", Self.noiseNames)).firstMatch
        XCTAssertTrue(noise.waitForExistence(timeout: 5), "No noise switch in the mixer")
        if (noise.value as? String) != "1" { noise.tap() }
        XCTAssertTrue(waitUntil(timeout: 3) { (noise.value as? String) == "1" }, "The noise switch didn't turn on")

        // Close the mixer: drag its header to the bottom edge (a quick swipe there doesn't).
        let header = app.staticTexts["Your mix"]
        XCTAssertTrue(header.exists, "No mixer header")
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        XCTAssertTrue(waitUntil(timeout: 5) { !header.exists }, "The mixer didn't close")
        // Playing: the orb offers Pause, or (Sleep, 3 s on) the controls have already faded.
        let pause = app.buttons["Pause all audio"], wake = app.buttons["Show controls"]
        XCTAssertTrue(waitUntil(timeout: 3) { pause.exists || wake.exists }, "The noise switch started no session")
    }

    /// Stops the session from the orb, waking the faded controls first. They fade again 3 s (Sleep)
    /// or 10 s (Focus) after a touch, and XCUITest's idle waits can eat most of that, so tap Pause
    /// straight after the wake (XCUITest lists the orb even while faded) and check briefly. A tap
    /// that lands on the wake layer instead just wakes the controls, so the next round pauses.
    @MainActor
    private func pauseAudio(_ app: XCUIApplication) {
        let pause = app.buttons["Pause all audio"]
        let wake = app.buttons["Show controls"]
        let play = app.buttons["Play"]
        for _ in 0..<5 {
            if wake.exists { wake.tap() }
            if pause.exists { pause.tap() }
            if play.waitForExistence(timeout: 1.5) { return }
        }
        XCTFail("Couldn't pause the session from the orb")
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

    /// Polls `condition` for `duration`; true only if it held at every look.
    @MainActor
    private func holds(for duration: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            if !condition() { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }
}
