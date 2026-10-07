import Foundation
import CoreMedia

/// Capture/encode presets. Kept deliberately small for V0.1; thermal throttling adjusts frame rate
/// within a tier rather than switching tiers mid-run (a format change would force a new writer run).
enum VideoQualityTier: String, CaseIterable, Codable, Identifiable {
    /// Raw values preserve settings written by earlier builds.
    case hd720p30
    case hd1080p30
    case hd1080p30High

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .hd720p30: return 1280
        case .hd1080p30, .hd1080p30High: return 1920
        }
    }

    var height: Int32 {
        switch self {
        case .hd720p30: return 720
        case .hd1080p30, .hd1080p30High: return 1080
        }
    }

    var frameRate: Int { 30 }

    /// Average HEVC bitrate. These are starting points; physical-drive footage validates the final values.
    var averageBitrate: Int {
        switch self {
        case .hd720p30: return 2_000_000
        case .hd1080p30: return 4_000_000
        case .hd1080p30High: return 6_000_000
        }
    }

    /// Fallback bitrate when only H.264 is available (about 35% higher for similar quality).
    var h264AverageBitrate: Int { averageBitrate * 4 / 3 }

    var displayName: String {
        switch self {
        case .hd720p30: return "Space Saver"
        case .hd1080p30: return "Standard"
        case .hd1080p30High: return "High Detail"
        }
    }

    var technicalDescription: String {
        switch self {
        case .hd720p30: return "720p · 30 fps"
        case .hd1080p30, .hd1080p30High: return "1080p · 30 fps"
        }
    }

    var purpose: String {
        switch self {
        case .hd720p30: return "Longest recording history"
        case .hd1080p30: return "Balanced detail and storage"
        case .hd1080p30High: return "More detail, larger files"
        }
    }

    func estimatedBytesPerHour(audioEnabled: Bool) -> Int64 {
        let audioBitsPerSecond = audioEnabled ? 96_000 : 0
        return Int64((Double(averageBitrate + audioBitsPerSecond) / 8) * 3_600)
    }

    var dimensions: CMVideoDimensions { CMVideoDimensions(width: width, height: height) }
}
