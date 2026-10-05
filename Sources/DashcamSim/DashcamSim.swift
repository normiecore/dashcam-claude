import Foundation
import DashcamCore

/// Developer simulation tool. Drives the real DashcamCore pipeline (store, retention, incidents,
/// assembly) with synthetic segments and a manual clock, so multi-hour scenarios run in seconds on
/// a Mac or Linux box without a camera. Usage:
///
///   swift run dashcam-sim drive [--hours 2] [--segment 4] [--buffer 300] [--post 60] \
///       [--incidents 1200,3000] [--free-mb 4096] [--keep]
///   swift run dashcam-sim replay path/to/trace.csv [--sensitivity low|medium|high]
@main
struct DashcamSim {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { usage(); return }
        arguments.removeFirst()
        do {
            switch command {
            case "drive": try await drive(options: parse(arguments))
            case "replay": try replay(arguments: arguments)
            default: usage()
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }

    static func usage() {
        print("""
        dashcam-sim drive [--hours H] [--segment S] [--buffer B] [--post P] [--incidents t1,t2,...] [--free-mb MB] [--keep]
        dashcam-sim replay <trace.csv> [--sensitivity low|medium|high]
        """)
    }

    static func parse(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key.hasPrefix("--") {
                let name = String(key.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    options[name] = arguments[index + 1]
                    index += 2
                } else {
                    options[name] = "true"
                    index += 1
                }
            } else {
                options["_\(index)"] = key
                index += 1
            }
        }
        return options
    }

    // MARK: drive

    static func drive(options: [String: String]) async throws {
        let hours = Double(options["hours"] ?? "1") ?? 1
        let segmentSeconds = Double(options["segment"] ?? "4") ?? 4
        let bufferSeconds = Double(options["buffer"] ?? "300") ?? 300
        let postRoll = Double(options["post"] ?? "60") ?? 60
        let freeMB = Int64(options["free-mb"] ?? "4096") ?? 4096
        let incidentTimes = (options["incidents"] ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.sorted()
        let bytesPerSecond: Int64 = 4_500_000 / 8 + 12_000
        let keep = options["keep"] == "true"

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-sim-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }

        let clock = ManualWallClock(start: Date(timeIntervalSince1970: 1_700_000_000))
        let sink = InMemoryLogSink(capacity: 200)
        let logger = DashcamLogger(sinks: [sink], minimumLevel: .notice, clock: clock)
        let fs = SimulatedFileSystem(freeBytes: freeMB * 1_048_576)
        let store = SegmentStore(rootURL: root.appendingPathComponent("buffer"), fileSystem: fs, logger: logger)
        let incidents = IncidentManager(rootURL: root.appendingPathComponent("incidents"), store: store, fileSystem: fs, clock: clock, policy: IncidentPolicy(preRoll: bufferSeconds, postRoll: postRoll), logger: logger)
        let buffer = RollingBufferManager(store: store, incidents: incidents, policy: RetentionPolicy(targetDuration: bufferSeconds, minimumFreeBytes: 512 * 1_048_576), clock: clock, logger: logger)
        try await store.load()
        try await incidents.load()

        let run = RunID.make(at: clock.now())
        try await buffer.beginRun(run)
        let initURL = root.appendingPathComponent("buffer/\(run.rawValue)/init.mp4")
        try FileManager.default.createDirectory(at: initURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: 512).write(to: initURL)
        try await store.add(Segment(id: .init(run: run, sequence: 0), kind: .initialization, startTime: clock.now(), duration: 0, byteCount: 512, relativePath: Segment.initializationPath(run: run)))

        let start = clock.now()
        let totalSegments = Int(hours * 3600 / segmentSeconds)
        var pendingIncidents = incidentTimes
        var maxBuffered: TimeInterval = 0
        var minBufferedAfterFill: TimeInterval = .infinity
        var deletedBytes: Int64 = 0
        let wall = Date()

        print("Simulating \(hours) h of driving: \(totalSegments) segments of \(Int(segmentSeconds)) s, buffer \(Int(bufferSeconds)) s, post-roll \(Int(postRoll)) s, free space \(freeMB) MB")
        for sequence in 1...max(1, totalSegments) {
            let elapsed = clock.now().timeIntervalSince(start)
            while let next = pendingIncidents.first, next <= elapsed {
                pendingIncidents.removeFirst()
                let incident = try await incidents.trigger(source: .developerSimulation, note: "sim at \(Int(next)) s")
                print(String(format: "t=%6.0fs  incident %@ opened with %.0f s of pre-roll (%d parts)", elapsed, incident.id.uuidString.prefix(8) as CVarArg, incident.footageDuration, incident.parts.count))
            }
            let relative = Segment.relativePath(run: run, sequence: sequence, fileExtension: "m4s")
            let url = root.appendingPathComponent("buffer/\(relative)")
            try Data(repeating: UInt8(sequence & 0xff), count: 1_024).write(to: url)
            let segment = Segment(id: .init(run: run, sequence: sequence), kind: .media, startTime: clock.now(), duration: segmentSeconds, byteCount: Int64(Double(bytesPerSecond) * segmentSeconds), relativePath: relative)
            clock.advance(by: segmentSeconds)
            let plan = try await buffer.ingest(segment)
            deletedBytes += plan.deletedBytes
            fs.consume(segment.byteCount)
            fs.release(plan.deletedBytes)
            let buffered = await buffer.bufferedDuration()
            maxBuffered = max(maxBuffered, buffered)
            if elapsed > bufferSeconds * 1.5 { minBufferedAfterFill = min(minBufferedAfterFill, buffered) }
            if plan.isStorageCritical {
                print(String(format: "t=%6.0fs  storage critical (free %d MB); a real session would stop here", elapsed, fs.freeBytes / 1_048_576))
                break
            }
        }
        try await buffer.endRun()

        for incident in await incidents.incidents(in: [.readyToAssemble]) {
            do {
                let done = try await incidents.assemble(incident.id, using: FMP4ClipAssembler())
                let covered = done.coveredStart.map { $0.timeIntervalSince(start) } ?? 0
                print(String(format: "incident %@: %@, footage %.0f s starting at t=%.0f s, %d clip file(s), %.1f MB", done.id.uuidString.prefix(8) as CVarArg, done.state.rawValue, done.footageDuration, covered, done.clipRelativePaths.count, Double(done.totalBytes) / 1_048_576))
            } catch {
                print("incident \(incident.id.uuidString.prefix(8)) assembly failed: \(error)")
            }
        }

        let indexed = await store.segments()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("buffer/\(run.rawValue)"), includingPropertiesForKeys: nil).filter { $0.pathExtension != "json" }
        print("")
        print(String(format: "Buffer: max %.0f s, min after fill %.0f s, %d segments indexed, %d files on disk, %.1f MB deleted over the drive", maxBuffered, minBufferedAfterFill.isFinite ? minBufferedAfterFill : 0, indexed.count, files.count, Double(deletedBytes) / 1_048_576))
        var pass = true
        func check(_ condition: Bool, _ message: String) { print((condition ? "PASS " : "FAIL ") + message); pass = pass && condition }
        check(maxBuffered <= bufferSeconds + segmentSeconds, "buffer never exceeds target plus one segment")
        check(!minBufferedAfterFill.isFinite || minBufferedAfterFill >= bufferSeconds - segmentSeconds, "buffer never dips below target minus one segment once full")
        check(files.count == indexed.count, "every indexed segment has a file and no orphans remain")
        let allIncidents = await incidents.allIncidents()
        check(allIncidents.allSatisfy { $0.state == .complete }, "every incident completed")
        for incident in allIncidents {
            let expected = min(bufferSeconds, incident.triggerTime.timeIntervalSince(start)) + postRoll
            check(abs(incident.footageDuration - expected) <= 2 * segmentSeconds, String(format: "incident %@ covers about %.0f s (got %.0f s)", incident.id.uuidString.prefix(8) as CVarArg, expected, incident.footageDuration))
        }
        print(String(format: "Wall time %.2f s. %@", Date().timeIntervalSince(wall), keep ? "Output kept at \(root.path)" : ""))
        if !pass { exit(2) }
    }

    // MARK: replay

    static func replay(arguments: [String]) throws {
        let options = parse(arguments)
        guard let path = options["_0"] else { usage(); return }
        let csv = try String(contentsOfFile: path, encoding: .utf8)
        let configuration: MotionDetectorConfiguration
        switch options["sensitivity"] ?? "low" {
        case "high": configuration = MotionDetectorConfiguration(impactThresholdG: 2.2, impactMinimumSamples: 2, hardBrakingThresholdG: 0.7, hardBrakingMinimumDuration: 0.6, rotationThreshold: 5.0)
        case "medium": configuration = MotionDetectorConfiguration(impactThresholdG: 3.0, impactMinimumSamples: 3, hardBrakingThresholdG: .infinity, rotationThreshold: 6.0)
        default: configuration = MotionDetectorConfiguration(impactThresholdG: 4.0, impactMinimumSamples: 4, hardBrakingThresholdG: .infinity, rotationThreshold: .infinity)
        }
        let samples = try MotionTrace.parse(csv: csv)
        let events = MotionImpactDetector.events(in: samples, configuration: configuration)
        let peak = samples.map(\.accelerationMagnitude).max() ?? 0
        print(String(format: "%d samples over %.1f s, peak |a| %.2f g, sensitivity %@", samples.count, (samples.last?.timestamp ?? 0) - (samples.first?.timestamp ?? 0), peak, options["sensitivity"] ?? "low"))
        if events.isEmpty { print("No events") }
        for event in events {
            print(String(format: "  %@ at %.2f s, peak %.2f", event.kind.rawValue, event.timestamp, event.peakMagnitude))
        }
    }
}

