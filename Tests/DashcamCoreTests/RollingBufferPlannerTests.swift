import Foundation
import Testing
@testable import DashcamCore

@Suite("Rolling buffer planner")
struct RollingBufferPlannerTests {
    let run = RunID(rawValue: "run-a")
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let policy = RetentionPolicy(targetDuration: 300, maxBufferBytes: nil, minimumFreeBytes: 0)

    /// Segments of 4 s laid back-to-back ending at `now`, oldest first.
    func backToBack(count: Int, duration: TimeInterval = 4, bytes: Int64 = 1_000) -> [Segment] {
        (0..<count).map { i in
            makeSegment(run: run, sequence: i + 1, start: now.addingTimeInterval(-duration * Double(count - i)), duration: duration, bytes: bytes)
        }
    }

    @Test("Segments that ended before the window are expired, newer ones kept")
    func expiresByAge() {
        let segments = backToBack(count: 100) // 400 s of footage
        let plan = RollingBufferPlanner.plan(segments: segments, protected: [], activeRun: run, now: now, policy: policy, availableBytes: nil)
        #expect(plan.delete.count == 25)
        #expect(plan.retain.count == 75)
        #expect(plan.delete.allSatisfy { $0.endTime <= now.addingTimeInterval(-300) })
        #expect(plan.retain.mediaDuration == 300)
        #expect(!plan.isStorageCritical)
    }

    @Test("A segment straddling the cutoff is kept")
    func straddlingSegmentKept() {
        let s = makeSegment(run: run, sequence: 1, start: now.addingTimeInterval(-302), duration: 4)
        let plan = RollingBufferPlanner.plan(segments: [s], protected: [], activeRun: run, now: now, policy: policy, availableBytes: nil)
        #expect(plan.delete.isEmpty)
    }

    @Test("Protected segments are never expired")
    func protectedNotExpired() {
        let segments = backToBack(count: 100)
        let protected = Set(segments.prefix(10).map(\.id))
        let plan = RollingBufferPlanner.plan(segments: segments, protected: protected, activeRun: run, now: now, policy: policy, availableBytes: nil)
        #expect(plan.delete.count == 15)
        #expect(plan.delete.allSatisfy { !protected.contains($0.id) })
    }

    @Test("Byte cap deletes oldest unprotected segments first")
    func byteCap() {
        let segments = backToBack(count: 10, bytes: 100)
        var capped = policy
        capped.maxBufferBytes = 450
        let plan = RollingBufferPlanner.plan(segments: segments, protected: [segments[0].id], activeRun: run, now: now, policy: capped, availableBytes: nil)
        // 10 x 100 bytes = 1000; need <= 450 -> delete 6; oldest (seq 1) is protected, so seq 2...7 go.
        #expect(plan.delete.map(\.id.sequence) == [2, 3, 4, 5, 6, 7])
        #expect(plan.retainedBytes == 400)
    }

    @Test("Free-space floor deletes until satisfied and flags critical when it cannot be")
    func freeSpaceFloor() {
        let segments = backToBack(count: 10, bytes: 100)
        var floor = policy
        floor.minimumFreeBytes = 1_000
        let satisfiable = RollingBufferPlanner.plan(segments: segments, protected: [], activeRun: run, now: now, policy: floor, availableBytes: 700)
        #expect(satisfiable.delete.count == 3)
        #expect(!satisfiable.isStorageCritical)

        // Deleting everything frees exactly 1000 bytes, which meets the floor: not critical.
        let exact = RollingBufferPlanner.plan(segments: segments, protected: [], activeRun: run, now: now, policy: floor, availableBytes: 0)
        #expect(exact.delete.count == 10)
        #expect(!exact.isStorageCritical)

        // Protected footage that cannot be deleted leaves the floor unreachable: critical.
        let hopeless = RollingBufferPlanner.plan(segments: segments, protected: Set(segments.suffix(5).map(\.id)), activeRun: run, now: now, policy: floor, availableBytes: 0)
        #expect(hopeless.delete.count == 5)
        #expect(hopeless.isStorageCritical)
    }

