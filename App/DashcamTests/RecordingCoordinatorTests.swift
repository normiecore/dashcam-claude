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
        try await h.waitForFootageInANewRun(besides: runsBefore, timeout: 15)
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
            // The old stall check would only notice after 10 to 15 s; the recorded intent acts at once.
            try await h.waitUntil("recovered (delay \(delay) ms)", timeout: 9) {
                h.coordinator.isRecording && h.fake.isRunning
            }
            try await h.waitForMediaSegments(1, after: before.addingTimeInterval(0.5), timeout: 12)
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

// MARK: - Harness

enum HarnessError: Error {
    case timeout(String)
    case unexpectedState(String)
}

/// One coordinator wired to a fake camera and a temporary storage root, with short segments and
/// post-roll so a test runs in seconds.
@MainActor
final class CoordinatorHarness {
    let root: URL
    let fake = FakeCaptureService()
    let settings: AppSettings
    let log = InMemoryLogSink(capacity: 5_000)
    let coordinator: RecordingCoordinator
    private let defaultsSuite: String

    init(audio: Bool = false) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-\(UUID().uuidString)", isDirectory: true)
        defaultsSuite = "dashcam-tests-\(UUID().uuidString)"
        settings = AppSettings(defaults: UserDefaults(suiteName: defaultsSuite) ?? .standard)
        settings.segmentSeconds = 2
        settings.postRollSeconds = 5
        settings.bufferMinutes = 1
        settings.audioEnabled = audio
        settings.hasCompletedOnboarding = true
        settings.autoStartRecording = false
        settings.motionDetectionEnabled = false
        settings.minimumFreeMegabytes = 256
        let storage = StorageLocations(
            buffer: root.appendingPathComponent("buffer", isDirectory: true),
            incidents: root.appendingPathComponent("incidents", isDirectory: true),
            isAppDefault: false
        )
        coordinator = RecordingCoordinator(settings: settings, logger: DashcamLogger(sinks: [log]), memoryLog: log, capture: fake, storage: storage)
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

// MARK: - Fake camera

/// Stands in for `CameraCaptureService`. Produces 30 fps of synthetic 320x240 frames, plus 44.1 kHz
/// audio when the "microphone" is configured, on a serial data queue with host-clock timestamps like
/// a real capture session, and offers controls to simulate the session events the coordinator must
/// survive. Events are delivered on the main queue, as the real service delivers them.
final class FakeCaptureService: CaptureControlling, @unchecked Sendable {
    weak var sink: CaptureSampleSink?
    var eventHandler: ((CaptureEvent) -> Void)?
    var cameraStatus: AVAuthorizationStatus = .authorized
    var microphoneStatus: AVAuthorizationStatus = .authorized
    var horizonLevelCaptureAngle: CGFloat = 0
    var videoDevice: AVCaptureDevice? { nil }
    var synchronizationClock: CMClock? { CMClockGetHostTimeClock() }

    private static let sampleRate = 44_100
    private static let samplesPerTick = 1_470 // one thirtieth of a second

    private let lock = NSLock()
    private let dataQueue = DispatchQueue(label: "test.fake-capture.data", qos: .userInitiated)
    // Guarded by `lock`.
    private var running = false
    private var interrupted = false
    private var videoFlowing = true
    private var audioFlowing = true
    private var configuredAudio = false
    private var shutDown = false
    private var pendingConfigureError: Error?
    private var configures = 0
    private var stops = 0
    private var resets = 0
    // Owned by `dataQueue`.
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private var audioStart: CMTime?
    private var audioSamplesSent: Int64 = 0
    private let video: SyntheticFrameSource
    private let tone: SyntheticToneSource

    init() {
        // Both sources only fail if CoreVideo/CoreMedia cannot allocate, which would fail every test anyway.
        video = try! SyntheticFrameSource(width: 320, height: 240)
        tone = try! SyntheticToneSource(sampleRate: FakeCaptureService.sampleRate)
    }

    var isRunning: Bool { lock.withLock { running } }
    var isInterrupted: Bool { lock.withLock { interrupted } }
    var configureCount: Int { lock.withLock { configures } }
    var stopCount: Int { lock.withLock { stops } }
    var resetCount: Int { lock.withLock { resets } }

    // MARK: CaptureControlling

    func currentCameraAuthorization() -> AVAuthorizationStatus { cameraStatus }
    func currentMicrophoneAuthorization() -> AVAuthorizationStatus { microphoneStatus }
    func requestCameraPermission() async -> Bool { cameraStatus == .authorized }
    func requestMicrophonePermission() async -> Bool { microphoneStatus == .authorized }

