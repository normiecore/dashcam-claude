import XCTest
import CoreImage
import ImageIO
@testable import HassyNatural

final class PhotoEngineTests: XCTestCase {
    func testPublicIPhone17ProRAWActuallyRenders() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "Public17Pro", withExtension: "dng", subdirectory: "Fixtures") else {
            throw XCTSkip("Run scripts/acquire_test_raw.py for the public RAW fixture; hosted CI requires this download")
        }
        let engine = PhotoEngine()
        let photo = try await engine.load(url: url)
        XCTAssertTrue(photo.isRaw)
        XCTAssertEqual(Int(photo.image.extent.width * photo.image.extent.height), 6048*8064)
        let rendered = try await engine.preview(photo: photo, settings: .init())
        XCTAssertGreaterThan(rendered.width, 1000)
        XCTAssertGreaterThan(rendered.height, 1000)
    }
    func testOriginalAndFullSizeExportAreDecodable() async throws {
        let engine = PhotoEngine()
        let photo = await engine.demoPhoto()
        let preview = try await engine.preview(photo: photo, settings: .init(strength: 0, exposure: 0))
        XCTAssertEqual(preview.width, 1200)
        XCTAssertEqual(preview.height, 900)
        let url = try await engine.export(photo: photo, settings: .init())
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 900)
    }

    func testUnreadableRAWIsRejectedWithoutUsingPreview() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".dng")
        try Data("invalid raw".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await PhotoEngine().load(url: url)
            XCTFail("An undecodable RAW must not be accepted")
        } catch { XCTAssertTrue(error is PhotoError) }
    }

    func testImportPreservesExportDimensions() async throws {
        let engine = PhotoEngine()
        let demo = await engine.demoPhoto()
        let url = try await engine.export(photo: demo, settings: .init(strength: 0, exposure: 0))
        defer { try? FileManager.default.removeItem(at: url) }
        let imported = try await engine.load(url: url)
        XCTAssertEqual(imported.image.extent.width, 1200)
        XCTAssertEqual(imported.image.extent.height, 900)
        XCTAssertFalse(imported.isRaw)
    }
}
