import Foundation

public enum SegmentKind: String, Codable, Sendable {
    /// fMP4 initialization segment (`ftyp` + `moov`). Zero duration. Required to play the run's media segments.
    case initialization
    /// A media segment (`moof` + `mdat`) or, for self-contained writers, a complete movie file.
    case media
}

/// One on-disk piece of footage in the rolling buffer.
///
/// Times are wall-clock so that retention ("last five minutes") and incident windows
/// ("sixty seconds after the trigger") can be computed independently of the media timeline.
public struct Segment: Hashable, Codable, Sendable, Identifiable {
    public struct ID: Hashable, Codable, Sendable, CustomStringConvertible {
        public let run: RunID
        public let sequence: Int

        public init(run: RunID, sequence: Int) {
            self.run = run
            self.sequence = sequence
        }

        public var description: String { "\(run.rawValue)#\(sequence)" }
    }

    public let id: ID
    public let kind: SegmentKind
    /// Wall-clock time of the first sample in the segment (for initialization segments, the run start).
    public let startTime: Date
    /// Media duration in seconds. Zero for initialization segments. Estimated when `isComplete` is false.
    public let duration: TimeInterval
    public let byteCount: Int64
    /// Path relative to the buffer root, e.g. `run-1700000000-1a2b3c4d/000042.m4s`.
    public let relativePath: String
    /// False when the writer was interrupted before the segment was finalized (duration is then an estimate).
    public let isComplete: Bool

    public init(id: ID, kind: SegmentKind, startTime: Date, duration: TimeInterval, byteCount: Int64, relativePath: String, isComplete: Bool = true) {
        self.id = id
        self.kind = kind
        self.startTime = startTime
        self.duration = max(0, duration)
        self.byteCount = max(0, byteCount)
        self.relativePath = relativePath
        self.isComplete = isComplete
    }

    public var endTime: Date { startTime.addingTimeInterval(duration) }

    /// Half-open overlap test on wall-clock time. Initialization segments never overlap a window
    /// (they are attached to incidents through their run, not through time).
    public func overlaps(start: Date, end: Date) -> Bool {
        guard kind == .media, end > start else { return false }
        return startTime < end && endTime > start
    }

    /// Conventional relative path for a segment file inside the buffer root.
    public static func relativePath(run: RunID, sequence: Int, fileExtension: String) -> String {
        let padded = String(format: "%06d", sequence)
        return "\(run.rawValue)/\(padded).\(fileExtension)"
    }

    public static func initializationPath(run: RunID, fileExtension: String = "mp4") -> String {
        "\(run.rawValue)/init.\(fileExtension)"
    }
}

public extension Array where Element == Segment {
    /// Sorted by start time, then by sequence, with initialization segments before media of the same instant.
    func chronological() -> [Segment] {
        sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime { return lhs.startTime < rhs.startTime }
            if lhs.kind != rhs.kind { return lhs.kind == .initialization }
            return lhs.id.sequence < rhs.id.sequence
        }
    }

    var totalBytes: Int64 { reduce(0) { $0 + $1.byteCount } }

    var mediaDuration: TimeInterval { filter { $0.kind == .media }.reduce(0) { $0 + $1.duration } }
}
