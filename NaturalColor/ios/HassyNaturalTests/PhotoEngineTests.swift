import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
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
        // Exercise the actual 48 MP graph and default HEIC writer, rather
        // than inferring full-resolution export from a small synthetic image.
        let exported = try await engine.exportCapture(url: url, settings: .init(), output: .init())
        defer { try? FileManager.default.removeItem(at: exported) }
        // A processed-only capture still develops the actual RAW, but only
        // the finished image is selected for the Photos transaction.
        XCTAssertEqual(PhotoSaveMode.processed.resources(original: url, processed: exported), [exported])
        XCTAssertEqual(PhotoSaveMode.both.resources(original: url, processed: exported), [url, exported])
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        try assertRenderProvenance(properties, input: "raw", settings: .init(), output: .init(), source: source)
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

    func testMediumHEICExportPreservesPixelsAndHasMatchingFileType() async throws {
        XCTAssertEqual(PhotoOutputOptions().format, .heic)
        XCTAssertEqual(PhotoOutputOptions().quality, .medium)
        let engine = PhotoEngine()
        let photo = await engine.demoPhoto()
        let url = try await engine.export(photo: photo, settings: .init(), output: .init())
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let raster = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(raster.width, 1200)
        XCTAssertEqual(raster.height, 900)
        let type = CGImageSourceGetType(source) as String?
        XCTAssertEqual(type, url.pathExtension == "heic" ? UTType.heic.identifier : UTType.jpeg.identifier)
        let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
        if supported.contains(UTType.heic.identifier) { XCTAssertEqual(url.pathExtension, "heic") }
    }

    func testHEICQualityChangesBytesWithoutChangingResolution() async throws {
        let engine = PhotoEngine()
        let photo = await engine.demoPhoto()
        let medium = try await engine.export(photo: photo, settings: .init(), output: .init())
        let high = try await engine.export(photo: photo, settings: .init(), output: .init(quality: .high))
        defer { try? FileManager.default.removeItem(at: medium); try? FileManager.default.removeItem(at: high) }
        let mediumBytes = try Data(contentsOf: medium).count
        let highBytes = try Data(contentsOf: high).count
        XCTAssertLessThan(mediumBytes, highBytes)
        for url in [medium, high] {
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let raster = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(raster.width * raster.height, 1200 * 900)
        }
    }

    private func assertRenderProvenance(_ properties: [CFString: Any], input: String,
                                        settings: EditSettings, output: PhotoOutputOptions,
                                        source: CGImageSource) throws {
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment] as? String)
        let data = try XCTUnwrap(comment.data(using: .utf8))
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(provenance["schema"] as? String, "natural-render-v1")
        XCTAssertEqual(provenance["renderer"] as? String, "recovered-standard-sdr-v1")
        XCTAssertEqual(provenance["input"] as? String, input)
        XCTAssertEqual(try XCTUnwrap(provenance["strength"] as? NSNumber).floatValue, settings.strength, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(provenance["exposureEV"] as? NSNumber).floatValue, settings.exposure, accuracy: 0.000001)
        XCTAssertEqual(provenance["aspectRatio"] as? String, settings.aspectRatio.rawValue)
        let storedOutput = try XCTUnwrap(provenance["output"] as? [String: Any])
        let type = CGImageSourceGetType(source) as String?
        let heic = type == UTType.heic.identifier
        XCTAssertTrue(heic || type == UTType.jpeg.identifier)
        XCTAssertEqual(storedOutput["format"] as? String, heic ? "heic" : "jpeg")
        XCTAssertEqual(storedOutput["colorSpace"] as? String, heic ? "Display P3" : "sRGB")
        XCTAssertEqual(storedOutput["quality"] as? String, output.quality.rawValue)
        XCTAssertEqual(try XCTUnwrap(storedOutput["compression"] as? NSNumber).doubleValue, output.quality.compression, accuracy: 0.000001)
        let profile = try XCTUnwrap(properties[kCGImagePropertyProfileName] as? String)
        XCTAssertTrue(profile.lowercased().contains(heic ? "p3" : "srgb"), "Unexpected export profile: \(profile)")
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let build = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        XCTAssertFalse(version.isEmpty)
        XCTAssertFalse(build.isEmpty)
        XCTAssertEqual(provenance["appVersion"] as? String, version)
        XCTAssertEqual(provenance["appBuild"] as? String, build)
        if input == "raw" {
            let raw = try XCTUnwrap(provenance["rawDevelopment"] as? [String: Any])
            XCTAssertFalse(try XCTUnwrap(raw["decoderVersion"] as? String).isEmpty)
            for key in ["baselineExposure", "shadowBias", "neutralTemperature", "neutralTint"] {
                XCTAssertTrue(try XCTUnwrap(raw[key] as? NSNumber).doubleValue.isFinite, key)
            }
            XCTAssertGreaterThan(try XCTUnwrap(raw["neutralTemperature"] as? NSNumber).doubleValue, 0)
            for key in ["exposure", "boostAmount", "boostShadowAmount"] {
                XCTAssertEqual(try XCTUnwrap(raw[key] as? NSNumber).floatValue, 0, accuracy: 0.000001, key)
            }
            XCTAssertEqual(raw["gamutMappingEnabled"] as? Bool, false)
            if raw["localToneMapSupported"] as? Bool == true {
                XCTAssertEqual(try XCTUnwrap(raw["localToneMapAmount"] as? NSNumber).floatValue, 0, accuracy: 0.000001)
            }
        } else { XCTAssertNil(provenance["rawDevelopment"]) }
        // Some encoders omit TIFF Software; the EXIF build record is required.
        if let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let software = tiff[kCGImagePropertyTIFFSoftware] as? String {
            XCTAssertTrue(software.contains(version))
            XCTAssertTrue(software.contains("(\(build))"))
        }
    }

    func testJPEGAndHEICRecordRenderBuildAndInputWithoutCopyingSourceMetadata() async throws {
        let engine = PhotoEngine()
        let demo = await engine.demoPhoto()
        let raster = try await engine.preview(photo: demo, settings: .init(strength: 0))
        let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-sensitive-name-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(sourceURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, raster, [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "synthetic private comment",
                kCGImagePropertyExifDateTimeOriginal: "2001:02:03 04:05:06"
            ],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "synthetic private artist"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"]
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let originalSource = try XCTUnwrap(CGImageSourceCreateWithURL(sourceURL as CFURL, nil))
        let originalProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(originalSource, 0, nil) as? [CFString: Any])
        XCTAssertNotNil(originalProperties[kCGImagePropertyGPSDictionary])
        let originalExif = try XCTUnwrap(originalProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        XCTAssertEqual(originalExif[kCGImagePropertyExifUserComment] as? String, "synthetic private comment")
        let photo = try await engine.load(url: sourceURL)
        XCTAssertFalse(photo.isRaw)
        let settings = EditSettings(strength: 0.625, exposure: -0.5, aspectRatio: .threeTwo)
        for format in [PhotoFileFormat.jpeg, .heic] {
            let output = PhotoOutputOptions(format: format, quality: format == .heic ? .medium : .high)
            let url = try await engine.export(photo: photo, settings: settings, output: output)
            defer { try? FileManager.default.removeItem(at: url) }
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(encoded, 0, nil) as? [CFString: Any])
            try assertRenderProvenance(properties, input: "processed", settings: settings, output: output, source: encoded)
            XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
            let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
            XCTAssertNil(exif[kCGImagePropertyExifDateTimeOriginal])
            let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment] as? String)
            XCTAssertFalse(comment.contains("synthetic private"))
            XCTAssertFalse(comment.contains("source-sensitive-name"))
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            XCTAssertNil(tiff?[kCGImagePropertyTIFFArtist])
        }
    }

    private let exportPatchWidth = 128
    private let exportPatchHeight = 128
    private let exportPatches: [[Float]] = [
        [0, 0, 0], [0.01, 0.01, 0.01], [0.18, 0.18, 0.18], [0.7, 0.7, 0.7], [1, 1, 1],
        [0.8, 0.015, 0.01], [0.015, 0.65, 0.02], [0.015, 0.025, 0.8],
        [0.7, 0.6, 0.01], [0.015, 0.6, 0.65], [0.65, 0.015, 0.7], [0.42, 0.25, 0.17]
    ]

    private func flatPatchPhoto() -> LoadedPhoto {
        let width = exportPatches.count * exportPatchWidth
        var rgba = [Float](repeating: 1, count: width * exportPatchHeight * 4)
        for y in 0..<exportPatchHeight {
            for x in 0..<width {
                let patch = exportPatches[x / exportPatchWidth]
                for channel in 0..<3 { rgba[(y * width + x) * 4 + channel] = patch[channel] }
            }
        }
        let bytes = rgba.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: bytes, bytesPerRow: width * 16,
                            size: CGSize(width: CGFloat(width), height: CGFloat(exportPatchHeight)), format: .RGBAf,
                            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return LoadedPhoto(image: image, name: "Export reference patches", isRaw: false)
    }

    private func managedPatchMeans(_ image: CGImage) throws -> [[Double]] {
        XCTAssertEqual(image.width, exportPatches.count * exportPatchWidth)
        XCTAssertEqual(image.height, exportPatchHeight)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        // Average central 16x16 areas, far from chroma-subsampled patch edges.
        return exportPatches.indices.map { patch in
            var sums = [Double](repeating: 0, count: 3)
            for y in (exportPatchHeight / 2 - 8)..<(exportPatchHeight / 2 + 8) {
                for x in (patch * exportPatchWidth + exportPatchWidth / 2 - 8)..<(patch * exportPatchWidth + exportPatchWidth / 2 + 8) {
                    for channel in 0..<3 { sums[channel] += Double(bytes[(y * image.width + x) * 4 + channel]) }
                }
            }
            return sums.map { $0 / 256 }
        }
    }

    private func profileProbe(_ space: CGColorSpace) -> [Float] {
        // Primaries distinguish P3/sRGB; middle gray also checks the transfer.
        let values: [Float] = [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1, 0.5, 0.5, 0.5, 1]
        let bytes = values.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: bytes, bytesPerRow: 64, size: CGSize(width: 4, height: 1),
                            format: .RGBAf, colorSpace: space)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        var result = [Float](repeating: 0, count: 16)
        result.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: 64,
                           bounds: image.extent, format: .RGBAf, colorSpace: linear)
        }
        return result
    }

    func testDecodedJPEGAndP3HEICPreservePreviewAppearanceAndExportProfiles() async throws {
        let engine = PhotoEngine()
        let photo = flatPatchPhoto()
        // No preview resize: each path sees identical constant pixel inputs.
        for strength in [Float(0), Float(1)] {
            let settings = EditSettings(strength: strength)
            let preview = try await engine.preview(photo: photo, settings: settings)
            let expected = try managedPatchMeans(preview)
            if strength == 0 {
                for patch in exportPatches.indices {
                    for channel in 0..<3 {
                        let linear = Double(exportPatches[patch][channel])
                        let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
                        XCTAssertEqual(expected[patch][channel], encoded * 255, accuracy: 1.1)
                    }
                }
            }
            var decodedMeans: [[[Double]]] = []
            for format in [PhotoFileFormat.jpeg, .heic] {
                let quality: PhotoFileQuality = format == .heic ? .medium : .high
                let url = try await engine.export(photo: photo, settings: settings, output: .init(format: format, quality: quality))
                defer { try? FileManager.default.removeItem(at: url) }
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                let space = try XCTUnwrap(decoded.colorSpace)
                XCTAssertEqual(space.model, .rgb)
                XCTAssertNotNil(space.name, "Export must decode with a named color profile")
                let heic = url.pathExtension == "heic"
                let supported = CGImageDestinationCopyTypeIdentifiers() as! [String]
                if format == .heic && supported.contains(UTType.heic.identifier) { XCTAssertTrue(heic) }
                let expectedSpace = CGColorSpace(name: heic ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
                let actualProfile = profileProbe(space)
                let expectedProfile = profileProbe(expectedSpace)
                for index in actualProfile.indices {
                    XCTAssertEqual(actualProfile[index], expectedProfile[index], accuracy: 0.003,
                                   "\(url.pathExtension) color profile probe \(index)")
                }
                let actual = try managedPatchMeans(decoded)
                decodedMeans.append(actual)
                for patch in exportPatches.indices {
                    for channel in 0..<3 {
                        XCTAssertEqual(actual[patch][channel], expected[patch][channel], accuracy: heic ? 6 : 4,
                                       "\(url.pathExtension) strength \(strength), patch \(patch), channel \(channel)")
                    }
                }
            }
            for patch in exportPatches.indices {
                for channel in 0..<3 {
                    XCTAssertEqual(decodedMeans[0][patch][channel], decodedMeans[1][patch][channel], accuracy: 7,
                                   "JPEG/HEIC strength \(strength), patch \(patch), channel \(channel)")
                }
            }
        }
    }

    @MainActor func testCaptureOrientationFollowsDeviceAndRetainsPoseWhenFlat() {
        XCTAssertEqual(CaptureOrientation.angle(for: .portrait, previous: 0), 90)
        XCTAssertEqual(CaptureOrientation.angle(for: .landscapeLeft, previous: 90), 0)
        XCTAssertEqual(CaptureOrientation.angle(for: .landscapeRight, previous: 90), 180)
        XCTAssertEqual(CaptureOrientation.angle(for: .portraitUpsideDown, previous: 90), 270)
        XCTAssertEqual(CaptureOrientation.angle(for: .faceUp, previous: 180), 180)
        XCTAssertEqual(CaptureOrientation.angle(for: .unknown, previous: 0), 0)
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
