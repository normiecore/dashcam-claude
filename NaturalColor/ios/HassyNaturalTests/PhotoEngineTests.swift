import XCTest
import CoreImage
import ImageIO
@testable import HassyNatural

final class PhotoEngineTests: XCTestCase {
    func testPublicIPhone17ProRAWActuallyRendersAndExportsFullResolution() async throws {
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
        // Exercise the actual 48 MP graph and concrete JPEG writer, rather
        // than inferring full-resolution export from a small synthetic image.
        let exported = try await engine.export(photo: photo, settings: .init())
        defer { try? FileManager.default.removeItem(at: exported) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, Int(photo.image.extent.width))
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, Int(photo.image.extent.height))
        let thumbnail = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ] as CFDictionary))
        XCTAssertGreaterThan(thumbnail.width, 100)
        XCTAssertGreaterThan(thumbnail.height, 100)
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

    func testStandardRatiosCropWithoutResamplingAndPreserveNative() async throws {
        let engine = PhotoEngine()
        let photo = await engine.demoPhoto()
        for (ratio, width, height) in [(PhotoAspectRatio.native, 1200, 900), (.fourThirds, 1200, 900),
                                      (.threeTwo, 1200, 800), (.sixteenNine, 1200, 675), (.square, 900, 900)] {
            let url = try await engine.export(photo: photo, settings: .init(strength: 0, aspectRatio: ratio))
            defer { try? FileManager.default.removeItem(at: url) }
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, width, ratio.rawValue)
            XCTAssertEqual(image.height, height, ratio.rawValue)
        }
        XCTAssertEqual(photo.image.extent.size, CGSize(width: 1200, height: 900))
        let portrait = PhotoAspectRatio.sixteenNine.cropRect(in: CGRect(x: 0, y: 0, width: 6048, height: 8064))
        XCTAssertEqual(portrait.size, CGSize(width: 4536, height: 8064))
        XCTAssertEqual(portrait.midX, 3024)
    }

    func testSaveModesKeepOriginalAndProcessedSeparate() {
        let original = URL(fileURLWithPath: "/original.dng")
        let processed = URL(fileURLWithPath: "/processed.jpg")
        XCTAssertEqual(PhotoSaveMode.both.resources(original: original, processed: processed), [original, processed])
        XCTAssertEqual(PhotoSaveMode.original.resources(original: original, processed: nil), [original])
        XCTAssertEqual(PhotoSaveMode.processed.resources(original: original, processed: processed), [processed])
        XCTAssertEqual(EditSettings().aspectRatio, .native)
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
