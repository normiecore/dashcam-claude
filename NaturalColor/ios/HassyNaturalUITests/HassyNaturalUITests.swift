import XCTest

final class HassyNaturalUITests: XCTestCase {
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
        app.buttons["About Hassy Natural"].tap()
        XCTAssertTrue(app.staticTexts["An independent camera and photo editor exploring natural colour rendering."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["cameraShutter"].waitForExistence(timeout: 5))
        attach(app, name: "Camera launch without hardware")
    }

    func testCaptureInterfaceGridFormatAndExposureControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--camera-ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["INTERFACE PREVIEW"].waitForExistence(timeout: 10))
        // The simulator fixture must never pretend that it can capture photos.
        XCTAssertFalse(app.buttons["cameraShutter"].isEnabled)
        let grid = app.buttons["cameraGrid"]
        XCTAssertEqual(grid.value as? String, "Off")
        grid.tap()
        XCTAssertEqual(grid.value as? String, "On")
        app.buttons["captureFormat"].tap()
        app.buttons["JPEG"].tap()
        XCTAssertEqual(app.buttons["captureFormat"].value as? String, "JPEG")
        attach(app, name: "Camera instrument layout with composition grid")
        app.buttons["cameraControls"].tap()
        let exposure = app.sliders["cameraExposureSlider"]
        XCTAssertTrue(exposure.waitForExistence(timeout: 5))
        exposure.adjust(toNormalizedSliderPosition: 0.75)
        let value = (exposure.value as? String ?? "").replacingOccurrences(of: " EV", with: "")
        XCTAssertEqual(Float(value) ?? -100, 1, accuracy: 0.2)
        attach(app, name: "Camera exposure controls")
        app.buttons["Done"].tap()
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertEqual(grid.value as? String, "On")
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
        XCTAssertEqual(compare.value as? String, "Edited")
        compare.tap()
        XCTAssertEqual(compare.value as? String, "Original")
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
