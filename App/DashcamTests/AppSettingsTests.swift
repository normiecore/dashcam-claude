import Foundation
import XCTest
@testable import Dashcam

final class AppSettingsTests: XCTestCase {
    func testDefaultsSeparateRecentHistoryFromSavedClipWindow() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.quality, .hd1080p30)
        XCTAssertEqual(settings.bufferMinutes, 5)
        XCTAssertEqual(settings.incidentPolicy.preRoll, 5 * 60)
        XCTAssertEqual(settings.retentionPolicy.targetDuration, 6 * 3_600)
        XCTAssertEqual(settings.retentionPolicy.maxBufferBytes, Int64(4) * 1_073_741_824)
    }

    func testQualityAndBudgetProduceUsefulHistoryEstimates() {
        let suite = "AppSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.recentHistoryMinutes = 12 * 60
        settings.recentHistoryGigabytes = 4

        settings.quality = .hd720p30
        let spaceSaver = settings.estimatedRecentHistorySeconds
        settings.quality = .hd1080p30
        let standard = settings.estimatedRecentHistorySeconds
        settings.quality = .hd1080p30High
        let highDetail = settings.estimatedRecentHistorySeconds

        XCTAssertGreaterThan(spaceSaver, standard)
        XCTAssertGreaterThan(standard, highDetail)
        XCTAssertGreaterThan(highDetail, 3_600)
    }
}
