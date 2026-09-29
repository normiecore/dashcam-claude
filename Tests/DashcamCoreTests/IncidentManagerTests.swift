import Foundation
import Testing
@testable import DashcamCore

@Suite("Incident manager")
struct IncidentManagerTests {
    /// Produces `count` back-to-back segments through the buffer manager.
    func fill(_ env: BufferTestEnvironment, run: RunID, from sequence: Int, count: Int) async throws -> [Segment] {
        var out: [Segment] = []
        for i in 0..<count {
            out.append(try await env.produceSegment(run: run, sequence: sequence + i))
        }
        return out
    }

    @Test("Trigger links the pre-roll footage plus the run's initialization segment")
    func triggerAttachesPreRoll() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 20, postRoll: 8))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        let initSegment = try await env.writeInitialization(run: run)
        let produced = try await fill(env, run: run, from: 1, count: 10) // 40 s

        let incident = try await env.incidents.trigger(source: .manual)
        #expect(incident.state == .collecting)
        #expect(incident.primarySource == .manual)
        // Window is [now-20, now+8]; segments 6...10 (last 20 s) overlap.
        let attached = incident.mediaParts.map(\.segment.id.sequence)
        #expect(attached == [6, 7, 8, 9, 10])
        #expect(incident.parts.first?.segment.id == initSegment.id)
        #expect(incident.parts.allSatisfy { $0.linkedRelativePath != nil })
        for part in incident.parts {
            #expect(FileManager.default.fileExists(atPath: env.incidents.url(for: part, of: incident.id).path))
        }
        _ = produced
        // Manifest persisted.
        let manifest = env.incidents.directory(for: incident.id).appendingPathComponent(IncidentManager.manifestName)
        #expect(FileManager.default.fileExists(atPath: manifest.path))
    }

    @Test("Post-roll segments are attached until the window is covered, then the incident is ready")
    func postRollCollection() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 10, postRoll: 10))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 5)

        let opened = try await env.incidents.trigger(source: .developerSimulation)
        // Two more segments (8 s) are not enough for a 10 s post-roll.
        _ = try await fill(env, run: run, from: 6, count: 2)
        var current = await env.incidents.incident(opened.id)!
        #expect(current.state == .collecting)
        #expect(current.mediaParts.map(\.segment.id.sequence) == [3, 4, 5, 6, 7])

        // Third segment ends at +12 s, covering the window end.
        _ = try await fill(env, run: run, from: 8, count: 1)
        current = await env.incidents.incident(opened.id)!
        #expect(current.state == .readyToAssemble)
        #expect(current.mediaParts.map(\.segment.id.sequence) == [3, 4, 5, 6, 7, 8])
        #expect(current.coveredStart! <= opened.windowStart)
        #expect(current.coveredEnd! >= opened.windowEnd)

        // Later segments are ignored by the closed incident.
        _ = try await fill(env, run: run, from: 9, count: 2)
        current = await env.incidents.incident(opened.id)!
        #expect(current.mediaParts.count == 6)
    }

    @Test("Linked footage survives buffer retention deleting the original")
    func linkedFootageSurvivesRetention() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 12, minimumFreeBytes: 0), incidentPolicy: IncidentPolicy(preRoll: 8, postRoll: 4))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 3)
        let incident = try await env.incidents.trigger(source: .manual)
        _ = try await fill(env, run: run, from: 4, count: 10) // pushes everything pre-trigger out of the buffer

        let remaining = await env.store.segments().filter { $0.kind == .media }.map(\.id.sequence)
        #expect(!remaining.contains(2))
        let final = await env.incidents.incident(incident.id)!
        #expect(final.state == .readyToAssemble)
        for part in final.parts {
            let url = env.incidents.url(for: part, of: incident.id)
            #expect(FileManager.default.fileExists(atPath: url.path), "\(part.segment.relativePath) should still exist")
            if part.segment.kind == .media {
                let data = try Data(contentsOf: url)
                #expect(data == BufferTestEnvironment.payload(sequence: part.segment.id.sequence, bytes: 4_096))
            }
        }
    }

    @Test("A second trigger during collection extends the same incident")
    func mergeTriggers() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 10, postRoll: 10))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 3)
        let first = try await env.incidents.trigger(source: .manual)
        _ = try await fill(env, run: run, from: 4, count: 1)
        let second = try await env.incidents.trigger(source: .motionHeuristic, note: "impact 4.2g")
        #expect(second.id == first.id)
        #expect(second.triggers.count == 2)
        #expect(second.windowEnd.timeIntervalSince(first.windowEnd) == 4)
        let all = await env.incidents.allIncidents()
        #expect(all.count == 1)
    }

    @Test("With merging disabled, overlapping triggers create separate incidents sharing footage")
    func separateIncidents() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 10, postRoll: 10, mergeOverlappingTriggers: false))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 3)
        let a = try await env.incidents.trigger(source: .manual)
        let b = try await env.incidents.trigger(source: .appleCrashDetection)
        #expect(a.id != b.id)
        #expect(a.mediaParts.map(\.segment.id) == b.mediaParts.map(\.segment.id))
    }

    @Test("Recording stop closes collecting incidents with the footage they have")
    func recordingStop() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 10, postRoll: 60))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 3)
        let incident = try await env.incidents.trigger(source: .manual)
        _ = try await fill(env, run: run, from: 4, count: 1)
        try await env.buffer.endRun()
        let closed = await env.incidents.incident(incident.id)!
        #expect(closed.state == .readyToAssemble)
        #expect(closed.mediaParts.count == 4)
    }

    @Test("Trigger with an empty buffer then stop yields a failed incident, not a crash")
    func emptyBuffer() async throws {
        let env = try BufferTestEnvironment()
        try await env.load()
        let incident = try await env.incidents.trigger(source: .manual)
        #expect(incident.parts.isEmpty)
        try await env.incidents.recordingDidStop()
        let closed = await env.incidents.incident(incident.id)!
        #expect(closed.state == .failed)
        #expect(closed.failureReason != nil)
    }

    @Test("Incidents interrupted by an app crash are recovered as ready to assemble")
    func crashRecovery() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 10, postRoll: 600))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 3)
        let incident = try await env.incidents.trigger(source: .manual)
        #expect(incident.state == .collecting)

        // Simulate relaunch: a fresh manager over the same directories.
        let relaunched = IncidentManager(rootURL: env.incidents.rootURL, store: env.store, fileSystem: env.fs, clock: env.clock)
        let recovered = try await relaunched.load()
        #expect(recovered.count == 1)
        #expect(recovered[0].id == incident.id)
        #expect(recovered[0].state == .readyToAssemble)
        #expect(recovered[0].parts.count == incident.parts.count)
    }

    @Test("When linking fails the buffer copy is protected from retention until the incident finishes")
    func linkFailureFallsBackToProtection() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 8, minimumFreeBytes: 0), incidentPolicy: IncidentPolicy(preRoll: 8, postRoll: 4))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 2)
        env.fs.failLinks = true
        let incident = try await env.incidents.trigger(source: .manual)
        #expect(incident.parts.allSatisfy { $0.linkedRelativePath == nil })
        let protected = await env.incidents.protectedSegmentIDs()
        #expect(protected == Set(incident.parts.map(\.segment.id)))

        _ = try await fill(env, run: run, from: 3, count: 6) // would normally expire segments 1-2
        let stillThere = await env.store.segments().map(\.id.sequence)
        #expect(stillThere.contains(1) && stillThere.contains(2))

        // Assemble: reads from buffer copies, then the protection lifts.
        env.fs.failLinks = false
        let done = try await env.incidents.assemble(incident.id, using: FMP4ClipAssembler())
        #expect(done.state == .complete)
        let protectedAfter = await env.incidents.protectedSegmentIDs()
        #expect(protectedAfter.isEmpty)
        try await env.buffer.enforceRetention()
        let afterRetention = await env.store.segments().map(\.id.sequence)
        #expect(!afterRetention.contains(1))
    }

    @Test("Assembly concatenates init + media in order and releases parts")
    func assembly() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 8, postRoll: 4))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run, bytes: 16)
        _ = try await fill(env, run: run, from: 1, count: 2)
        let incident = try await env.incidents.trigger(source: .manual)
        _ = try await fill(env, run: run, from: 3, count: 1)
        let ready = await env.incidents.incident(incident.id)!
        #expect(ready.state == .readyToAssemble)

        let done = try await env.incidents.assemble(incident.id, using: FMP4ClipAssembler())
        #expect(done.state == .complete)
        #expect(done.clipRelativePaths.count == 1)
        let clip = env.incidents.clipURLs(for: done)[0]
        let data = try Data(contentsOf: clip)
        var expected = Data(repeating: 0xAA, count: 16)
        for seq in 1...3 { expected.append(BufferTestEnvironment.payload(sequence: seq, bytes: 4_096)) }
        #expect(data == expected)
        #expect(!FileManager.default.fileExists(atPath: env.incidents.partsDirectory(for: done.id).path))

        // Re-assembling a complete incident is rejected.
        await #expect(throws: DashcamCoreError.self) {
            try await env.incidents.assemble(incident.id, using: FMP4ClipAssembler())
        }
        try await env.incidents.delete(incident.id)
        let remaining = await env.incidents.allIncidents()
        #expect(remaining.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: env.incidents.directory(for: incident.id).path))
    }

    @Test("Footage spanning two runs assembles into two clips")
    func twoRuns() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 8, postRoll: 4))
        try await env.load()
        let runA = RunID(rawValue: "run-a")
        try await env.buffer.beginRun(runA)
        try await env.writeInitialization(run: runA, bytes: 8)
        _ = try await fill(env, run: runA, from: 1, count: 2)
        let incident = try await env.incidents.trigger(source: .manual)
        // Interruption: new run.
        let runB = RunID(rawValue: "run-b")
        try await env.buffer.beginRun(runB)
        try await env.writeInitialization(run: runB, bytes: 8)
        _ = try await fill(env, run: runB, from: 1, count: 1)
        let done = try await env.incidents.assemble(incident.id, using: FMP4ClipAssembler())
        #expect(done.clipRelativePaths.count == 2)
        #expect(done.clipRelativePaths[0].hasSuffix("-part1.mp4"))
        #expect(done.clipRelativePaths[1].hasSuffix("-part2.mp4"))
    }

    @Test("A delayed crash event protects footage retroactively and needs no post-roll")
    func retroactiveTrigger() async throws {
        let env = try BufferTestEnvironment(retention: RetentionPolicy(targetDuration: 600, minimumFreeBytes: 0), incidentPolicy: IncidentPolicy(preRoll: 8, postRoll: 8))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 20) // 80 s of footage
        let eventTime = env.clock.now().addingTimeInterval(-40)
        let incident = try await env.incidents.trigger(source: .appleCrashDetection, occurredAt: eventTime)
        #expect(incident.state == .readyToAssemble)
        #expect(incident.triggerTime == eventTime)
        // Window [-48, -32] relative to now: segments 9 through 12 (each 4 s, 20 segments ending at now).
        #expect(incident.mediaParts.map(\.segment.id.sequence) == [9, 10, 11, 12])

        // A retroactive event with no footage fails cleanly.
        let ancient = try await env.incidents.trigger(source: .appleCrashDetection, occurredAt: env.clock.now().addingTimeInterval(-3_600))
        #expect(ancient.state == .failed)

        // A future-dated event is clamped to now and collects like a live trigger.
        let future = try await env.incidents.trigger(source: .developerSimulation, occurredAt: env.clock.now().addingTimeInterval(60))
        #expect(future.state == .collecting)
        #expect(future.triggerTime == env.clock.now())
    }

    @Test("Events are published for the UI layer")
    func events() async throws {
        let env = try BufferTestEnvironment(incidentPolicy: IncidentPolicy(preRoll: 4, postRoll: 4))
        try await env.load()
        let run = RunID.make(at: env.clock.now())
        try await env.buffer.beginRun(run)
        try await env.writeInitialization(run: run)
        _ = try await fill(env, run: run, from: 1, count: 1)
        let opened = try await env.incidents.trigger(source: .manual)
        _ = try await fill(env, run: run, from: 2, count: 1)
        var iterator = env.incidents.events.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        #expect(first == .triggered(opened))
        if case .readyToAssemble(let incident)? = second {
            #expect(incident.id == opened.id)
        } else {
            Issue.record("Expected readyToAssemble, got \(String(describing: second))")
        }
    }
}
