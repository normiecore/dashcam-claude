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

/// Builds a fragmented MP4 clip from an initialization segment and its media segments. Fragment
/// timestamps are rebased so the clip starts at zero (see `FMP4`). When the inputs are not parseable
/// as fMP4 the segments are concatenated untouched rather than failing: footage first.
/// One output file per run.
public struct FMP4ClipAssembler: ClipAssembler {
    public var fileExtension: String

    public init(fileExtension: String = "mp4") {
        self.fileExtension = fileExtension
    }

    public func assemble(_ plan: ClipAssemblyPlan, into outputDirectory: URL, baseName: String) async throws -> [String] {
        guard !plan.isEmpty else { throw DashcamCoreError.emptyAssemblyPlan }
        var outputs: [String] = []
        let groups = plan.groups.filter { !$0.media.isEmpty }
        for (index, group) in groups.enumerated() {
            guard let initialization = group.initialization else {
                throw DashcamCoreError.missingInitializationSegment(group.run)
            }
            let name = groups.count == 1 ? "\(baseName).\(fileExtension)" : "\(baseName)-part\(index + 1).\(fileExtension)"
            let destination = outputDirectory.appendingPathComponent(name)
            _ = try FMP4ClipAssembler.writeClip(initialization: initialization, mediaSegments: group.media, to: destination)
            outputs.append(name)
        }
        return outputs
    }

    /// Writes `initialization` followed by `mediaSegments` (rebased to start at zero) to `output`
    /// atomically. Returns the rebase plan, or nil if the inputs were concatenated without rebasing.
    @discardableResult
    public static func writeClip(initialization: URL, mediaSegments: [URL], to output: URL) throws -> FMP4.RebasePlan? {
        let plan = FMP4.rebasePlan(initialization: initialization, mediaSegments: mediaSegments)
        try writeConcatenated(to: output) { emit in
            try emit(Data(contentsOf: initialization, options: .mappedIfSafe))
            for url in mediaSegments {
                var data = try Data(contentsOf: url, options: .mappedIfSafe)
                if let plan, let fields = try? FMP4.timeFields(mediaSegment: data) {
                    var copy = Data(data)
                    try FMP4.apply(plan, to: &copy, fields: fields)
                    data = copy
                }
                try emit(data)
            }
        }
        return plan
    }

    /// Plain concatenation with no timestamp rewriting.
    public static func concatenate(_ inputs: [URL], to output: URL) throws {
        try writeConcatenated(to: output) { emit in
            for input in inputs {
                try emit(Data(contentsOf: input, options: .mappedIfSafe))
            }
        }
    }

    private static func writeConcatenated(to output: URL, body: (_ emit: (Data) throws -> Void) throws -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(output.lastPathComponent).partial")
        if fm.fileExists(atPath: temporary.path) { try fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil) else {
            throw DashcamCoreError.fileSystem("Could not create \(temporary.lastPathComponent)")
        }
        // The throwing FileHandle API: the legacy write(_:)/synchronizeFile() raise an Objective-C
        // exception on a full disk, which Swift cannot catch, and a disk-full export is exactly when
        // this code runs. A thrown error reaches the incident manager, which marks the incident failed.
        let handle = try FileHandle(forWritingTo: temporary)
        var closed = false
        defer { if !closed { try? handle.close() } }
        do {
            try body { data in try handle.write(contentsOf: data) }
            try handle.synchronize()
            try handle.close()
            closed = true
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
        if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
        try fm.moveItem(at: temporary, to: output)
    }
}
