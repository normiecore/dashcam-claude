import Foundation
import CoreImage
import ImageIO

let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
let extendedP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
let sdrValues: [Float] = [0.286, 0.776, 0.947, 1]
let hdrValues: [Float] = [0.286, 1.044, 2.315, 4]

func image(_ values: [Float]) -> CIImage {
    var rgba = [Float](repeating: 1, count: 256 * 64 * 4)
    for y in 0..<64 {
        for x in 0..<256 {
            for c in 0..<3 { rgba[(y * 256 + x) * 4 + c] = values[x / 64] }
        }
    }
    return CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) }, bytesPerRow: 256 * 16,
                   size: CGSize(width: 256, height: 64), format: .RGBAf, colorSpace: linear)
}

let reader = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
func centres(_ image: CIImage) -> [Float] {
    var rgba = [Float](repeating: 0, count: 256 * 64 * 4)
    rgba.withUnsafeMutableBytes {
        reader.render(image, toBitmap: $0.baseAddress!, rowBytes: 256 * 16,
                      bounds: CGRect(x: 0, y: 0, width: 256, height: 64), format: .RGBAf, colorSpace: linear)
    }
    return (0..<4).map { rgba[(32 * 256 + $0 * 64 + 32) * 4 + 1] }
}

if CommandLine.arguments.dropFirst().first == "--decode" {
    var checked = 0
    var failures = 0
    for path in CommandLine.arguments.dropFirst(2) {
        guard let decoded = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.expandToHDR: true]),
              Int(decoded.extent.width) == 256, Int(decoded.extent.height) == 64 else { continue }
        checked += 1
        let values = centres(decoded)
        let error = zip(values, hdrValues).map { abs($0.0 - $0.1) }.max()!
        let passed = decoded.contentHeadroom > 2 && error < 0.32
        if !passed { failures += 1 }
        let payload: [String: Any] = ["path": path, "headroom": decoded.contentHeadroom,
                                     "values": values, "maxError": error, "passed": passed]
        print("GAINMAP_HOST_DECODE " + String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!)
    }
    guard checked > 0 else { print("No 256x64 ladder HEIC attachments found"); exit(2) }
    exit(failures == 0 ? 0 : 1)
}

if #available(macOS 26.0, *) {
    let contexts: [(String, CIContext)] = [
        ("default", CIContext(options: [.cacheIntermediates: false])),
        ("app", CIContext(options: [.workingColorSpace: linear, .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false]))
    ]
    for (contextName, context) in contexts {
        for rasterized in [false, true] {
            for rgb in [false, true] {
                for (formatName, format) in [("RGBA8", CIFormat.RGBA8), ("RGB10", CIFormat.RGB10)] {
                  for explicitISO in [false, true] {
                   for fileWriter in [false, true] {
                    for (spaceName, outputSpace) in [("P3", p3), ("extendedP3", extendedP3)] {
                    let sdr = image(sdrValues).settingContentHeadroom(1)
                    var hdr = image(hdrValues).settingContentHeadroom(4)
                    if rasterized, let raster = context.createCGImage(hdr, from: hdr.extent, format: .RGBAh, colorSpace: extendedP3) {
                        hdr = CIImage(cgImage: raster, options: [.contentHeadroom: 4])
                    }
                    var options: [CIImageRepresentationOption: Any] = [.hdrImage: hdr, .hdrGainMapAsRGB: rgb]
                    if explicitISO {
                        options[CIImageRepresentationOption(rawValue: kCGImageDestinationEncodeRequest as String)] = kCGImageDestinationEncodeToISOGainmap
                    }
                    let label = "\(contextName)-\(rasterized ? "raster" : "CIImage")-\(rgb ? "RGBmap" : "monoMap")-\(formatName)-\(explicitISO ? "ISO" : "default")-\(fileWriter ? "file" : "data")-\(spaceName)"
                    var encoded: Data?
                    if fileWriter {
                        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
                        do {
                            try context.writeHEIFRepresentation(of: sdr, to: url, format: format, colorSpace: outputSpace, options: options)
                            encoded = try Data(contentsOf: url)
                        } catch { print("GAINMAP_PROBE \(label) WRITE_ERROR \(error)") }
                        try? FileManager.default.removeItem(at: url)
                    } else { encoded = context.heifRepresentation(of: sdr, format: format, colorSpace: outputSpace, options: options) }
                    guard let data = encoded,
                          let decoded = CIImage(data: data, options: [.expandToHDR: true]),
                          let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                        print("GAINMAP_PROBE \(label) ENCODE_FAILED")
                        continue
                    }
                    let iso = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)
                    let apple = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeHDRGainMap)
                    let values = centres(decoded)
                    let payload: [String: Any] = ["label": label, "headroom": decoded.contentHeadroom,
                        "values": values, "ISO": iso != nil, "Apple": apple != nil,
                        "maxError": zip(values, hdrValues).map { abs($0.0 - $0.1) }.max()!]
                    print("GAINMAP_PROBE " + String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!)
                    }
                   }
                  }
                }
            }
        }
    }
}
