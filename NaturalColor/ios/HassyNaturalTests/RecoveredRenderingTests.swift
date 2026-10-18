import XCTest
import CoreImage
import CoreGraphics
@testable import HassyNatural

/// Exercises actual Core Image color handling and the direct Metal operator.
/// Expected values come from the separately verified portable C++ core.
final class RecoveredRenderingTests: XCTestCase {
    private struct Profile: Decodable {
        let width: Int
        let height: Int
        let start: [Float]
        let divisor: Float
    }

    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!

    private var patches: [[Float]] {
        // Neutral shadow ramps and exact nodes of the 65-point sqrt-shaped cube.
        let nodes: [Float] = [0, 1, 2, 4, 8, 12, 16, 24, 32, 48, 64]
        var result = nodes.map { n -> [Float] in
            let v = (n / 64) * (n / 64)
            return [v, v, v]
        }
        let triplets: [[Float]] = [
            [8, 16, 24], [24, 8, 16], [16, 24, 8],
            [16, 32, 48], [48, 16, 32], [32, 48, 16],
            [32, 40, 48], [48, 32, 40], [40, 48, 32],
            [48, 56, 64], [64, 48, 56], [56, 64, 48]
        ]
        result += triplets.map { $0.map { ($0 / 64) * ($0 / 64) } }
        // Interior coordinates catch accidental node-only agreement.
        result += [
            [0.018, 0.027, 0.033], [0.12, 0.21, 0.32],
            [0.55, 0.42, 0.27], [0.31, 0.45, 0.22],
            [0.065, 0.065, 0.065], [0.18, 0.18, 0.18],
            [0.73, 0.73, 0.73]
        ]
        return result
    }

