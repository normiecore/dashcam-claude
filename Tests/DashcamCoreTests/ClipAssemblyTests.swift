import Foundation
import Testing
@testable import DashcamCore

@Suite("Clip assembly")
struct ClipAssemblyTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("Planner groups by run, orders chronologically and drops runs without media")
    func planner() {
        let runA = RunID(rawValue: "a"), runB = RunID(rawValue: "b"), runC = RunID(rawValue: "c")
        let parts: [(segment: Segment, url: URL)] = [
            (makeSegment(run: runB, sequence: 1, start: base.addingTimeInterval(100)), URL(fileURLWithPath: "/b/1")),
            (makeSegment(run: runA, sequence: 2, start: base.addingTimeInterval(4)), URL(fileURLWithPath: "/a/2")),
            (makeSegment(run: runA, sequence: 0, start: base, duration: 0, kind: .initialization), URL(fileURLWithPath: "/a/init")),
            (makeSegment(run: runA, sequence: 1, start: base), URL(fileURLWithPath: "/a/1")),
            (makeSegment(run: runB, sequence: 0, start: base.addingTimeInterval(100), duration: 0, kind: .initialization), URL(fileURLWithPath: "/b/init")),
            (makeSegment(run: runC, sequence: 0, start: base.addingTimeInterval(200), duration: 0, kind: .initialization), URL(fileURLWithPath: "/c/init")),
        ]
        let plan = ClipAssemblyPlanner.plan(parts: parts)
        #expect(plan.groups.count == 2)
        #expect(plan.groups[0].run == runA)
        #expect(plan.groups[0].initialization?.path == "/a/init")
        #expect(plan.groups[0].media.map(\.path) == ["/a/1", "/a/2"])
        #expect(plan.groups[0].duration == 8)
        #expect(plan.groups[1].run == runB)
        #expect(!plan.isEmpty)
        #expect(ClipAssemblyPlanner.plan(parts: []).isEmpty)
    }

    @Test("Concatenation is byte exact and atomic; missing init fails")
    func concatenation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let initURL = dir.appendingPathComponent("init.mp4"), m1 = dir.appendingPathComponent("1.m4s"), m2 = dir.appendingPathComponent("2.m4s")
        try Data([0xF, 0xA, 0xC, 0xE]).write(to: initURL)
        try Data(repeating: 1, count: 100_000).write(to: m1)
        try Data(repeating: 2, count: 50_000).write(to: m2)
        let run = RunID(rawValue: "r")
        let plan = ClipAssemblyPlan(groups: [.init(run: run, initialization: initURL, media: [m1, m2], startTime: base, duration: 8)])
        let outputs = try await FMP4ClipAssembler().assemble(plan, into: dir, baseName: "clip")
        #expect(outputs == ["clip.mp4"])
        let data = try Data(contentsOf: dir.appendingPathComponent("clip.mp4"))
        #expect(data.count == 150_004)
        #expect(data.prefix(4) == Data([0xF, 0xA, 0xC, 0xE]))
        #expect(data[4] == 1 && data[100_003] == 1 && data[100_004] == 2)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".clip.mp4.partial").path))

        let noInit = ClipAssemblyPlan(groups: [.init(run: run, initialization: nil, media: [m1], startTime: base, duration: 4)])
        await #expect(throws: DashcamCoreError.missingInitializationSegment(run)) {
            try await FMP4ClipAssembler().assemble(noInit, into: dir, baseName: "x")
        }
        await #expect(throws: DashcamCoreError.emptyAssemblyPlan) {
            try await FMP4ClipAssembler().assemble(ClipAssemblyPlan(groups: []), into: dir, baseName: "x")
        }
    }
}
