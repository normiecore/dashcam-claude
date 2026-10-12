import Foundation
import Testing
@testable import DashcamCore

@Suite("Saved drives")
struct SavedDriveTests {
    @Test("A stopped drive stays available after an hour and can be saved and assembled")
    func delayedSaveAfterIdle() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 12, minimumFreeBytes: 0))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        let initialization = try await env.writeInitialization(run: run, bytes: 16)
        for sequence in 1...4 { try await env.produceSegment(run: run, sequence: sequence) }
        try await env.buffer.endRun()
        let recordedEnd = env.clock.now()
        env.clock.advance(by: 3_600)
        try await env.load()
        let plan = try await env.buffer.enforceRetention()
        #expect(plan.delete.isEmpty)

        let saved = try await env.incidents.saveRecordedRun(run)
        #expect(saved.state == .readyToAssemble)
        #expect(saved.mediaParts.map(\.segment.id.sequence) == [2, 3, 4])
        #expect(saved.parts.first?.segment.id == initialization.id)
        #expect(saved.windowStart == recordedEnd.addingTimeInterval(-12))
        #expect(saved.windowEnd == recordedEnd)
        #expect(saved.triggerTime == recordedEnd)
        #expect(saved.createdAt == env.clock.now())
        #expect(saved.triggers.first?.note == "Saved drive")
        let completed = try await env.incidents.assemble(saved.id, using: FMP4ClipAssembler())
        #expect(completed.state == .complete)
        let bytes = try Data(contentsOf: env.incidents.clipURLs(for: completed)[0])
        var expected = Data(repeating: 0xAA, count: 16)
        for sequence in 2...4 { expected.append(BufferTestEnvironment.payload(sequence: sequence, bytes: 4_096)) }
        #expect(bytes == expected)
    }

    @Test("Saving a drive isolates its run and cannot merge or extend a live incident")
    func immutableRunSnapshot() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 20, postRoll: 60))
        try await env.load()
        let runA = RunID(rawValue: "run-a")
        try await env.buffer.beginRun(runA)
        try await env.writeInitialization(run: runA)
        try await env.produceSegment(run: runA, sequence: 1)
        let live = try await env.incidents.trigger(source: .motionHeuristic)
        let saved = try await env.incidents.saveRecordedRun(runA)
        #expect(saved.id != live.id)
        #expect(saved.primarySource == .manual)
        let runB = RunID(rawValue: "run-b")
        try await env.buffer.beginRun(runB)
        try await env.writeInitialization(run: runB)
        try await env.produceSegment(run: runB, sequence: 1)
        let unchanged = await env.incidents.incident(saved.id)
        #expect(unchanged == saved)
        #expect(saved.parts.allSatisfy { $0.segment.id.run == runA })
    }

    @Test("An empty drive fails without leaving a phantom library item")
    func emptyRun() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        await #expect(throws: DashcamCoreError.self) {
            try await env.incidents.saveRecordedRun(RunID(rawValue: "missing"))
        }
        let all = await env.incidents.allIncidents()
        #expect(all.isEmpty)
    }

    @Test("Saved drives exclude incomplete media")
    func incompleteMediaIsNotPresentedAsSavedFootage() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let run = RunID(rawValue: "partial")
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        let complete = try await env.produceSegment(run: run, sequence: 1)
        let partial = try await env.produceSegment(run: run, sequence: 2, ingest: false)
        try await env.store.add(Segment(id: partial.id, kind: partial.kind, startTime: partial.startTime,
                                        duration: partial.duration, byteCount: partial.byteCount,
                                        relativePath: partial.relativePath, isComplete: false))
        let saved = try await env.incidents.saveRecordedRun(run)
        #expect(saved.mediaParts.map(\.segment.id) == [complete.id])
        #expect(saved.windowEnd == complete.endTime)
    }

    @Test("Saving with failed hard links protects originals until assembly")
    func failedLinksRemainProtected() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 4, minimumFreeBytes: 0))
        try await env.load()
        let run = RunID(rawValue: "protected")
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        try await env.produceSegment(run: run, sequence: 1)
        env.fs.failLinks = true
        let saved = try await env.incidents.saveRecordedRun(run)
        let protected = await env.incidents.protectedSegmentIDs()
        #expect(protected == Set(saved.segmentIDs))
        try await env.produceSegment(run: run, sequence: 2)
        let segments = await env.store.segments()
        #expect(segments.contains { $0.id.run == run && $0.id.sequence == 1 })
    }

    @Test("Idle history still obeys the storage cap")
    func idleStoragePressure() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 12, minimumFreeBytes: 0))
        try await env.load()
        let run = RunID(rawValue: "idle-pressure")
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        for sequence in 1...3 { try await env.produceSegment(run: run, sequence: sequence) }
        try await env.buffer.endRun()
        env.clock.advance(by: 3_600)
        await env.buffer.setPolicy(RetentionPolicy(targetDuration: 12, maxBufferBytes: 4_608, minimumFreeBytes: 0))
        let plan = try await env.buffer.enforceRetention()
        #expect(plan.delete.filter { $0.kind == .media }.map(\.id.sequence) == [1, 2])
        #expect(plan.retain.filter { $0.kind == .media }.map(\.id.sequence) == [3])
    }
}
