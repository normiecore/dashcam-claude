import Foundation
import Testing
@testable import DashcamCore

@Suite("Segment store")
struct SegmentStoreTests {
    @Test("Add writes a sidecar and load rebuilds the same index")
    func persistence() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        let initSegment = try await env.writeInitialization(run: run)
        let s1 = try await env.produceSegment(run: run, sequence: 1, ingest: false)
        let s2 = try await env.produceSegment(run: run, sequence: 2, ingest: false)

        #expect(FileManager.default.fileExists(atPath: env.store.sidecarURL(for: s1).path))

        let reloaded = SegmentStore(rootURL: env.store.rootURL, fileSystem: env.fs)
        let report = try await reloaded.load()
        #expect(report.indexed == 3)
        #expect(report.orphanFilesRemoved == 0)
        let segments = await reloaded.segments()
        #expect(segments.map(\.id) == [initSegment.id, s1.id, s2.id])
        #expect(approximatelyEqual(segments[1].startTime, s1.startTime))
        #expect(segments[2].duration == env.segmentDuration)
    }

    @Test("Load removes orphan files, dangling sidecars and corrupt sidecars")
    func reconcile() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        let good = try await env.produceSegment(run: run, sequence: 1, ingest: false)
        let runDir = await env.store.directory(for: run)

        // Orphan media file without sidecar (writer died mid-segment).
        try Data([1, 2, 3]).write(to: runDir.appendingPathComponent("000002.m4s"))
        // Sidecar whose media file vanished.
        let ghost = makeSegment(run: run, sequence: 3, start: env.clock.now())
        try SegmentStore.makeEncoder().encode(ghost).write(to: runDir.appendingPathComponent("000003.json"))
        // Corrupt sidecar.
        try Data("not json".utf8).write(to: runDir.appendingPathComponent("000004.json"))
        // Empty run directory.
        try FileManager.default.createDirectory(at: env.store.rootURL.appendingPathComponent("run-empty"), withIntermediateDirectories: true)

        let reloaded = SegmentStore(rootURL: env.store.rootURL, fileSystem: env.fs)
        let report = try await reloaded.load()
        #expect(report.indexed == 1)
        #expect(report.orphanFilesRemoved == 1)
        #expect(report.missingFilesDropped == 1)
        #expect(report.corruptSidecarsRemoved == 1)
        #expect(report.emptyRunsRemoved == 1)
        let segments = await reloaded.segments()
        #expect(segments.map(\.id) == [good.id])
        #expect(!FileManager.default.fileExists(atPath: runDir.appendingPathComponent("000002.m4s").path))
        #expect(!FileManager.default.fileExists(atPath: env.store.rootURL.appendingPathComponent("run-empty").path))
    }

    @Test("Remove deletes media, sidecar and the empty run directory")
    func remove() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        let s1 = try await env.produceSegment(run: run, sequence: 1, ingest: false)
        try await env.store.remove(s1.id)
        #expect(!FileManager.default.fileExists(atPath: env.store.url(for: s1).path))
        #expect(!FileManager.default.fileExists(atPath: env.store.sidecarURL(for: s1).path))
        let runDirExists = await env.store.directory(for: run)
        #expect(!FileManager.default.fileExists(atPath: runDirExists.path))
        let count = await env.store.count
        #expect(count == 0)
    }

    @Test("Adding a segment whose file is missing fails")
    func addMissingFile() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let ghost = makeSegment(sequence: 1, start: env.clock.now())
        await #expect(throws: DashcamCoreError.self) {
            try await env.store.add(ghost)
        }
    }

    @Test("Available capacity is reported")
    func capacity() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let available = try await env.store.availableCapacity()
        #expect(available > 0)
        env.fs.availableCapacityOverride = 42
        let overridden = try await env.store.availableCapacity()
        #expect(overridden == 42)
    }
}
