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

/// Where the coordinator keeps footage. The app uses its Application Support directories; tests pass
/// temporary ones so they never touch the app's own buffer.
struct StorageLocations {
    var buffer: URL
    var incidents: URL
    /// True for the app's real directories, which get backup exclusions at launch.
    var isAppDefault: Bool

    static let app = StorageLocations(buffer: AppPaths.buffer, incidents: AppPaths.incidents, isAppDefault: true)
}

/// A message for the Record screen. Each instance has its own identity so the UI can dismiss one
/// banner without hiding the next identical message (two incidents in a row produce the same text).
struct Banner: Identifiable, Equatable {
    let id = UUID()
    let text: String
}

/// Orchestrates the dash-cam session. Everything the UI shows comes from here; everything the
/// capture layer produces flows through here into DashcamCore.
///
/// Recording is foreground-only on iOS (camera use is prohibited in the background and the screen
/// lock backgrounds the app), so the coordinator treats backgrounding and system interruptions as
/// "finish the current run so its footage is on disk, then start a new run when allowed".
///
/// Concurrency model: everything here runs on the main actor. Operations that finish or start a
/// writer are *transitions*; only one runs at a time (`isTransitioning`). Requests that arrive during
/// a transition are not dropped: they are recorded (`stopRequested`, `pendingRotation`,
/// `pendingWriterFailure`) and `reconcile()` acts on them, and on the session's real state, as soon
/// as the transition ends. The watchdog repeats the same reconciliation every 5 s as a backstop.
@MainActor
final class RecordingCoordinator: ObservableObject {
    // MARK: Published state

    @Published private(set) var state: RecorderState = .idle
    @Published private(set) var configuration: CaptureConfigurationSummary?
    /// The camera the preview should follow; set once the session is configured, cleared on reset.
    @Published private(set) var previewDevice: AVCaptureDevice?
    @Published private(set) var bufferedSeconds: TimeInterval = 0
    @Published private(set) var bufferSegmentCount = 0
    @Published private(set) var storage: StorageStatus?
    @Published private(set) var incidents: [Incident] = []
    @Published private(set) var lastError: Banner?
    @Published private(set) var statusMessage: Banner?
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
    /// Developer override of the free-space floor, in megabytes; nil means the setting applies.
    @Published private(set) var storageFloorOverrideMegabytes: Int?
    @Published var isDimmed = false

    /// True while the current run has an audio track (audio on, microphone granted and present).
    @Published private(set) var runHasAudio = false

    var activeIncident: Incident? { incidents.first { $0.state == .collecting } }
    var isRecording: Bool { if case .recording = state { return true } else { return false } }
    /// Whether the current run asked for audio; differs from `runHasAudio` when the microphone is
    /// denied or absent, so settings changes do not keep rotating runs that can never get audio.
    private var runAudioRequested = false

    // MARK: Dependencies

    let settings: AppSettings
    let logger: DashcamLogger
    let memoryLog: InMemoryLogSink
    let capture: any CaptureControlling
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
    private var stopRequested = false
    private var pendingRotation: (reason: String, reconfigure: Bool)?
    private var pendingWriterFailure: (run: RunID, error: Error)?
    private var pendingRecovery: (error: Error, reset: Bool)?
    private var pendingInterruption: String?
    private var writerFailures: [Date] = []
    /// When the audio interruption began; the watchdog clears a stale flag if no ended notification comes.
    private var audioInterruptedAt: Date?
    /// One resume is attempted while only audio is interrupted; if that run gets no frames it is paused
    /// again and no further resume is tried until the session's interruption clears.
    private var resumedDuringAudioInterruption = false
    /// The segment interval the current writer was built with (the setting may change mid-run).
    private var runSegmentInterval: TimeInterval = 4
    /// The teardown started by fail(); start() waits for it so a restart cannot race it.
    private var failTeardown: Task<Void, Never>?
    /// Set when bootstrap held auto-start back for the consent screen; only then does Continue start.
    private var autoStartDeferredByOnboarding = false
    private var interruptedAt: Date?
    private var runAngle: CGFloat = 0
    private var rotationCheck: Task<Void, Never>?
    private var runTeardown: Task<Void, Never>?
    /// Developer tool: makes the coordinator treat the session as interrupted for a few seconds.
    private var simulatedInterruption = false
    private var ingestContinuation: AsyncStream<IngestItem>.Continuation?
    private var ingestTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var watchdog: Timer?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var assembling = Set<UUID>()
    private var storageFloorOverride: Int64?
    private var clipsSavedToPhotos = Set<String>()
    private var statusClearTask: Task<Void, Never>?

    private let storageLocations: StorageLocations

