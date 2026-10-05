import Foundation

/// Every incident trigger, whatever produced it, funnels into `IncidentManager.trigger(source:)`.
public enum IncidentSource: String, Codable, Sendable, CaseIterable {
    case manual
    case appleCrashDetection
    case motionHeuristic
    case developerSimulation

    public var displayName: String {
        switch self {
        case .manual: return "Manual"
        case .appleCrashDetection: return "Apple Crash Detection"
        case .motionHeuristic: return "Motion heuristic"
        case .developerSimulation: return "Developer simulation"
        }
    }
}

public struct IncidentPolicy: Codable, Sendable, Equatable {
    /// Footage before the trigger to preserve. Default: the whole buffer (five minutes).
    public var preRoll: TimeInterval
    /// Footage after the trigger to keep recording into the incident.
    public var postRoll: TimeInterval
    /// When true, a trigger that arrives while an incident is still collecting extends that incident's
    /// window instead of opening a second, overlapping incident.
    public var mergeOverlappingTriggers: Bool

    public init(preRoll: TimeInterval = 300, postRoll: TimeInterval = 60, mergeOverlappingTriggers: Bool = true) {
        self.preRoll = max(0, preRoll)
        self.postRoll = max(0, postRoll)
        self.mergeOverlappingTriggers = mergeOverlappingTriggers
    }
}

public struct IncidentTrigger: Codable, Sendable, Equatable {
    public let source: IncidentSource
    public let time: Date
    public let note: String?

    public init(source: IncidentSource, time: Date, note: String? = nil) {
        self.source = source
        self.time = time
        self.note = note
    }
}

public enum IncidentState: String, Codable, Sendable {
    /// The post-roll window is still in the future; new segments are being attached.
    case collecting
    /// All footage is on disk under the incident directory; a clip can be assembled.
    case readyToAssemble
    case assembling
    case complete
    case failed
}

/// A footage part attached to an incident. `linkedRelativePath` is set when the segment file was hard-linked
/// (or copied) into the incident directory; when nil, the incident still relies on the buffer copy and the
/// segment ID is reported as protected so retention leaves it alone.
public struct IncidentPart: Codable, Sendable, Equatable {
    public let segment: Segment
    public let linkedRelativePath: String?

    public init(segment: Segment, linkedRelativePath: String?) {
        self.segment = segment
        self.linkedRelativePath = linkedRelativePath
    }
}

public struct Incident: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let createdAt: Date
    public var triggers: [IncidentTrigger]
    public var windowStart: Date
    public var windowEnd: Date
    public var state: IncidentState
    public var parts: [IncidentPart]
    /// Relative paths (within the incident directory) of assembled clip files.
    public var clipRelativePaths: [String]
    public var failureReason: String?

    public init(id: UUID, createdAt: Date, triggers: [IncidentTrigger], windowStart: Date, windowEnd: Date, state: IncidentState = .collecting, parts: [IncidentPart] = [], clipRelativePaths: [String] = [], failureReason: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.triggers = triggers
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.state = state
        self.parts = parts
        self.clipRelativePaths = clipRelativePaths
        self.failureReason = failureReason
    }

    public var primarySource: IncidentSource { triggers.first?.source ?? .manual }
    public var triggerTime: Date { triggers.first?.time ?? createdAt }
    public var segmentIDs: [Segment.ID] { parts.map(\.segment.id) }
    public var mediaParts: [IncidentPart] { parts.filter { $0.segment.kind == .media } }
    /// Wall-clock span actually covered by attached media.
    public var coveredStart: Date? { mediaParts.map(\.segment.startTime).min() }
    public var coveredEnd: Date? { mediaParts.map(\.segment.endTime).max() }
    public var footageDuration: TimeInterval { mediaParts.map(\.segment).mediaDuration }
    public var totalBytes: Int64 { parts.map(\.segment).totalBytes }
    public var isFinished: Bool { state == .complete || state == .failed }

    func contains(_ id: Segment.ID) -> Bool {
        parts.contains { $0.segment.id == id }
    }
}