    func configureAndStart(quality: VideoQualityTier, audioEnabled: Bool, stabilization: Bool) async throws -> CaptureConfigurationSummary {
        let microphone = microphoneStatus == .authorized
        let outcome: Result<Bool, Error> = lock.withLock {
            configures += 1
            if let error = pendingConfigureError {
                pendingConfigureError = nil
                return .failure(error)
            }
            configuredAudio = audioEnabled && microphone
            running = !shutDown
            return .success(configuredAudio)
        }
        let withAudio = try outcome.get()
        startTicking()
        return CaptureConfigurationSummary(deviceName: "Fake camera", width: 320, height: 240, frameRate: 30, codec: "pending", stabilization: "off", audioEnabled: withAudio, usingPreset: false)
    }

    func stop() async {
        lock.withLock {
            stops += 1
            running = false
        }
    }

    func reset() async {
        lock.withLock {
            resets += 1
            running = false
            configuredAudio = false
        }
    }

    func setFrameRate(_ fps: Int) {}

    func onDataQueue(_ block: @escaping () -> Void) {
        dataQueue.async(execute: block)
    }

    func recommendedVideoSettings(quality: VideoQualityTier, segmentInterval: TimeInterval) -> (settings: [String: Any], codec: AVVideoCodecType)? {
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: 400_000,
            AVVideoMaxKeyFrameIntervalDurationKey: segmentInterval,
            AVVideoExpectedSourceFrameRateKey: 30,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
            AVVideoCompressionPropertiesKey: compression,
        ]
        return (settings: settings, codec: AVVideoCodecType.h264)
    }

    func recommendedAudioSettings() -> [String: Any]? {
        guard lock.withLock({ configuredAudio }) else { return nil }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: FakeCaptureService.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
    }

    func attachPreview(_ layer: AVCaptureVideoPreviewLayer, onConnectionChanged: @escaping () -> Void) {}

    // MARK: Simulation controls

    /// Another app takes the camera: frames stop and the session reports interrupted.
    func beginCameraInterruption(_ reason: AVCaptureSession.InterruptionReason = .videoDeviceInUseByAnotherClient) {
        lock.withLock {
            interrupted = true
            videoFlowing = false
            audioFlowing = false
        }
        post(.interrupted(reason))
    }

    /// A call or alarm takes the audio device. Whether video continues is undocumented, so both are simulated.
    func beginAudioInterruption(videoContinues: Bool) {
        lock.withLock {
            interrupted = true
            audioFlowing = false
            videoFlowing = videoContinues
        }
        post(.interrupted(.audioDeviceInUseByAnotherClient))
    }

    func endInterruption() {
        lock.withLock {
            interrupted = false
            videoFlowing = true
            audioFlowing = true
        }
        post(.interruptionEnded)
    }

    /// The session stops with a runtime error. `failNextConfigure` makes the next restart attempt throw.
    func failSession(mediaServicesReset: Bool, failNextConfigure: Error? = nil) {
        lock.withLock {
            running = false
            pendingConfigureError = failNextConfigure
        }
        let code = mediaServicesReset ? AVError.mediaServicesWereReset.rawValue : AVError.unknown.rawValue
        let error = NSError(domain: AVFoundationErrorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: "Simulated runtime error"])
        post(.runtimeError(error, mediaServicesWereReset: mediaServicesReset))
    }

    /// The phone is turned: the horizon-level capture angle changes.
    func rotate(to angle: CGFloat) {
        horizonLevelCaptureAngle = angle
        post(.rotationAngleChanged(angle))
    }

    /// Stops producing samples for good; later configure calls report running but deliver nothing.
    func shutdown() {
        lock.withLock {
            shutDown = true
            running = false
        }
        dataQueue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    // MARK: Sample production (dataQueue)

    private func post(_ event: CaptureEvent) {
        DispatchQueue.main.async { [weak self] in self?.eventHandler?(event) }
    }

    private func startTicking() {
        dataQueue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: self.dataQueue)
            source.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.tick() }
            source.resume()
            self.timer = source
        }
    }

    private func tick() {
        let state = lock.withLock { (video: running && videoFlowing, audio: running && audioFlowing && configuredAudio) }
        guard let target = sink else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if state.video, let frame = try? video.makeSampleBuffer(presentationTime: now, duration: CMTime(value: 1, timescale: 30), frameIndex: frameIndex) {
            frameIndex += 1
            target.captureDidOutputVideo(frame)
        }
        if state.audio {
            // Contiguous audio timestamps from the moment audio (re)started, like a microphone.
            let start = audioStart ?? now
            if audioStart == nil {
                audioStart = now
                audioSamplesSent = 0
            }
            let pts = CMTimeAdd(start, CMTime(value: audioSamplesSent, timescale: CMTimeScale(FakeCaptureService.sampleRate)))
            if let chunk = try? tone.makeSampleBuffer(presentationTime: pts, frameCount: FakeCaptureService.samplesPerTick) {
                audioSamplesSent += Int64(FakeCaptureService.samplesPerTick)
                target.captureDidOutputAudio(chunk)
            }
        } else {
            audioStart = nil
        }
    }
}
