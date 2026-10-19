import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import HassyNatural

/// Scene tone stage: GPU/portable agreement, Standard-curve grey targets,
/// highlight compression and Display P3 retention in the HEIC export.
final class SceneToneTests: XCTestCase {
    private struct Profile: Decodable {
        let width: Int
        let height: Int
        let start: [Float]
        let divisor: Float
    }

    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private let filmExposure = HN_FILM_MIDDLE_GREY / HN_SCENE_MIDDLE_GREY

    private func resource(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext)))
    }

    private func floats(_ data: Data) -> [Float] {
        var values = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    /// Patches laid out left to right, each width x height pixels.
    private func patchImage(_ samples: [[Float]], width: Int = 1, height: Int = 1) -> CIImage {
        let total = samples.count * width
        var rgba = [Float](repeating: 1, count: total * height * 4)
        for (index, pixel) in samples.enumerated() {
            for y in 0..<height {
                for x in 0..<width {
                    let destination = (y * total + index * width + x) * 4
                    for channel in 0..<3 { rgba[destination + channel] = pixel[channel] }
                }
            }
        }
        let data = rgba.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: total * 16,
                       size: CGSize(width: CGFloat(total), height: CGFloat(height)), format: .RGBAf, colorSpace: linear)
    }

    private func bytes(_ image: CGImage, space: CGColorSpace) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return bytes
    }

    private func encoded(_ value: Float) -> Double {
        let v = min(max(Double(value), 0), 1)
        return 255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)
    }

    func testTonedKernelMatchesPortableOperatorAcrossHeadroom() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: resource("ReferenceProfile", "json"))
        let table = floats(try resource("ReferenceChroma", "f32"))
        let film = floats(try resource("StandardCurve", "f32"))
        let kernel = try RecoveredKernel(chroma: table, film: film, width: profile.width, height: profile.height,
            cbStart: profile.start[0], crStart: profile.start[1], divisor: profile.divisor)
        var samples: [[Float]] = []
        for stops in stride(from: Float(-9), through: 5, by: 0.5) {
            let v = 0.18 * pow(2, stops)
            samples.append([v, v, v])
        }
        samples += [[3.2, 2.9, 2.1], [0.9, 2.4, 0.6], [0.01, 0.02, 0.05], [0.35, 0.18, 0.08],
                    [0.02, 0.25, 0.22], [5.5, 5.0, 4.6], [0.0004, 0.0003, 0.0002], [0, 0, 0]]
        let tones = [hn_scene_tone(exposure: 1, compression: 0, shadowFill: 0),
                     hn_scene_tone(exposure: filmExposure, compression: 0, shadowFill: 0),
                     hn_scene_tone(exposure: filmExposure, compression: 1.4, shadowFill: 0.3),
                     hn_scene_tone(exposure: filmExposure, compression: 2.5, shadowFill: 0.6)]
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue])
        for var tone in tones {
            let image = try kernel.apply(input: patchImage(samples), strength: 1, tone: tone)
            var rendered = [Float](repeating: 0, count: samples.count * 4)
            rendered.withUnsafeMutableBytes { output in
                context.render(image, toBitmap: output.baseAddress!, rowBytes: samples.count * 16,
                               bounds: image.extent, format: .RGBAf, colorSpace: linear)
            }
            for (index, sample) in samples.enumerated() {
                var direct = [Float](repeating: 0, count: 3)
                let success = sample.withUnsafeBufferPointer { input in
                    table.withUnsafeBufferPointer { chroma in
                        film.withUnsafeBufferPointer { curve in
                            direct.withUnsafeMutableBufferPointer { destination in
                                hn_toned_pixel_with_curve(input.baseAddress, &tone, chroma.baseAddress,
                                    profile.width, profile.height, profile.start[0], profile.start[1],
                                    profile.divisor, 1, curve.baseAddress, film.count, destination.baseAddress)
                            }
                        }
                    }
                }
                XCTAssertEqual(success, 1)
                for channel in 0..<3 {
                    XCTAssertEqual(rendered[index * 4 + channel], direct[channel], accuracy: 0.002,
                                   "Tone \(tone), patch \(index), channel \(channel)")
                }
            }
        }
    }

    func testQuietRawSceneKeepsOriginalRenderingAndHighlightsRollOff() async throws {
        let engine = PhotoEngine()
        let ladder: [Float] = [0.18, 0.36, 0.72, 1.44, 2.88, 4.0]
        let image = patchImage(ladder.map { [$0, $0, $0] })
        let processed = LoadedPhoto(image: image, name: "Grey ladder", isRaw: false)
        let original = try bytes(await engine.preview(photo: processed, settings: .init()), space: srgb)
        XCTAssertEqual(Double(original[1]), 145.7, accuracy: 2, "Original operator at 0.18")
        // A RAW scene whose measured white fits the film domain renders
        // exactly as the original recovered operator did.
        let quiet = LoadedPhoto(image: image, name: "Grey ladder", isRaw: true,
                                sceneStats: hn_scene_stats(white: 0.9, darkFraction: 0))
        let quietBytes = try bytes(await engine.preview(photo: quiet, settings: .init()), space: srgb)
        XCTAssertEqual(quietBytes, original, "Quiet RAW scenes are unchanged")
        // High-contrast scene: the measured white folds into the film shoulder.
        let bright = LoadedPhoto(image: image, name: "Grey ladder", isRaw: true,
                                 sceneStats: hn_scene_stats(white: 4.0, darkFraction: 0))
        let brightBytes = try bytes(await engine.preview(photo: bright, settings: .init()), space: srgb)
        let rolled = (0..<ladder.count).map { Double(brightBytes[$0 * 4 + 1]) }
        XCTAssertEqual(rolled[0], Double(original[1]), accuracy: 0.5, "Middle grey keeps the Standard curve")
        XCTAssertEqual(rolled[1], 197.9, accuracy: 2.5, "+1 EV sits just above the knee")
        for index in 1..<ladder.count { XCTAssertGreaterThan(rolled[index], rolled[index - 1], "Highlights stay separated") }
        // The measured white reaches film white; everything below it keeps tone.
        XCTAssertLessThan(rolled[4], 254, "+4 EV below the measured white is not clipped")
        XCTAssertEqual(Double(original[4 * 4 + 1]), 255, accuracy: 0.5, "The original clipped +4 EV")
        // Partial strength blends from the folded input, so it keeps the shoulder.
        let half = try bytes(await engine.preview(photo: bright, settings: .init(strength: 0.5)), space: srgb)
        XCTAssertLessThan(half[4 * 4 + 1], 254, "Half strength does not re-clip folded highlights")
    }

    func testCalibratedFilmExposureMeetsStandardCurveTargets() throws {
        // Documents the Standard curve design point used if a grey-card
        // calibration places an 18% card at 0.125 in the film domain.
        let profile = try JSONDecoder().decode(Profile.self, from: resource("ReferenceProfile", "json"))
        let table = floats(try resource("ReferenceChroma", "f32"))
        let film = floats(try resource("StandardCurve", "f32"))
        var tone = hn_scene_tone(exposure: filmExposure, compression: 0, shadowFill: 0)
        for (value, target, tolerance) in [(Float(0.18), 118.7, 2.0), (0.36, 172.4, 2.5), (0.72, 223.9, 2.5)] {
            var direct = [Float](repeating: 0, count: 3)
            XCTAssertEqual(hn_toned_pixel_with_curve([value, value, value], &tone, table, profile.width, profile.height,
                           profile.start[0], profile.start[1], profile.divisor, 1, film, film.count, &direct), 1)
            XCTAssertEqual(encoded(direct[1]), target, accuracy: tolerance, "Grey \(value)")
        }
    }

    func testShadowFillLiftsLowerMidtonesAndLeavesBlackAndGrey() async throws {
        let engine = PhotoEngine()
        let values: [Float] = [0, 0.18 * pow(2, -2.5), 0.18]
        let image = patchImage(values.map { [$0, $0, $0] })
        let flat = LoadedPhoto(image: image, name: "Shadows", isRaw: true, sceneStats: hn_scene_stats(white: 0.5, darkFraction: 0))
        // Backlit: many dark pixels and highlights at film white (no compression yet).
        let backlit = LoadedPhoto(image: image, name: "Shadows", isRaw: true, sceneStats: hn_scene_stats(white: 1.0, darkFraction: 0.6))
        let lowKey = LoadedPhoto(image: image, name: "Shadows", isRaw: true, sceneStats: hn_scene_stats(white: 0.4, darkFraction: 0.6))
        let a = try bytes(await engine.preview(photo: flat, settings: .init()), space: srgb)
        let b = try bytes(await engine.preview(photo: backlit, settings: .init()), space: srgb)
        XCTAssertEqual(a[1], 0)
        XCTAssertEqual(b[1], 0)
        XCTAssertGreaterThan(Int(b[5]), Int(a[5]) + 8, "Lower midtones lift in a backlit scene")
        XCTAssertEqual(Double(b[9]), Double(a[9]), accuracy: 1, "Middle grey is unchanged")
        let c = try bytes(await engine.preview(photo: lowKey, settings: .init()), space: srgb)
        XCTAssertEqual(c, a, "A low-key scene without bright highlights is not filled")
    }

    func testP3HEICRetainsColoursOutsideSRGB() async throws {
        let engine = PhotoEngine()
        let teal: [Float] = [0.02, 0.25, 0.22]
        let photo = LoadedPhoto(image: patchImage([teal], width: 64, height: 64), name: "Teal", isRaw: false)
        let url = try await engine.export(photo: photo, settings: .init(), output: .init(format: .heic, quality: .high))
        defer { try? FileManager.default.removeItem(at: url) }
        guard url.pathExtension == "heic" else { throw XCTSkip("HEIC encoding unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let p3 = try bytes(decoded, space: CGColorSpace(name: CGColorSpace.displayP3)!)
        let centre = (32 * 64 + 32) * 4
        // Expected Display P3 encoding of the unclamped operator output.
        let profile = try JSONDecoder().decode(Profile.self, from: resource("ReferenceProfile", "json"))
        let table = floats(try resource("ReferenceChroma", "f32"))
        let film = floats(try resource("StandardCurve", "f32"))
        var direct = [Float](repeating: 0, count: 3)
        XCTAssertEqual(hn_recovered_pixel_with_curve(teal, table, profile.width, profile.height, profile.start[0],
                       profile.start[1], profile.divisor, 1, film, film.count, &direct), 1)
        XCTAssertLessThan(direct[0], -0.02, "Fixture must fall outside sRGB")
        let toP3: [[Float]] = [[0.8225, 0.1774, 0], [0.0332, 0.9669, 0], [0.0171, 0.0724, 0.9108]]
        let unclamped = toP3.map { row in zip(row, direct).map { $0 * $1 }.reduce(0, +) }
        let clamped = toP3.map { row in zip(row, direct.map { min(max($0, 0), 1) }).map { $0 * $1 }.reduce(0, +) }
        XCTAssertEqual(Double(p3[centre]), encoded(unclamped[0]), accuracy: 6, "P3 red keeps the out-of-sRGB value")
        XCTAssertGreaterThan(encoded(clamped[0]) - encoded(unclamped[0]), 15, "Clamping would visibly desaturate")
        XCTAssertEqual(Double(p3[centre + 1]), encoded(unclamped[1]), accuracy: 6)
        XCTAssertEqual(Double(p3[centre + 2]), encoded(unclamped[2]), accuracy: 6)
    }

    func testHighContrastHEICCarriesGainMapThatRestoresHighlights() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("Gain maps with declared headroom need iOS 26") }
        let engine = PhotoEngine()
        let values: [Float] = [0.18, 0.72, 2.0, 4.0]
        let photo = LoadedPhoto(image: patchImage(values.map { [$0, $0, $0] }, width: 64, height: 64), name: "HDR ladder",
                                isRaw: true, sceneStats: hn_scene_stats(white: 4.0, darkFraction: 0))
        let url = try await engine.export(photo: photo, settings: .init(), output: .init(format: .heic, quality: .high))
        defer { try? FileManager.default.removeItem(at: url) }
        guard url.pathExtension == "heic" else { throw XCTSkip("HEIC encoding unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
        let apple = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
        XCTAssertTrue(iso != nil || apple != nil, "High-contrast HEIC carries a gain map")
        // Provenance survives the Core Image gain-map writer.
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let exif = try XCTUnwrap(properties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let comment = try XCTUnwrap(exif[kCGImagePropertyExifUserComment] as? String)
        let provenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(comment.utf8)) as? [String: Any])
        let output = try XCTUnwrap(provenance["output"] as? [String: Any])
        XCTAssertEqual(output["hdrGainMap"] as? Bool, true)
        XCTAssertEqual(output["colorSpace"] as? String, "Display P3")
        let outputProfile = try XCTUnwrap(properties[kCGImagePropertyProfileName] as? String)
        XCTAssertTrue(outputProfile.lowercased().contains("p3"), outputProfile)
        // SDR base keeps the finished rendering; the HDR rendition lifts only
        // the folded highlights above SDR white.
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        func centres(_ image: CIImage) -> [Float] {
            var pixels = [Float](repeating: 0, count: Int(image.extent.width) * Int(image.extent.height) * 4)
            pixels.withUnsafeMutableBytes { buffer in
                context.render(image, toBitmap: buffer.baseAddress!, rowBytes: Int(image.extent.width) * 16,
                               bounds: image.extent, format: .RGBAf, colorSpace: linear)
            }
            let width = Int(image.extent.width)
            return values.indices.map { pixels[(32 * width + $0 * 64 + 32) * 4 + 1] }
        }
        let sdrImage = try XCTUnwrap(CIImage(contentsOf: url))
        let hdrImage = try XCTUnwrap(CIImage(contentsOf: url, options: [.expandToHDR: true]))
        let gainMap = try XCTUnwrap(CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true]))
        let applied = centres(sdrImage.applyingGainMap(gainMap, headroom: 8))
        let sdr = centres(sdrImage)
        let hdr = centres(hdrImage)
        // Independently render the float HDR kernel output. This distinguishes
        // lost range during encoding from failures to expand the stored map.
        let profile = try JSONDecoder().decode(Profile.self, from: resource("ReferenceProfile", "json"))
        let kernel = try RecoveredKernel(chroma: floats(try resource("ReferenceChroma", "f32")),
            film: floats(try resource("StandardCurve", "f32")), width: profile.width, height: profile.height,
            cbStart: profile.start[0], crStart: profile.start[1], divisor: profile.divisor)
        var stats = hn_scene_stats(white: 4.0, darkFraction: 0)
        var tone = hn_scene_tone(exposure: 1, compression: 0, shadowFill: 0)
        XCTAssertEqual(hn_choose_scene_tone(&stats, 0, &tone), 1)
        let expectedImage = try kernel.apply(input: photo.image, strength: 1, tone: tone, hdr: true)
        let expected = centres(expectedImage)
        // A tiny, explicitly rasterized reference isolates the writer's lazy
        // graph handling without imposing this allocation on real captures.
        let extendedP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let raster = try XCTUnwrap(context.createCGImage(expectedImage, from: expectedImage.extent,
                                                        format: .RGBAh, colorSpace: extendedP3))
        let referenceData = try XCTUnwrap(context.heifRepresentation(
            of: try kernel.apply(input: photo.image, strength: 1, tone: tone).settingContentHeadroom(1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!,
            options: [.hdrImage: CIImage(cgImage: raster, options: [.contentHeadroom: exp2(tone.compression)])]))
        let rasterReference = centres(try XCTUnwrap(CIImage(data: referenceData, options: [.expandToHDR: true])))
        print("ROUND4_PROBE {\"gainMapISO\":\(iso != nil),\"gainMapApple\":\(apple != nil)," +
              "\"decodedHeadroom\":\(hdrImage.contentHeadroom),\"sdr\":\(sdr),\"hdr\":\(hdr)," +
              "\"explicitGainMap\":\(applied),\"expectedHDR\":\(expected),\"rasterReference\":\(rasterReference)}")
        let encodedAttachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: UTType.heic.identifier)
        encodedAttachment.name = "HDR ladder with gain map"
        encodedAttachment.lifetime = .keepAlways
        add(encodedAttachment)
        if let preview = context.pngRepresentation(of: sdrImage, format: .RGBA8, colorSpace: srgb, options: [:]) {
            let attachment = XCTAttachment(data: preview, uniformTypeIdentifier: UTType.png.identifier)
            attachment.name = "HDR ladder SDR base"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(sdr[0], 0.286, accuracy: 0.03, "SDR middle grey")
        XCTAssertEqual(sdr[3], 1, accuracy: 0.02, "Measured white reaches SDR white")
        XCTAssertEqual(hdr[0], sdr[0], accuracy: 0.03, "Below the knee SDR and HDR agree")
        XCTAssertGreaterThan(hdr[2] / sdr[2], 1.5, "Folded highlights regain range")
        XCTAssertGreaterThan(hdr[3], 2.0, "Scene white extends above SDR white")
        XCTAssertLessThanOrEqual(hdr[3], 8.5, "Headroom stays within three stops")
        XCTAssertGreaterThan(expected[3], 2, "The float renderer supplies genuine HDR pixels")
        for index in values.indices {
            XCTAssertEqual(rasterReference[index], expected[index], accuracy: max(0.04, expected[index] * 0.08),
                           "Rasterized reference preserves HDR at patch \(index)")
            XCTAssertEqual(hdr[index], expected[index], accuracy: max(0.04, expected[index] * 0.08),
                           "Expanded HEIC preserves the HDR rendition at patch \(index)")
            XCTAssertEqual(applied[index], hdr[index], accuracy: max(0.04, hdr[index] * 0.05),
                           "Explicit and automatic gain-map decoding agree at patch \(index)")
        }
        // Strength 0 bypasses the renderer: no tone recorded, no gain map.
        let plain = try await engine.export(photo: photo, settings: .init(strength: 0), output: .init(format: .heic, quality: .high))
        defer { try? FileManager.default.removeItem(at: plain) }
        let plainSource = try XCTUnwrap(CGImageSourceCreateWithURL(plain as CFURL, nil))
        XCTAssertNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(plainSource, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        let plainProperties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(plainSource, 0, nil) as? [CFString: Any])
        let plainExif = try XCTUnwrap(plainProperties[kCGImagePropertyExifDictionary] as? [CFString: Any])
        let plainComment = try XCTUnwrap(plainExif[kCGImagePropertyExifUserComment] as? String)
        let plainProvenance = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plainComment.utf8)) as? [String: Any])
        let plainTone = try XCTUnwrap(plainProvenance["sceneTone"] as? [String: Any])
        XCTAssertEqual((plainTone["compression"] as? NSNumber)?.floatValue, 0)
    }

    func testPublicRAWMeasuresSceneAndRecordsTone() async throws {
        guard let url = Bundle(for: Self.self).url(forResource: "Public17Pro", withExtension: "dng", subdirectory: "Fixtures") else {
            throw XCTSkip("Run scripts/acquire_test_raw.py for the public RAW fixture")
        }
        let engine = PhotoEngine()
        let photo = try await engine.load(url: url)
        var stats = try XCTUnwrap(photo.sceneStats)
        XCTAssertTrue(stats.white.isFinite && stats.white > 0)
        XCTAssertTrue((0...1).contains(stats.darkFraction))
        var tone = hn_scene_tone()
        XCTAssertEqual(hn_choose_scene_tone(&stats, 0, &tone), 1)
        XCTAssertEqual(tone.exposure, HN_RAW_FILM_EXPOSURE, accuracy: 0.000001)
        XCTAssertEqual(photo.rawDevelopment?["extendedDynamicRangeAmount"] as? Float, PhotoEngine.rawExtendedDynamicRange)
        print("ROUND4_PROBE " + "{\"publicSceneWhite\":\(stats.white),\"publicDarkFraction\":\(stats.darkFraction)," +
              "\"compression\":\(tone.compression),\"shadowFill\":\(tone.shadowFill)}")
        // The public scene normally chooses SDR. Force the high-contrast path
        // on the same full-resolution decoded image to cover gain-map export
        // at camera resolution, rather than only on the tiny ladder fixture.
        guard #available(iOS 26.0, *) else { return }
        let stressed = LoadedPhoto(image: photo.image, name: "Full-resolution HDR regression", isRaw: true,
                                   sceneStats: hn_scene_stats(white: 4, darkFraction: 0))
        let exported = try await engine.export(photo: stressed, settings: .init(),
                                              output: .init(format: .heic, quality: .medium))
        defer { try? FileManager.default.removeItem(at: exported) }
        guard exported.pathExtension == "heic" else { throw XCTSkip("HEIC encoding unavailable") }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(exported as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, Int(photo.image.extent.width))
        XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, Int(photo.image.extent.height))
        XCTAssertNotNil(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap))
        let expanded = try XCTUnwrap(CIImage(contentsOf: exported, options: [.expandToHDR: true]))
        XCTAssertGreaterThan(expanded.contentHeadroom, 1)
        print("ROUND4_PROBE {\"fullResolutionHDRWidth\":\(Int(expanded.extent.width))," +
              "\"height\":\(Int(expanded.extent.height)),\"decodedHeadroom\":\(expanded.contentHeadroom)}")
    }
}
