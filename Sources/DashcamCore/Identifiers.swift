import Foundation

/// Identifies one uninterrupted recording run (one writer lifetime). Every time the capture
/// pipeline (re)starts, a new run begins. Segments are grouped under their run because, with
/// fragmented MP4 output, the media segments of a run are only playable together with that run's
/// initialization segment.
public struct RunID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an identifier that sorts chronologically when used as a directory name.
    public static func make(at date: Date) -> RunID {
        let stamp = Int(date.timeIntervalSince1970)
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return RunID(rawValue: "run-\(stamp)-\(suffix)")
    }

    public var description: String { rawValue }
}

extension RunID: Codable {
    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum DashcamCoreError: Error, Equatable, Sendable {
    case fileSystem(String)
    case corruptSidecar(String)
    case unknownIncident(UUID)
    case invalidState(String)
    case missingInitializationSegment(RunID)
    case emptyAssemblyPlan
}
