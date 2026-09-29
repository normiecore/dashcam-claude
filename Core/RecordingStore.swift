import Foundation
#if SWIFT_PACKAGE
import CRetentionPolicy
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum SegmentState: String, Codable, Sendable { case writing, ready, damaged }
enum IncidentState: String, Codable, Sendable { case collecting, saved, interrupted }
enum IncidentSource: String, Codable, Sendable { case manual, developer, safetyKit, motion }

struct SegmentRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let filename: String
    var start: Double
    var end: Double?
    var byteCount: Int64
    var state: SegmentState
}

struct IncidentRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let sessionID: UUID
    let createdAt: Date
    let eventTime: Double
    let windowStart: Double
    let windowEnd: Double
    let source: IncidentSource
    var state: IncidentState
    var note: String?
}

struct StoreSnapshot: Sendable {
    let segments: [SegmentRecord]
    let incidents: [IncidentRecord]
    let totalBytes: Int64
    let recoveryMessages: [String]
}

enum RecordingStoreError: Error, LocalizedError {
    case corruptMetadata(String)
    case invalidOperation(String)
    case insufficientStorage

    var errorDescription: String? {
        switch self {
        case .corruptMetadata(let detail): return "Recording metadata requires recovery: \(detail)"
        case .invalidOperation(let detail): return detail
        case .insufficientStorage: return "Insufficient storage to keep the recording reserve"
        }
    }
}

private struct RecordingSession: Codable {
    let id: UUID
    let createdAt: Date
    var active: Bool
    var stoppedAt: Double? = nil
    var stopReason: String? = nil
    // Optional for compatibility with the first manifest format. A crash or
    // failed incident journal write must never turn the last buffer disposable.
    var requiresReview: Bool? = nil
}

private struct Manifest: Codable {
    var version = 1
    var sessions: [RecordingSession] = []
    var segments: [SegmentRecord] = []
    var incidents: [IncidentRecord] = []
    var pendingDeletionIDs: [UUID] = []
    var recoveryMessages: [String] = []
}

/// Call from a single serial queue. A separate store process must not share this root.
final class RecordingStore {
    static let rollingSeconds: Double = 300
    static let postIncidentSeconds: Double = 30

    let root: URL
    private let segmentsDirectory: URL
    private let recoveryDirectory: URL
    private let manifestURL: URL
    private var manifest: Manifest
    private var ownedSessions = Set<UUID>()

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        segmentsDirectory = self.root.appendingPathComponent("segments", isDirectory: true)
        recoveryDirectory = self.root.appendingPathComponent("recovery", isDirectory: true)
        manifestURL = self.root.appendingPathComponent("manifest.json")
        let manager = FileManager.default
        try manager.createDirectory(at: self.root, withIntermediateDirectories: true)
        try manager.createDirectory(at: segmentsDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        try Self.configureStorage(at: self.root)
        try Self.configureStorage(at: segmentsDirectory)
        try Self.configureStorage(at: recoveryDirectory)
        if manager.fileExists(atPath: manifestURL.path) {
            do {
                manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
                try Self.validate(manifest)
            } catch {
                throw RecordingStoreError.corruptMetadata(String(describing: error))
            }
        } else {
            // A missing manifest alongside media is uncertain. Never silently reset the library.
            let media = try manager.contentsOfDirectory(atPath: segmentsDirectory.path)
            let recovered = try manager.contentsOfDirectory(atPath: recoveryDirectory.path)
            guard media.isEmpty && recovered.isEmpty else {
                throw RecordingStoreError.corruptMetadata("Manifest missing while media exists")
            }
            manifest = Manifest()
            try persist(manifest)
        }
        try recover()
    }

    @discardableResult
    func beginSession(at date: Date) throws -> UUID {
        try pruneStoppedSessions()
        let id = UUID()
        var next = manifest
        next.sessions.append(RecordingSession(id: id, createdAt: date, active: true))
        try commit(next)
        ownedSessions.insert(id)
        return id
    }

    @discardableResult
    func beginSegment(sessionID: UUID, start: Double) throws -> SegmentRecord {
        guard start.isFinite, manifest.sessions.contains(where: { $0.id == sessionID && $0.active }) else {
            throw RecordingStoreError.invalidOperation("Session inactive or segment time invalid")
        }
        let id = UUID()
        let record = SegmentRecord(id: id, sessionID: sessionID, filename: "segments/\(id.uuidString).mov",
                                   start: start, end: nil, byteCount: 0, state: .writing)
        var next = manifest
        next.segments.append(record)
        try commit(next) // durable registration happens before the caller opens the writer
        return record
    }