    /// - Parameters:
    ///   - capture: The camera. Defaults to the real `CameraCaptureService`; tests inject a fake.
    ///   - storage: Where footage lives. Defaults to the app's directories.
    init(settings: AppSettings, logger: DashcamLogger, memoryLog: InMemoryLogSink, capture: (any CaptureControlling)? = nil, storage: StorageLocations = .app) {
        self.settings = settings
        self.logger = logger
        self.memoryLog = memoryLog
        self.storageLocations = storage
        let fileSystem = DefaultFileSystem()
        store = SegmentStore(rootURL: storage.buffer, fileSystem: fileSystem, logger: logger)
        incidentManager = IncidentManager(rootURL: storage.incidents, store: store, fileSystem: fileSystem, policy: settings.incidentPolicy, logger: logger)
        buffer = RollingBufferManager(store: store, incidents: incidentManager, policy: settings.retentionPolicy, logger: logger)
        self.capture = capture ?? CameraCaptureService(logger: logger)
        exporter = ClipExportService(logger: logger)
        motionDetector = MotionIncidentDetector(configuration: settings.motionSensitivity.configuration, logger: logger)
        safetyKit = SafetyKitIncidentDetector(logger: logger)

        self.capture.sink = router
        // Delivered on the main queue by the capture service, but the closure type is nonisolated;
        // hop explicitly so the call is main-actor isolated. Ordering between these Tasks is not
        // guaranteed, which is why `handle` records intent instead of assuming order.
        self.capture.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        motionDetector.onIncident = { [weak self] detected in
            Task { await self?.triggerIncident(source: detected.source, note: detected.note, occurredAt: detected.occurredAt) }
        }
        // SafetyKit marks an event handled only when this returns true, so a failed trigger (storage not
        // ready in a cold background launch) can still be protected when the system redelivers it.
        safetyKit.onIncident = { [weak self] detected in
            guard let self else { return false }
            return await self.triggerIncident(source: detected.source, note: detected.note, occurredAt: detected.occurredAt) != nil
        }
        startIngestPipeline()
        startIncidentEventConsumer()
        installLifecycleObservers()
        settings.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { await self?.applySettings() } }
            .store(in: &cancellables)
    }

    // MARK: Bootstrap

    private var storageLoad: Task<Void, Never>?
    private var launchWorkDone = false

    /// Ensures the on-disk index and incidents are loaded before any work that depends on them. A
    /// SafetyKit event can launch the process in the background with no scene, so `bootstrap()` cannot
    /// be assumed to have run. Cheap after the first call.
    func bootstrapIfNeeded() async {
        if storageLoad == nil {
            storageLoad = Task { @MainActor [weak self] in await self?.loadStorage() }
        }
        await storageLoad?.value
    }

    /// Call once at launch from the UI. Loads storage, then does the launch work that may take a while
    /// (pending exports, retention, auto-start) without holding up triggers that only need the index.
    func bootstrap() async {
        await bootstrapIfNeeded()
        guard !launchWorkDone else { return }
        launchWorkDone = true
        // Retention also runs without a session so a relaunch trims stale footage before the
        // free-space gate in start() looks at it.
        _ = try? await buffer.enforceRetention()
        await refreshStats()
        // Never record before the consent screen has been accepted (App Review 2.5.14).
        if settings.autoStartRecording {
            if settings.hasCompletedOnboarding {
                if permissions.cameraGranted { await start() }
            } else {
                autoStartDeferredByOnboarding = true
            }
        }
        // Recovered exports can take many seconds each (passthrough remux of hundreds of MB); they
        // must not hold the camera back, so they run after the session is up.
        let pending = incidents.filter { $0.state == .readyToAssemble }.map(\.id)
        if !pending.isEmpty {
            Task { @MainActor [weak self] in
                for id in pending { await self?.assemble(id) }
            }
        }
    }

    /// The consent screen's Continue button. Starts recording only if bootstrap deferred an auto-start
    /// for it; re-reading the welcome screen from Settings must never start a recording.
    func onboardingCompleted() async {
        guard autoStartDeferredByOnboarding else { return }
        autoStartDeferredByOnboarding = false
        if settings.autoStartRecording, permissions.cameraGranted, !state.isActive {
            await start()
        }
    }

    private func loadStorage() async {
        do {
            if storageLocations.isAppDefault {
                try AppPaths.prepare()
            } else {
                for url in [storageLocations.buffer, storageLocations.incidents] {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                }
            }
            let report = try await store.load()
            logger.notice(.app, "Launch: buffer index \(report.indexed) segments, \(report.orphanFilesRemoved) orphans removed")
            let recovered = try await incidentManager.load()
            logger.notice(.app, "Launch: \(recovered.count) incidents on disk")
        } catch {
            setError("Storage setup failed: \(error.localizedDescription)")
            logger.fault(.app, "Bootstrap failed: \(error)")
        }
        refreshPermissions()
        safetyKit.start()
        await refreshIncidents()
        await refreshStats()
    }

    // MARK: Session control

    func start() async {
        // A failed session tears itself down asynchronously; a restart must not race that teardown.
        if let teardown = failTeardown { await teardown.value }
        guard !state.isActive, beginTransition() else { return }
        defer { endTransition() }
        setError(nil)
        setStatus(nil)
        userWantsRecording = true
        recoveryAttempts = 0
        writerFailures.removeAll()
        clearPendingIntents()
        transition(.startRequested)

        var camera = capture.currentCameraAuthorization()
        if camera == .notDetermined {
            _ = await capture.requestCameraPermission()
            camera = capture.currentCameraAuthorization()
        }
        if settings.audioEnabled, capture.currentMicrophoneAuthorization() == .notDetermined {
            _ = await capture.requestMicrophonePermission()
        }
        refreshPermissions()
        guard camera == .authorized else {
            fail("Camera access is required. Enable it in Settings > Privacy & Security > Camera.")
            return
        }

        await refreshStats()
        if storage?.level == .critical {
            fail("Not enough free space to record. Free up at least \(effectiveRetentionPolicy.minimumFreeBytes / 1_048_576) MB and try again.")
            return
        }

        do {
            configuration = try await capture.configureAndStart(quality: settings.quality, audioEnabled: settings.audioEnabled, stabilization: settings.stabilizationEnabled)
            previewDevice = capture.videoDevice
            guard case .starting = state else {
                logger.warning(.recorder, "State changed to \(state) while the camera was starting; not arming a writer")
                return
            }
            try await beginRun()
            sessionStartedAt = Date()
            resyncFrameRate()
            applyIdleTimer()
            startWatchdog()
            if settings.motionDetectionEnabled { motionDetector.start() }
            logger.notice(.recorder, "Recording started")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        guard state.isActive else { return }
        // Intent is recorded before the guard: a Stop tapped during a pause/resume must win over the
        // automatic resume that would otherwise follow.
        userWantsRecording = false
        guard beginTransition() else {
            stopRequested = true
            logger.notice(.recorder, "Stop requested during a transition; will stop when it ends")
            return
        }
        defer { endTransition() }
        stopRequested = false
        // .stopping is not an active state, so the lifecycle-armed background task does not cover this
        // flush; hold one here so a lock during the final finishWriting cannot suspend us mid-flush.
        let flushTask = BackgroundTaskHolder(name: "dashcam.stop")
        defer { flushTask.end() }
        transition(.stopRequested)
        motionDetector.stop()
        stopWatchdog()
        rotationCheck?.cancel()
        await endRun()
        await drainIngest()
        await capture.stop()
        do { try await buffer.endRun() } catch { logger.error(.buffer, "endRun failed: \(error)") }
        transition(.stopped)
        sessionStartedAt = nil
        runStartedAt = nil
        isDimmed = false
        clearPendingIntents()
        writerFailures.removeAll()
        setStatus(nil)
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
            var incident = try await incidentManager.trigger(source: source, note: note, occurredAt: occurredAt)
            saveMotionTrace(for: incident)
            if incident.state == .collecting, !state.isActive {
                // Nothing is recording, so no post-roll can ever arrive: close the incident with the
                // buffered footage instead of leaving it "collecting" until the next session. A stop or
                // failure teardown may still be flushing the writer's last segment (the seconds right
                // before the tap), so join it and drain ingest first; then re-check, because a new
                // session may have started while we waited. Never reached from ingest itself.
                await endRun()
                await drainIngest()
                if !state.isActive {
                    try await incidentManager.recordingDidStop()
                }
                incident = await incidentManager.incident(incident.id) ?? incident
            }
            await refreshIncidents()
            if incident.state == .collecting {
                if isRecording {
                    setStatus("Saving incident: \(Int(incident.footageDuration))s so far, recording \(Int(settings.incidentPolicy.postRoll))s more")
                } else {
                    setStatus("Saving incident: \(Int(incident.footageDuration))s so far; finishes when recording resumes")
                }
            }
            return incident
        } catch {
            setError("Could not save incident: \(error.localizedDescription)")
            logger.error(.incident, "Trigger failed: \(error)")
            return nil
        }
    }

    /// Writes the last minute of motion samples next to the incident so thresholds can be tuned from
    /// real drives. Best effort: never affects footage handling.
    private func saveMotionTrace(for incident: Incident) {
        let samples = motionDetector.recentSamples()
        guard !samples.isEmpty else { return }
        let url = incidentManager.directory(for: incident.id).appendingPathComponent("motion.csv")
        do {
            try MotionTrace.csv(from: samples).write(to: url, atomically: true, encoding: .utf8)
            logger.info(.motion, "Saved \(samples.count) motion samples with incident \(incident.id)")
        } catch {
            logger.warning(.motion, "Could not save motion trace: \(error)")
        }
    }

    /// Deletion is only offered for finished incidents; the UI mirrors this rule.
    static func canDelete(_ incident: Incident) -> Bool {
        incident.state == .complete || incident.state == .failed
    }

    func deleteIncident(_ id: UUID) async {
        guard let incident = incidents.first(where: { $0.id == id }) else { return }
        guard RecordingCoordinator.canDelete(incident), !assembling.contains(id) else {
            setError("This clip is still being saved. Try again when it finishes.")
            return
        }
        do {
            try await incidentManager.delete(id)
        } catch {
            setError("Could not delete clip: \(error.localizedDescription)")
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

    /// Saves the incident's clips to Photos and returns how many were newly added. Clips already
    /// saved in this process are skipped, so a retry after a partial failure does not duplicate them.
    /// Throws on the first failure; the caller owns the message shown to the user.
    func saveToPhotos(_ incident: Incident) async throws -> Int {
        var saved = 0
        for url in clipURLs(for: incident) where !clipsSavedToPhotos.contains(url.path) {
            try await exporter.saveToPhotos(url)
            clipsSavedToPhotos.insert(url.path)
            saved += 1
        }
        return saved
    }

    func refreshIncidents() async {
        incidents = await incidentManager.allIncidents()
    }

    // MARK: Permissions

    func refreshPermissions() {
        permissions = PermissionSnapshot(camera: capture.currentCameraAuthorization(), microphone: capture.currentMicrophoneAuthorization())
    }

    /// Prompts for the camera and, only if audio recording is on, the microphone.
    func requestPermissions() async {
        if capture.currentCameraAuthorization() == .notDetermined {
            _ = await capture.requestCameraPermission()
        }
        if settings.audioEnabled, capture.currentMicrophoneAuthorization() == .notDetermined {
            _ = await capture.requestMicrophonePermission()
        }
        refreshPermissions()
    }

    // MARK: Developer tools

    func developerSimulateCrash() async {
        _ = await triggerIncident(source: .developerSimulation, note: "Simulate Crash")
    }

    /// Fakes a camera interruption (as another app taking the camera would) and its end 3 s later.
    func developerSimulateInterruption() {
        guard isRecording, !simulatedInterruption else { return }
        simulatedInterruption = true
        handle(.interrupted(.videoDeviceInUseByAnotherClient))
        Task {
            try? await Task.sleep(for: .seconds(3))
            simulatedInterruption = false
            // A real interruption may have begun meanwhile; the session says so, and then a fake
            // "ended" would force a resume the camera cannot honour.
            if !capture.isInterrupted { handle(.interruptionEnded) }
        }
    }

    func developerSimulateMediaServicesReset() {
        let error = NSError(domain: AVFoundationErrorDomain, code: AVError.mediaServicesWereReset.rawValue, userInfo: [NSLocalizedDescriptionKey: "Simulated media services reset"])
        handle(.runtimeError(error, mediaServicesWereReset: true))
    }

    func developerSimulateWriterFailure() {
        guard let run = state.runID else { return }
        Task { await handleWriterFailure(CaptureError.configurationFailed("simulated writer failure"), run: run) }
    }

    /// Temporarily raises the free-space floor so retention and the critical-storage path can be exercised.
    func developerSetStorageFloor(megabytes: Int?) async {
        storageFloorOverrideMegabytes = megabytes
        storageFloorOverride = megabytes.map { Int64($0) * 1_048_576 }
        await applySettings()
        _ = try? await buffer.enforceRetention()
        await refreshStats()
    }

    func developerReplayMotionTrace(csv: String) throws -> [MotionEvent] {
        try motionDetector.replay(csv: csv)
    }

    var recentLogEntries: [LogEntry] { memoryLog.entries() }

    /// Copies the log file into a shareable temporary location, replacing earlier copies.
    func exportLogFile() -> URL? {
        (logger.sinksOfType(FileLogSink.self).first)?.flush()
        let source = AppPaths.logFile
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        let temporary = FileManager.default.temporaryDirectory
        if let stale = try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil) {
            for url in stale where url.lastPathComponent.hasPrefix("dashcam-") && url.pathExtension == "log" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let destination = temporary.appendingPathComponent("dashcam-\(Int(Date().timeIntervalSince1970)).log")
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    // MARK: Transitions

    /// Claims the single transition slot. Returns false if another transition is in flight; callers
    /// then record their intent for `reconcile()` instead of acting.
    private func beginTransition() -> Bool {
        guard !isTransitioning else { return false }
        isTransitioning = true
        return true
    }

    private func endTransition() {
        isTransitioning = false
        reconcile()
    }

    /// Runs after every transition and on every watchdog tick: acts on intent recorded during a
    /// transition and on the session's real state, so nothing is lost to ordering.
    private func reconcile() {
        guard !isTransitioning else { return }
        if stopRequested {
            stopRequested = false
            if state.isActive { Task { await stop() } }
            return
        }
        // A runtime error supersedes a pending writer failure or rotation: recovery replaces the run.
        if let pending = pendingRecovery {
            pendingRecovery = nil
            if state.isActive, pending.reset || !capture.isRunning {
                pendingWriterFailure = nil
                pendingRotation = nil
                Task { await recover(from: pending.error, mediaServicesReset: pending.reset) }
                return
            }
        }
        if let pending = pendingWriterFailure {
            pendingWriterFailure = nil
            if case .recording(let run) = state, run == pending.run {
                Task { await handleWriterFailure(pending.error, run: run) }
                return
            }
        }
        if let pending = pendingRotation {
            pendingRotation = nil
            if isRecording {
                Task { await rotateRun(reason: pending.reason, reconfigure: pending.reconfigure) }
                return
            }
        }
        if let reason = pendingInterruption {
            pendingInterruption = nil
            if case .recording = state, sessionInterrupted {
                Task { await pauseForInterruption(reason) }
                return
            }
        }
        let inBackground = UIApplication.shared.applicationState == .background
        if case .recording = state {
            if inBackground {
                Task { await pauseForInterruption("app in background") }
            } else if !capture.isRunning, !sessionInterrupted {
                // The session died (a runtime error dropped during a transition); do not wait 10 s for the stall check.
                Task { await recover(from: CaptureError.configurationFailed("session stopped running"), mediaServicesReset: false) }
            } else if sessionInterrupted, !videoFramesFlowing, runOldEnoughToJudgeFrames {
                Task { await pauseForInterruption("camera interrupted") }
            }
            return
        }
        if case .interrupted = state, userWantsRecording, !inBackground, interruptionAllowsResume {
            Task { await resumeAfterInterruption() }
        }
    }

    /// The session's interruption flag no longer blocks a resume, or only audio is interrupted and a
    /// video-only resume has not been tried yet for this interruption.
    private var interruptionAllowsResume: Bool {
        !sessionInterrupted || (audioInterrupted && !resumedDuringAudioInterruption)
    }

    /// Right after a run is armed no frame has arrived yet; give the first one 2 s before missing frames
    /// count as a camera interruption.
    private var runOldEnoughToJudgeFrames: Bool {
        runStartedAt.map { Date().timeIntervalSince($0) > 2 } ?? true
    }

    /// Audio is wanted and permitted but the capture graph has no microphone input (denied at start and
    /// granted since, or the input could not be added): the next rotation must rebuild the graph.
    private var needsMicrophoneRebuild: Bool {
        settings.audioEnabled && !audioInterrupted && configuration?.audioEnabled != true
            && capture.currentMicrophoneAuthorization() == .authorized
    }

    private func clearPendingIntents() {
        stopRequested = false
        pendingRotation = nil
        pendingWriterFailure = nil
        pendingRecovery = nil
        pendingInterruption = nil
        audioInterrupted = false
        audioInterruptedAt = nil
        resumedDuringAudioInterruption = false
    }

    /// Makes the coordinator's idea of the frame rate match the device after a (re)configuration and
    /// re-applies thermal mitigation, so a throttle is neither lost by a rebuild nor kept after Stop/Start.
    private func resyncFrameRate() {
        currentFrameRate = configuration?.frameRate ?? settings.quality.frameRate
        thermalState = ProcessInfo.processInfo.thermalState
        applyThermalMitigation(force: true)
    }

    /// The session's interruption flag, or the developer simulation of one.
    private var sessionInterrupted: Bool { capture.isInterrupted || simulatedInterruption }

    /// True while video frames have arrived in the last 2 s. An audio-only interruption (call, alarm)
    /// sets `session.isInterrupted` but leaves video flowing; a camera interruption stops it at once.
    private var videoFramesFlowing: Bool {
        guard let gap = router.secondsSinceLastVideoFrame else { return false }
        return gap < 2
    }

    // MARK: Run management

    private func beginRun() async throws {
        let run = RunID.make(at: Date())
        try await buffer.beginRun(run)
        guard let video = capture.recommendedVideoSettings(quality: settings.quality, segmentInterval: settings.segmentInterval) else {
            throw CaptureError.configurationFailed("no encoder settings available")
        }
        let wantsAudio = settings.audioEnabled && !audioInterrupted
        let audio = wantsAudio ? capture.recommendedAudioSettings() : nil
        let angle = capture.horizonLevelCaptureAngle
        var writerConfiguration = SegmentWriter.Configuration(
            runID: run,
            bufferRoot: store.rootURL,
            segmentInterval: settings.segmentInterval,
            videoSettings: video.settings,
            audioSettings: audio,
            transform: CGAffineTransform(rotationAngle: angle * .pi / 180)
        )
        writerConfiguration.sourceClock = capture.synchronizationClock
        let writer = try SegmentWriter(configuration: writerConfiguration, logger: logger)
        let continuation = ingestContinuation
        writer.onSegment = { segment in continuation?.yield(.segment(segment)) }
        writer.onFailure = { [weak self] error in
            Task { @MainActor in await self?.handleWriterFailure(error, run: run) }
        }
        configuration?.codec = video.codec == .hevc ? "HEVC" : "H.264"
        runAudioRequested = wantsAudio
        runHasAudio = audio != nil
        runAngle = angle
        runSegmentInterval = settings.segmentInterval
        router.audioMuted = audio == nil
        router.resetStatistics()
        capture.onDataQueue { [router, logger] in
            if let old = router.swap(writer) {
                // Should not happen (every path finishes the writer before arming another); if it does,
                // finish the old one so its footage reaches disk instead of vanishing with the object.
                logger.error(.recorder, "beginRun replaced a live writer for run \(old.configuration.runID); finishing it")
                old.finish {}
            }
        }
        runStartedAt = Date()
        if case .recording = state { transition(.rotated(run)) } else { transition(.started(run)) }
        logger.notice(.recorder, "Run \(run) writer armed (\(configuration?.codec ?? "?"), audio \(runHasAudio), rotation \(Int(angle))°, segment \(Int(settings.segmentInterval))s)")
    }

    /// Finishes the current writer (if any) and waits until its last segment is persisted. Concurrent
    /// callers share one teardown, so nobody returns while a writer is still flushing, and a wedged
    /// `finishWriting` cannot freeze every later transition (15 s cap, logged as a fault).
    private func endRun() async {
        // Each call chains a teardown behind the one in flight: it waits for that one, then finishes
        // whatever writer is armed by then (a restart racing a failure teardown arms a new one). With
        // nothing armed the swap is a no-op that resumes at once. Chaining, rather than looping on
        // `runTeardown`, matters: awaiting an already finished task does not suspend, so a waiter that
        // woke before the owner cleared `runTeardown` would spin on the main actor forever.
        let previous = runTeardown
        let task = Task { @MainActor [capture, router, logger] in
            await previous?.value
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(continuation)
                capture.onDataQueue {
                    guard let old = router.swap(nil) else {
                        once.resume()
                        return
                    }
                    old.finish { once.resume() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                    if once.resume() {
                        logger.fault(.recorder, "Writer did not finish within 15 s; continuing without it")
                    }
                }
            }
        }
        runTeardown = task
        await task.value
        if runTeardown == task { runTeardown = nil }
    }

    /// Replaces the writer without leaving the recording state: writer failure, orientation change,
    /// audio coming or going. Costs a sub-second gap at the run boundary; an incident spanning it
    /// simply gets two clip parts.
    private func rotateRun(reason: String, reconfigure: Bool = false) async {
        guard isRecording else { return }
        guard beginTransition() else {
            pendingRotation = (reason, reconfigure || (pendingRotation?.reconfigure ?? false))
            return
        }
        defer { endTransition() }
        logger.notice(.recorder, "Rotating run: \(reason)")
        await endRun()
        do {
            if reconfigure || needsMicrophoneRebuild {
                configuration = try await capture.configureAndStart(quality: settings.quality, audioEnabled: settings.audioEnabled, stabilization: settings.stabilizationEnabled)
                previewDevice = capture.videoDevice
                resyncFrameRate()
            }
            try await beginRun()
        } catch {
            fail("Could not restart recording: \(error.localizedDescription)")
        }
    }

    private func handleWriterFailure(_ error: Error, run: RunID) async {
        guard case .recording(let current) = state, current == run else { return }
        guard !isTransitioning else {
            pendingWriterFailure = (run, error)
            return
        }
        let now = Date()
        writerFailures = writerFailures.filter { now.timeIntervalSince($0) < 120 } + [now]
        guard writerFailures.count <= 3 else {
            fail("Recording failed repeatedly: \(error.localizedDescription)")
            return
        }
        logger.error(.recorder, "Writer failure (\(writerFailures.count) recently), rotating to a new run: \(error)")
        setStatus("Recording hiccup; starting a new run")
        await rotateRun(reason: "writer failure")
        if isRecording { setStatus(nil) }
    }

    // MARK: Capture events

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .interrupted(let reason):
            guard state.isActive else { return }
            if reason == .audioDeviceInUseByAnotherClient {
                guard !audioInterrupted else { return }
                audioInterrupted = true
                audioInterruptedAt = Date()
                resumedDuringAudioInterruption = false
                setStatus("Audio paused by a call or alarm; video continues")
                // A writer whose audio input has gone silent is on undocumented ground; continue in a
                // video-only run and bring audio back in a new run when the interruption ends.
                if isRecording, runHasAudio { Task { await rotateRun(reason: "audio interrupted") } }
                return
            }
            let description = reason.map(CameraCaptureService.describe) ?? "camera interrupted"
            Task { await pauseForInterruption(description) }
        case .interruptionEnded:
            // With a call and a camera interruption overlapping, one "ended" does not mean the audio
            // device is back; the session's flag says whether anything is still interrupted.
            if audioInterrupted, !capture.isInterrupted {
                clearAudioInterruption()
            }
            if case .interrupted = state, userWantsRecording {
                // If a pause is still in flight, reconcile() resumes when it ends.
                if !isTransitioning { Task { await resumeAfterInterruption() } }
            }
        case .runtimeError(let error, let reset):
            Task { await recover(from: error, mediaServicesReset: reset) }
        case .systemPressure(let level):
            pressureLevel = level
            applyThermalMitigation()
        case .rotationAngleChanged(let angle):
            scheduleRotationCheck(angle)
        case .didStartRunning, .didStopRunning:
            break
        }
    }

    /// The audio device is back: clear the flag and, if this run was built without audio, rotate to one with it.
    private func clearAudioInterruption() {
        audioInterrupted = false
        audioInterruptedAt = nil
        resumedDuringAudioInterruption = false
        if isRecording {
            setStatus(nil)
            if settings.audioEnabled, !runAudioRequested { Task { await rotateRun(reason: "audio available again") } }
        }
    }

    /// The writer's transform is fixed when the run starts. When the phone is rotated into its mount
    /// after Start, wait for the orientation to settle (2 s) and then start a new, correctly oriented run.
    private func scheduleRotationCheck(_ angle: CGFloat) {
        rotationCheck?.cancel()
        guard isRecording, angle != runAngle else { return }
        rotationCheck = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            let current = self.capture.horizonLevelCaptureAngle
            guard current != self.runAngle else { return }
            await self.rotateRun(reason: "orientation changed to \(Int(current))°")
        }
    }

    private func pauseForInterruption(_ reason: String) async {
        guard state.isActive else { return }
        if case .interrupted = state { return }
        guard beginTransition() else {
            pendingInterruption = reason // reconcile() acts on it when the transition ends
            return
        }
        defer { endTransition() }
        transition(.interruptionBegan(reason))
        setStatus("Paused: \(reason)")
        await endRun()
        runStartedAt = nil
    }

    private func resumeAfterInterruption() async {
        guard case .interrupted = state, userWantsRecording, beginTransition() else { return }
        defer { endTransition() }
        await performResume()
    }

    /// Body of a resume; the caller holds the transition slot.
    private func performResume() async {
        guard case .interrupted = state, userWantsRecording else { return }
        transition(.interruptionEnded)
        if sessionInterrupted, audioInterrupted { resumedDuringAudioInterruption = true }
        do {
            if !capture.isRunning || needsMicrophoneRebuild {
                configuration = try await capture.configureAndStart(quality: settings.quality, audioEnabled: settings.audioEnabled, stabilization: settings.stabilizationEnabled)
                previewDevice = capture.videoDevice
                resyncFrameRate()
            }
            try await beginRun()
            setStatus(nil)
            applyIdleTimer()
            logger.notice(.recorder, "Resumed after interruption")
        } catch {
            fail("Could not resume recording: \(error.localizedDescription)")
        }
    }

    /// Runtime error (including a media-services reset): finish the writer, rebuild or stop the
    /// session, and resume after a short pause. Holds the transition slot throughout so nothing can
    /// arm a writer against a session that is about to be torn down.
    private func recover(from error: Error, mediaServicesReset: Bool) async {
        guard state.isActive else { return }
        guard beginTransition() else {
            // Recorded, not dropped: reconcile() runs it when the current transition ends. A reset is
            // never downgraded by a later plain error.
            pendingRecovery = (error, mediaServicesReset || (pendingRecovery?.reset ?? false))
            logger.notice(.recorder, "Runtime error during a transition; recovering when it ends")
            return
        }
        defer { endTransition() }
        pendingRecovery = nil
        recoveryAttempts += 1
        logger.error(.recorder, "Recovering from runtime error (attempt \(recoveryAttempts)): \(error.localizedDescription)")
        if case .interrupted = state {} else {
            transition(.interruptionBegan("camera error"))
            setStatus("Recovering camera")
            await endRun()
            runStartedAt = nil
        }
        if mediaServicesReset {
            await capture.reset()
            previewDevice = nil
        } else {
            await capture.stop()
        }
        guard recoveryAttempts <= 3 else {
            fail("The camera stopped working repeatedly (\(error.localizedDescription)). Try restarting the phone.")
            return
        }
        try? await Task.sleep(for: .seconds(1))
        guard !stopRequested, UIApplication.shared.applicationState != .background else { return }
        await performResume()
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
    /// segment and the index has it before the process is suspended, then release the background task.
    /// The camera interruption notification may arrive before or after this; both orders end here.
    private func handleDidEnterBackground() async {
        guard state.isActive else { endBackgroundTask(); return }
        logger.notice(.recorder, "Entering background; finishing current run")
        await waitForTransition(upTo: 2)
        await pauseForInterruption("app in background")
        await endRun()          // joins an in-flight teardown started by the interruption path
        await drainIngest()
        endBackgroundTask()
    }

    private func waitForTransition(upTo seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        while isTransitioning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func handleDidBecomeActive() async {
        endBackgroundTask()
        refreshPermissions()
        if case .interrupted = state, userWantsRecording, !isTransitioning, !sessionInterrupted {
            // The system already ended the interruption; otherwise interruptionEnded (or the watchdog) resumes.
            await resumeAfterInterruption()
        }
        await refreshStats()
    }

    // MARK: Thermal

    /// `force` re-applies the target even when the bookkeeping already matches: after a rebuild the
    /// device is back at the format's rate, and after Stop/Start it keeps whatever was last set.
    private func applyThermalMitigation(force: Bool = false) {
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
        let changed = target != currentFrameRate
        if changed || force {
            currentFrameRate = target
            capture.setFrameRate(target)
            if changed || target < settings.quality.frameRate {
                setStatus(target < settings.quality.frameRate ? "Reducing frame rate to \(target) fps to cool down" : nil)
            }
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
        guard !isTransitioning else { return }
        let inBackground = UIApplication.shared.applicationState == .background
        // The audio flag has no "ended" guarantee either: clear it once the session is no longer
        // interrupted for 5 s, and bring audio back.
        if audioInterrupted, !sessionInterrupted, !inBackground,
           let since = audioInterruptedAt, Date().timeIntervalSince(since) > 5 {
            logger.notice(.recorder, "Audio interruption over but no notification arrived; restoring audio")
            clearAudioInterruption()
        }
        // Interruption-ended delivery is not guaranteed by Apple; the session's isInterrupted flag is
        // the truth source. Reconcile our state with it in both directions.
        if case .interrupted = state, userWantsRecording, interruptionAllowsResume, !inBackground,
           let since = interruptedAt, Date().timeIntervalSince(since) > 5 {
            logger.notice(.recorder, "Session no longer interrupted but no notification arrived; resuming")
            Task { await resumeAfterInterruption() }
            return
        }
        // A camera interruption stops frames at once, whether or not a call is also interrupting
        // audio; pause instead of spending recovery attempts on a session that cannot deliver.
        if case .recording = state, sessionInterrupted, !videoFramesFlowing, runOldEnoughToJudgeFrames {
            logger.warning(.recorder, "Session reports interrupted while recording; pausing run")
            Task { await pauseForInterruption("camera interrupted") }
            return
        }
        guard case .recording = state, let started = runStartedAt else { return }
        if !capture.isRunning, !sessionInterrupted, !inBackground {
            logger.fault(.recorder, "Session stopped running while recording; recovering")
            Task { await recover(from: CaptureError.configurationFailed("session stopped running"), mediaServicesReset: false) }
            return
        }
        // While interrupted, missing frames are the interruption, not a stall; do not spend attempts.
        guard !sessionInterrupted else { return }
        let stalled: Bool
        if let gap = router.secondsSinceLastVideoFrame {
            stalled = gap > 8
        } else {
            stalled = Date().timeIntervalSince(started) > 10
        }
        if stalled {
            logger.fault(.recorder, "No video frames while recording; restarting capture")
            Task { await recover(from: CaptureError.configurationFailed("video frames stopped arriving"), mediaServicesReset: false) }
            return
        }
        // Frames arrive but nothing reaches disk: a writer that failed silently or never started. The
        // threshold follows the interval the running writer was built with, not the live setting.
        let lastOutput = max(lastSegmentAt ?? .distantPast, started)
        let silence = Date().timeIntervalSince(lastOutput)
        if silence > max(3 * runSegmentInterval, 15), let run = state.runID {
            logger.fault(.recorder, "Frames arriving but no segment written for \(Int(silence)) s; rotating writer")
            Task { await handleWriterFailure(CaptureError.configurationFailed("segments stopped"), run: run) }
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
            if segment.kind == .media {
                // Footage reaching disk is the evidence of health that resets the failure counters.
                writerFailures.removeAll()
                recoveryAttempts = 0
            }
            if plan.isStorageCritical, case .recording = state {
                logger.fault(.storage, "Storage critical during recording; stopping")
                setError("Recording stopped: the phone is almost out of storage.")
                // Never await stop() here: it drains this very pipeline and would deadlock the loop.
                Task { @MainActor [weak self] in await self?.stop() }
            }
        } catch {
            logger.error(.buffer, "Ingest failed for \(segment.relativePath): \(error)")
        }
        await refreshStats()
        if segment.kind == .media, activeIncident != nil || incidents.contains(where: { !$0.isFinished }) {
            await refreshIncidents()
        }
    }

    /// Resolves once every segment yielded so far has been indexed. Must not be awaited from `ingest`.
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
            setStatus("Incident footage secured (\(Int(incident.footageDuration))s); exporting")
            await assemble(incident.id)
        case .completed(let incident):
            setStatus("Incident clip saved (\(Int(incident.footageDuration))s)", autoClearAfter: 8)
        case .failed(let incident):
            setError("Incident could not be saved: \(incident.failureReason ?? "unknown error")")
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

    // MARK: Banners

    private func setStatus(_ text: String?, autoClearAfter seconds: TimeInterval? = nil) {
        statusClearTask?.cancel()
        statusClearTask = nil
        guard let text else { statusMessage = nil; return }
        let banner = Banner(text: text)
        statusMessage = banner
        if let seconds {
            statusClearTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self, self.statusMessage?.id == banner.id else { return }
                self.statusMessage = nil
            }
        }
    }

    private func setError(_ text: String?) {
        lastError = text.map { Banner(text: $0) }
    }

    // MARK: Stats and settings

    func refreshStats() async {
        bufferedSeconds = await buffer.bufferedDuration()
        bufferSegmentCount = await store.count
        let available = (try? await store.availableCapacity()) ?? 0
        let bufferBytes = await store.totalBytes
        let incidentBytes = AppPaths.directorySize(storageLocations.incidents)
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
        }
        if isRecording, settings.audioEnabled, !audioInterrupted, capture.currentMicrophoneAuthorization() == .notDetermined {
            _ = await capture.requestMicrophonePermission()
            refreshPermissions()
        }
        let wantsAudio = settings.audioEnabled && !audioInterrupted
        if isRecording, wantsAudio != runAudioRequested || (wantsAudio && !runHasAudio && needsMicrophoneRebuild) {
            // Audio was switched on or off mid-session (or the microphone became available): a new run
            // with the right tracks, rebuilding the capture graph if the microphone is not in it yet.
            await rotateRun(reason: wantsAudio ? "audio turned on" : "audio turned off", reconfigure: needsMicrophoneRebuild)
        } else if isRecording, settings.segmentInterval != runSegmentInterval {
            // A writer's segment interval cannot change after it starts; a new run picks the setting up.
            await rotateRun(reason: "segment length changed")
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
            if case .interrupted = next { interruptedAt = Date() } else { interruptedAt = nil }
        } else {
            logger.warning(.recorder, "Ignored event \(event) in state \(state)")
        }
    }

    /// Unrecoverable failure: publish it, then tear the session down completely so no writer is left
    /// armed and any collecting incident is closed with the footage it has (otherwise it would sit in
    /// "collecting" until the next launch).
    private func fail(_ message: String) {
        setError(message)
        logger.error(.recorder, "Recording failed: \(message)")
        transition(.failed(message))
        userWantsRecording = false
        motionDetector.stop()
        stopWatchdog()
        rotationCheck?.cancel()
        runStartedAt = nil
        sessionStartedAt = nil
        isDimmed = false
        audioInterrupted = false
        audioInterruptedAt = nil
        applyIdleTimer()
        // The teardown holds a background task (.failed is not an active state, so the lifecycle one
        // does not cover it) and takes the transition slot, so a Start tapped meanwhile waits for it
        // (start() awaits failTeardown) instead of arming a writer the teardown then stops.
        let holder = BackgroundTaskHolder(name: "dashcam.fail-teardown")
        failTeardown = Task { @MainActor [weak self] in
            defer { holder.end() }
            guard let self else { return }
            await self.waitForTransition(upTo: 20)
            self.isTransitioning = true
            defer {
                self.isTransitioning = false
                self.failTeardown = nil
            }
            await self.endRun()
            await self.drainIngest()
            await self.capture.stop()
            do { try await self.buffer.endRun() } catch { self.logger.error(.buffer, "endRun after failure: \(error)") }
            await self.refreshIncidents()
            await self.refreshStats()
        }
    }
}

/// A UIKit background task that ends itself on expiry and is idempotent to end, for flushes that
/// happen while the recorder is not in an active state (stop and failure teardowns).
@MainActor
private final class BackgroundTaskHolder {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}

/// Resumes a continuation at most once, from any thread. Lets a timeout and the real completion race safely.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation = continuation
    }

    /// Returns true if this call performed the resume.
    @discardableResult
    func resume() -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume()
        return pending != nil
    }
}
