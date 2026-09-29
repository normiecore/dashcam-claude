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

    public var deletedBytes: Int64 { delete.totalBytes }
    public var retainedBytes: Int64 { retain.totalBytes }

    public init(delete: [Segment], retain: [Segment], isStorageCritical: Bool) {
        self.delete = delete
        self.retain = retain
        self.isStorageCritical = isStorageCritical
    }
}

/// Pure retention planner. Given the current index and constraints, decides which segments to delete.
///
/// Order of operations:
/// 1. Expire unprotected media segments that ended before `now - targetDuration`.
/// 2. While the byte cap or free-space floor is violated, delete the oldest unprotected media segment.
/// 3. Delete initialization segments whose run has no media left and is not the active run.
public enum RollingBufferPlanner {
    public static func plan(
        segments: [Segment],
        protected: Set<Segment.ID>,
        activeRun: RunID?,
        now: Date,
        policy: RetentionPolicy,
        availableBytes: Int64?
    ) -> RetentionPlan {
        var kept = segments.chronological()
        var deleting: [Segment] = []

        // 1. Age expiry.
        let cutoff = now.addingTimeInterval(-policy.targetDuration)
        let expired = kept.filter { $0.kind == .media && $0.endTime <= cutoff && !protected.contains($0.id) }
        if !expired.isEmpty {
            let expiredIDs = Set(expired.map(\.id))
            kept.removeAll { expiredIDs.contains($0.id) }
            deleting.append(contentsOf: expired)
        }

        // 2. Pressure: byte cap and free-space floor.
        var freed = expired.totalBytes
        func overCap() -> Bool {
            if let cap = policy.maxBufferBytes, kept.totalBytes > cap { return true }
            if let available = availableBytes, available + freed < policy.minimumFreeBytes { return true }
            return false
        }
        while overCap() {
            guard let index = kept.firstIndex(where: { $0.kind == .media && !protected.contains($0.id) }) else { break }
            let victim = kept.remove(at: index)
            deleting.append(victim)
            freed += victim.byteCount
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
        }

        let critical: Bool
        if let available = availableBytes {
            critical = available + freed < policy.minimumFreeBytes
        } else {
            critical = false
        }
        return RetentionPlan(delete: deleting, retain: kept, isStorageCritical: critical)
    }
}