    func segmentURL(_ record: SegmentRecord) -> URL {
        // Only records returned from this store should be passed here. Never accept a caller's path.
        segmentsDirectory.appendingPathComponent("\(record.id.uuidString).mov")
    }

    func finishSegment(id: UUID, end: Double, byteCount: Int64, actualStart: Double? = nil) throws {
        guard let index = manifest.segments.firstIndex(where: { $0.id == id }),
              manifest.segments[index].state == .writing,
              end.isFinite, byteCount > 0 else {
            throw RecordingStoreError.invalidOperation("Cannot finalize segment with invalid interval or size")
        }
        let finalStart = actualStart ?? manifest.segments[index].start
        guard finalStart.isFinite, finalStart >= manifest.segments[index].start,
              finalStart < end else {
            throw RecordingStoreError.invalidOperation("First accepted sample is outside the registered interval")
        }
        let file = segmentURL(manifest.segments[index])
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard (attributes[.type] as? FileAttributeType) == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == byteCount else {
            throw RecordingStoreError.invalidOperation("Segment file absent, not regular, or size mismatch")
        }
        // The writer must finish and close before this method. Sync the media before publishing it.
        let handle = try FileHandle(forUpdating: file)
        defer { try? handle.close() }
        try handle.synchronize()
        var next = manifest
        next.segments[index].start = finalStart
        next.segments[index].end = end
        next.segments[index].byteCount = byteCount
        next.segments[index].state = .ready
        let sessionID = next.segments[index].sessionID
        completeCoveredIncidents(in: &next, sessionID: sessionID)
        try commit(next)
    }

    func failSegment(id: UUID, reason: String) throws {
        guard let index = manifest.segments.firstIndex(where: { $0.id == id }),
              manifest.segments[index].state == .writing else {
            throw RecordingStoreError.invalidOperation("Segment is not writing")
        }
        var next = manifest
        let failed = next.segments[index]
        next.segments[index].state = .damaged
        next.recoveryMessages.append("Unfinished segment \(id): \(reason)")
        for incidentIndex in next.incidents.indices where next.incidents[incidentIndex].sessionID == failed.sessionID && next.incidents[incidentIndex].state == .collecting {
            if failed.start < next.incidents[incidentIndex].windowEnd {
                next.incidents[incidentIndex].state = .interrupted
                next.incidents[incidentIndex].note = reason
            }
        }
        try commit(next)
    }

    @discardableResult
    func triggerIncident(sessionID: UUID, at time: Double, source: IncidentSource) throws -> IncidentRecord {
        guard time.isFinite, manifest.sessions.contains(where: { $0.id == sessionID && $0.active }),
              time <= Double.greatestFiniteMagnitude - Self.postIncidentSeconds else {
            throw RecordingStoreError.invalidOperation("Incident requires an active session and finite host time")
        }
        let incident = IncidentRecord(id: UUID(), sessionID: sessionID, createdAt: Date(),
                                      eventTime: time, windowStart: time - Self.rollingSeconds,
                                      windowEnd: time + Self.postIncidentSeconds, source: source,
                                      state: .collecting, note: nil)
        var next = manifest
        next.incidents.append(incident)
        let prior = next.segments.filter { $0.sessionID == sessionID && $0.start < time }
        if let first = prior.min(by: { $0.start < $1.start }), first.start > incident.windowStart {
            next.incidents[next.incidents.count - 1].note = "Pre-event history shorter than five minutes"
        } else if prior.isEmpty {
            next.incidents[next.incidents.count - 1].note = "No pre-event segment was available"
        }
        // Cancel deletion intent for a file that becomes protected before any file removal.
        let existingSegments = next.segments
        next.pendingDeletionIDs.removeAll { id in
            guard let segment = existingSegments.first(where: { $0.id == id }) else { return true }
            return protected(segment, by: [incident])
        }
        try commit(next) // never acknowledge a trigger whose protection has not reached disk
        return next.incidents[next.incidents.count - 1]
    }

