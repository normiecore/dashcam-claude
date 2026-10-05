import Foundation
import CoreMedia

/// Capture/encode presets. Kept deliberately small for V0.1; thermal throttling adjusts frame rate
/// within a tier rather than switching tiers mid-run (a format change would force a new writer run).
enum VideoQualityTier: String, CaseIterable, Codable, Identifiable {
    case hd1080p30
    case hd720p30

    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .hd1080p30: return 1920
        case .hd720p30: return 1280
        }
    }

    var height: Int32 {
        switch self {
        case .hd1080p30: return 1080
        case .hd720p30: return 720
        }
    }

    var frameRate: Int { 30 }

    /// Average HEVC bitrate. Roughly 34 MB/min at 1080p and 18 MB/min at 720p.
    var averageBitrate: Int {
        switch self {
        case .hd1080p30: return 4_500_000
        case .hd720p30: return 2_400_000
        }
    }

    /// Fallback bitrate when only H.264 is available (about 35% higher for similar quality).
    var h264AverageBitrate: Int { averageBitrate * 4 / 3 }

    var displayName: String {
        switch self {
        case .hd1080p30: return "1080p 30 fps"
        case .hd720p30: return "720p 30 fps"
        }
    }

    var dimensions: CMVideoDimensions { CMVideoDimensions(width: width, height: height) }
}
