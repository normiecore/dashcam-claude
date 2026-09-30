import Foundation

/// Glue between the capture layer, the segment store, the incident manager and the retention planner.
/// The capture layer calls `ingest` once per finished segment; everything else happens here.
public actor RollingBufferManager {
    public var policy: RetentionPolicy
    public private(set) var activeRun: RunID?
    public private(set) var lastPlan: RetentionPlan?
    public private(set) var lastStorageStatus: StorageStatus?

    private let store: SegmentStore
    private let incidents: IncidentManager
    private let clock: WallClock
    private let logger: DashcamLogger

    public init(store: SegmentStore, incidents: IncidentManager, policy: RetentionPolicy = RetentionPolicy(), clock: WallClock = SystemWallClock(), logger: DashcamLogger = .disabled) {
        self.store = store
        self.incidents = incidents
        self.policy = policy
        self.clock = clock
        self.logger = logger
    }

    public var storeURL: URL { store.rootURL }

    public func setPolicy(_ policy: RetentionPolicy) {
        self.policy = policy
    }

    /// Prepares the directory for a new writer run.
    public func beginRun(_ run: RunID) async throws {
        try await store.prepareRun(run)
        activeRun = run
        logger.info(.buffer, "Run \(run) began")
    }

    /// Ends the active run; collecting incidents are closed with the footage they have.
    public func endRun() async throws {
        if let run = activeRun { logger.info(.buffer, "Run \(run) ended") }
        activeRun = nil
        try await incidents.recordingDidStop()
    }

    /// Indexes a finished segment, offers it to open incidents, then enforces retention.
    @discardableResult
    public func ingest(_ segment: Segment) async throws -> RetentionPlan {
        try await store.add(segment)
        try await incidents.segmentDidFinalize(segment)
        return try await enforceRetention()
    }

    @discardableResult
    public func enforceRetention() async throws -> RetentionPlan {
        let segments = await store.segments()
        let protected = await incidents.protectedSegmentIDs()
        let shared = await incidents.sharedStorageSegmentIDs()
        let available: Int64? = try? await store.availableCapacity()
        let plan = RollingBufferPlanner.plan(
            segments: segments,
            protected: protected,
            activeRun: activeRun,
            now: clock.now(),
            policy: policy,
            availableBytes: available,
            sharedStorage: shared
        )
        for segment in plan.delete {
            do {
                try await store.remove(segment.id)
            } catch {
                logger.error(.buffer, "Failed to delete \(segment.relativePath): \(error)")
            }
        }
        if !plan.delete.isEmpty {
            logger.debug(.buffer, "Retention deleted \(plan.delete.count) segment(s), \(plan.deletedBytes / 1024) KiB; retaining \(plan.retain.count)")
        }
        if plan.isStorageCritical {
            logger.warning(.storage, "Free space below floor even after retention")
        }
        lastPlan = plan
        if let available {
            lastStorageStatus = StorageStatus.evaluate(
                availableBytes: available + plan.reclaimedBytes,
                bufferBytes: plan.retainedBytes,
                incidentBytes: 0,
                policy: policy
            )
        }
        return plan
    }

    public func segments() async -> [Segment] {
        await store.segments()
    }

    /// Footage currently held in the buffer (media only).
    public func bufferedDuration() async -> TimeInterval {
        await store.segments().mediaDuration
    }
}