    func finishSession(sessionID: UUID, at time: Double, reason: String,
                       preserveUnprotected: Bool = false) throws {
        guard time.isFinite, let index = manifest.sessions.firstIndex(where: { $0.id == sessionID && $0.active }) else {
            throw RecordingStoreError.invalidOperation("Cannot finish inactive session")
        }
        var next = manifest
        next.sessions[index].active = false
        next.sessions[index].stoppedAt = time
        next.sessions[index].stopReason = reason
        if preserveUnprotected {
            next.sessions[index].requiresReview = true
            next.recoveryMessages.append("Session \(sessionID) retained after a storage fault; review before reclaiming footage")
        }
        for i in next.incidents.indices where next.incidents[i].sessionID == sessionID && next.incidents[i].state == .collecting {
            next.incidents[i].state = .interrupted
            next.incidents[i].note = "Recording stopped: \(reason)"
        }
        if next.segments.contains(where: { $0.sessionID == sessionID && $0.state == .writing }) {
            next.recoveryMessages.append("Session \(sessionID) ended with an unfinished writer")
        }
        try commit(next)
        ownedSessions.remove(sessionID)
    }

    /// Rolling cleanup is a two-phase, durable deletion; call only after finalization.
    func prune(sessionID: UUID, now: Double) throws {
        guard now.isFinite, manifest.sessions.contains(where: { $0.id == sessionID }) else {
            throw RecordingStoreError.invalidOperation("Unknown session or invalid host time")
        }
        guard !manifest.sessions.contains(where: { $0.id == sessionID && $0.requiresReview == true }) else { return }
        let candidates = manifest.segments.filter { segment in
            guard segment.sessionID == sessionID, let end = segment.end else { return false }
            return rp_may_delete(segment.state == .ready,
                                 protected(segment, by: manifest.incidents), false) &&
                   rp_is_expired(end, now, Self.rollingSeconds)
        }
        try pruneCandidates(candidates)
    }

    /// Host timestamps may reset across boots, so prior sessions expire by session state only.
    private func pruneStoppedSessions() throws {
        let inactive = Set(manifest.sessions.filter { !$0.active && $0.requiresReview != true }.map(\.id))
        let candidates = manifest.segments.filter { segment in
            inactive.contains(segment.sessionID) &&
            rp_may_delete(segment.state == .ready,
                          protected(segment, by: manifest.incidents), false)
        }
        try pruneCandidates(candidates)
    }

