import Foundation
import CoreGraphics

/// Crops use whole source pixels and never resample or enlarge the original.
enum PhotoAspectRatio: String, CaseIterable, Identifiable, Sendable {
    case native = "Native", fourThirds = "4:3", threeTwo = "3:2", sixteenNine = "16:9", square = "1:1"
    var id: String { rawValue }
    func cropRect(in source: CGRect) -> CGRect {
        guard self != .native else { return source }
        let longToShort: CGFloat
        switch self {
        case .native: return source
        case .fourThirds: longToShort = 4 / 3
        case .threeTwo: longToShort = 3 / 2
        case .sixteenNine: longToShort = 16 / 9
        case .square: longToShort = 1
        }
        let ratio = source.width < source.height ? 1 / longToShort : longToShort
        let width = floor(min(source.width, source.height * ratio))
        let height = floor(min(source.height, source.width / ratio))
        return CGRect(x: floor(source.midX - width / 2), y: floor(source.midY - height / 2), width: width, height: height)
    }
}

enum PhotoSaveMode: String, CaseIterable, Identifiable, Sendable {
    case both = "Original + processed", processed = "Processed only", original = "Original only"
    var id: String { rawValue }
    func resources(original: URL, processed: URL?) -> [URL] {
        switch self {
        case .both: return [original] + (processed.map { [$0] } ?? [])
        case .processed: return processed.map { [$0] } ?? []
        case .original: return [original]
        }
    }
}
