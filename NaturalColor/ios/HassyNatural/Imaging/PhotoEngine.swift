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
        case .photoAccess: return "Allow Natural to add photos in Settings, or use Share to save to Files."
        }
    }
}

struct LoadedPhoto: @unchecked Sendable {
    let image: CIImage
    let name: String
    let isRaw: Bool
    let rawDevelopment: [String: Any]?
    /// Measured once per decode so preview and full-size export choose the same tone.
    let sceneStats: hn_scene_stats?
    init(image: CIImage, name: String, isRaw: Bool, rawDevelopment: [String: Any]? = nil,
         sceneStats: hn_scene_stats? = nil) {
        self.image = image; self.name = name; self.isRaw = isRaw
        self.rawDevelopment = rawDevelopment
        self.sceneStats = sceneStats
    }
    var dimensions: String { "\(Int(image.extent.width)) × \(Int(image.extent.height))" }
}

actor PhotoEngine {
    /// CIRAWFilter limits linear highlights at its default of 0. 1 keeps the
    /// file's measured headroom; 2 only adds reconstructed clipped values.
    static let rawExtendedDynamicRange: Float = 1
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: linear, .outputColorSpace: display,
        .cacheIntermediates: false, .workingFormat: CIFormat.RGBAf.rawValue
    ])
    private var recoveredKernel: RecoveredKernel?
    private var reference: ReferenceAssets?
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

    /// Apple defaults to adding its global tone curve. Disable creative tone
    /// processing before the recovered Standard stage.
    private static func configure(_ decoder: CIRAWFilter) {
        decoder.boostAmount = 0
        decoder.boostShadowAmount = 0
        if decoder.isLocalToneMapSupported { decoder.localToneMapAmount = 0 }
        decoder.isGamutMappingEnabled = false
        decoder.exposure = 0
        // Keep linear highlights above 1.0 for the scene tone stage, which
        // folds them into the film shoulder instead of clipping.
        decoder.extendedDynamicRangeAmount = rawExtendedDynamicRange
    }

    func load(url: URL) throws -> LoadedPhoto {
        let ext = url.pathExtension.lowercased()
        let raw = ["dng","3fr","fff","arw","cr2","cr3","nef","raf","rw2","orf"].contains(ext)
        let image: CIImage?
        var rawDevelopment: [String: Any]?
        var sceneStats: hn_scene_stats?
        if raw {
            // A RAW must decode actual sensor data. Never silently substitute its preview.
            if let decoder = CIRAWFilter(imageURL: url) {
                Self.configure(decoder)
                // Record the decoder's effective defaults/settings without
                // altering exposure normalization or scene white balance.
                rawDevelopment = [
                    "decoderVersion": String(describing: decoder.decoderVersion),
                    "baselineExposure": decoder.baselineExposure,
                    "shadowBias": decoder.shadowBias,
                    "neutralTemperature": decoder.neutralTemperature,
                    "neutralTint": decoder.neutralTint,
                    "exposure": decoder.exposure,
                    "boostAmount": decoder.boostAmount,
                    "boostShadowAmount": decoder.boostShadowAmount,
                    "localToneMapSupported": decoder.isLocalToneMapSupported,
                    "gamutMappingEnabled": decoder.isGamutMappingEnabled,
                    "extendedDynamicRangeAmount": decoder.extendedDynamicRangeAmount
                ]
                if decoder.isLocalToneMapSupported { rawDevelopment?["localToneMapAmount"] = decoder.localToneMapAmount }
                image = decoder.outputImage
                // A reduced decode with identical settings measures the scene
                // without another full-resolution pass. Measurement failure
                // leaves highlights uncompressed; it never blocks a photo.
                if let analysis = CIRAWFilter(imageURL: url) {
                    Self.configure(analysis)
                    let longest = max(analysis.nativeSize.width, analysis.nativeSize.height)
                    if longest > 512 { analysis.scaleFactor = Float(512 / longest) }
                    if let small = analysis.outputImage { sceneStats = try? measure(small) }
                }
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
        return LoadedPhoto(image: image.transformed(by: origin), name: url.deletingPathExtension().lastPathComponent,
                           isRaw: raw, rawDevelopment: rawDevelopment, sceneStats: sceneStats)
    }

    /// Robust scene statistics from a small linear rendition of the whole frame.
    private func measure(_ image: CIImage) throws -> hn_scene_stats {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty else { throw PhotoError.invalidImage }
        let scale = min(1, 256 / max(extent.width, extent.height))
        // Clamp to extent so resampled edge pixels stay opaque (transparent,
        // premultiplied edges would count as dark), then crop inside.
        let small = image.transformed(by: .init(translationX: -extent.minX, y: -extent.minY)).clampedToExtent()
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
        let bounds = CGRect(x: 0, y: 0, width: floor(extent.width * scale), height: floor(extent.height * scale))
        let width = Int(bounds.width), height = Int(bounds.height)
        guard width > 0, height > 0 else { throw PhotoError.invalidImage }
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            context.render(small, toBitmap: buffer.baseAddress!, rowBytes: width * 16,
                           bounds: bounds, format: .RGBAf, colorSpace: linear)
        }
        var stats = hn_scene_stats()
        guard hn_measure_scene(pixels, width * height, &stats) == 1 else { throw PhotoError.rendering }
        return stats
    }

    /// RAW decodes get highlight compression and shadow fill chosen from the
    /// measured scene. Already rendered HEIC/JPEG input keeps the original
    /// recovered operator.
    private func sceneTone(for photo: LoadedPhoto, settings: EditSettings) -> hn_scene_tone {
        let identity = hn_scene_tone(exposure: 1, compression: 0, shadowFill: 0)
        // Strength 0 bypasses the kernel, so no tone (or gain map) applies.
        guard photo.isRaw, settings.strength > 0 else { return identity }
        var stats = photo.sceneStats ?? hn_scene_stats(white: 0, darkFraction: 0)
        var tone = identity
        return hn_choose_scene_tone(&stats, settings.exposure, &tone) == 1 ? tone : identity
    }

    private func filtered(_ image: CIImage, settings: EditSettings, tone: hn_scene_tone,
                          hdr: Bool = false) throws -> CIImage {
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
        return try recoveredKernel.apply(input: exposed, strength: settings.strength, tone: tone, hdr: hdr)
            .cropped(to: image.extent)
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
        let image = original ? small : try filtered(small, settings: settings, tone: sceneTone(for: photo, settings: settings))
        guard let result = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: display) else { throw PhotoError.rendering }
        return result
    }

    // One actor turn keeps repeated full-resolution captures from accumulating
    // decoded RAW images while waiting for their corresponding exports.
    func exportCapture(url: URL, settings: EditSettings, output: PhotoOutputOptions) throws -> URL {
        try export(photo: load(url: url), settings: settings, output: output)
    }

    private func exportProperties(photo: LoadedPhoto, settings: EditSettings,
                                  output: PhotoOutputOptions, heic: Bool, hdr: Bool = false) throws -> [CFString: Any] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        // Version this identifier when the RAW development or recovered operator
        // changes. A marketing version alone cannot distinguish rendering builds.
        let tone = sceneTone(for: photo, settings: settings)
        var provenance: [String: Any] = [
            "schema": "natural-render-v1",
            "renderer": "recovered-standard-scene-v1",
            "sceneTone": ["exposure": tone.exposure, "compression": tone.compression, "shadowFill": tone.shadowFill],
            "input": photo.isRaw ? "raw" : "processed",
            "strength": settings.strength,
            "exposureEV": settings.exposure,
            "aspectRatio": settings.aspectRatio.rawValue,
            "appVersion": version,
            "appBuild": build,
            "output": [
                "format": heic ? "heic" : "jpeg",
                "colorSpace": heic ? "Display P3" : "sRGB",
                "quality": output.quality.rawValue,
                "compression": output.quality.compression,
                "hdrGainMap": hdr
            ]
        ]
        if let rawDevelopment = photo.rawDevelopment { provenance["rawDevelopment"] = rawDevelopment }
        if let stats = photo.sceneStats { provenance["sceneStats"] = ["white": stats.white, "darkFraction": stats.darkFraction] }
        // An unavailable decoder readback must not prevent saving a valid photo.
        // JSON has no NaN/infinity representation; preserve missing diagnostics
        // as null without changing any value used by the rendering graph.
        func jsonSafe(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] { return dictionary.mapValues(jsonSafe) }
            if let number = value as? NSNumber, !number.doubleValue.isFinite { return NSNull() }
            return value
        }
        let data = try JSONSerialization.data(withJSONObject: jsonSafe(provenance), options: [.sortedKeys])
        guard let comment = String(data: data, encoding: .utf8) else { throw PhotoError.encoding }
        // Only these app diagnostics are authored here. Source EXIF, names,
        // locations and capture dates are not copied into the finished image.
        return [
            kCGImageDestinationLossyCompressionQuality: output.quality.compression,
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "Natural \(version) (\(build))"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: comment]
        ]
    }

    /// HNCS HDR-style output: the SDR base plus an ISO gain map that restores
    /// the folded highlight stops on HDR displays. Nil when unavailable.
    private func writeGainMapHEIC(sdr: CIImage, hdr: CIImage, headroom: Float, properties: [CFString: Any],
                                  quality: Double, to url: URL) -> URL? {
        // Declaring the HDR headroom (needed for a non-identity map) is iOS 26+.
        guard #available(iOS 26.0, *) else { return nil }
        var metadata: [AnyHashable: Any] = [:]
        for (key, value) in properties where key != kCGImageDestinationLossyCompressionQuality { metadata[key as String] = value }
        // Both kernel graphs have unknown headroom. Declare both ends of the
        // gain-map ratio; keep the graphs lazy so a 48 MP capture does not need
        // another full-resolution floating-point raster in memory.
        let options: [CIImageRepresentationOption: Any] = [
            .hdrImage: hdr.settingContentHeadroom(headroom),
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality
        ]
        guard let data = context.heifRepresentation(of: sdr.settingProperties(metadata).settingContentHeadroom(1), format: .RGBA8,
                                                    colorSpace: wideDisplay, options: options) else { return nil }
        do { try data.write(to: url, options: .atomic) } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    func export(photo: LoadedPhoto, settings: EditSettings,
                output: PhotoOutputOptions = .init(format: .jpeg, quality: .high)) throws -> URL {
        let tone = sceneTone(for: photo, settings: settings)
        let framed = crop(photo.image, ratio: settings.aspectRatio)
        let image = try filtered(framed, settings: settings, tone: tone)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = photo.name.replacingOccurrences(of: "/", with: "-") + "-natural-" + String(UUID().uuidString.prefix(6))
        let types = CGImageDestinationCopyTypeIdentifiers() as! [String]
        let tryHEIC = output.format == .heic && types.contains(UTType.heic.identifier)
        // Rasterize a finite image before encoding; keep the source dimensions.
        // HEIC retains a tagged Display P3 image; compatible JPEG uses sRGB.
        // Only scenes whose highlights were folded into the shoulder carry a
        // gain map; everything else is identical in SDR and HDR.
        if tryHEIC, tone.compression > 0 {
            let hdr = try filtered(framed, settings: settings, tone: tone, hdr: true)
            let properties = try exportProperties(photo: photo, settings: settings, output: output, heic: true, hdr: true)
            if let url = writeGainMapHEIC(sdr: image, hdr: hdr, headroom: exp2(tone.compression),
                                          properties: properties, quality: output.quality.compression,
                                          to: directory.appendingPathComponent(name + ".heic")) { return url }
        }
        for heic in tryHEIC ? [true, false] : [false] {
            let space = heic ? wideDisplay : display
            guard let raster = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space) else { throw PhotoError.rendering }
            // Record the actual encoder branch, including a JPEG fallback,
            // before creating a destination that would need cleanup on failure.
            let properties = try exportProperties(photo: photo, settings: settings, output: output, heic: heic)
            let url = directory.appendingPathComponent(name + (heic ? ".heic" : ".jpg"))
            let type = heic ? UTType.heic : .jpeg
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, raster, properties as CFDictionary)
            if CGImageDestinationFinalize(destination) { return url }
            try? FileManager.default.removeItem(at: url)
        }
        throw PhotoError.encoding
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