/// Default file system with a fake free-space counter so storage pressure can be simulated.
final class SimulatedFileSystem: SegmentFileSystem, @unchecked Sendable {
    private let inner = DefaultFileSystem()
    private let lock = NSLock()
    private var free: Int64

    init(freeBytes: Int64) { free = freeBytes }

    var freeBytes: Int64 { lock.lock(); defer { lock.unlock() }; return free }
    func consume(_ bytes: Int64) { lock.lock(); free -= bytes; lock.unlock() }
    func release(_ bytes: Int64) { lock.lock(); free += bytes; lock.unlock() }

    func fileExists(at url: URL) -> Bool { inner.fileExists(at: url) }
    func isDirectory(at url: URL) -> Bool { inner.isDirectory(at: url) }
    func createDirectory(at url: URL) throws { try inner.createDirectory(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try inner.contentsOfDirectory(at: url) }
    func removeItem(at url: URL) throws { try inner.removeItem(at: url) }
    func moveItem(at source: URL, to destination: URL) throws { try inner.moveItem(at: source, to: destination) }
    func linkItem(at source: URL, to destination: URL) throws { try inner.linkItem(at: source, to: destination) }
    func fileSize(at url: URL) throws -> Int64 { try inner.fileSize(at: url) }
    func write(_ data: Data, to url: URL) throws { try inner.write(data, to: url) }
    func read(from url: URL) throws -> Data { try inner.read(from: url) }
    func availableCapacity(forVolumeContaining url: URL) throws -> Int64 { freeBytes }
}
