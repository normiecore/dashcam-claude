import Foundation

public enum StorageLevel: String, Sendable, Codable {
    case ok
    /// Below twice the free-space floor: warn the user, keep recording.
    case low
    /// Below the free-space floor even after retention ran: recording must stop or refuse to start.
    case critical
}

public struct StorageStatus: Sendable, Equatable, Codable {
    public var availableBytes: Int64
    public var bufferBytes: Int64
    public var incidentBytes: Int64
    public var level: StorageLevel

    public init(availableBytes: Int64, bufferBytes: Int64, incidentBytes: Int64, level: StorageLevel) {
        self.availableBytes = availableBytes
        self.bufferBytes = bufferBytes
        self.incidentBytes = incidentBytes
        self.level = level
    }

    public static func evaluate(availableBytes: Int64, bufferBytes: Int64, incidentBytes: Int64, policy: RetentionPolicy) -> StorageStatus {
        let level: StorageLevel
        if availableBytes < policy.minimumFreeBytes {
            level = .critical
        } else if availableBytes < policy.minimumFreeBytes * 2 {
            level = .low
        } else {
            level = .ok
        }
        return StorageStatus(availableBytes: availableBytes, bufferBytes: bufferBytes, incidentBytes: incidentBytes, level: level)
    }

    /// Rough footprint estimate for planning: bytes per second at a given video bitrate plus audio.
    public static func estimatedBytes(forDuration seconds: TimeInterval, videoBitsPerSecond: Int, audioBitsPerSecond: Int = 96_000) -> Int64 {
        Int64((Double(videoBitsPerSecond + audioBitsPerSecond) / 8.0) * seconds)
    }
}
