import AVFoundation
import CoreMedia
import XCTest
import DashcamCore
@testable import Dashcam

/// Drives the real `RecordingCoordinator` (real segment writer, store, incident manager and clip
/// export) against a fake camera, in the Simulator. Each test asserts an invariant that must hold
/// whatever order the asynchronous events arrive in; the race tests repeat with different delays to
/// cover several interleavings.
final class RecordingCoordinatorTests: XCTestCase {

    // MARK: Recording and stopping

    @MainActor
    func testRecordingProducesSegmentsAndStopFlushesTheFinalPartialSegment() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitForMediaSegments(2)
        // Stop about halfway through a segment, so the final flush is a short partial segment that
        // is lost if stop() does not wait for the writer.
        let segments = await h.mediaSegments()
        let latestEnd = try XCTUnwrap(segments.last).endTime
        try await h.waitUntil("half a segment after the latest one") { Date() >= latestEnd.addingTimeInterval(1) }

        let stopRequestedAt = Date()
        await h.coordinator.stop()
        XCTAssertEqual(h.coordinator.state, .idle)
        XCTAssertFalse(h.fake.isRunning)

        let media = await h.mediaSegments()
        let now = Date()
        for segment in media {
            // Regression: the first segment's report timestamp was misread as movie time and the segment
            // stamped the device's uptime into the future.
            XCTAssertLessThanOrEqual(segment.endTime, now.addingTimeInterval(0.5), "\(segment.relativePath) is stamped in the future: \(segment.startTime)")
            XCTAssertGreaterThan(segment.startTime, now.addingTimeInterval(-120), "\(segment.relativePath) is stamped too far in the past: \(segment.startTime)")
        }
        let last = try XCTUnwrap(media.last)
        XCTAssertEqual(last.endTime.timeIntervalSince1970, stopRequestedAt.timeIntervalSince1970, accuracy: 0.6,
                       "stop() must flush and index the partial segment recorded up to the tap")
        for (earlier, later) in zip(media, media.dropFirst()) where earlier.id.run == later.id.run {
            XCTAssertEqual(later.startTime.timeIntervalSince(earlier.endTime), 0, accuracy: 0.2, "segments of one run are contiguous")
        }
        let all = await h.coordinator.store.segments()
        for segment in all {
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.coordinator.store.url(for: segment).path), "\(segment.relativePath) on disk")
            XCTAssertTrue(FileManager.default.fileExists(atPath: h.coordinator.store.sidecarURL(for: segment).path), "\(segment.relativePath) sidecar on disk")
        }
        try await Task.sleep(for: .seconds(2.5))
        let afterwards = await h.mediaSegments()
        XCTAssertEqual(afterwards.count, media.count, "no writer is left armed after stop()")
        await h.finish()
    }

    // MARK: Incidents

    @MainActor
    func testSaveIncidentKeepsPreRollCollectsPostRollAndExportsAPlayableClip() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitForMediaSegments(2)
        let triggeredAt = Date()
        let triggered = await h.coordinator.triggerIncident(source: .manual, note: "test")
        let incident = try XCTUnwrap(triggered)
        XCTAssertEqual(incident.state, .collecting)
        XCTAssertGreaterThanOrEqual(incident.mediaParts.count, 2, "the pre-roll is protected the moment the trigger arrives")

        try await h.waitUntil("incident exported", timeout: 45) {
            h.incident(incident.id)?.state == .complete
        }
        let done = try XCTUnwrap(h.incident(incident.id))
        let coveredEnd = try XCTUnwrap(done.coveredEnd)
        XCTAssertGreaterThanOrEqual(coveredEnd.timeIntervalSince(triggeredAt), 4.5, "the post-roll after the trigger is collected")
        let clips = h.coordinator.clipURLs(for: done)
        XCTAssertEqual(clips.count, 1)
        let clip = try XCTUnwrap(clips.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.path))
        let duration = try await AVURLAsset(url: clip).load(.duration)
        XCTAssertEqual(duration.seconds, done.footageDuration, accuracy: 0.6, "the exported clip holds all of the protected footage")
        XCTAssertTrue(h.coordinator.isRecording, "recording continues after an incident")
        await h.finish()
    }

    @MainActor
    func testSaveIncidentAfterStopClosesAtOnceWithTheBufferedFootage() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitForMediaSegments(2)
        await h.coordinator.stop()
        let triggered = await h.coordinator.triggerIncident(source: .manual, note: "after stop")
        let incident = try XCTUnwrap(triggered)
        XCTAssertNotEqual(incident.state, .collecting, "nothing is recording, so no post-roll can arrive")
        XCTAssertGreaterThanOrEqual(incident.mediaParts.count, 2)
        try await h.waitUntil("incident exported", timeout: 45) { h.incident(incident.id)?.state == .complete }
        await h.finish()
    }

    @MainActor
    func testSaveIncidentDuringStopIncludesTheFinalFlushedSegment() async throws {
        for delay in [0, 20, 80] {
            let h = CoordinatorHarness(); h.cleanUp(after: self)
            try await h.startRecording()
            try await h.waitForMediaSegments(2)
            try await Task.sleep(for: .milliseconds(900))
            let stopping = Task { await h.coordinator.stop() }
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            let triggered = await h.coordinator.triggerIncident(source: .manual, note: "during stop")
            await stopping.value
            let incident = try XCTUnwrap(triggered, "delay \(delay) ms")
            try await h.waitUntil("incident finished (delay \(delay) ms)", timeout: 45) {
                let state = h.incident(incident.id)?.state
                return state == .complete || state == .failed
            }
            let final = try XCTUnwrap(h.incident(incident.id))
            XCTAssertEqual(final.state, .complete, "delay \(delay) ms: \(final.failureReason ?? "")")
            let media = await h.mediaSegments()
            let lastSegment = try XCTUnwrap(media.last)
            XCTAssertTrue(final.mediaParts.contains { $0.segment.id == lastSegment.id },
                          "delay \(delay) ms: the segment flushed by the stop, just before the tap, belongs to the incident")
            await h.finish()
        }
    }

    @MainActor
    func testTwoSaveTapsAtOnceProduceOneIncident() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitForMediaSegments(2)
        let first = Task { await h.coordinator.triggerIncident(source: .manual, note: "tap 1") }
        let second = Task { await h.coordinator.triggerIncident(source: .manual, note: "tap 2") }
        let a = await first.value
        let b = await second.value
        let incidentA = try XCTUnwrap(a)
        let incidentB = try XCTUnwrap(b)
        XCTAssertEqual(incidentA.id, incidentB.id, "the second tap merges into the first incident")
        await h.coordinator.refreshIncidents()
        XCTAssertEqual(h.coordinator.incidents.count, 1)
        XCTAssertEqual(h.coordinator.incidents.first?.triggers.count, 2)
        await h.finish()
    }

    // MARK: Rolling buffer

    @MainActor
    func testTheBufferRollsOverUnderACollectingIncidentAndItsFootageSurvives() async throws {
        // A 1 minute buffer of 2 s segments. The incident is saved about 50 s in with a 20 s post-roll,
        // so its oldest footage ages out of the buffer while it is still collecting. About 85 s.
        executionTimeAllowance = 240
        let target: TimeInterval = 60
        let segmentLength: TimeInterval = 2
        let h = CoordinatorHarness(postRollSeconds: 20); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitForMediaSegments(24, timeout: 90)
        let initial = await h.mediaSegments()
        let first = try XCTUnwrap(initial.first)
        let firstBufferURL = h.coordinator.store.url(for: first)
        let triggered = await h.coordinator.triggerIncident(source: .manual, note: "before the rollover")
        let incident = try XCTUnwrap(triggered)
        let firstPart = try XCTUnwrap(incident.mediaParts.first { $0.segment.id == first.id }, "the pre-roll reaches back to the first segment")
        XCTAssertNotNil(firstPart.linkedRelativePath, "the incident holds its own link to the footage")

        try await h.waitUntil("the first segment ages out of the buffer", timeout: 40) {
            await !h.mediaSegments().contains { $0.id == first.id }
        }
        let current = await h.coordinator.incidentManager.incident(incident.id)
        let collecting = try XCTUnwrap(current)
        XCTAssertEqual(collecting.state, .collecting, "the rollover happened while the incident was still collecting its post-roll")
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstBufferURL.path), "the expired segment's buffer file is deleted")
        let heldPart = try XCTUnwrap(collecting.mediaParts.first { $0.segment.id == first.id }, "the incident still lists the expired segment")
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.coordinator.incidentManager.url(for: heldPart, of: incident.id).path),
                      "the incident's link keeps the expired footage on disk")

        try await h.waitUntil("incident exported", timeout: 60) { h.incident(incident.id)?.state == .complete }
        try await h.waitForMediaSegments(3, after: Date())
        let media = await h.mediaSegments()
        let buffered = media.mediaDuration
        // A check can land between a segment's indexing and the retention pass it triggers, so one
        // extra segment is allowed above the target.
        XCTAssertLessThanOrEqual(buffered, target + 2 * segmentLength + 0.5, "retention keeps about the buffer length")
        XCTAssertGreaterThanOrEqual(buffered, target - segmentLength - 0.5, "retention deletes only footage that has aged out")
        let oldest = try XCTUnwrap(media.first)
        XCTAssertGreaterThan(oldest.endTime, Date().addingTimeInterval(-(target + 2 * segmentLength + 1)), "nothing older than the buffer is kept")
        XCTAssertTrue(h.coordinator.isRecording, "retention runs while recording continues")

        await h.coordinator.stop()
        let indexed = await h.coordinator.store.segments()
        var expected = Set<String>()
        for segment in indexed {
            expected.insert(h.coordinator.store.url(for: segment).resolvingSymlinksInPath().path)
            expected.insert(h.coordinator.store.sidecarURL(for: segment).resolvingSymlinksInPath().path)
        }
        let onDisk = regularFiles(under: h.root.appendingPathComponent("buffer", isDirectory: true))
        XCTAssertEqual(onDisk.subtracting(expected).sorted(), [], "no buffer file outlives its index entry")
        XCTAssertEqual(expected.subtracting(onDisk).sorted(), [], "every indexed segment is on disk")

        let done = try XCTUnwrap(h.incident(incident.id))
        XCTAssertEqual(done.state, .complete)
        let coveredStart = try XCTUnwrap(done.coveredStart)
        XCTAssertEqual(coveredStart.timeIntervalSince(first.startTime), 0, accuracy: 0.1, "the clip starts with footage that had left the buffer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.coordinator.incidentManager.partsDirectory(for: done.id).path), "the incident's links are released after export")
        let clip = try XCTUnwrap(h.coordinator.clipURLs(for: done).first)
        let duration = try await AVURLAsset(url: clip).load(.duration)
        XCTAssertEqual(duration.seconds, done.footageDuration, accuracy: 0.6, "the clip holds all of the protected footage")
        await h.finish()
    }

    // MARK: Interruptions

    @MainActor
    func testCameraInterruptionPausesAndResumesInANewRun() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        let runsBefore = await h.runs()
        h.fake.beginCameraInterruption()
        try await h.waitUntil("paused") { h.isInterrupted }
        h.fake.endInterruption()
        try await h.waitUntil("recording again") { h.coordinator.isRecording }
        try await h.waitForFootageInANewRun(besides: runsBefore)
        XCTAssertEqual(h.coordinator.recoveryAttempts, 0)
        await h.finish()
    }

    @MainActor
    func testStopWhileAnInterruptionIsBeingHandledStaysStopped() async throws {
        for delay in [0, 40, 200] {
            let h = CoordinatorHarness(); h.cleanUp(after: self)
            try await h.startRecording()
            h.fake.beginCameraInterruption()
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            await h.coordinator.stop()
            try await h.waitUntil("stopped (delay \(delay) ms)") { h.coordinator.state == .idle }
            h.fake.endInterruption()
            try await Task.sleep(for: .seconds(2))
            XCTAssertEqual(h.coordinator.state, .idle, "delay \(delay) ms: the interruption ending after Stop must not restart recording")
            XCTAssertFalse(h.fake.isRunning, "delay \(delay) ms")
            await h.finish()
        }
    }

    @MainActor
    func testCallThatKeepsVideoRotatesToVideoOnlyAndBack() async throws {
        let h = CoordinatorHarness(audio: true); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitUntil("a run with audio") { h.coordinator.runHasAudio }

        h.fake.beginAudioInterruption(videoContinues: true)
        try await h.waitUntil("a video-only run") { h.coordinator.isRecording && !h.coordinator.runHasAudio }
        try await h.waitForMediaSegments(1, after: Date())
        XCTAssertTrue(h.coordinator.isRecording, "video keeps recording through the call")

        h.fake.endInterruption()
        try await h.waitUntil("audio back after the call") { h.coordinator.isRecording && h.coordinator.runHasAudio }
        try await h.waitForMediaSegments(1, after: Date())
        XCTAssertEqual(h.coordinator.recoveryAttempts, 0)
        await h.finish()
    }

    @MainActor
    func testCallThatStopsVideoPausesWithoutSpendingRecoveryAttempts() async throws {
        let h = CoordinatorHarness(audio: true); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitUntil("a run with audio") { h.coordinator.runHasAudio }

        h.fake.beginAudioInterruption(videoContinues: false)
        try await h.waitUntil("paused by the call", timeout: 20) { h.isInterrupted }
        XCTAssertEqual(h.coordinator.recoveryAttempts, 0, "a call is an interruption, not a camera fault")

        h.fake.endInterruption()
        try await h.waitUntil("recording with audio after the call", timeout: 20) {
            h.coordinator.isRecording && h.coordinator.runHasAudio
        }
        try await h.waitForMediaSegments(1, after: Date())
        XCTAssertEqual(h.coordinator.recoveryAttempts, 0)
        await h.finish()
    }

    @MainActor
    func testRotatingThePhoneIntoItsMountStartsANewRun() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        let runsBefore = await h.runs()
        h.fake.rotate(to: 90)
        // Generous: the property is that footage continues in a new run, not how fast a loaded CI
        // machine's file system lets the store start it.
        try await h.waitForFootageInANewRun(besides: runsBefore, timeout: 40)
        XCTAssertTrue(h.coordinator.isRecording)
        await h.finish()
    }

    // MARK: Faults

    @MainActor
    func testStorageCriticalStopsRecordingAndRecordingCanStartAgain() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        // A floor far above any real free space: the next segment reports storage critical.
        await h.coordinator.developerSetStorageFloor(megabytes: 1 << 26)
        try await h.waitUntil("stopped for storage", timeout: 15) { h.coordinator.state == .idle }
        XCTAssertTrue(h.coordinator.lastError?.text.contains("storage") ?? false, "\(h.coordinator.lastError?.text ?? "no error shown")")

        await h.coordinator.developerSetStorageFloor(megabytes: nil)
        await h.coordinator.start()
        XCTAssertTrue(h.coordinator.isRecording, "no transition is left wedged after the storage stop: \(h.coordinator.state)")
        try await h.waitForMediaSegments(1, after: Date())
        await h.finish()
    }

    @MainActor
    func testRuntimeErrorDuringARunRotationIsRecovered() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        for delay in [0, 30, 150] {
            let before = Date()
            h.coordinator.developerSimulateWriterFailure()
            if delay > 0 { try await Task.sleep(for: .milliseconds(delay)) }
            h.fake.failSession(mediaServicesReset: false)
            try await h.waitUntil("recovered (delay \(delay) ms)", timeout: 40) {
                h.coordinator.isRecording && h.fake.isRunning
            }
            try await h.waitForMediaSegments(1, after: before.addingTimeInterval(0.5), timeout: 30)
        }
        // The recorded intent recovers as soon as the rotation ends. If the error had been dropped, only
        // the watchdog's backstop would have noticed the dead session; it must not have been needed.
        // (Checked through the log rather than a deadline, so a slow file system does not fail the test.)
        for backstop in ["Session stopped running while recording", "No video frames while recording"] {
            XCTAssertFalse(h.logContains(backstop), "the watchdog had to recover: \(backstop)\n\(h.recentLog())")
        }
        XCTAssertTrue(h.coordinator.isRecording)
        await h.finish()
    }

    @MainActor
    func testMediaServicesResetRebuildsTheSessionAndResumes() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        let before = Date()
        h.fake.failSession(mediaServicesReset: true)
        try await h.waitUntil("session rebuilt") { h.fake.resetCount == 1 }
        try await h.waitUntil("recording again") { h.coordinator.isRecording && h.fake.isRunning }
        try await h.waitForMediaSegments(1, after: before.addingTimeInterval(0.5))
        await h.finish()
    }

    @MainActor
    func testFailureClosesTheCollectingIncidentAndARestartWorks() async throws {
        let h = CoordinatorHarness(); h.cleanUp(after: self)
        try await h.startRecording()
        try await h.waitForMediaSegments(2)
        let triggered = await h.coordinator.triggerIncident(source: .manual, note: "before failure")
        let incident = try XCTUnwrap(triggered)
        XCTAssertEqual(incident.state, .collecting)

        // The session dies and the camera cannot be restarted: recovery fails the session.
        h.fake.failSession(mediaServicesReset: false, failNextConfigure: CaptureError.configurationFailed("simulated camera failure"))
        try await h.waitUntil("failed") { h.isFailed }
        try await h.waitUntil("incident closed by the failure teardown") {
            guard let state = h.incident(incident.id)?.state else { return false }
            return state != .collecting
        }

        await h.coordinator.start()
        XCTAssertTrue(h.coordinator.isRecording, "a restart after a failure works: \(h.coordinator.state)")
        try await h.waitForMediaSegments(1, after: Date())
        await h.finish()
    }
}