    private func pruneCandidates(_ candidates: [SegmentRecord]) throws {
        guard !candidates.isEmpty else { return }
        // Never recursively remove a directory or accept a swapped/truncated file under a
        // known UUID name. Treat any discrepancy as uncertain media and stop cleanup.
        for segment in candidates {
            if manifest.pendingDeletionIDs.contains(segment.id) &&
               !FileManager.default.fileExists(atPath: segmentURL(segment).path) { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: segmentURL(segment).path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == segment.byteCount else {
                throw RecordingStoreError.invalidOperation("Cannot prune uncertain segment \(segment.id)")
            }
        }
        var next = manifest
        let pending = Set(next.pendingDeletionIDs)
        next.pendingDeletionIDs.append(contentsOf: candidates.map(\.id).filter { !pending.contains($0) })
        try commit(next)
        // No other mutator can run on this serial queue between recheck and removal.
        for segment in candidates {
            guard let current = manifest.segments.first(where: { $0.id == segment.id }),
                  rp_may_delete(current.state == .ready,
                                protected(current, by: manifest.incidents), false) else { continue }
            let file = segmentURL(current)
            if FileManager.default.fileExists(atPath: file.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                      (attributes[.size] as? NSNumber)?.int64Value == current.byteCount else {
                    throw RecordingStoreError.invalidOperation("Segment changed during cleanup: \(current.id)")
                }
                try FileManager.default.removeItem(at: file)
            }
            var completed = manifest
            completed.segments.removeAll { $0.id == segment.id }
            completed.pendingDeletionIDs.removeAll { $0 == segment.id }
            try commit(completed)
        }
    }

    func snapshot() -> StoreSnapshot {
        let total = manifest.segments.reduce(Int64(0)) { partial, segment in
            let (sum, overflow) = partial.addingReportingOverflow(segment.byteCount)
            return overflow ? Int64.max : sum
        }
        return StoreSnapshot(segments: manifest.segments, incidents: manifest.incidents,
                             totalBytes: total, recoveryMessages: manifest.recoveryMessages)
    }

    func incidentSegments(id: UUID) throws -> [SegmentRecord] {
        guard let incident = manifest.incidents.first(where: { $0.id == id }) else {
            throw RecordingStoreError.invalidOperation("Incident not found")
        }
        guard incident.state != .collecting else {
            throw RecordingStoreError.invalidOperation("Incident tail is not yet finalized")
        }
        let window = RPWindow(start: incident.windowStart, end: incident.windowEnd)
        let related = manifest.segments.filter { segment in
            guard segment.sessionID == incident.sessionID else { return false }
            if let end = segment.end {
                return rp_interval_overlaps(segment.start, end, window.start, window.end)
            }
            return segment.start < incident.windowEnd // unknown end: conservatively intersects
        }
        guard related.allSatisfy({ $0.state == .ready }) else {
            throw RecordingStoreError.invalidOperation("Incident contains unfinished or damaged media")
        }
        for segment in related {
            let file = segmentURL(segment)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard (attributes[.type] as? FileAttributeType) == .typeRegular,
                  (attributes[.size] as? NSNumber)?.int64Value == segment.byteCount else {
                throw RecordingStoreError.invalidOperation("Incident media is missing or has changed")
            }
        }
        return related.sorted { $0.start < $1.start }
    }

    func deleteIncident(id: UUID) throws {
        guard manifest.incidents.contains(where: { $0.id == id }) else {
            throw RecordingStoreError.invalidOperation("Incident not found")
        }
        var next = manifest
        next.incidents.removeAll { $0.id == id }
        try commit(next)
    }

    /// Run at startup. Unknown files and failed writers are retained for manual recovery.
    func recover() throws {
        var next = manifest
        for index in next.sessions.indices where next.sessions[index].active && !ownedSessions.contains(next.sessions[index].id) {
            next.sessions[index].active = false
            next.sessions[index].stopReason = "Unexpected termination"
            next.sessions[index].requiresReview = true
            next.recoveryMessages.append("Session \(next.sessions[index].id) ended unexpectedly; its remaining footage is retained for review")
        }
        for index in next.segments.indices {
            if next.segments[index].state == .writing && !ownedSessions.contains(next.segments[index].sessionID) {
                next.segments[index].state = .damaged
                next.recoveryMessages.append("Unfinished segment \(next.segments[index].id) retained for recovery")
            } else if next.segments[index].state == .ready &&
                        !FileManager.default.fileExists(atPath: segmentURL(next.segments[index]).path) &&
                        !next.pendingDeletionIDs.contains(next.segments[index].id) {
                next.segments[index].state = .damaged
                next.recoveryMessages.append("Missing ready segment \(next.segments[index].id)")
            }
        }
        for index in next.incidents.indices where next.incidents[index].state == .saved {
            let incident = next.incidents[index]
            if next.segments.contains(where: { $0.sessionID == incident.sessionID && $0.state == .damaged &&
                $0.start < incident.windowEnd && ($0.end ?? .infinity) > incident.windowStart }) {
                next.incidents[index].state = .interrupted
                next.incidents[index].note = "Incident media is damaged or missing"
            }
        }
        for index in next.incidents.indices where next.incidents[index].state == .collecting && !ownedSessions.contains(next.incidents[index].sessionID) {
            next.incidents[index].state = .interrupted
            next.incidents[index].note = "Recording terminated before the incident tail finalized"
        }
        // Finish a deletion only if the already-persisted intent names a now-missing file.
        for id in next.pendingDeletionIDs {
            if let segment = next.segments.first(where: { $0.id == id }),
               !FileManager.default.fileExists(atPath: segmentURL(segment).path) {
                next.segments.removeAll { $0.id == id }
            }
        }
        next.pendingDeletionIDs.removeAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let nextData = try encoder.encode(next)
        let previousData = try encoder.encode(manifest)
        if nextData != previousData { try commit(next) }
        let knownNames = Set(manifest.segments.map { "\($0.id.uuidString).mov" })
        for name in try FileManager.default.contentsOfDirectory(atPath: segmentsDirectory.path) where !knownNames.contains(name) {
            let source = segmentsDirectory.appendingPathComponent(name)
            let destination = recoveryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name)")
            try FileManager.default.moveItem(at: source, to: destination)
            var updated = manifest
            updated.recoveryMessages.append("Unknown file moved to recovery: \(destination.lastPathComponent)")
            try commit(updated)
        }
        let recovered = try FileManager.default.contentsOfDirectory(atPath: recoveryDirectory.path)
        for name in recovered where !manifest.recoveryMessages.contains(where: { $0.contains(name) }) {
            var updated = manifest
            updated.recoveryMessages.append("Recovery file retained: \(name)")
            try commit(updated)
        }
    }

