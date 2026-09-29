import AVFoundation
import Combine
import Foundation
import UIKit
import DashcamCore

struct PermissionSnapshot: Equatable {
    var camera: AVAuthorizationStatus = .notDetermined
    var microphone: AVAuthorizationStatus = .notDetermined
    var cameraGranted: Bool { camera == .authorized }
    var cameraDenied: Bool { camera == .denied || camera == .restricted }
}

/// Orchestrates the dash-cam session. Everything the UI shows comes from here; everything the
/// capture layer produces flows through here into DashcamCore.
///
/// Recording is foreground-only on iOS (camera use is prohibited in the background and the screen
/// lock backgrounds the app), so the coordinator treats backgrounding and system interruptions as
/// "finish the current run so its footage is on disk, then start a new run when allowed".
@MainActor
final class RecordingCoordinator: ObservableObject {
    // MARK: Published state

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var configuration: CaptureConfigurationSummary?
    @Published private(set) var bufferedSeconds: TimeInterval = 0
    @Published private(set) var bufferSegmentCount = 0
    @Published private(set) var storage: StorageStatus?
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var lastError: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var pressureLevel: AVCaptureDevice.SystemPressureState.Level = .nominal
    @Published private(set) var thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var permissions = PermissionSnapshot()
    @Published private(set) var sessionStartedAt: Date?
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var videoFrames = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var audioInterrupted = false
    @Published private(set) var recoveryAttempts = 0
    @Published private(set) var currentFrameRate = 30
    @Published private(set) var lastSegmentAt: Date?
    @Published private(set) var batteryState: UIDevice.BatteryState = .unknown
    @Published private(set) var batteryLevel: Float = -1
    @Published var isDimmed = false

    var activeIncident: Incident? { incidents.first { $0.state == .collecting } }
    var isRecording: Bool { if case .recording = state { return true } else { return false } }

    // MARK: Dependencies

    let settings: AppSettings
    let logger: DashcamLogger
    let memoryLog: InMemoryLogSink
    let capture: CameraCaptureService
    let store: SegmentStore
    let incidentManager: IncidentManager
    let buffer: RollingBufferManager
    let motionDetector: MotionIncidentDetector
    let safetyKit: SafetyKitIncidentDetector
    private let router = CaptureRouter()
    private let exporter: ClipExportService

    // MARK: Internals

    private enum IngestItem {
        case segment(Segment)
        case barrier(CheckedContinuation<Void, Never>)
    }

    private var userWantsRecording = false
    private var isTransitioning = false
    private var ingestContinuation: AsyncStream<IngestItem>.Continuation?
    private var ingestTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var assembling = Set<UUID>()
    private var storageFloorOverride: Int64?

