import XCTest

/// Drives the app's screens in the Simulator. Every launch uses the simulated camera and wipes its own
/// settings and storage, with 2 s segments, a 1 minute buffer and a 5 s post-roll (`--ui-testing`, see
/// LaunchConfiguration.swift), so no test depends on another or on the app's real footage. Each test
/// also attaches screenshots of the screens it reaches; CI exports them as a preview of the app.
final class DashcamUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: Recording and incidents

    @MainActor
    func testFirstRunConsentThenRecordSaveIncidentReviewAndDeleteTheClip() throws {
        let app = launch(skipOnboarding: false)

        XCTAssertTrue(app.staticTexts["Welcome to Dashcam"].waitForExistence(timeout: 20), "the consent screen is shown on first run")
        snapshot(app, "01 Welcome")
        app.buttons["onboarding.continue"].tap()

        startRecording(app, snapshotBefore: "02 Ready to record")
        snapshot(app, "03 Recording")
        let save = app.buttons["record.saveIncident"]
        XCTAssertTrue(save.wait(for: \.isEnabled, toEqual: true, timeout: 15), "Save clip is enabled while recording")
        save.tap()
        let card = element(app, "record.incidentCard")
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the incident card shows while the post-roll is recorded")
        snapshot(app, "04 Saving an incident")
        XCTAssertTrue(card.waitForNonExistence(timeout: 60), "the incident closes after its 5 s post-roll")
        XCTAssertTrue(state(app).label.contains("Recording"), "recording continues after an incident: \(state(app).label)")
        stopRecording(app)

        app.tabBars.buttons["Clips"].tap()
        let row = element(app, "clips.row")
        XCTAssertTrue(row.waitForExistence(timeout: 15), "the incident is listed")
        XCTAssertTrue(row.wait(labelContaining: "Manual", timeout: 5), row.label)
        XCTAssertTrue(row.wait(labelContaining: "Saved", timeout: 60), "the clip finishes exporting: \(row.label)")
        snapshot(app, "05 Clips")
        row.tap()

        XCTAssertTrue(app.buttons["clip.share"].waitForExistence(timeout: 15), "a finished clip can be shared")
        snapshot(app, "06 Clip")
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
        snapshot(app, "07 Dimmed")

        cover.press(forDuration: 1.6)
        XCTAssertTrue(cover.wait(labelContaining: "Saving clip", timeout: 10), "holding the dimmed screen saves a clip without waking it: \(cover.label)")
        snapshot(app, "08 Dimmed, saving an incident")

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
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "the Settings screen opens")
        snapshot(app, "09 Settings")
        let tools = app.buttons["settings.developerTools"]
        scrollUntilHittable(tools, in: app)
        tools.tap()
        let crash = app.buttons["developer.simulateCrash"]
        XCTAssertTrue(crash.waitForExistence(timeout: 10), "the developer menu opens")
        snapshot(app, "10 Developer tools")
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
        snapshot(app, "11 Camera access off")
        let start = app.buttons["record.startStop"]
        XCTAssertTrue(start.exists)
        XCTAssertFalse(start.isEnabled, "recording cannot start without camera access")
        XCTAssertFalse(app.buttons["record.saveIncident"].isEnabled, "there is nothing to save")
    }

    // MARK: Adaptive layout

    @MainActor
    func testRecordControlsRemainReachableInPortraitAndLandscape() throws {
        let device = XCUIDevice.shared
        device.orientation = .portrait
        defer { device.orientation = .portrait }

        let app = launch()
        let start = app.buttons["record.startStop"]
        XCTAssertTrue(start.waitForExistence(timeout: 20))
        XCTAssertTrue(start.isHittable, "Start is reachable in portrait on this iPhone size")
        start.tap()
        XCTAssertTrue(state(app).wait(labelContaining: "Recording", timeout: 20))

        device.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["record.startStop"].wait(for: \.isHittable, toEqual: true, timeout: 10), "Stop is reachable in landscape")
        XCTAssertTrue(app.buttons["record.saveIncident"].isHittable, "Save clip is reachable in landscape")
        XCTAssertTrue(app.buttons["record.dim"].isHittable, "Dim screen is reachable in landscape")

        device.orientation = .portrait
        XCTAssertTrue(app.buttons["record.startStop"].wait(for: \.isHittable, toEqual: true, timeout: 10), "Stop remains reachable after returning to portrait")
        stopRecording(app)
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
    private func startRecording(_ app: XCUIApplication, snapshotBefore name: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["record.startStop"]
        XCTAssertTrue(button.waitForExistence(timeout: 20), "the Record screen is shown", file: file, line: line)
        XCTAssertTrue(button.wait(for: \.isEnabled, toEqual: true, timeout: 15), "Start recording is enabled", file: file, line: line)
        if let name { snapshot(app, name) }
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

    /// Attaches a screenshot to the test result, kept on success too. CI exports these attachments
    /// (`xcresulttool export attachments`) as the simulator preview; the name orders them.
    @MainActor
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
