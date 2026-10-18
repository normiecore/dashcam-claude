import XCTest
import CoreImage
@testable import HassyNatural

final class NaturalRenderingTests: XCTestCase {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private func rendered(_ samples: [[Float]], strength: Float) throws -> [[Float]] {
        let rgba: [Float] = samples.flatMap { [$0[0], $0[1], $0[2], 1] }
        let image = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: samples.count * 16,
            size: CGSize(width: samples.count, height: 1), format: .RGBAf, colorSpace: linear)
        let result = try NaturalKernel().apply(input: image, strength: strength)
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        var pixels = [Float](repeating: 0, count: rgba.count)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(result, toBitmap: bytes.baseAddress!, rowBytes: samples.count * 16,
                bounds: image.extent, format: .RGBAf, colorSpace: linear)
        }
        return samples.indices.map { Array(pixels[($0*4)..<($0*4+3)]) }
    }
    func testNeutralRampStaysNeutralMonotonicAndKeepsBlackAndWhite() throws {
        let samples: [[Float]] = (0...100).map { i in let x = Float(i)/100; return [x,x,x] }
        let result = try rendered(samples, strength: 1)
        for i in result.indices {
            XCTAssertEqual(result[i][0], result[i][1], accuracy: 0.00001)
            XCTAssertEqual(result[i][1], result[i][2], accuracy: 0.00001)
            if i > 0 { XCTAssertGreaterThan(result[i][0], result[i-1][0]) }
        }
        XCTAssertEqual(result[0][0], 0, accuracy: 0.00001)
        XCTAssertEqual(result[100][0], 1, accuracy: 0.00001)
        XCTAssertEqual(result[50][0], 0.5, accuracy: 0.00001)
    }
    func testFinishPreservesChromaticityAndZeroStrengthPreservesInput() throws {
        let samples: [[Float]] = [[0.1,0.2,0.3],[0.6,0.4,0.2],[0.3,0.5,0.15]]
        let zero = try rendered(samples, strength: 0)
        let full = try rendered(samples, strength: 1)
        for i in samples.indices {
            for c in 0..<3 { XCTAssertEqual(zero[i][c], samples[i][c], accuracy: 0.00001) }
            XCTAssertEqual(full[i][0]/full[i][1], samples[i][0]/samples[i][1], accuracy: 0.00001)
            XCTAssertEqual(full[i][2]/full[i][1], samples[i][2]/samples[i][1], accuracy: 0.00001)
            XCTAssertLessThan(abs(full[i][1]-samples[i][1]), 0.02)
        }
    }
    func testProductionDoesNotBundleResearchTables() {
        for name in ["ReferenceChroma", "StandardCurve"] {
            XCTAssertNil(Bundle.main.url(forResource: name, withExtension: "f32"))
        }
        XCTAssertNil(Bundle.main.url(forResource: "ReferenceProfile", withExtension: "json"))
        XCTAssertNil(Bundle.main.url(forResource: "HNCSMatrix.provenance", withExtension: "json"))
    }
}
