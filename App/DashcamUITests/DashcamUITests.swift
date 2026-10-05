import XCTest

/// Drives the app's screens in the Simulator. Every launch uses the simulated camera and wipes its own
/// settings and storage, with 2 s segments, a 1 minute buffer and a 5 s post-roll (`--ui-testing`, see
/// LaunchConfiguration.swift), so no test depends on another or on the app's real footage.
final class DashcamUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Recording and incidents

    @MainActor
    func testFirstRunConsentThenRecordSaveIncidentReviewAndDeleteTheClip() throws {
        let app = launch(skipOnboarding: false)

        XCTAssertTrue(app.staticTexts["Welcome to Dashcam"].waitForExistence(timeout: 20), "the consent screen is shown on first run")
        app.buttons["onboarding.continue"].tap()

        startRecording(app)
        let save = app.buttons["record.saveIncident"]
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 15), "Save Incident is enabled while recording")
        save.tap()
        let card = element(app, "record.incidentCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the incident card shows while the post-roll is recorded")
        XCTAssertTrue(card.waitForNonExistence(timeout: 60), "the incident closes after its 5 s post-roll")
        XCTAssertTrue(state(app).label.contains("Recording"), "recording continues after an incident: \(state(app).label)")
        stopRecording(app)

        app.tabBars.buttons["Clips"].tap()
        let row = element(app, "clips.row")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the incident is listed")
        XCTAssertTrue(row.wait(labelContaining: "Manual", timeout: 5), row.label)
        XCTAssertTrue(row.wait(labelContaining: "Saved", timeout: 60), "the clip finishes exporting: \(row.label)")
        row.tap()

        XCTAssertTrue(app.buttons["clip.share"].waitForExistence(timeout: 15), "a finished clip can be shared")
        let delete = app.buttons["clip.delete"]
        scrollUntilHittable(delete, in: app)
        delete.tap()
        let confirm = app.buttons["Delete Clip"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), "deleting asks for confirmation")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["No saved clips"].waitForExistence(timeout: 15), "the library is empty after deleting its only clip")
    }

    @MainActor
    func testDimScreenShowsRecHoldSavesAnIncidentAndTapWakes() throws {
        let app = launch()
        startRecording(app)

        app.buttons["record.dim"].tap()
        let cover = element(app, "dimmed.cover")
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "the dimmed cover is shown")
        XCTAssertTrue(cover.wait(labelContaining: "REC", timeout: 5), "the dimmed screen keeps a recording indicator: \(cover.label)")

        cover.press(forDuration: 1.6)
        XCTAssertTrue(cover.wait(labelContaining: "Securing footage", timeout: 10), "holding the dimmed screen saves an incident without waking it: \(cover.label)")

        cover.tap()
        XCTAssertTrue(cover.waitForNonExistence(timeout: 10), "a tap wakes the screen")
        XCTAssertTrue(state(app).label.contains("Recording"), "recording continued while dimmed: \(state(app).label)")
        stopRecording(app)
    }

    @MainActor
    func testSimulateCrashFromTheDeveloperMenuSavesAnIncident() throws {
        let app = launch()
        startRecording(app)

        app.tabBars.buttons["Settings"].tap()
        let tools = app.buttons["settings.developerTools"]
        scrollUntilHittable(tools, in: app)
        tools.tap()
        let crash = app.buttons["developer.simulateCrash"]
        XCTAssertTrue(crash.waitForExistence(timeout: 10), "the developer menu opens")
        crash.tap()

        app.tabBars.buttons["Clips"].tap()
        let row = element(app, "clips.row")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the simulated crash creates an incident")
        XCTAssertTrue(row.wait(labelContaining: "Developer simulation", timeout: 5), row.label)
        XCTAssertTrue(row.wait(labelContaining: "Saved", timeout: 60), "the clip finishes exporting: \(row.label)")

        app.tabBars.buttons["Record"].tap()
        stopRecording(app)
    }

    // MARK: Permissions

    @MainActor
    func testWithCameraAccessDeniedTheRecordScreenOffersSettingsAndCannotStart() throws {
        let app = launch(["--camera-denied"])

        XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 20), "the denied state is explained")
        XCTAssertTrue(app.buttons["permissions.openSettings"].exists, "a link to Settings is offered")
        let start = app.buttons["record.startStop"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "recording cannot start without camera access")
        XCTAssertFalse(app.buttons["record.saveIncident"].isEnabled, "there is nothing to save")
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ arguments: [String] = [], skipOnboarding: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--simulated-camera"] + (skipOnboarding ? ["--skip-onboarding"] : []) + arguments
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func state(_ app: XCUIApplication) -> XCUIElement {
        element(app, "record.state")
    }

    @MainActor
    private func startRecording(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["record.startStop"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Record screen is shown", file: file, line: line)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), "Start recording is enabled", file: file, line: line)
        button.tap()
        let indicator = state(app)
        XCTAssertTrue(indicator.wait(labelContaining: "Recording", timeout: 20), "recording starts: \(indicator.label)", file: file, line: line)
    }

    @MainActor
    private func stopRecording(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["record.startStop"].tap()
        let indicator = state(app)
        XCTAssertTrue(indicator.wait(labelContaining: "Stopped", timeout: 20), "recording stops: \(indicator.label)", file: file, line: line)
    }

    /// Lists and forms load rows lazily; swipe until the element is on screen.
    @MainActor
    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }
}

extension XCUIElement {
    /// Waits for the element's accessibility label to contain `text`.
    @MainActor
    func wait(labelContaining text: String, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