    private func photo(_ samples: [[Float]]) -> LoadedPhoto {
        var rgba: [Float] = []
        rgba.reserveCapacity(samples.count * 4)
        for pixel in samples {
            precondition(pixel.count == 3)
            rgba.append(contentsOf: pixel)
            rgba.append(Float(1))
        }
        let rowBytes = samples.count * 4 * MemoryLayout<Float>.stride
        let data = rgba.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
        }
        precondition(data.count == rowBytes, "Float patch buffer length must match the bitmap row")
        let image = CIImage(bitmapData: data, bytesPerRow: rowBytes,
                            size: CGSize(width: CGFloat(samples.count), height: 1), format: .RGBAf, colorSpace: linear)
        return LoadedPhoto(image: image, name: "Linear reference patches", isRaw: false)
    }

    private func rgbBytes(_ image: CGImage) throws -> [[Int]] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: display,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return stride(from: 0, to: bytes.count, by: 4).map { [Int(bytes[$0]), Int(bytes[$0 + 1]), Int(bytes[$0 + 2])] }
    }

    private func encodedByte(_ linearValue: Float) -> Int {
        let value = min(max(Double(linearValue), 0), 1)
        let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        return Int((encoded * 255).rounded())
    }

    private func resource(_ name: String, ext: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    private func floats(_ data: Data) throws -> [Float] {
        XCTAssertEqual(data.count % MemoryLayout<Float>.size, 0)
        var result = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
        _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return result
    }

    func testDirectKernelFloatRenderingMatchesPortableOperator() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: resource("ReferenceProfile", ext: "json"))
        let table = try floats(resource("ReferenceChroma", ext: "f32"))
        let film = try floats(resource("StandardCurve", ext: "f32"))
        let kernel = try RecoveredKernel(chroma: table, film: film, width: profile.width, height: profile.height,
            cbStart: profile.start[0], crStart: profile.start[1], divisor: profile.divisor)
        // Primaries push the table coordinates to profile bounds; near black
        // exercises the explicit finite-black policy and film-floor lookup.
        let samples = patches + [
            [0.000001, 0.000001, 0.000001], [0.0001, 0.0003, 0.0002],
            [1, 0, 0], [0, 1, 0], [0, 0, 1],
            [1, 0.0001, 0], [0.0001, 1, 0], [0, 0.0001, 1]
        ]
        let image = try kernel.apply(input: photo(samples).image, strength: 1)
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear,
                                          .workingFormat: CIFormat.RGBAf.rawValue])
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
                            hn_recovered_pixel_with_curve(input.baseAddress, chroma.baseAddress,
                                profile.width, profile.height, profile.start[0], profile.start[1],
                                profile.divisor, 1, curve.baseAddress, film.count, destination.baseAddress)
                        }
                    }
                }
            }
            XCTAssertEqual(success, 1)
            for channel in 0..<3 {
                // Output stays unclamped so Display P3 exports keep colours outside sRGB.
                let expected = direct[channel]
                XCTAssertTrue(rendered[index * 4 + channel].isFinite)
                // GPU arithmetic may cross one quantized film-table entry.
                XCTAssertEqual(rendered[index * 4 + channel], expected, accuracy: 0.002,
                               "Direct kernel patch \(index), channel \(channel)")
            }
            XCTAssertEqual(rendered[index * 4 + 3], 1, accuracy: 0.00001)
        }
    }

    func testOriginalAndZeroStrengthPreserveLinearToSRGBEncoding() async throws {
        let samples = patches
        let source = photo(samples)
        let engine = PhotoEngine()
        let original = try rgbBytes(await engine.preview(photo: source, settings: .init(), original: true))
        let zero = try rgbBytes(await engine.preview(photo: source, settings: .init(strength: 0)))
        for index in samples.indices {
            for channel in 0..<3 {
                let expected = encodedByte(samples[index][channel])
                XCTAssertLessThanOrEqual(abs(original[index][channel] - expected), 1,
                    "Original encoding patch \(index), channel \(channel)")
                XCTAssertLessThanOrEqual(abs(zero[index][channel] - expected), 1,
                    "Zero-strength encoding patch \(index), channel \(channel)")
            }
        }
    }

    func testRecoveredPreviewMatchesDirectOperatorAndLinearStrengthBlend() async throws {
        let samples = patches
        let source = photo(samples)
        let engine = PhotoEngine()
        let profile = try JSONDecoder().decode(Profile.self, from: resource("ReferenceProfile", ext: "json"))
        let table = try floats(resource("ReferenceChroma", ext: "f32"))
        let film = try floats(resource("StandardCurve", ext: "f32"))
        XCTAssertEqual(table.count, profile.width * profile.height * 2)
        XCTAssertEqual(film.count, 65536)

        var mapped: [[Float]] = []
        for sample in samples {
            var output = [Float](repeating: 0, count: 3)
            let success = sample.withUnsafeBufferPointer { input in
                table.withUnsafeBufferPointer { chroma in
                    film.withUnsafeBufferPointer { curve in
                        output.withUnsafeMutableBufferPointer { destination in
                            hn_recovered_pixel_with_curve(input.baseAddress, chroma.baseAddress,
                                profile.width, profile.height, profile.start[0], profile.start[1],
                                profile.divisor, 1, curve.baseAddress, film.count, destination.baseAddress)
                        }
                    }
                }
            }
            XCTAssertEqual(success, 1)
            mapped.append(output)
        }

        for strength in [Float(1), Float(0.37)] {
            let rendered = try rgbBytes(await engine.preview(photo: source, settings: .init(strength: strength)))
            for index in samples.indices {
                for channel in 0..<3 {
                    let value = samples[index][channel] + strength * (mapped[index][channel] - samples[index][channel])
                    let expected = encodedByte(value)
                    XCTAssertLessThanOrEqual(abs(rendered[index][channel] - expected), 3,
                        "Recovered rendering patch \(index), channel \(channel), strength \(strength): actual \(rendered[index][channel]), direct \(expected)")
                }
            }
        }
    }
}
