import Foundation

/// Rules for the rolling buffer.
public struct RetentionPolicy: Codable, Sendable, Equatable {
    /// How much trailing footage the buffer retains under normal conditions. Default five minutes.
    public var targetDuration: TimeInterval
    /// Optional hard cap on bytes held by the buffer directory (protected segments are exempt but still counted).
    public var maxBufferBytes: Int64?
    /// Free-space floor for the volume. Oldest unprotected segments are deleted to stay above it.
    public var minimumFreeBytes: Int64

    public init(targetDuration: TimeInterval = 300, maxBufferBytes: Int64? = nil, minimumFreeBytes: Int64 = 750 * 1_048_576) {
        self.targetDuration = targetDuration
        self.maxBufferBytes = maxBufferBytes
        self.minimumFreeBytes = minimumFreeBytes
    }
}

public struct RetentionPlan: Sendable, Equatable {
    public var delete: [Segment]
    public var retain: [Segment]
    /// True when the free-space floor cannot be met even after deleting every deletable segment.
    public var isStorageCritical: Bool
    /// Bytes the deletions really give back to the volume. Smaller than `deletedBytes` when deleted
    /// segments are hard-linked into an incident, because the incident's link keeps the data.
    public var reclaimedBytes: Int64

    public var deletedBytes: Int64 { delete.totalBytes }
    public var retainedBytes: Int64 { retain.totalBytes }

    public init(delete: [Segment], retain: [Segment], isStorageCritical: Bool, reclaimedBytes: Int64? = nil) {
        self.delete = delete
        self.retain = retain
        self.isStorageCritical = isStorageCritical
        self.reclaimedBytes = reclaimedBytes ?? delete.totalBytes
    }
}

/// Pure retention planner. Given the current index and constraints, decides which segments to delete.
///
/// Order of operations:
/// 1. Expire unprotected media segments that ended before `now - targetDuration`.
/// 2. While the byte cap or free-space floor is violated, delete the oldest unprotected media segment.
/// 3. Delete initialization segments whose run has no media left and is not the active run.
///
/// `sharedStorage` names segments whose bytes an incident still holds through a hard link: deleting the
/// buffer copy is fine (the incident keeps the data) but frees nothing, so it is not credited against
/// the free-space floor. Without this, an incident's pre-roll would be "freed" on paper and the
/// storage-critical signal would go quiet exactly while a clip is about to be exported.
public enum RollingBufferPlanner {
    public static func plan(
        segments: [Segment],
        protected: Set<Segment.ID>,
        activeRun: RunID?,
        now: Date,
        policy: RetentionPolicy,
        availableBytes: Int64?,
        sharedStorage: Set<Segment.ID> = []
    ) -> RetentionPlan {
        var kept = segments.chronological()
        var deleting: [Segment] = []
        func reclaim(_ segment: Segment) -> Int64 { sharedStorage.contains(segment.id) ? 0 : segment.byteCount }

        // 1. Age expiry.
        let cutoff = now.addingTimeInterval(-policy.targetDuration)
        let expired = kept.filter { $0.kind == .media && $0.endTime <= cutoff && !protected.contains($0.id) }
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.id))
            kept.removeAll { expiredIDs.contains($0.id) }
            deleting.append(contentsOf: expired)
        }

        // 2. Pressure: byte cap and free-space floor.
        var freed = expired.reduce(Int64(0)) { $0 + reclaim($1) }
        func overCap() -> Bool {
            if let cap = policy.maxBufferBytes, kept.totalBytes > cap { return true }
            if let available = availableBytes, available + freed < policy.minimumFreeBytes { return true }
            return false
        }
        while overCap() {
            guard let index = kept.firstIndex(where: { $0.kind == .media && !protected.contains($0.id) }) else { break }
            let victim = kept.remove(at: index)
            deleting.append(victim)
            freed += reclaim(victim)
        }

        // 3. Orphaned initialization segments.
        let runsWithMedia = Set(kept.filter { $0.kind == .media }.map(\.id.run))
        let orphanInits = kept.filter {
            $0.kind == .initialization && !runsWithMedia.contains($0.id.run) && $0.id.run != activeRun && !protected.contains($0.id)
        }
        if !orphanInits.isEmpty {
            let orphanIDs = Set(orphanInits.map(\.id))
            kept.removeAll { orphanIDs.contains($0.id) }
            deleting.append(contentsOf: orphanInits)
            freed += orphanInits.reduce(Int64(0)) { $0 + reclaim($1) }
        }

        let critical: Bool
        if let available = availableBytes {
            critical = available + freed < policy.minimumFreeBytes
        } else {
            critical = false
        }
        return RetentionPlan(delete: deleting, retain: kept, isStorageCritical: critical, reclaimedBytes: freed)
    }
}