/// Paths of the regular files below `root`, symlinks resolved.
func regularFiles(under root: URL) -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
    var paths = Set<String>()
    for case let url as URL in enumerator where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
        paths.insert(url.resolvingSymlinksInPath().path)
    }
    return paths
}

// MARK: - Harness

/// Prints run lifecycle notices and every warning to the test output, so a CI log shows where time
/// went in passing tests too (the in-memory log is only dumped when a test fails).
struct ConsoleLogSink: LogSink {
    func write(_ entry: LogEntry) {
        guard entry.level >= .warning || (entry.level >= .notice && entry.category == .recorder) else { return }
        print(entry.formatted)
    }
}

enum HarnessError: Error {
    case timeout(String)
    case unexpectedState(String)
}

/// One coordinator wired to a fake camera and a temporary storage root, with short segments and
/// post-roll so a test runs in seconds.
@MainActor
final class CoordinatorHarness {
    let root: URL
    let fake = SimulatedCaptureService()
    let settings: AppSettings
    let log = InMemoryLogSink(capacity: 5_000)
    let coordinator: RecordingCoordinator
    private let defaultsSuite: String

    init(audio: Bool = false, postRollSeconds: Int = 5) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID().uuidString)", isDirectory: true)
        defaultsSuite = "dashcam-tests-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard)
        settings.segmentSeconds = 2
        settings.postRollSeconds = postRollSeconds
        settings.bufferMinutes = 1
        settings.audioEnabled = audio
        settings.hasCompletedOnboarding = true
        settings.autoStartRecording = false
        settings.motionDetectionEnabled = false
        settings.minimumFreeMegabytes = 256
        let storage = StorageLocations.isolated(root: root)
        coordinator = RecordingCoordinator(settings: settings, logger: DashcamLogger(sinks: [log, ConsoleLogSink()]), memoryLog: log, capture: fake, storage: storage)
    }

    /// Stops the fake camera and removes the files even when a test fails part way.
    func cleanUp(after testCase: XCTestCase) {
        let fake = self.fake
        let root = self.root
        let suite = defaultsSuite
        testCase.addTeardownBlock {
            fake.shutdown()
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
    }

    func startRecording(file: StaticString = #filePath, line: UInt = #line) async throws {
        await coordinator.bootstrap()
        await coordinator.start()
        guard coordinator.isRecording else {
            let detail = "state \(coordinator.state), error \(coordinator.lastError?.text ?? "none")"
            XCTFail("expected recording after start: \(detail)\n\(recentLog())", file: file, line: line)
            throw HarnessError.unexpectedState(detail)
        }
        try await waitForMediaSegments(1, file: file, line: line)
    }

    func finish() async {
        if coordinator.state.isActive { await coordinator.stop() }
        let deadline = Date().addingTimeInterval(10)
        while coordinator.state.isActive || coordinator.state == .stopping, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        fake.shutdown()
    }

    // MARK: Queries

    var isInterrupted: Bool {
        if case .interrupted = coordinator.state { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = coordinator.state { return true }
        return false
    }

    func incident(_ id: UUID) -> Incident? {
        coordinator.incidents.first { $0.id == id }
    }

    func mediaSegments() async -> [Segment] {
        await coordinator.store.segments().filter { $0.kind == .media }
    }

    /// Runs in the order their footage was recorded.
    func runs() async -> [RunID] {
        var seen: [RunID] = []
        for segment in await coordinator.store.segments() where !seen.contains(segment.id.run) {
            seen.append(segment.id.run)
        }
        return seen
    }

    func logContains(_ text: String) -> Bool {
        log.entries().contains { $0.message.contains(text) }
    }

    func recentLog(_ count: Int = 40) -> String {
        log.entries().suffix(count).map(\.formatted).joined(separator: "\n")
    }

    // MARK: Waiting

    func waitUntil(_ description: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out after \(Int(timeout)) s waiting for: \(description). State: \(coordinator.state).\nRecent log:\n\(recentLog())", file: file, line: line)
        throw HarnessError.timeout(description)
    }

    /// Waits for `count` media segments that started at or after `date` (or at all, when nil).
    func waitForMediaSegments(_ count: Int, after date: Date? = nil, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) async throws {
        let label = date.map { "\(count) media segment(s) starting after \($0)" } ?? "\(count) media segment(s)"
        try await waitUntil(label, timeout: timeout, file: file, line: line) {
            let media = await self.mediaSegments()
            guard let date else { return media.count >= count }
            return media.filter { $0.startTime >= date.addingTimeInterval(-0.1) }.count >= count
        }
    }

    func waitForFootageInANewRun(besides earlier: [RunID], timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line) async throws {
        try await waitUntil("footage in a run started after \(earlier.count) earlier run(s)", timeout: timeout, file: file, line: line) {
            let media = await self.mediaSegments()
            return media.contains { !earlier.contains($0.id.run) }
        }
    }
}
