import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import UIKit
import CryptoKit

struct EditSettings: Equatable, Sendable {
    var strength: Float = 1
    var exposure: Float = 0
    var aspectRatio: PhotoAspectRatio = .native
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
        .cacheIntermediates: false, .workingFormat: CIFormat.RGBAf.rawValue
    ])
    private var recoveredKernel: RecoveredKernel?
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
            if let decoder = CIRAWFilter(imageURL: url) {
                // Apple defaults to adding its global tone curve. Disable
                // creative tone processing before the recovered Standard stage.
                decoder.boostAmount = 0
                decoder.boostShadowAmount = 0
                if decoder.isLocalToneMapSupported { decoder.localToneMapAmount = 0 }
                decoder.isGamutMappingEnabled = false
                decoder.exposure = 0
                image = decoder.outputImage
            } else { image = nil }
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

    private func filtered(_ image: CIImage, settings: EditSettings) throws -> CIImage {
        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = image
        exposure.ev = settings.exposure
        guard let exposed = exposure.outputImage else { throw PhotoError.rendering }
        if settings.strength <= 0 { return exposed }
        if recoveredKernel == nil {
            let assets = try ReferenceAssets.load()
            reference = assets
            recoveredKernel = try RecoveredKernel(chroma: assets.chroma, film: assets.film,
                width: assets.profile.width, height: assets.profile.height,
                cbStart: assets.profile.start[0], crStart: assets.profile.start[1],
                divisor: assets.profile.divisor, nativeScale: 1)
        }
        guard let recoveredKernel else { throw PhotoError.rendering }
        return try recoveredKernel.apply(input: exposed, strength: settings.strength).cropped(to: image.extent)
    }

    private func crop(_ image: CIImage, ratio: PhotoAspectRatio) -> CIImage {
        let rect = ratio.cropRect(in: image.extent)
        return image.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
    }

    func preview(photo: LoadedPhoto, settings: EditSettings, original: Bool = false) throws -> CGImage {
        try Task.checkCancellation()
        let framed = crop(photo.image, ratio: settings.aspectRatio)
        let scale = min(1, 1600 / max(framed.extent.width, framed.extent.height))
        let small = framed.transformed(by: .init(scaleX: scale, y: scale))
        let image = original ? small : try filtered(small, settings: settings)
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else { throw PhotoError.rendering }
        return result
    }

    func export(photo: LoadedPhoto, settings: EditSettings) throws -> URL {
        let image = try filtered(crop(photo.image, ratio: settings.aspectRatio), settings: settings)
        // Bound rendering to a concrete RGBA8 raster before ImageIO encoding.
        // CIContext's tiled JPEG writer can request an unbounded intermediate
        // for generated/filter graphs, even when the visible extent is finite.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = photo.name.replacingOccurrences(of: "/", with: "-")
        let url = directory.appendingPathComponent("\(name)-natural-\(UUID().uuidString.prefix(6)).jpg")
        guard let raster = context.createCGImage(image, from: image.extent,
                format: .RGBA8, colorSpace: display),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PhotoError.encoding
        }
        CGImageDestinationAddImage(destination, raster, [
            kCGImageDestinationLossyCompressionQuality: 0.96,
            kCGImagePropertyOrientation: 1
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.encoding }
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
