import XCTest

final class HassyNaturalUITests: XCTestCase {
    func testWelcomeAndAboutRequireNoPhotoPermission() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["openCamera"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["openLibrary"].exists)
        XCTAssertTrue(app.buttons["openFiles"].exists)
        app.buttons["About Hassy Natural"].tap()
        XCTAssertTrue(app.staticTexts["An independent camera and photo editor exploring natural colour rendering."].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["openCamera"].exists)
    }

    func testEditorCompareAdjustAndReset() {
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
    }
}
