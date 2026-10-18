import XCTest
import CoreImage
@testable import HassyNatural

/// Measures what Apple's RAW decoder hands the renderer on the public ProRAW
/// fixture: highlight headroom above 1.0 and the effect of decoder options.
/// Results are logged as numbers only; the fixture is public.
final class DecoderHeadroomTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private lazy var context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false,
                                                   .workingFormat: CIFormat.RGBAf.rawValue])

    private struct Decoded {
        let pixels: [Float]
        let width: Int
        let height: Int
    }

    private func fixture() throws -> URL {
        guard let url = Bundle(for: Self.self).url(forResource: "Public17Pro", withExtension: "dng", subdirectory: "Fixtures") else {
            throw XCTSkip("Run scripts/acquire_test_raw.py for the public RAW fixture")
        }
        return url
    }

    private func decode(_ url: URL, edr: Float?, localToneMap: Float, shadowBias: Float? = nil,
                        defaults: inout [String: Any]) throws -> Decoded {
        let decoder = try XCTUnwrap(CIRAWFilter(imageURL: url))
        defaults["baselineExposure"] = decoder.baselineExposure
        defaults["defaultShadowBias"] = decoder.shadowBias
        defaults["defaultExtendedDynamicRangeAmount"] = decoder.extendedDynamicRangeAmount
        defaults["defaultLocalToneMapAmount"] = decoder.localToneMapAmount
        defaults["defaultBoostAmount"] = decoder.boostAmount
        defaults["decoderVersion"] = String(describing: decoder.decoderVersion)
        let longest = max(decoder.nativeSize.width, decoder.nativeSize.height)
        decoder.scaleFactor = Float(1024 / longest)
        decoder.boostAmount = 0
        decoder.boostShadowAmount = 0
        if decoder.isLocalToneMapSupported { decoder.localToneMapAmount = localToneMap }
        decoder.isGamutMappingEnabled = false
        decoder.exposure = 0
        if let edr { decoder.extendedDynamicRangeAmount = edr }
        if let shadowBias { decoder.shadowBias = shadowBias }
        let image = try XCTUnwrap(decoder.outputImage)
        let extent = image.extent
        let width = Int(extent.width), height = Int(extent.height)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(image, toBitmap: buffer.baseAddress!, rowBytes: width * 16, bounds: extent,
                           format: .RGBAf, colorSpace: linear)
        }
        context.clearCaches()
        return Decoded(pixels: pixels, width: width, height: height)
    }

    private func percentile(_ sorted: [Float], _ p: Double) -> Float {
        guard !sorted.isEmpty else { return .nan }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }

    private func stats(_ image: Decoded) -> [String: Any] {
        var peaks: [Float] = []
        var luminance: [Float] = []
        peaks.reserveCapacity(image.width * image.height)
        for index in 0..<(image.width * image.height) {
            let r = image.pixels[index * 4], g = image.pixels[index * 4 + 1], b = image.pixels[index * 4 + 2]
            peaks.append(max(r, max(g, b)))
            luminance.append(0.2126 * r + 0.7152 * g + 0.0722 * b)
        }
        peaks.sort()
        luminance.sort()
        let over = peaks.filter { $0 > 1.0001 }.count
        return ["width": image.width, "height": image.height,
                "peakMax": peaks.last ?? .nan, "peakP999": percentile(peaks, 0.999), "peakP99": percentile(peaks, 0.99),
                "peakP90": percentile(peaks, 0.90), "fractionOver1": Double(over) / Double(max(peaks.count, 1)),
                "lumP10": percentile(luminance, 0.10), "lumP25": percentile(luminance, 0.25),
                "lumP50": percentile(luminance, 0.50), "lumP75": percentile(luminance, 0.75),
                "lumP90": percentile(luminance, 0.90)]
    }

    /// Mean absolute difference over pixels both decodes keep well below 1.
    private func midtoneDifference(_ a: Decoded, _ b: Decoded) -> Double {
        guard a.width == b.width, a.height == b.height else { return .nan }
        var total = 0.0, count = 0
        for index in 0..<(a.width * a.height) {
            let peak = max(a.pixels[index * 4], max(a.pixels[index * 4 + 1], a.pixels[index * 4 + 2]))
            guard peak < 0.8 else { continue }
            for channel in 0..<3 { total += Double(abs(a.pixels[index * 4 + channel] - b.pixels[index * 4 + channel])) }
            count += 3
        }
        return count > 0 ? total / Double(count) : .nan
    }

    func testDecoderHeadroomAndToneOptions() throws {
        let url = try fixture()
        var defaults: [String: Any] = [:]
        let base = try decode(url, edr: nil, localToneMap: 0, defaults: &defaults)
        let edr1 = try decode(url, edr: 1, localToneMap: 0, defaults: &defaults)
        let edr2 = try decode(url, edr: 2, localToneMap: 0, defaults: &defaults)
        let ltmHalf = try decode(url, edr: 1, localToneMap: 0.5, defaults: &defaults)
        let ltmFull = try decode(url, edr: 1, localToneMap: 1, defaults: &defaults)
        let unbiased = try decode(url, edr: 1, localToneMap: 0, shadowBias: 0, defaults: &defaults)
        let report: [String: Any] = [
            "defaults": defaults,
            "appDecode": stats(base), "edr1": stats(edr1), "edr2": stats(edr2),
            "edr1LocalToneMapHalf": stats(ltmHalf), "edr1LocalToneMapFull": stats(ltmFull),
            "edr1ShadowBiasZero": stats(unbiased),
            "midtoneDifferenceAppVsEdr1": midtoneDifference(base, edr1),
            "midtoneDifferenceEdr1VsEdr2": midtoneDifference(edr1, edr2)
        ]
        func finite(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(finite) }
            if let number = value as? NSNumber, !number.doubleValue.isFinite { return "nonfinite" }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: finite(report), options: [.sortedKeys])
        print("HEADROOM_PROBE " + String(decoding: data, as: UTF8.self))
        XCTAssertGreaterThan(base.width, 500)
    }
}
