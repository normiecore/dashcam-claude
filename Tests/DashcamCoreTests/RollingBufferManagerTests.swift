import Foundation
import Testing
@testable import DashcamCore

@Suite("Rolling buffer manager")
struct RollingBufferManagerTests {
    @Test("Simulated long drive keeps the buffer at the target duration with files matching the index")
    func longDrive() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 300, minimumFreeBytes: 0))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        let segmentsPerHour = Int(3600 / env.segmentDuration)
        var maxBuffered: TimeInterval = 0
        var minBufferedAfterWarmup: TimeInterval = .infinity
        for sequence in 1...(segmentsPerHour * 2) { // two simulated hours
            try await env.produceSegment(run: run, sequence: sequence, bytes: 1_024)
            let buffered = await env.buffer.bufferedDuration()
            maxBuffered = max(maxBuffered, buffered)
            if sequence > 100 { minBufferedAfterWarmup = min(minBufferedAfterWarmup, buffered) }
        }
        #expect(maxBuffered <= 300 + env.segmentDuration)
        #expect(minBufferedAfterWarmup >= 300 - env.segmentDuration)
        let indexed = await env.store.segments()
        let files = try env.mediaFilesOnDisk()
        #expect(files.count == indexed.count)
        #expect(indexed.filter { $0.kind == .initialization }.count == 1)
    }

    @Test("Incident during a long drive preserves pre- and post-roll while the buffer keeps rolling")
    func incidentDuringDrive() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 300, minimumFreeBytes: 0), incidentPolicy: IncidentPolicy(preRoll: 300, postRoll: 60))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run, bytes: 32)
        for sequence in 1...200 { try await env.produceSegment(run: run, sequence: sequence, bytes: 512) } // 800 s
        let triggerTime = env.clock.now()
        let incident = try await env.incidents.trigger(source: .developerSimulation)
        for sequence in 201...400 { try await env.produceSegment(run: run, sequence: sequence, bytes: 512) }

        let done = try await env.incidents.assemble(incident.id, using: FMP4ClipAssembler())
        #expect(done.state == .complete)
        #expect(done.coveredStart! <= triggerTime.addingTimeInterval(-300 + env.segmentDuration))
        #expect(done.coveredEnd! >= triggerTime.addingTimeInterval(60))
        #expect(abs(done.footageDuration - 360) <= env.segmentDuration)
        let clip = env.incidents.clipURLs(for: done)[0]
        let size = try FileManager.default.attributesOfItem(atPath: clip.path)[.size] as? Int
        #expect(size == 32 + done.mediaParts.count * 512)

        // Buffer itself is still healthy.
        let buffered = await env.buffer.bufferedDuration()
        #expect(buffered <= 300 + env.segmentDuration)
        let plan = await env.buffer.lastPlan
        #expect(plan?.isStorageCritical == false)
    }

    @Test("Free-space pressure trims the buffer and reports critical storage")
    func storagePressure() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 300, minimumFreeBytes: 10_000))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        for sequence in 1...10 { try await env.produceSegment(run: run, sequence: sequence, bytes: 1_000) }
        env.fs.availableCapacityOverride = 7_000
        let plan = try await env.buffer.enforceRetention()
        #expect(plan.delete.count == 3)
        #expect(!plan.isStorageCritical)
        let status = await env.buffer.lastStorageStatus
        #expect(status?.level == .low)

        env.fs.availableCapacityOverride = 0
        let critical = try await env.buffer.enforceRetention()
        #expect(critical.isStorageCritical)
        let remaining = await env.store.segments().filter { $0.kind == .media }
        #expect(remaining.isEmpty)
        let criticalStatus = await env.buffer.lastStorageStatus
        #expect(criticalStatus?.level == .critical)
    }

    @Test("A deletion failure is logged and does not stop retention")
    func deletionFailure() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 8, minimumFreeBytes: 0))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        for sequence in 1...3 { try await env.produceSegment(run: run, sequence: sequence) }
        env.fs.failRemovals = true
        try await env.produceSegment(run: run, sequence: 4)
        #expect(env.logSink.entries().contains { $0.level == .error && $0.category == .buffer })
        env.fs.failRemovals = false
        try await env.buffer.enforceRetention()
        let remaining = await env.store.segments().map(\.id.sequence)
        #expect(remaining == [3, 4])
    }

    @Test("Restart: index reloads, old run's init survives while its media is in the window, then expires")
    func restartAcrossRuns() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 20, minimumFreeBytes: 0))
        try await env.load()
        let runA = RunID(rawValue: "run-a")
        try await env.buffer.beginRun(runA)
        try await env.writeInitialization(run: runA)
        for sequence in 1...3 { try await env.produceSegment(run: runA, sequence: sequence) }
        try await env.buffer.endRun()

        // Relaunch over the same directory.
        let env2Store = SegmentStore(rootURL: env.store.rootURL, fileSystem: env.fs)
        let report = try await env2Store.load()
        #expect(report.indexed == 4)
        let incidents2 = IncidentManager(rootURL: env.incidents.rootURL, store: env2Store, fileSystem: env.fs, clock: env.clock)
        let buffer2 = RollingBufferManager(store: env2Store, incidents: incidents2, policy: RetentionPolicy(targetDuration: 20, minimumFreeBytes: 0), clock: env.clock)
        let runB = RunID(rawValue: "run-b")
        try await buffer2.beginRun(runB)
        // Manually write run B's init through the new store.
        let initB = makeSegment(run: runB, sequence: 0, start: env.clock.now(), duration: 0, bytes: 8, kind: .initialization)
        try FileManager.default.createDirectory(at: env2Store.url(for: initB).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8).write(to: env2Store.url(for: initB))
        try await env2Store.add(initB)
        for sequence in 1...3 {
            let start = env.clock.now()
            let s = makeSegment(run: runB, sequence: sequence, start: start, duration: 4, bytes: 8)
            try Data(repeating: 2, count: 8).write(to: env2Store.url(for: s))
            env.clock.advance(by: 4)
            try await buffer2.ingest(s)
        }
        var runs = Set(await env2Store.segments().map(\.id.run))
        #expect(runs == [runA, runB]) // run A's newest media still inside the 20 s window

        for sequence in 4...8 {
            let start = env.clock.now()
            let s = makeSegment(run: runB, sequence: sequence, start: start, duration: 4, bytes: 8)
            try Data(repeating: 2, count: 8).write(to: env2Store.url(for: s))
            env.clock.advance(by: 4)
            try await buffer2.ingest(s)
        }
        runs = Set(await env2Store.segments().map(\.id.run))
        #expect(runs == [runB]) // run A (media and init) fully expired
        let runADir = await env2Store.directory(for: runA)
        #expect(!FileManager.default.fileExists(atPath: runADir.path))
    }
}