    init(settings: AppSettings, logger: DashcamLogger, memoryLog: InMemoryLogSink) {
        self.settings = settings
        self.logger = logger
        self.memoryLog = memoryLog
        let fileSystem = DefaultFileSystem()
        store = SegmentStore(rootURL: AppPaths.buffer, fileSystem: fileSystem, logger: logger)
        incidentManager = IncidentManager(rootURL: AppPaths.incidents, store: store, fileSystem: fileSystem, policy: settings.incidentPolicy, logger: logger)
        buffer = RollingBufferManager(store: store, incidents: incidentManager, policy: settings.retentionPolicy, logger: logger)
        capture = CameraCaptureService(logger: logger)
        exporter = ClipExportService(logger: logger)
        motionDetector = MotionIncidentDetector(configuration: settings.motionSensitivity.configuration, logger: logger)
        safetyKit = SafetyKitIncidentDetector(logger: logger)

        capture.sink = router
        capture.eventHandler = { [weak self] event in self?.handle(event) }
        motionDetector.onIncident = { [weak self] detected in
            Task { await self?.triggerIncident(source: detected.source, note: detected.note, occurredAt: detected.occurredAt) }
        }
        safetyKit.onIncident = { [weak self] detected in
            Task { await self?.triggerIncident(source: detected.source, note: detected.note, occurredAt: detected.occurredAt) }
        }
        startIngestPipeline()
        startIncidentEventConsumer()
        installLifecycleObservers()
        settings.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.applySettings() } }
            .store(in: &cancellables)
    }

    private var bootstrapState: BootstrapState = .notStarted

    private enum BootstrapState { case notStarted, running, done }

    /// Ensures storage is loaded before any work that depends on it. A SafetyKit event can launch the
    /// process in the background with no scene, so `bootstrap()` cannot be assumed to have run.
    func bootstrapIfNeeded() async {
        switch bootstrapState {
        case .done:
            return
        case .running:
            while bootstrapState == .running { try? await Task.sleep(for: .milliseconds(50)) }
        case .notStarted:
            await bootstrap()
        }
    }

    /// Call once at launch. Rebuilds the on-disk index, recovers interrupted incidents and assembles
    /// anything left pending by a previous run of the app.
    func bootstrap() async {
        guard bootstrapState == .notStarted else { await bootstrapIfNeeded(); return }
        bootstrapState = .running
        defer { bootstrapState = .done }
        do {
            try AppPaths.prepare()
            let report = try await store.load()
            logger.notice(.app, "Launch: buffer index \(report.indexed) segments, \(report.orphanFilesRemoved) orphans removed")
            let recovered = try await incidentManager.load()
            logger.notice(.app, "Launch: \(recovered.count) incidents on disk")
        } catch {
            lastError = "Storage setup failed: \(error.localizedDescription)"
            logger.fault(.app, "Bootstrap failed: \(error)")
        }
        refreshPermissions()
        safetyKit.start()
        await refreshIncidents()
        await refreshStats()
        for incident in incidents where incident.state == .readyToAssemble {
            await assemble(incident.id)
        }
        // Retention also runs without a session so a relaunch trims stale footage.
        _ = try? await buffer.enforceRetention()
        await refreshStats()
        if settings.autoStartRecording, permissions.cameraGranted {
            await start()
        }
    }

    // MARK: Session control

    func start() async {
        guard !isTransitioning, !state.isActive else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        lastError = nil
        statusMessage = nil
        userWantsRecording = true
        recoveryAttempts = 0
        transition(.startRequested)

        var camera = CameraCaptureService.cameraAuthorization()
        if camera == .notDetermined {
            _ = await CameraCaptureService.requestCameraAccess()
            camera = CameraCaptureService.cameraAuthorization()
        }
        if settings.audioEnabled, CameraCaptureService.microphoneAuthorization() == .notDetermined {
            _ = await CameraCaptureService.requestMicrophoneAccess()
        }
        refreshPermissions()
        guard camera == .authorized else {
            fail("Camera access is required. Enable it in Settings > Privacy & Security > Camera.")
            return
        }

        await refreshStats()
        if storage?.level == .critical {
            fail("Not enough free space to record. Free up at least \(settings.minimumFreeMegabytes) MB and try again.")
            return
        }

        do {
            configuration = try await capture.configureAndStart(quality: settings.quality, audioEnabled: settings.audioEnabled, stabilization: settings.stabilizationEnabled)
            try await beginRun()
            sessionStartedAt = Date()
            currentFrameRate = settings.quality.frameRate
            applyIdleTimer()
            startWatchdog()
            if settings.motionDetectionEnabled { motionDetector.start() }
            logger.notice(.recorder, "Recording started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard state.isActive, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        userWantsRecording = false
        transition(.stopRequested)
        motionDetector.stop()
        stopWatchdog()
        await endRun()
        await drainIngest()
        await capture.stop()
        do { try await buffer.endRun() } catch { logger.error(.buffer, "endRun failed: \(error)") }
        transition(.stopped)
        sessionStartedAt = nil
        runStartedAt = nil
        isDimmed = false
        statusMessage = nil
        applyIdleTimer()
        await refreshIncidents()
        await refreshStats()
        logger.notice(.recorder, "Recording stopped")
    }

    func toggle() async {
        if state.isActive { await stop() } else { await start() }
    }

    // MARK: Incidents

    /// The single entry point for every trigger source (manual button, motion, SafetyKit, developer).
    @discardableResult
    func triggerIncident(source: IncidentSource, note: String? = nil, occurredAt: Date? = nil) async -> Incident? {
        // A delayed crash event may arrive in a cold background launch: keep the process alive long
        // enough to link and persist the footage, and make sure the index is loaded first.
        let task = UIApplication.shared.beginBackgroundTask(withName: "dashcam.incident-trigger") {}
        defer { if task != .invalid { UIApplication.shared.endBackgroundTask(task) } }
        await bootstrapIfNeeded()
        do {
            let incident = try await incidentManager.trigger(source: source, note: note, occurredAt: occurredAt)
            await refreshIncidents()
            if incident.state == .collecting {
                statusMessage = "Saving incident: \(Int(incident.footageDuration))s so far, recording \(Int(settings.incidentPolicy.postRoll))s more"
            }
            return incident
        } catch {
            lastError = "Could not save incident: \(error.localizedDescription)"
            logger.error(.incident, "Trigger failed: \(error)")
            return nil
        }
    }

    func deleteIncident(_ id: UUID) async {
        do {
            try await incidentManager.delete(id)
        } catch {
            lastError = "Could not delete clip: \(error.localizedDescription)"
        }
        await refreshIncidents()
        await refreshStats()
    }

    func retryAssembly(_ id: UUID) async {
        await assemble(id)
    }

    func clipURLs(for incident: Incident) -> [URL] {
        incidentManager.clipURLs(for: incident)
    }

    func saveToPhotos(_ incident: Incident) async -> Bool {
        do {
            for url in clipURLs(for: incident) {
                try await ClipExportService.saveToPhotos(url)
            }
            statusMessage = "Saved to Photos"
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func refreshIncidents() async {
        incidents = await incidentManager.allIncidents()
    }

    // MARK: Permissions

    func refreshPermissions() {
        permissions = PermissionSnapshot(camera: CameraCaptureService.cameraAuthorization(), microphone: CameraCaptureService.microphoneAuthorization())
    }

    func requestPermissions() async {
        if CameraCaptureService.cameraAuthorization() == .notDetermined {
            _ = await CameraCaptureService.requestCameraAccess()
        }
        if CameraCaptureService.microphoneAuthorization() == .notDetermined {
            _ = await CameraCaptureService.requestMicrophoneAccess()
        }
        refreshPermissions()
    }

    // MARK: Developer tools

    func developerSimulateCrash() async {
        _ = await triggerIncident(source: .developerSimulation, note: "Simulate Crash")
    }

    /// Fakes a camera interruption (as another app taking the camera would) and its end 3 s later.
    func developerSimulateInterruption() {
        handle(.interrupted(.videoDeviceInUseByAnotherClient))
        Task {
            try? await Task.sleep(for: .seconds(3))
            handle(.interruptionEnded)
        }
    }

    func developerSimulateMediaServicesReset() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue, userInfo: [NSLocalizedDescriptionKey: "Simulated media services reset"])
        handle(.runtimeError(error, mediaServicesWereReset: true))
    }

    func developerSimulateWriterFailure() {
        Task { await handleWriterFailure(CaptureError.configurationFailed("simulated writer failure")) }
    }

    /// Temporarily raises the free-space floor so retention and the critical-storage path can be exercised.
    func developerSetStorageFloor(megabytes: Int?) async {
        storageFloorOverride = megabytes.map { Int64($0) * 1_048_576 }
        await applySettings()
        _ = try? await buffer.enforceRetention()
        await refreshStats()
    }

    func developerReplayMotionTrace(csv: String) throws -> [MotionEvent] {
        try motionDetector.replay(csv: csv)
    }

    var recentLogEntries: [LogEntry] { memoryLog.entries() }

    /// Copies the log file into a shareable temporary location.
    func exportLogFile() -> URL? {
        (logger.sinksOfType(FileLogSink.self).first)?.flush()
        let source = AppPaths.logFile
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("dashcam-\(Int(Date().timeIntervalSince1970)).log")
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: Run management

    private func beginRun() async throws {
        let run = RunID.make(at: Date())
        try await buffer.beginRun(run)
        guard let video = capture.recommendedVideoSettings(quality: settings.quality, segmentInterval: settings.segmentInterval) else {
            throw CaptureError.configurationFailed("no encoder settings available")
        }
        let audio = settings.audioEnabled ? capture.recommendedAudioSettings() : nil
        let angle = capture.horizonLevelCaptureAngle
        let writerConfiguration = SegmentWriter.Configuration(
            runID: run,
            bufferRoot: AppPaths.buffer,
            segmentInterval: settings.segmentInterval,
            videoSettings: video.settings,
            audioSettings: audio,
            transform: CGAffineTransform(rotationAngle: angle * .pi / 180)
        )
        let writer = try SegmentWriter(configuration: writerConfiguration, logger: logger)
        let continuation = ingestContinuation
        writer.onSegment = { segment in continuation?.yield(.segment(segment)) }
        writer.onFailure = { [weak self] error in
            Task { @MainActor in await self?.handleWriterFailure(error) }
        }
        configuration?.codec = video.codec == .hevc ? "HEVC" : "H.264"
        configuration?.audioEnabled = audio != nil
        router.audioMuted = audio == nil
        router.resetStatistics()
        capture.onDataQueue { [router] in
            _ = router.swap(writer)
        }
        runStartedAt = Date()
        transition(.started(run))
        logger.notice(.recorder, "Run \(run) writer armed (\(configuration?.codec ?? "?"), rotation \(Int(angle))°, segment \(Int(settings.segmentInterval))s)")
    }

    /// Finishes the current writer (if any) and waits until its last segment is persisted.
    private func endRun() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            capture.onDataQueue { [router] in
                guard let old = router.swap(nil) else {
                    continuation.resume()
                    return
                }
                old.finish { continuation.resume() }
            }
        }
    }

    private func handleWriterFailure(_ error: Error) async {
        guard case .recording = state, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        logger.error(.recorder, "Writer failure, rotating to a new run: \(error)")
        statusMessage = "Recording hiccup; starting a new run"
        transition(.interruptionBegan("writer failure"))
        await endRun()
        transition(.interruptionEnded)
        do {
            try await beginRun()
            statusMessage = nil
        } catch {
            fail("Could not restart recording: \(error.localizedDescription)")
        }
    }

    // MARK: Capture events

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .interrupted(let reason):
            guard state.isActive else { return }
            if reason == .audioDeviceInUseByAnotherClient {
                audioInterrupted = true
                statusMessage = "Audio paused by a call or alarm; video continues"
                return
            }
            let description = reason.map(CameraCaptureService.describe) ?? "camera interrupted"
            Task { await pauseForInterruption(description) }
        case .interruptionEnded:
            if audioInterrupted {
                audioInterrupted = false
                statusMessage = nil
            }
            if case .interrupted = state, userWantsRecording {
                Task { await resumeAfterInterruption() }
            }
        case .runtimeError(let error, let reset):
            Task { await recover(from: error, mediaServicesReset: reset) }
        case .systemPressure(let level):
            pressureLevel = level
            applyThermalMitigation()
        case .didStartRunning, .didStopRunning:
            break
        }
    }

    private func pauseForInterruption(_ reason: String) async {
        guard state.isActive, !isTransitioning else { return }
        if case .interrupted = state { return }
        isTransitioning = true
        defer { isTransitioning = false }
        transition(.interruptionBegan(reason))
        statusMessage = "Paused: \(reason)"
        await endRun()
        runStartedAt = nil
    }

    private func resumeAfterInterruption() async {
        guard case .interrupted = state, userWantsRecording, !isTransitioning else { return }
        isTransitioning = true
        defer { isTransitioning = false }
        transition(.interruptionEnded)
        do {
            if !capture.session.isRunning {
                configuration = try await capture.configureAndStart(quality: settings.quality, audioEnabled: settings.audioEnabled, stabilization: settings.stabilizationEnabled)
            }
            try await beginRun()
            statusMessage = nil
            recoveryAttempts = 0
            applyIdleTimer()
            logger.notice(.recorder, "Resumed after interruption")
        } catch {
            fail("Could not resume recording: \(error.localizedDescription)")
        }
    }

    private func recover(from error: Error, mediaServicesReset: Bool) async {
        guard state.isActive, !isTransitioning else { return }
        recoveryAttempts += 1
        logger.error(.recorder, "Recovering from runtime error (attempt \(recoveryAttempts)): \(error.localizedDescription)")
        if case .interrupted = state {} else {
            isTransitioning = true
            transition(.interruptionBegan("camera error"))
            statusMessage = "Recovering camera"
            await endRun()
            isTransitioning = false
        }
        if mediaServicesReset {
            await capture.reset()
        } else {
            await capture.stop()
        }
        guard recoveryAttempts <= 3 else {
            fail("The camera stopped working repeatedly (\(error.localizedDescription)). Try restarting the phone.")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        await resumeAfterInterruption()
    }

    // MARK: Lifecycle

    private func installLifecycleObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.armBackgroundTask() }
        })
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleDidEnterBackground() }
        })
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.handleDidBecomeActive() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        })
        observers.append(center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshBattery() }
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.thermalState = ProcessInfo.processInfo.thermalState
                self.logger.notice(.capture, "Thermal state \(self.thermalState.rawValue)")
                self.applyThermalMitigation()
            }
        })
    }

    private func armBackgroundTask() {
        guard state.isActive, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "dashcam.finish-run") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// The system interrupts the camera on backgrounding; make sure the writer has flushed its last
    /// segment before the process is suspended, then release the background task.
    private func handleDidEnterBackground() async {
        guard state.isActive else { endBackgroundTask(); return }
        logger.notice(.recorder, "Entering background; finishing current run")
        if case .interrupted = state {} else if !isTransitioning {
            isTransitioning = true
            transition(.interruptionBegan("app in background"))
            isTransitioning = false
        }
        await endRun()
        await drainIngest()
        runStartedAt = nil
        endBackgroundTask()
    }

    private func handleDidBecomeActive() async {
        endBackgroundTask()
        refreshPermissions()
        if case .interrupted = state, userWantsRecording {
            // If the system already ended the interruption we resume here; otherwise interruptionEnded will.
            await resumeAfterInterruption()
        }
        await refreshStats()
    }

    // MARK: Thermal

    private func applyThermalMitigation() {
        guard state.isActive else { return }
        var target = settings.quality.frameRate
        switch pressureLevel {
        case .nominal, .fair: break
        case .serious: target = 24
        case .critical: target = 15
        case .shutdown: return
        default: target = 24
        }
        if thermalState == .critical { target = min(target, 15) }
        if thermalState == .serious { target = min(target, 24) }
        if target != currentFrameRate {
            currentFrameRate = target
            capture.setFrameRate(target)
            statusMessage = target < settings.quality.frameRate ? "Reducing frame rate to \(target) fps to cool down" : nil
        }
    }

    // MARK: Watchdog

    private func startWatchdog() {
        stopWatchdog()
        watchdog = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func watchdogTick() {
        videoFrames = router.videoFrames
        droppedFrames = router.droppedFrames
        guard case .recording = state, !isTransitioning, let started = runStartedAt else { return }
        let stalled: Bool
        if let gap = router.secondsSinceLastVideoFrame {
            stalled = gap > 8
        } else {
            stalled = Date().timeIntervalSince(started) > 10
        }
        if stalled {
            logger.fault(.recorder, "No video frames while recording; restarting capture")
            Task { await recover(from: CaptureError.configurationFailed("video frames stopped arriving"), mediaServicesReset: false) }
        }
    }

    // MARK: Ingest pipeline

    private func startIngestPipeline() {
        let (stream, continuation) = AsyncStream<IngestItem>.makeStream(bufferingPolicy: .unbounded)
        ingestContinuation = continuation
        ingestTask = Task { [weak self] in
            for await item in stream {
                guard let self else { return }
                switch item {
                case .segment(let segment):
                    await self.ingest(segment)
                case .barrier(let waiter):
                    waiter.resume()
                }
            }
        }
    }

    private func ingest(_ segment: Segment) async {
        do {
            let plan = try await buffer.ingest(segment)
            lastSegmentAt = Date()
            if plan.isStorageCritical, state.isActive {
                logger.fault(.storage, "Storage critical during recording; stopping")
                await stop()
                lastError = "Recording stopped: the phone is almost out of storage."
            }
        } catch {
            logger.error(.buffer, "Ingest failed for \(segment.relativePath): \(error)")
        }
        await refreshStats()
        if segment.kind == .media, activeIncident != nil || incidents.contains(where: { !$0.isFinished }) {
            await refreshIncidents()
        }
    }

    private func drainIngest() async {
        guard let ingestContinuation else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ingestContinuation.yield(.barrier(continuation))
        }
    }

    // MARK: Incident events

    private func startIncidentEventConsumer() {
        eventsTask = Task { [weak self] in
            guard let events = self?.incidentManager.events else { return }
            for await event in events {
                guard let self else { return }
                await self.handleIncidentEvent(event)
            }
        }
    }

    private func handleIncidentEvent(_ event: IncidentEvent) async {
        switch event {
        case .triggered, .updated:
            break
        case .readyToAssemble(let incident):
            statusMessage = "Incident footage secured (\(Int(incident.footageDuration))s); exporting"
            await assemble(incident.id)
        case .completed(let incident):
            statusMessage = "Incident clip saved (\(Int(incident.footageDuration))s)"
        case .failed(let incident):
            lastError = "Incident could not be saved: \(incident.failureReason ?? "unknown error")"
        }
        await refreshIncidents()
    }

    private func assemble(_ id: UUID) async {
        guard !assembling.contains(id) else { return }
        assembling.insert(id)
        defer { assembling.remove(id) }
        do {
            _ = try await incidentManager.assemble(id, using: exporter)
        } catch {
            logger.error(.export, "Assembly failed for \(id): \(error)")
        }
        await refreshIncidents()
        await refreshStats()
    }

    // MARK: Stats and settings

    func refreshStats() async {
        bufferedSeconds = await buffer.bufferedDuration()
        bufferSegmentCount = await store.count
        let available = (try? await store.availableCapacity()) ?? 0
        let bufferBytes = await store.totalBytes
        let incidentBytes = AppPaths.directorySize(AppPaths.incidents)
        storage = StorageStatus.evaluate(availableBytes: available, bufferBytes: bufferBytes, incidentBytes: incidentBytes, policy: effectiveRetentionPolicy)
    }

    private var effectiveRetentionPolicy: RetentionPolicy {
        var policy = settings.retentionPolicy
        if let storageFloorOverride { policy.minimumFreeBytes = storageFloorOverride }
        return policy
    }

    private func applySettings() async {
        await buffer.setPolicy(effectiveRetentionPolicy)
        await incidentManager.setPolicy(settings.incidentPolicy)
        motionDetector.updateConfiguration(settings.motionSensitivity.configuration)
        if state.isActive {
            if settings.motionDetectionEnabled { motionDetector.start() } else { motionDetector.stop() }
            router.audioMuted = !settings.audioEnabled || configuration?.audioEnabled == false
        }
        applyIdleTimer()
    }

    private func applyIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = state.isActive && settings.keepScreenAwake
        // Battery monitoring only while a session is active (Apple: enable it only when needed).
        UIDevice.current.isBatteryMonitoringEnabled = state.isActive
        refreshBattery()
    }

    private func refreshBattery() {
        batteryState = UIDevice.current.batteryState
        batteryLevel = UIDevice.current.batteryLevel
    }

    /// True while recording on battery power; the UI shows a "not charging" hint.
    var isRecordingUnplugged: Bool { state.isActive && batteryState == .unplugged }

    private func transition(_ event: RecorderEvent) {
        if let next = RecorderStateMachine.reduce(state, event) {
            logger.debug(.recorder, "State \(state) --\(event)--> \(next)")
            state = next
        } else {
            logger.warning(.recorder, "Ignored event \(event) in state \(state)")
        }
    }

    private func fail(_ message: String) {
        lastError = message
        logger.error(.recorder, "Recording failed: \(message)")
        transition(.failed(message))
        userWantsRecording = false
        motionDetector.stop()
        stopWatchdog()
        runStartedAt = nil
        sessionStartedAt = nil
        isDimmed = false
        applyIdleTimer()
        Task { await capture.stop() }
    }
}
