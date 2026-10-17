import XCTest

final class HassyNaturalUITests: XCTestCase {
    override func setUpWithError() throws {
        // Hosted iOS 26 accessibility/launch operations sometimes take over
        // two minutes even with every assertion passing. Keep this allowance
        // specific to UI automation; image/unit checks retain their own limit.
        executionTimeAllowance = 240
        continueAfterFailure = false
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLaunchOpensCameraAndKeepsImportsAvailableWithoutHardware() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.otherElements["cameraScreen"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["A considered take\non natural colour."].exists)
        XCTAssertTrue(app.buttons["cameraShutter"].exists)
        XCTAssertTrue(app.buttons["cameraImport"].isEnabled)
        app.buttons["cameraImport"].tap()
        XCTAssertTrue(app.buttons["Photo library"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Import from Files"].exists)
        app.buttons["About Natural"].tap()
        XCTAssertTrue(app.staticTexts["A camera, with room to look."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["cameraShutter"].waitForExistence(timeout: 5))
        attach(app, name: "Camera launch without hardware")
    }

    func testCaptureInterfaceGridFormatAndExposureControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--camera-ui-testing", "--advanced-ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["INTERFACE PREVIEW"].waitForExistence(timeout: 10))
        // The simulator fixture must never pretend that it can capture photos.
        XCTAssertFalse(app.buttons["cameraShutter"].isEnabled)
        let grid = app.buttons["cameraGrid"]
        XCTAssertEqual(grid.value as? String, "Off")
        grid.tap()
        XCTAssertEqual(grid.value as? String, "On")
        attach(app, name: "Camera instrument layout with composition grid")
        app.buttons["cameraControls"].tap()
        let exposure = app.sliders["cameraExposureSlider"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        if !exposure.isHittable { app.swipeUp() }
        exposure.adjust(toNormalizedSliderPosition: 0.75)
        let value = (exposure.value as? String ?? "").replacingOccurrences(of: " EV", with: "")
        // XCTest's thumb gesture is approximate; verify direction, bounds and
        // exact propagation of the resulting setting rather than its pixel position.
        XCTAssertGreaterThan(Float(value) ?? -100, 0)
        XCTAssertLessThanOrEqual(Float(value) ?? 100, 2)
        attach(app, name: "Camera exposure controls")
        app.buttons["Done"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(grid.value as? String, "On")
        XCTAssertEqual(app.buttons["cameraExposureControl"].value as? String, value + " EV")
        app.buttons["cameraControls"].tap()
        let about = app.buttons["About Natural"]
        if !about.isHittable { app.swipeUp() }
        about.tap()
        XCTAssertTrue(app.staticTexts["A camera, with room to look."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
    }

    func testSimpleDefaultsRatiosAndAdvancedToggle() {
        let app = XCUIApplication()
        app.launchArguments = ["--camera-ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["INTERFACE PREVIEW"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["cameraGrid"].exists)
        XCTAssertFalse(app.buttons["captureFormat"].exists)
        XCTAssertFalse(app.buttons["cameraExposureControl"].exists)
        XCTAssertEqual(app.buttons["cameraRatio"].value as? String, "Native")
        attach(app, name: "Simple camera native framing")
        app.buttons["cameraRatio"].tap()
        app.buttons["1:1"].tap()
        XCTAssertEqual(app.buttons["cameraRatio"].value as? String, "1:1")
        attach(app, name: "Simple camera square crop")
        app.buttons["cameraControls"].tap()
        XCTAssertTrue(app.staticTexts["Medium"].exists)
        XCTAssertEqual(app.switches["saveRAW"].value as? String, "0")
        attach(app, name: "Medium HEIC and RAW off defaults")
        app.switches["saveRAW"].tap()
        app.switches["advancedMode"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["cameraGrid"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["cameraExposureControl"].exists)
        XCTAssertEqual(app.staticTexts["captureFormat"].value as? String, "RAW")
        app.buttons["cameraControls"].tap()
        app.switches["advancedMode"].tap()
        app.buttons["Done"].tap()
        XCTAssertFalse(app.buttons["cameraGrid"].exists)
        XCTAssertTrue(app.buttons["cameraShutter"].exists)
    }

    func testDeniedCameraStillOffersSettingsAndImport() {
        let app = XCUIApplication()
        app.launchArguments = ["--camera-denied-ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        XCTAssertFalse(app.buttons["cameraShutter"].isEnabled)
        XCTAssertTrue(app.buttons["cameraImport"].isEnabled)
        attach(app, name: "Camera permission recovery")
    }

    func testEditorCompareAdjustResetAndReturnToCamera() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let compare = app.buttons["compareButton"]
        XCTAssertTrue(compare.waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Studio gradient"].waitForExistence(timeout: 30))
        XCTAssertTrue(compare.isHittable)
        XCTAssertEqual(compare.value as? String, "Edited")
        compare.tap()
        let original = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Original"), object: compare)
        XCTAssertEqual(XCTWaiter.wait(for: [original], timeout: 5), .completed)
        compare.tap()
        XCTAssertEqual(compare.value as? String, "Edited")
        app.sliders["strengthSlider"].adjust(toNormalizedSliderPosition: 0.3)
        app.sliders["exposureSlider"].adjust(toNormalizedSliderPosition: 0.75)
        app.buttons["resetButton"].tap()
        XCTAssertTrue(app.staticTexts["+0.0 EV"].exists)
        XCTAssertTrue(app.buttons["saveButton"].isEnabled)
        XCTAssertTrue(app.buttons["shareButton"].isEnabled)
        attach(app, name: "Natural review controls")
        app.buttons["backToCamera"].tap()
        XCTAssertTrue(app.buttons["cameraShutter"].waitForExistence(timeout: 10))
        XCTAssertFalse(compare.exists)
        XCTAssertTrue(app.buttons["reviewCapture"].isEnabled)
        app.buttons["reviewCapture"].tap()
        XCTAssertTrue(compare.waitForExistence(timeout: 10))
        XCTAssertEqual(compare.value as? String, "Edited")
    }
}
