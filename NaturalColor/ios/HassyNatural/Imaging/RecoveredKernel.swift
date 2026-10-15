import CoreImage
import Foundation

/// Direct table evaluation; no RGB cube resampling. GPU numerical parity must
/// pass separate Apple CI comparisons against the portable C++ implementation.
final class RecoveredKernel {
    enum KernelError: Error {
        case invalidAssets, missingLibrary, unavailable, renderFailed
    }

    private let kernel: CIKernel
    private let chroma: CIImage
    private let film: CIImage
    private let grid: CIVector
    private let divisor: Float
    private let nativeScale: Float

    init(chroma: [Float], film: [Float], width: Int, height: Int,
         cbStart: Float, crStart: Float, divisor: Float, nativeScale: Float = 1,
         bundle: Bundle = .main) throws {
        guard width >= 2, height >= 2, width <= 256, height <= 256,
              chroma.count == width*height*2, film.count == 65536,
              chroma.allSatisfy({ $0.isFinite }), film.allSatisfy({ $0.isFinite }),
              cbStart.isFinite, crStart.isFinite, divisor.isFinite, divisor > 0,
              nativeScale.isFinite, nativeScale > 0 else { throw KernelError.invalidAssets }
        guard let url = bundle.url(forResource: "default", withExtension: "metallib") else {
            throw KernelError.missingLibrary
        }
        let library = try Data(contentsOf: url)
        kernel = try CIKernel(functionName: "recoveredKernel", fromMetalLibraryData: library)

        func texture(_ values: [Float], width: Int, height: Int, components: Int) -> CIImage {
            var rgba = [Float](repeating: 0, count: width*height*4)
            for i in 0..<(width*height) {
                // Bitmap rows enter Core Image from the top. The recovered
                // tables use y=0 for their first row, so reverse upload rows.
                let source = ((height - 1 - i / width) * width + i % width) * components
                rgba[i*4] = values[source]
                if components == 2 { rgba[i*4+1] = values[source+1] }
                rgba[i*4+3] = 1
            }
            let data = rgba.withUnsafeBytes { Data($0) }
            // Unmanaged float textures preserve negative CbCr values and film
            // coordinates; no sRGB conversion or quantization is appropriate.
            return CIImage(bitmapData: data, bytesPerRow: width*4*MemoryLayout<Float>.size,
                           size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: .RGBAf,
                           colorSpace: nil)
        }
        self.chroma = texture(chroma, width: width, height: height, components: 2)
        self.film = texture(film, width: 256, height: 256, components: 1)
        grid = CIVector(x: CGFloat(width), y: CGFloat(height),
                        z: CGFloat(cbStart), w: CGFloat(crStart))
        self.divisor = divisor
        self.nativeScale = nativeScale
    }

    /// Input must be evaluated by a CIContext with extended-linear-sRGB working
    /// space, matching the explicit phone bridge in RecoveredColor.cpp.
    func apply(input: CIImage, strength: Float) throws -> CIImage {
        guard strength.isFinite, !input.extent.isEmpty, !input.extent.isInfinite else {
            throw KernelError.renderFailed
        }
        let tableExtent = chroma.extent
        let filmExtent = film.extent
        let options = CIVector(x: CGFloat(divisor), y: CGFloat(nativeScale),
                               z: CGFloat(min(max(strength, 0), 1)), w: 0)
        guard let output = kernel.apply(extent: input.extent, roiCallback: { index, rect in
            switch index {
            case 1: return tableExtent
            case 2: return filmExtent
            default: return rect
            }
        }, arguments: [input, chroma, film, grid, options]) else {
            throw KernelError.renderFailed
        }
        return output
    }
}
