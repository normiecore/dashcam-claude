import Foundation

/// Ordered description of how incident parts combine into playable clips. Parts are grouped by run
/// because footage from different runs (before/after a capture restart) cannot share one fMP4 header.
public struct ClipAssemblyPlan: Sendable, Equatable {
    public struct Group: Sendable, Equatable {
        public let run: RunID
        public let initialization: URL?
        public let media: [URL]
        public let startTime: Date
        public let duration: TimeInterval

        public init(run: RunID, initialization: URL?, media: [URL], startTime: Date, duration: TimeInterval) {
            self.run = run
            self.initialization = initialization
            self.media = media
            self.startTime = startTime
            self.duration = duration
        }
    }

    public let groups: [Group]

    public init(groups: [Group]) { self.groups = groups }

    public var isEmpty: Bool { groups.allSatisfy { $0.media.isEmpty } }
}

public enum ClipAssemblyPlanner {
    public static func plan(parts: [(segment: Segment, url: URL)]) -> ClipAssemblyPlan {
        let byRun = Dictionary(grouping: parts, by: { $0.segment.id.run })
        var groups: [ClipAssemblyPlan.Group] = []
        for (run, runParts) in byRun {
            let sorted = runParts.sorted { $0.segment.chronologicalKey < $1.segment.chronologicalKey }
            let media = sorted.filter { $0.segment.kind == .media }
            guard !media.isEmpty else { continue }
            let initialization = sorted.first { $0.segment.kind == .initialization }?.url
            groups.append(ClipAssemblyPlan.Group(
                run: run,
                initialization: initialization,
                media: media.map(\.url),
                startTime: media[0].segment.startTime,
                duration: media.map(\.segment).mediaDuration
            ))
        }
        groups.sort { $0.startTime < $1.startTime }
        return ClipAssemblyPlan(groups: groups)
    }
}

private extension Segment {
    var chronologicalKey: (TimeInterval, Int, Int) {
        (startTime.timeIntervalSince1970, kind == .initialization ? 0 : 1, id.sequence)
    }
}

/// Turns a plan into clip files inside `outputDirectory`. Returns the relative paths of the files produced.
public protocol ClipAssembler: Sendable {
    func assemble(_ plan: ClipAssemblyPlan, into outputDirectory: URL, baseName: String) async throws -> [String]
}

/// Byte-level concatenation. An fMP4 initialization segment followed by its media segments, in order,
/// is itself a valid fragmented MP4 file, so no re-encoding or AVFoundation is needed to produce a clip.
/// One output file per run.
public struct FMP4ClipAssembler: ClipAssembler {
    public var fileExtension: String

    public init(fileExtension: String = "mp4") {
        self.fileExtension = fileExtension
    }

    public func assemble(_ plan: ClipAssemblyPlan, into outputDirectory: URL, baseName: String) async throws -> [String] {
        guard !plan.isEmpty else { throw DashcamCoreError.emptyAssemblyPlan }
        var outputs: [String] = []
        for (index, group) in plan.groups.enumerated() where !group.media.isEmpty {
            guard let initialization = group.initialization else {
                throw DashcamCoreError.missingInitializationSegment(group.run)
            }
            let name = plan.groups.count == 1 ? "\(baseName).\(fileExtension)" : "\(baseName)-part\(index + 1).\(fileExtension)"
            let destination = outputDirectory.appendingPathComponent(name)
            try FMP4ClipAssembler.concatenate([initialization] + group.media, to: destination)
            outputs.append(name)
        }
        return outputs
    }

    public static func concatenate(_ inputs: [URL], to output: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).partial")
        if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw DashcamCoreError.fileSystem("Could not create \(temporary.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: temporary)
        var closed = false
        defer { if !closed { handle.closeFile() } }
        for input in inputs {
            let data = try Data(contentsOf: input, options: .mappedIfSafe)
            handle.write(data)
        }
        handle.synchronizeFile()
        handle.closeFile()
        closed = true
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.moveItem(at: temporary, to: output)
    }
}
