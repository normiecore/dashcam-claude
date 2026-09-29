import Foundation

public struct ReconcileReport: Sendable, Equatable {
    public var indexed = 0
    public var orphanFilesRemoved = 0
    public var missingFilesDropped = 0
    public var corruptSidecarsRemoved = 0
    public var emptyRunsRemoved = 0
    public init() {}
}

/// Owns the rolling-buffer directory and its index.
///
/// Persistence model: every segment has a JSON sidecar (`000042.json` next to `000042.m4s`) written
/// atomically after the media file is complete. The in-memory index is rebuilt from sidecars at launch,
/// so an abrupt termination can lose at most the segment that was in flight. Files without a sidecar
/// are treated as unfinished and removed at load unless a caller registered them as incomplete.
public actor SegmentStore {
    public nonisolated let rootURL: URL
    private let fs: SegmentFileSystem
    private let logger: DashcamLogger
    private var index: [Segment.ID: Segment] = [:]

    public static let sidecarExtension = "json"

    public init(rootURL: URL, fileSystem: SegmentFileSystem = DefaultFileSystem(), logger: DashcamLogger = .disabled) {
        self.rootURL = rootURL
        self.fs = fileSystem
        self.logger = logger
    }

    // MARK: Paths

    public func directory(for run: RunID) -> URL {
        rootURL.appendingPathComponent(run.rawValue, isDirectory: true)
    }

    public nonisolated func url(for segment: Segment) -> URL {
        rootURL.appendingPathComponent(segment.relativePath)
    }

    public nonisolated func sidecarURL(for segment: Segment) -> URL {
        url(for: segment).deletingPathExtension().appendingPathExtension(SegmentStore.sidecarExtension)
    }

    // MARK: Lifecycle

    /// Creates the root directory and rebuilds the index from sidecars, removing anything unreadable.
    @discardableResult
    public func load() throws -> ReconcileReport {
        try fs.createDirectory(at: rootURL)
        var report = ReconcileReport()
        var rebuilt: [Segment.ID: Segment] = [:]
        let decoder = SegmentStore.makeDecoder()

        for runDir in try fs.contentsOfDirectory(at: rootURL) where fs.isDirectory(at: runDir) {
            let entries = try fs.contentsOfDirectory(at: runDir)
            var claimedFiles = Set<String>()
            for sidecar in entries where sidecar.pathExtension == SegmentStore.sidecarExtension {
                do {
                    let segment = try decoder.decode(Segment.self, from: fs.read(from: sidecar))
                    let mediaURL = url(for: segment)
                    if fs.fileExists(at: mediaURL) {
                        rebuilt[segment.id] = segment
                        claimedFiles.insert(mediaURL.lastPathComponent)
                        report.indexed += 1
                    } else {
                        report.missingFilesDropped += 1
                        try? fs.removeItem(at: sidecar)
                    }
                } catch {
                    report.corruptSidecarsRemoved += 1
                    logger.warning(.buffer, "Removing corrupt sidecar \(sidecar.lastPathComponent): \(error)")
                    try? fs.removeItem(at: sidecar)
                }
            }
            for file in entries where file.pathExtension != SegmentStore.sidecarExtension && !claimedFiles.contains(file.lastPathComponent) {
                report.orphanFilesRemoved += 1
                logger.notice(.buffer, "Removing orphan segment file \(runDir.lastPathComponent)/\(file.lastPathComponent)")
                try? fs.removeItem(at: file)
            }
            if (try? fs.contentsOfDirectory(at: runDir))?.isEmpty ?? false {
                report.emptyRunsRemoved += 1
                try? fs.removeItem(at: runDir)
            }
        }
        index = rebuilt
        logger.info(.buffer, "Buffer index loaded: \(report.indexed) segments, \(report.orphanFilesRemoved) orphans removed, \(report.missingFilesDropped) missing files dropped")
        return report
    }

    public func prepareRun(_ run: RunID) throws {
        try fs.createDirectory(at: directory(for: run))
    }

    // MARK: Mutation

    /// Registers a segment whose media file has already been written to `url(for:)`.
    public func add(_ segment: Segment) throws {
        let mediaURL = url(for: segment)
        guard fs.fileExists(at: mediaURL) else {
            throw DashcamCoreError.fileSystem("Segment file missing at \(segment.relativePath)")
        }
        let data = try SegmentStore.makeEncoder().encode(segment)
        try fs.write(data, to: sidecarURL(for: segment))
        index[segment.id] = segment
    }

    /// Deletes the media file and sidecar. A missing file is tolerated so retention never wedges.
    public func remove(_ id: Segment.ID) throws {
        guard let segment = index[id] else { return }
        let mediaURL = url(for: segment)
        var firstError: Error?
        if fs.fileExists(at: mediaURL) {
            do { try fs.removeItem(at: mediaURL) } catch { firstError = error }
        }
        let sidecar = sidecarURL(for: segment)
        if fs.fileExists(at: sidecar) {
            do { try fs.removeItem(at: sidecar) } catch { firstError = firstError ?? error }
        }
        index.removeValue(forKey: id)
        let runDir = directory(for: id.run)
        if (try? fs.contentsOfDirectory(at: runDir))?.isEmpty ?? false {
            try? fs.removeItem(at: runDir)
        }
        if let firstError { throw firstError }
    }

    // MARK: Queries

    public func segments() -> [Segment] {
        Array(index.values).chronological()
    }

    public func segment(_ id: Segment.ID) -> Segment? {
        index[id]
    }

    public func initializationSegment(for run: RunID) -> Segment? {
        index.values.first { $0.kind == .initialization && $0.id.run == run }
    }

    public var count: Int { index.count }

    public var totalBytes: Int64 { Array(index.values).totalBytes }

    public func availableCapacity() throws -> Int64 {
        try fs.availableCapacity(forVolumeContaining: rootURL)
    }

    // MARK: Coding

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
