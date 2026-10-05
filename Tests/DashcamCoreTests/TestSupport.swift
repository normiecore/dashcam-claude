import Foundation
import Testing
@testable import DashcamCore

/// Temporary on-disk environment with a deterministic clock and a synthetic segment producer.
final class BufferTestEnvironment: @unchecked Sendable {
    let root: URL
    let clock: ManualWallClock
    let fs: FaultyFileSystem
    let logSink = InMemoryLogSink()
    let logger: DashcamLogger
    let store: SegmentStore
    let incidents: IncidentManager
    let buffer: RollingBufferManager
    let segmentDuration: TimeInterval

    init(retention: RetentionPolicy = RetentionPolicy(minimumFreeBytes: 0), incidentPolicy: IncidentPolicy = IncidentPolicy(preRoll: 300, postRoll: 60), segmentDuration: TimeInterval = 4, start: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        clock = ManualWallClock(start: start)
        fs = FaultyFileSystem()
        logger = DashcamLogger(sinks: [logSink], clock: clock)
        store = SegmentStore(rootURL: root.appendingPathComponent("buffer", isDirectory: true), fileSystem: fs, logger: logger)
        incidents = IncidentManager(rootURL: root.appendingPathComponent("incidents", isDirectory: true), store: store, fileSystem: fs, clock: clock, policy: incidentPolicy, logger: logger)
        buffer = RollingBufferManager(store: store, incidents: incidents, policy: retention, clock: clock, logger: logger)
        self.segmentDuration = segmentDuration
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func load() async throws {
        try await store.load()
        try await incidents.load()
    }

    // MARK: Synthetic segments

    /// Writes an initialization segment file for `run` and indexes it via the store directly.
    @discardableResult
    func writeInitialization(run: RunID, bytes: Int = 512) async throws -> Segment {
        let relative = Segment.initializationPath(run: run)
        let url = store.url(for: Segment(id: .init(run: run, sequence: 0), kind: .initialization, startTime: clock.now(), duration: 0, byteCount: 0, relativePath: relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xAA, count: bytes).write(to: url)
        let segment = Segment(id: .init(run: run, sequence: 0), kind: .initialization, startTime: clock.now(), duration: 0, byteCount: Int64(bytes), relativePath: relative)
        try await store.add(segment)
        return segment
    }

    /// Writes a media segment starting at the clock's current time, advances the clock by its duration,
    /// and feeds it through the buffer manager exactly like the capture layer would.
    @discardableResult
    func produceSegment(run: RunID, sequence: Int, bytes: Int = 4_096, ingest: Bool = true) async throws -> Segment {
        let start = clock.now()
        let relative = Segment.relativePath(run: run, sequence: sequence, fileExtension: "m4s")
        let url = store.rootURL.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try BufferTestEnvironment.payload(sequence: sequence, bytes: bytes).write(to: url)
        clock.advance(by: segmentDuration)
        let segment = Segment(id: .init(run: run, sequence: sequence), kind: .media, startTime: start, duration: segmentDuration, byteCount: Int64(bytes), relativePath: relative)
        if ingest {
            try await buffer.ingest(segment)
        } else {
            try await store.add(segment)
        }
        return segment
    }

    static func payload(sequence: Int, bytes: Int) -> Data {
        var data = Data(count: bytes)
        let marker = UInt8(truncatingIfNeeded: sequence)
        for i in 0..<bytes { data[i] = i < 4 ? marker : UInt8(truncatingIfNeeded: i) }
        return data
    }

    func mediaFilesOnDisk() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: store.rootURL.path) else { return [] }
        let runs = try FileManager.default.contentsOfDirectory(at: store.rootURL, includingPropertiesForKeys: nil)
        return try runs.flatMap { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil) }
            .filter { $0.pathExtension != SegmentStore.sidecarExtension }
    }
}

/// File system wrapper with switchable failures, for exercising error paths.
final class FaultyFileSystem: SegmentFileSystem, @unchecked Sendable {
    private let inner = DefaultFileSystem()
    private let lock = NSLock()
    private var _failLinks = false
    private var _availableCapacityOverride: Int64?
    private var _failRemovals = false
    private var _capacityDelay: TimeInterval = 0
    private var _capacityQueries = 0

    var failLinks: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failLinks }
        set { lock.lock(); defer { lock.unlock() }; _failLinks = newValue }
    }

    var failRemovals: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _failRemovals }
        set { lock.lock(); defer { lock.unlock() }; _failRemovals = newValue }
    }

    /// Makes each free-space query block its thread this long, like a slow purgeable-space computation.
    var capacityDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _capacityDelay }
        set { lock.lock(); defer { lock.unlock() }; _capacityDelay = newValue }
    }

    var capacityQueries: Int { lock.lock(); defer { lock.unlock() }; return _capacityQueries }

    var availableCapacityOverride: Int64? {
        get { lock.lock(); defer { lock.unlock() }; return _availableCapacityOverride }
        set { lock.lock(); defer { lock.unlock() }; _availableCapacityOverride = newValue }
    }

    func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { inner.isDirectory(at: url) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try inner.contentsOfDirectory(at: url) }
    func removeItem(at url: URL) throws {
        if failRemovals { throw DashcamCoreError.fileSystem("injected removal failure") }
        try inner.removeItem(at: url)
    }
    func moveItem(at source: URL, to destination: URL) throws { try inner.moveItem(at: source, to: destination) }
    func linkItem(at source: URL, to destination: URL) throws {
        if failLinks { throw DashcamCoreError.fileSystem("injected link failure") }
        try inner.linkItem(at: source, to: destination)
    }
    func fileSize(at url: URL) throws -> Int64 { try inner.fileSize(at: url) }
    func write(_ data: Data, to url: URL) throws { try inner.write(data, to: url) }
    func read(from url: URL) throws -> Data { try inner.read(from: url) }
    func availableCapacity(forVolumeContaining url: URL) throws -> Int64 {
        let delay: TimeInterval = lock.withLock {
            _capacityQueries += 1
            return _capacityDelay
        }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if let override = availableCapacityOverride { return override }
        return try inner.availableCapacity(forVolumeContaining: url)
    }
}

func makeSegment(run: RunID = RunID(rawValue: "run-test"), sequence: Int, start: Date, duration: TimeInterval = 4, bytes: Int64 = 1_000, kind: SegmentKind = .media) -> Segment {
    let path = kind == .media ? Segment.relativePath(run: run, sequence: sequence, fileExtension: "m4s") : Segment.initializationPath(run: run)
    return Segment(id: .init(run: run, sequence: sequence), kind: kind, startTime: start, duration: duration, byteCount: bytes, relativePath: path)
}

func approximatelyEqual(_ a: Date, _ b: Date, tolerance: TimeInterval = 0.001) -> Bool {
    abs(a.timeIntervalSince(b)) <= tolerance
}
