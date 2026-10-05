import XCTest

/// App Store Connect rejects builds whose privacy manifest is missing required-reason declarations
/// (enforced since 2024-05-01). The rolling buffer uses disk-space, file-metadata and UserDefaults
/// APIs, so these entries must survive every refactor.
final class PrivacyManifestTests: XCTestCase {
    private func loadManifest() throws -> [String: Any] {
        let bundle = Bundle(for: PrivacyManifestTests.self)
        let hostBundle = Bundle.main
        let url = try XCTUnwrap(
            hostBundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
                ?? bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"),
            "PrivacyInfo.xcprivacy must be bundled with the app"
        )
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testManifestDeclaresRequiredReasonAPIs() throws {
        let manifest = try loadManifest()
        XCTAssertEqual(manifest["NSPrivacyTracking"] as? Bool, false)
        XCTAssertEqual((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.count, 0, "footage never leaves the device")
        let accessed = try XCTUnwrap(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        var reasons: [String: Set<String>] = [:]
        for entry in accessed {
            let type = try XCTUnwrap(entry["NSPrivacyAccessedAPIType"] as? String)
            let codes = try XCTUnwrap(entry["NSPrivacyAccessedAPITypeReasons"] as? [String])
            reasons[type] = Set(codes)
        }
        XCTAssertTrue(reasons["NSPrivacyAccessedAPICategoryDiskSpace"]?.contains("E174.1") == true, "free-space checks drive retention")
        XCTAssertTrue(reasons["NSPrivacyAccessedAPICategoryDiskSpace"]?.contains("85F4.1") == true, "free space is shown to the user")
        XCTAssertTrue(reasons["NSPrivacyAccessedAPICategoryFileTimestamp"]?.contains("C617.1") == true, "segment sizes/timestamps inside the container")
        XCTAssertTrue(reasons["NSPrivacyAccessedAPICategoryUserDefaults"]?.contains("CA92.1") == true, "settings live in UserDefaults")
    }

    func testUsageDescriptionsArePresent() {
        let info = Bundle.main.infoDictionary ?? [:]
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryAddUsageDescription", "NSMotionUsageDescription"] {
            let value = info[key] as? String
            XCTAssertFalse((value ?? "").isEmpty, "\(key) must be set; starting capture without it raises an exception")
        }
        XCTAssertNil(info["UIBackgroundModes"], "no background mode extends camera capture; declaring one is a review risk")
    }
}