    /// Query before opening the next writer; a false result means recording should stop.
    func hasRecordingReserve(estimatedNextBytes: UInt64, reserveBytes: UInt64) throws -> Bool {
        let values = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values.volumeAvailableCapacityForImportantUsage, available >= 0 else {
            return false // unknown capacity cannot be treated as safe
        }
        return rp_has_recording_reserve(UInt64(available), estimatedNextBytes, reserveBytes)
    }

    private func protected(_ segment: SegmentRecord, by incidents: [IncidentRecord]) -> Bool {
        let windows = incidents.filter { $0.sessionID == segment.sessionID }.map {
            RPWindow(start: $0.windowStart, end: $0.windowEnd)
        }
        return windows.withUnsafeBufferPointer {
            rp_segment_protected(segment.start, segment.end ?? segment.start,
                                 segment.state == .writing || segment.end == nil,
                                 $0.baseAddress, $0.count)
        }
    }

    private func completeCoveredIncidents(in document: inout Manifest, sessionID: UUID) {
        for i in document.incidents.indices where document.incidents[i].sessionID == sessionID && document.incidents[i].state == .collecting {
            let incident = document.incidents[i]
            let readyTail = document.segments.filter {
                $0.sessionID == sessionID && $0.state == .ready &&
                ($0.end ?? -.infinity) > incident.eventTime && $0.start < incident.windowEnd
            }.sorted { $0.start < $1.start }
            // Small inter-segment sample timestamp gaps are expected. Larger gaps cannot be
            // repaired by a later writer and must never produce a complete-looking incident.
            var covered = incident.eventTime
            for segment in readyTail where segment.start <= covered + 0.25 {
                covered = max(covered, segment.end ?? covered)
            }
            let reachesTail = covered >= incident.windowEnd
            let failedTail = document.segments.contains { segment in
                segment.sessionID == sessionID && segment.state == .damaged &&
                segment.start < incident.windowEnd && (segment.end ?? .infinity) > incident.eventTime
            }
            if reachesTail && !failedTail { document.incidents[i].state = .saved }
        }
    }

    private func commit(_ next: Manifest) throws {
        try Self.validate(next)
        try persist(next)
        manifest = next
    }

    private func persist(_ next: Manifest) throws {
        let temporary = root.appendingPathComponent(".manifest-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(next).write(to: temporary)
        try Self.configureStorage(at: temporary)
        let handle = try FileHandle(forWritingTo: temporary)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, manifestURL.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // Some filesystems do not permit syncing a directory. Rename is already atomic.
        let directoryFD = open(root.path, O_RDONLY)
        if directoryFD >= 0 { _ = fsync(directoryFD); _ = close(directoryFD) }
    }

    private static func validate(_ document: Manifest) throws {
        guard document.version == 1 else { throw RecordingStoreError.corruptMetadata("Unknown manifest version") }
        let sessionIDs = Set(document.sessions.map(\.id))
        guard sessionIDs.count == document.sessions.count,
              Set(document.segments.map(\.id)).count == document.segments.count,
              Set(document.incidents.map(\.id)).count == document.incidents.count else {
            throw RecordingStoreError.corruptMetadata("Duplicate identity")
        }
        for segment in document.segments {
            guard sessionIDs.contains(segment.sessionID), segment.filename == "segments/\(segment.id.uuidString).mov",
                  segment.start.isFinite, segment.byteCount >= 0,
                  (segment.end == nil || (segment.end!.isFinite && segment.end! > segment.start)),
                  (segment.state != .ready || (segment.end != nil && segment.byteCount > 0)) else {
                throw RecordingStoreError.corruptMetadata("Invalid segment \(segment.id)")
            }
        }
        for incident in document.incidents {
            guard sessionIDs.contains(incident.sessionID), incident.eventTime.isFinite,
                  incident.windowStart.isFinite, incident.windowEnd.isFinite,
                  incident.windowStart == incident.eventTime - rollingSeconds,
                  incident.windowEnd == incident.eventTime + postIncidentSeconds,
                  incident.windowStart < incident.eventTime && incident.eventTime < incident.windowEnd else {
                throw RecordingStoreError.corruptMetadata("Invalid incident \(incident.id)")
            }
        }
        let segmentIDs = Set(document.segments.map(\.id))
        guard Set(document.pendingDeletionIDs).count == document.pendingDeletionIDs.count,
              document.pendingDeletionIDs.allSatisfy(segmentIDs.contains) else {
            throw RecordingStoreError.corruptMetadata("Invalid deletion intent")
        }
    }

    private static func configureStorage(at url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: url.path)
        #endif
    }
}
