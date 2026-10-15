import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import UIKit
import CryptoKit

struct EditSettings: Equatable, Sendable {
    var strength: Float = 1
    var exposure: Float = 0
}

enum PhotoError: LocalizedError {
    case unreadable, invalidImage, rendering, encoding, photoAccess
    var errorDescription: String? {
        switch self {
        case .unreadable: return "This photo could not be decoded. Try the original JPEG, HEIC or DNG file."
        case .invalidImage: return "This image has unsupported dimensions."
        case .rendering: return "The photo could not be rendered. Try a smaller photo."
        case .encoding: return "The edited photo could not be exported."
        case .photoAccess: return "Allow Hassy Natural to add photos in Settings, or use Share to save to Files."
        }
    }
}

struct LoadedPhoto: @unchecked Sendable {
    let image: CIImage
    let name: String
    let isRaw: Bool
    var dimensions: String { "\(Int(image.extent.width)) × \(Int(image.extent.height))" }
}

actor PhotoEngine {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linear, .outputColorSpace: display,
        .cacheIntermediates: false
    ])
    private var cachedStrength: Float?
    private var cachedDimension: Int?
    private var cachedCube: Data?
    private var reference: ReferenceAssets?

    func demoPhoto() -> LoadedPhoto {
        let filter = CIFilter.linearGradient()
        filter.point0 = CGPoint(x: 0, y: 0)
        filter.point1 = CGPoint(x: 1200, y: 900)
        filter.color0 = CIColor(red: 0.07, green: 0.28, blue: 0.51)
        filter.color1 = CIColor(red: 0.95, green: 0.63, blue: 0.23)
        let image = filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 1200, height: 900))
        return LoadedPhoto(image: image, name: "Studio gradient", isRaw: false)
    }

    func load(url: URL) throws -> LoadedPhoto {
        let ext = url.pathExtension.lowercased()
        let raw = ["dng","3fr","fff","arw","cr2","cr3","nef","raf","rw2","orf"].contains(ext)
        let image: CIImage?
        if raw {
            // A RAW must decode actual sensor data. Never silently substitute its preview.
            image = CIRAWFilter(imageURL: url)?.outputImage
        } else {
            image = CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
        }
        guard let image else { throw PhotoError.unreadable }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, extent.width.isFinite, extent.height.isFinite,
              extent.width > 0, extent.height > 0,
              extent.width * extent.height <= 110_000_000 else { throw PhotoError.invalidImage }
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        return LoadedPhoto(image: image.transformed(by: origin), name: url.deletingPathExtension().lastPathComponent, isRaw: raw)
    }

    private func filtered(_ image: CIImage, settings: EditSettings, dimension: Int = 65) throws -> CIImage {
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = settings.exposure
        guard let exposed = exposure.outputImage else { throw PhotoError.rendering }
        if settings.strength <= 0 { return exposed }
        if cachedStrength != settings.strength || cachedDimension != dimension || cachedCube == nil {
            let assets: ReferenceAssets
            if let reference { assets = reference } else {
                assets = try ReferenceAssets.load()
                reference = assets
            }
            let count = dimension*dimension*dimension*4
            var cube = [Float](repeating: 0, count: count)
            let made = cube.withUnsafeMutableBufferPointer { buffer in
                assets.chroma.withUnsafeBufferPointer { table in
                    assets.film.withUnsafeBufferPointer { film in
                        hn_make_reference_cube_shaped(buffer.baseAddress, buffer.count, UInt32(dimension), settings.strength,
                            table.baseAddress, assets.profile.width, assets.profile.height,
                            assets.profile.start[0], assets.profile.start[1], assets.profile.divisor,
                            1, film.baseAddress, film.count, 2)
                    }
                }
            }
            guard made == 1 else { throw PhotoError.rendering }
            cachedCube = cube.withUnsafeBytes { Data($0) }
            cachedStrength = settings.strength
            cachedDimension = dimension
        }
        // A square-root input shaper gives the cube more precision in shadows.
        // Its inverse (q*q) is baked into the independently tested C++ cube.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = exposed
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        let shaper = CIFilter.gammaAdjust()
        shaper.inputImage = clamp.outputImage
        shaper.power = 0.5
        guard let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { throw PhotoError.rendering }
        filter.setValue(shaper.outputImage, forKey: kCIInputImageKey)
        filter.setValue(dimension, forKey: "inputCubeDimension")
        filter.setValue(cachedCube, forKey: "inputCubeData")
        filter.setValue(linear, forKey: "inputColorSpace")
        guard let result = filter.outputImage else { throw PhotoError.rendering }
        return result.cropped(to: image.extent)
    }

    func preview(photo: LoadedPhoto, settings: EditSettings, original: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        let scale = min(1, 1600 / max(photo.image.extent.width, photo.image.extent.height))
        let small = photo.image.transformed(by: .init(scaleX: scale, y: scale))
        let image = original ? small : try filtered(small, settings: settings)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else { throw PhotoError.rendering }
        return result
    }

    func export(photo: LoadedPhoto, settings: EditSettings) throws -> URL {
        let image = try filtered(photo.image, settings: settings, dimension: 128)
        // Rendering directly to an encoded file avoids retaining a second full-resolution bitmap.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = photo.name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(name)-natural-\(UUID().uuidString.prefix(6)).jpg")
        try context.writeJPEGRepresentation(of: image, to: url, colorSpace: display, options: [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.96
        ])
        return url
    }
}

private struct ReferenceProfile: Decodable {
    let width: Int
    let height: Int
    let start: [Float]
    let divisor: Float
    let sha256: String
}

private struct ReferenceAssets {
    let profile: ReferenceProfile
    let chroma: [Float]
    let film: [Float]
    static func load() throws -> ReferenceAssets {
        func data(_ name: String, _ ext: String) throws -> Data {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else { throw PhotoError.rendering }
            return try Data(contentsOf: url)
        }
        func floats(_ bytes: Data, count: Int) throws -> [Float] {
            guard bytes.count == count * MemoryLayout<Float>.size else { throw PhotoError.rendering }
            var values = [Float](repeating: 0, count: count)
            _ = values.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
            guard values.allSatisfy({ $0.isFinite }) else { throw PhotoError.rendering }
            return values
        }
        let profile = try JSONDecoder().decode(ReferenceProfile.self, from: data("ReferenceProfile", "json"))
        guard profile.width >= 2, profile.height >= 2, profile.width <= 256, profile.height <= 256,
              profile.start.count == 2, profile.start.allSatisfy({ $0.isFinite }),
              profile.divisor.isFinite, profile.divisor > 0 else { throw PhotoError.rendering }
        let chroma = try data("ReferenceChroma", "f32")
        let film = try data("StandardCurve", "f32")
        func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
        guard hash(chroma) == profile.sha256,
              hash(film) == "b3324e976976df34b5f6ecbd4c4e6830a68b1b1a75c573a0800ef6f144e29598" else { throw PhotoError.rendering }
        return try ReferenceAssets(profile: profile,
            chroma: floats(chroma, count: profile.width*profile.height*2), film: floats(film, count: 65536))
    }
}
