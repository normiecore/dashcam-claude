import Foundation

public enum IncidentEvent: Sendable, Equatable {
    case triggered(Incident)
    case updated(Incident)
    case readyToAssemble(Incident)
    case completed(Incident)
    case failed(Incident)
}

/// Unified incident pipeline. Protects footage the moment a trigger arrives by hard-linking the
/// overlapping buffer segments into a per-incident directory, keeps attaching new segments until the
/// post-roll window is covered, then hands the collected parts to a `ClipAssembler`.
///
/// Recovery: every state change is persisted to `manifest.json`. At launch, incidents left in
/// `.collecting` (the app died or was killed) are promoted to `.readyToAssemble` with whatever footage
/// they already hold, so nothing already protected is ever lost.
public actor IncidentManager {
    public nonisolated let rootURL: URL
    public var policy: IncidentPolicy
    private let store: SegmentStore
    private let fs: SegmentFileSystem
    private let clock: WallClock
    private let logger: DashcamLogger
    private var incidents: [UUID: Incident] = [:]
    public nonisolated let events: AsyncStream<IncidentEvent>
    private let continuation: AsyncStream<IncidentEvent>.Continuation

    public static let manifestName = "manifest.json"
    public static let partsDirectoryName = "parts"

    public init(rootURL: URL, store: SegmentStore, fileSystem: SegmentFileSystem = DefaultFileSystem(), clock: WallClock = SystemWallClock(), policy: IncidentPolicy = IncidentPolicy(), logger: DashcamLogger = .disabled) {
        self.rootURL = rootURL
        self.store = store
        self.fs = fileSystem
        self.clock = clock
        self.policy = policy
        self.logger = logger
        let (stream, continuation) = AsyncStream<IncidentEvent>.makeStream(bufferingPolicy: .bufferingNewest(256))
        self.events = stream
        self.continuation = continuation
    }

    // MARK: Paths

    public nonisolated func directory(for incidentID: UUID) -> URL {
        rootURL.appendingPathComponent(incidentID.uuidString, isDirectory: true)
    }

    public nonisolated func partsDirectory(for incidentID: UUID) -> URL {
        directory(for: incidentID).appendingPathComponent(IncidentManager.partsDirectoryName, isDirectory: true)
    }

    /// Absolute URL for a part: the linked copy when present, else the buffer copy.
    public nonisolated func url(for part: IncidentPart, of incidentID: UUID) -> URL {
        if let linked = part.linkedRelativePath {
            return directory(for: incidentID).appendingPathComponent(linked)
        }
        return store.url(for: part.segment)
    }

    public nonisolated func clipURLs(for incident: Incident) -> [URL] {
        incident.clipRelativePaths.map { directory(for: incident.id).appendingPathComponent($0) }
    }

    // MARK: Lifecycle

    /// Loads manifests from disk. Incidents interrupted mid-collection become ready to assemble.
    @discardableResult
    public func load() throws -> [Incident] {
        try fs.createDirectory(at: rootURL)
        let decoder = SegmentStore.makeDecoder()
        var loaded: [UUID: Incident] = [:]
        for dir in try fs.contentsOfDirectory(at: rootURL) where fs.isDirectory(at: dir) {
            let manifest = dir.appendingPathComponent(IncidentManager.manifestName)
            guard fs.fileExists(at: manifest) else {
                logger.warning(.incident, "Incident directory without manifest: \(dir.lastPathComponent)")
                continue
            }
            do {
                var incident = try decoder.decode(Incident.self, from: fs.read(from: manifest))
                if incident.state == .collecting || incident.state == .assembling {
                    incident.state = incident.parts.isEmpty ? .failed : .readyToAssemble
                    if incident.parts.isEmpty { incident.failureReason = "No footage was captured before the app stopped." }
                    try persist(incident)
                    logger.notice(.incident, "Recovered incident \(incident.id) as \(incident.state.rawValue) with \(incident.parts.count) parts")
                }
                loaded[incident.id] = incident
            } catch {
                logger.error(.incident, "Unreadable incident manifest \(dir.lastPathComponent): \(error)")
            }
        }
        incidents = loaded
        return allIncidents()
    }

    // MARK: Triggering

    /// The single entry point for every incident source.
    @discardableResult
    public func trigger(source: IncidentSource, note: String? = nil) async throws -> Incident {
        let now = clock.now()
        let trigger = IncidentTrigger(source: source, time: now, note: note)
        logger.notice(.incident, "Incident trigger from \(source.rawValue) at \(now)")

        if policy.mergeOverlappingTriggers,
           var existing = incidents.values.first(where: { $0.state == .collecting && $0.windowEnd >= now }) {
            existing.triggers.append(trigger)
            existing.windowEnd = max(existing.windowEnd, now.addingTimeInterval(policy.postRoll))
            incidents[existing.id] = existing
            try persist(existing)
            continuation.yield(.updated(existing))
            logger.info(.incident, "Merged trigger into incident \(existing.id); window now ends \(existing.windowEnd)")
            return existing
        }

        var incident = Incident(
            id: UUID(),
            createdAt: now,
            triggers: [trigger],
            windowStart: now.addingTimeInterval(-policy.preRoll),
            windowEnd: now.addingTimeInterval(policy.postRoll)
        )
        try fs.createDirectory(at: partsDirectory(for: incident.id))

        // Snapshot the buffer, then attach synchronously so retention cannot slip in between.
        let available = await store.segments()
        let overlapping = available.filter { $0.overlaps(start: incident.windowStart, end: incident.windowEnd) }
        for segment in overlapping.chronological() {
            attach(segment, to: &incident, from: available)
        }
        incidents[incident.id] = incident
        try persist(incident)
        continuation.yield(.triggered(incident))
        logger.notice(.incident, "Incident \(incident.id) opened with \(incident.mediaParts.count) pre-roll segments (\(Int(incident.footageDuration))s)")
        return incident
    }

    /// Called by the buffer manager after each finished segment is indexed.
    public func segmentDidFinalize(_ segment: Segment) async throws {
        guard segment.kind == .media else { return }
        let collecting = incidents.values.filter { $0.state == .collecting }
        guard !collecting.isEmpty else { return }
        var snapshot: [Segment]?
        for var incident in collecting {
            var changed = false
            if segment.overlaps(start: incident.windowStart, end: incident.windowEnd), !incident.contains(segment.id) {
                if snapshot == nil { snapshot = await store.segments() }
                attach(segment, to: &incident, from: snapshot ?? [])
                changed = true
            }
            if segment.endTime >= incident.windowEnd {
                incident.state = .readyToAssemble
                changed = true
                logger.notice(.incident, "Incident \(incident.id) collected \(Int(incident.footageDuration))s of footage; ready to assemble")
            }
            if changed {
                incidents[incident.id] = incident
                try persist(incident)
                continuation.yield(incident.state == .readyToAssemble ? .readyToAssemble(incident) : .updated(incident))
            }
        }
    }

    /// Recording stopped (user action, interruption that will not resume, app going away): close out
    /// collecting incidents with whatever they have.
    public func recordingDidStop() throws {
        for var incident in incidents.values where incident.state == .collecting {
            incident.state = incident.parts.isEmpty ? .failed : .readyToAssemble
            if incident.parts.isEmpty { incident.failureReason = "Recording stopped before any footage was captured." }
            incidents[incident.id] = incident
            try persist(incident)
            continuation.yield(incident.state == .failed ? .failed(incident) : .readyToAssemble(incident))
            logger.notice(.incident, "Incident \(incident.id) closed early by recording stop (\(incident.parts.count) parts)")
        }
    }

    // MARK: Assembly

    /// Assembles the incident's parts into clip files using `assembler`, then releases the linked parts.
    @discardableResult
    public func assemble(_ id: UUID, using assembler: ClipAssembler) async throws -> Incident {
        guard var incident = incidents[id] else { throw DashcamCoreError.unknownIncident(id) }
        guard incident.state == .readyToAssemble || incident.state == .failed else {
            throw DashcamCoreError.invalidState("Incident \(id) is \(incident.state.rawValue)")
        }
        incident.state = .assembling
        incidents[id] = incident
        try persist(incident)

        let plan = ClipAssemblyPlanner.plan(parts: incident.parts.map { ($0.segment, url(for: $0, of: id)) })
        do {
            let baseName = IncidentManager.clipBaseName(for: incident)
            let outputs = try await assembler.assemble(plan, into: directory(for: id), baseName: baseName)
            incident.clipRelativePaths = outputs
            incident.state = .complete
            incident.failureReason = nil
            incidents[id] = incident
            try persist(incident)
            releaseParts(of: incident)
            continuation.yield(.completed(incident))
            logger.notice(.incident, "Incident \(id) assembled into \(outputs.count) clip(s)")
        } catch {
            incident.state = .failed
            incident.failureReason = "\(error)"
            incidents[id] = incident
            try persist(incident)
            continuation.yield(.failed(incident))
            logger.error(.incident, "Incident \(id) assembly failed: \(error)")
            throw error
        }
        return incident
    }

    public func delete(_ id: UUID) throws {
        guard incidents[id] != nil else { return }
        try fs.removeItem(at: directory(for: id))
        incidents.removeValue(forKey: id)
    }

    // MARK: Queries

    public func allIncidents() -> [Incident] {
        incidents.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func incident(_ id: UUID) -> Incident? { incidents[id] }

    public func incidents(in states: Set<IncidentState>) -> [Incident] {
        allIncidents().filter { states.contains($0.state) }
    }

    /// Buffer segments that must not be deleted because an unfinished incident still depends on the buffer copy.
    public func protectedSegmentIDs() -> Set<Segment.ID> {
        var ids = Set<Segment.ID>()
        for incident in incidents.values where !incident.isFinished {
            for part in incident.parts where part.linkedRelativePath == nil {
                ids.insert(part.segment.id)
            }
        }
        return ids
    }

    // MARK: Internals

    private func attach(_ segment: Segment, to incident: inout Incident, from available: [Segment]) {
        if segment.kind == .media, !incident.parts.contains(where: { $0.segment.kind == .initialization && $0.segment.id.run == segment.id.run }),
           let initSegment = available.first(where: { $0.kind == .initialization && $0.id.run == segment.id.run }) {
            incident.parts.append(link(initSegment, into: incident.id))
        }
        guard !incident.contains(segment.id) else { return }
        incident.parts.append(link(segment, into: incident.id))
    }

    private func link(_ segment: Segment, into incidentID: UUID) -> IncidentPart {
        let source = store.url(for: segment)
        let fileName = segment.relativePath.replacingOccurrences(of: "/", with: "_")
        let relative = "\(IncidentManager.partsDirectoryName)/\(fileName)"
        let destination = directory(for: incidentID).appendingPathComponent(relative)
        do {
            if fs.fileExists(at: destination) { try fs.removeItem(at: destination) }
            try fs.linkItem(at: source, to: destination)
            return IncidentPart(segment: segment, linkedRelativePath: relative)
        } catch {
            logger.error(.incident, "Could not link \(segment.relativePath) into incident \(incidentID); protecting buffer copy instead: \(error)")
            return IncidentPart(segment: segment, linkedRelativePath: nil)
        }
    }

    private func releaseParts(of incident: Incident) {
        let partsDir = partsDirectory(for: incident.id)
        if fs.fileExists(at: partsDir) {
            do { try fs.removeItem(at: partsDir) } catch {
                logger.warning(.incident, "Could not remove parts of incident \(incident.id): \(error)")
            }
        }
    }

    private func persist(_ incident: Incident) throws {
        try fs.createDirectory(at: directory(for: incident.id))
        let data = try SegmentStore.makeEncoder().encode(incident)
        try fs.write(data, to: directory(for: incident.id).appendingPathComponent(IncidentManager.manifestName))
    }

    static func clipBaseName(for incident: Incident) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "incident-\(formatter.string(from: incident.triggerTime))"
    }
}