    @Test("Segments hard-linked into an incident are deleted but not credited as freed space")
    func sharedStorageNotCredited() {
        let segments = backToBack(count: 10, bytes: 100)
        var floor = policy
        floor.minimumFreeBytes = 1_000
        // Every segment's bytes are also held by an incident's link: deleting the buffer copies frees nothing.
        let shared = Set(segments.map(\.id))
        let plan = RollingBufferPlanner.plan(segments: segments, protected: [], activeRun: run, now: now, policy: floor, availableBytes: 500, sharedStorage: shared)
        #expect(plan.delete.count == 10, "buffer copies may still be deleted")
        #expect(plan.reclaimedBytes == 0)
        #expect(plan.isStorageCritical, "the floor is still unmet because nothing was really freed")

        // Half shared: only the unshared half counts, so the floor is met after deleting all of them.
        let halfShared = Set(segments.prefix(5).map(\.id))
        let mixed = RollingBufferPlanner.plan(segments: segments, protected: [], activeRun: run, now: now, policy: floor, availableBytes: 500, sharedStorage: halfShared)
        #expect(mixed.reclaimedBytes == 500)
        #expect(!mixed.isStorageCritical)
        #expect(mixed.deletedBytes == 1_000)
    }

    @Test("Initialization segment is removed only when its run has no media and is inactive")
    func initializationSegmentLifecycle() {
        let oldRun = RunID(rawValue: "run-old")
        let oldInit = makeSegment(run: oldRun, sequence: 0, start: now.addingTimeInterval(-1_000), duration: 0, kind: .initialization)
        let oldMedia = makeSegment(run: oldRun, sequence: 1, start: now.addingTimeInterval(-1_000), duration: 4)
        let activeInit = makeSegment(run: run, sequence: 0, start: now, duration: 0, kind: .initialization)

        let plan = RollingBufferPlanner.plan(segments: [oldInit, oldMedia, activeInit], protected: [], activeRun: run, now: now, policy: policy, availableBytes: nil)
        #expect(Set(plan.delete.map(\.id)) == Set([oldInit.id, oldMedia.id]))
        #expect(plan.retain == [activeInit])

        // Same, but the old run's media is protected: its init must survive too.
        let protectedPlan = RollingBufferPlanner.plan(segments: [oldInit, oldMedia, activeInit], protected: [oldMedia.id], activeRun: run, now: now, policy: policy, availableBytes: nil)
        #expect(protectedPlan.delete.isEmpty)
    }

    @Test("Planner is deterministic and order independent")
    func deterministic() {
        let segments = backToBack(count: 50)
        let a = RollingBufferPlanner.plan(segments: segments, protected: [], activeRun: run, now: now, policy: policy, availableBytes: nil)
        let b = RollingBufferPlanner.plan(segments: segments.shuffled(), protected: [], activeRun: run, now: now, policy: policy, availableBytes: nil)
        #expect(a == b)
    }

    @Test("Overlap is half-open")
    func overlapSemantics() {
        let s = makeSegment(run: run, sequence: 1, start: now, duration: 4)
        #expect(s.overlaps(start: now.addingTimeInterval(-10), end: now.addingTimeInterval(1)))
        #expect(!s.overlaps(start: now.addingTimeInterval(4), end: now.addingTimeInterval(10)))
        #expect(!s.overlaps(start: now.addingTimeInterval(-10), end: now))
        #expect(s.overlaps(start: now.addingTimeInterval(3.999), end: now.addingTimeInterval(10)))
        let initSegment = makeSegment(run: run, sequence: 0, start: now, duration: 0, kind: .initialization)
        #expect(!initSegment.overlaps(start: now.addingTimeInterval(-1), end: now.addingTimeInterval(1)))
    }
}
