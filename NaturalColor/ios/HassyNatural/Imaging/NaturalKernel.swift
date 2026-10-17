import CoreImage
import Foundation

/// An original, small luminance adjustment in linear light. No lookup tables,
/// sensor emulation, channel-specific colour shifts or third-party profiles.
final class NaturalKernel {
    private let kernel: CIKernel
    init() throws {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib") else { throw PhotoError.rendering }
        kernel = try CIKernel(functionName: "naturalFinish", fromMetalLibraryData: Data(contentsOf: url))
    }
    func apply(input: CIImage, strength: Float) throws -> CIImage {
        guard strength.isFinite,
              let result = kernel.apply(extent: input.extent, roiCallback: { _, rect in rect },
                  arguments: [input, min(max(strength, 0), 1)]) else { throw PhotoError.rendering }
        return result
    }
}
