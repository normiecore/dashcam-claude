import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import UIKit

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
        case .photoAccess: return "Allow Natural to add photos in Settings, or use Share to save to Files."
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
    private var naturalKernel: NaturalKernel?
    private let wideDisplay = CGColorSpace(name: CGColorSpace.displayP3)!

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
                // Use Apple's native RAW development (including its tone and
                // colour management). Do not apply another camera's profile.
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
        if naturalKernel == nil { naturalKernel = try NaturalKernel() }
        guard let naturalKernel else { throw PhotoError.rendering }
        return try naturalKernel.apply(input: exposed, strength: settings.strength).cropped(to: image.extent)
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
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: wideDisplay) else { throw PhotoError.rendering }
        return result
    }

    // One actor turn keeps repeated full-resolution captures from accumulating
    // decoded RAW images while waiting for their corresponding exports.
    func exportCapture(url: URL, settings: EditSettings, output: PhotoOutputOptions) throws -> URL {
        try export(photo: load(url: url), settings: settings, output: output)
    }

    func export(photo: LoadedPhoto, settings: EditSettings,
                output: PhotoOutputOptions = .init(format: .jpeg, quality: .high)) throws -> URL {
        let image = try filtered(crop(photo.image, ratio: settings.aspectRatio), settings: settings)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = photo.name.replacingOccurrences(of: "/", with: "-") + "-natural-" + String(UUID().uuidString.prefix(6))
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        let tryHEIC = output.format == .heic && types.contains(UTType.heic.identifier)
        // Rasterize a finite image before encoding; keep the source dimensions.
        // HEIC retains a tagged Display P3 image; compatible JPEG uses sRGB.
        for heic in tryHEIC ? [true, false] : [false] {
            let space = heic ? wideDisplay : display
            guard let raster = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { throw PhotoError.rendering }
            let url = directory.appendingPathComponent(name + (heic ? ".heic" : ".jpg"))
            let type = heic ? UTType.heic : .jpeg
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, raster, [
                kCGImageDestinationLossyCompressionQuality: output.quality.compression,
                kCGImagePropertyOrientation: 1
            ] as CFDictionary)
            if CGImageDestinationFinalize(destination) { return url }
            try? FileManager.default.removeItem(at: url)
        }
        throw PhotoError.encoding
    }
}
