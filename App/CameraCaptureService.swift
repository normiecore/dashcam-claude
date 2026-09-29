import AVFoundation
import OSLog
import UIKit

struct CaptureStatus {
    let isRecording: Bool
    let isBusy: Bool
    let isStarting: Bool
    let isStopping: Bool
    let message: String
    let droppedFrames: Int
    let snapshot: StoreSnapshot
}

enum CaptureServiceError: LocalizedError {
    case cameraDenied, cameraUnavailable, configurationFailed, thermalPressure, unavailableCapacity
    case lowCapacity, busy, noRecording, incompleteIncident

    var errorDescription: String? {
        switch self {
        case .cameraDenied: return "Camera access is required to record. Enable it in Settings."
        case .cameraUnavailable: return "The rear wide camera is unavailable."
        case .configurationFailed: return "The 720p camera capture session could not be configured."
        case .thermalPressure: return "iPhone is too warm to start a reliable recording."
        case .unavailableCapacity: return "Available storage could not be checked safely."
        case .lowCapacity: return "Recording stopped to preserve the storage reserve."
        case .busy: return "Stop recording and wait for movies to finish before changing the library."
        case .noRecording: return "Start recording before saving an incident."
        case .incompleteIncident: return "Incident media is incomplete or missing; retained files need recovery."
        }
    }
}

/// The session, its sample delegates, writers and the store have one owner: captureQueue.
/// Public callbacks are delivered on the main queue with value snapshots.
final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {
    let captureSession = AVCaptureSession()
    var onUpdate: ((CaptureStatus) -> Void)?
    var onError: ((String) -> Void)?

    private let logger = Logger(subsystem: "com.daz.dashcam", category: "capture")
    private let captureQueue = DispatchQueue(label: "app.dashcam.capture", qos: .userInitiated)
    private let store: RecordingStore
    private let root: URL
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var finalizationWarning: DispatchSourceTimer?

    private var sessionID: UUID?
    private var active: (record: SegmentRecord, writer: SegmentWriter)?
    private var pendingFinishes = 0
    private var startGeneration = 0
    private var starting = false
    private var stopping = false
    private var recording = false
    private var hasRecordedFrame = false
    private var useAudio = false
    private var audioRequested = false
    private var droppedFrames = 0
    private var consecutiveVideoDrops = 0
    private var lastVideoHostTime: Double?
    private var startedHostTime: Double?
    private var stopReason = "user"
    private var stopCompletions: [() -> Void] = []
    private var message = "Ready to record."
    private var storageFault: String?

    init(root: URL? = nil) throws {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask, appropriateFor: nil, create: true)
        self.root = root ?? support.appendingPathComponent("Dashcam", isDirectory: true)
        store = try RecordingStore(root: self.root)
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVCaptureSessionRuntimeError,
                                            object: captureSession, queue: nil) { [weak self] _ in
            self?.stop(reason: "Camera runtime error")
        })
        observers.append(center.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                            object: captureSession, queue: nil) { [weak self] _ in
            self?.stop(reason: "Camera interruption")
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: nil) { [weak self] notification in
            guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            self?.stop(reason: "Audio session interruption")
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                            object: nil, queue: nil) { [weak self] _ in
            let state = ProcessInfo.processInfo.thermalState
            if state == .serious || state == .critical {
                self?.stop(reason: "Thermal pressure")
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        watchdog?.cancel()
        finalizationWarning?.cancel()
    }

    func refreshSnapshot() {
        captureQueue.async { [weak self] in self?.publish() }
    }

    func start(audioEnabled: Bool = false) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.starting, !self.stopping, !self.recording, self.pendingFinishes == 0 else { return }
            if let fault = self.storageFault {
                self.report("Recording store needs recovery before another session. Restart the app. \(fault)")
                return
            }
            self.startGeneration += 1
            let generation = self.startGeneration
            self.starting = true
            self.message = "Requesting camera access…"
            self.logger.info("Capture start requested, audio opt-in: \(audioEnabled)")
            self.publish()
            self.requestCameraAccess(generation: generation, audioEnabled: audioEnabled)
        }
    }

    private func requestCameraAccess(generation: Int, audioEnabled: Bool) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestAudioAccess(generation: generation, audioEnabled: audioEnabled)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                guard let self = self else { return }
                self.captureQueue.async {
                    if allowed {
                        self.requestAudioAccess(generation: generation, audioEnabled: audioEnabled)
                    } else if generation == self.startGeneration {
                        self.failStart(CaptureServiceError.cameraDenied)
                    }
                }
            }
        default:
            failStart(CaptureServiceError.cameraDenied)
        }
    }

    private func requestAudioAccess(generation: Int, audioEnabled: Bool) {
        guard generation == startGeneration, starting else { return }
        audioRequested = audioEnabled
        guard audioEnabled else { continueStart(generation: generation, audioEnabled: false); return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            continueStart(generation: generation, audioEnabled: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] allowed in
                guard let self = self else { return }
                self.captureQueue.async {
                    self.continueStart(generation: generation, audioEnabled: allowed)
                }
            }
        default:
            continueStart(generation: generation, audioEnabled: false)
        }
    }

    private func continueStart(generation: Int, audioEnabled: Bool) {
        guard generation == startGeneration, starting else { return }
        // Permission sheets can outlive the foreground scene; never launch capture afterward.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let foreground = UIApplication.shared.applicationState == .active
            self.captureQueue.async {
                guard generation == self.startGeneration, self.starting else { return }
                guard foreground else {
                    self.failStartMessage("Return to the app to start recording.")
                    return
                }
                do {
                    let thermal = ProcessInfo.processInfo.thermalState
                    guard thermal != .serious && thermal != .critical else {
                        throw CaptureServiceError.thermalPressure
                    }
                    try self.configureSession(audioEnabled: audioEnabled)
                    // Starting a session safely reclaims ordinary footage from
                    // stopped sessions before the capacity gate. Otherwise a
                    // low-space device could never reach its own safe cleanup.
                    do { self.sessionID = try self.store.beginSession(at: Date()) }
                    catch { self.latchStorageFault(error); throw error }
                    try self.prepareStorage()
                    self.useAudio = audioEnabled && self.audioOutput != nil
                    self.droppedFrames = 0
                    self.consecutiveVideoDrops = 0
                    self.hasRecordedFrame = false
                    self.startedHostTime = self.hostTime()
                    self.lastVideoHostTime = nil
                    self.captureSession.startRunning() // Never called on the main queue.
                    guard self.captureSession.isRunning else { throw CaptureServiceError.configurationFailed }
                    self.recording = true
                    self.starting = false
                    self.logger.info("Camera session started")
                    self.message = self.audioRequested && !self.useAudio
                        ? "Microphone unavailable; starting video only…"
                        : "Starting camera capture…"
                    self.startWatchdog()
                    self.publish()
                } catch {
                    if self.sessionID != nil {
                        self.starting = false
                        self.recording = true // finishSession must run even if startRunning failed.
                        self.stopOnQueue(reason: error.localizedDescription)
                    } else {
                        self.failStart(error)
                    }
                }
            }
        }
    }

    private func configureSession(audioEnabled: Bool) throws {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        for input in captureSession.inputs { captureSession.removeInput(input) }
        for output in captureSession.outputs { captureSession.removeOutput(output) }
        videoOutput = nil
        audioOutput = nil
        guard captureSession.canSetSessionPreset(.hd1280x720) else {
            throw CaptureServiceError.configurationFailed
        }
        captureSession.sessionPreset = .hd1280x720
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw CaptureServiceError.cameraUnavailable }
        let input = try AVCaptureDeviceInput(device: camera)
        guard captureSession.canAddInput(input) else { throw CaptureServiceError.configurationFailed }
        captureSession.addInput(input)
        guard captureSession.canSetSessionPreset(.hd1280x720),
              camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                  $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
              }) else { throw CaptureServiceError.configurationFailed }
        let video = AVCaptureVideoDataOutput()
        video.alwaysDiscardsLateVideoFrames = true
        video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
        guard captureSession.canAddOutput(video) else { throw CaptureServiceError.configurationFailed }
        captureSession.addOutput(video)
        video.setSampleBufferDelegate(self, queue: captureQueue)
        if let connection = video.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .landscapeRight
        }
        videoOutput = video
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        } catch {
            throw CaptureServiceError.configurationFailed
        }
        if audioEnabled {
            guard let microphone = AVCaptureDevice.default(for: .audio) else { return }
            let micInput = try AVCaptureDeviceInput(device: microphone)
            let audio = AVCaptureAudioDataOutput()
            if captureSession.canAddInput(micInput), captureSession.canAddOutput(audio) {
                captureSession.addInput(micInput)
                captureSession.addOutput(audio)
                audio.setSampleBufferDelegate(self, queue: captureQueue)
                audioOutput = audio
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard recording, !stopping, let sessionID = sessionID else { return }
        if output === videoOutput {
            lastVideoHostTime = hostTime()
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            guard pts.isFinite else { stopOnQueue(reason: "Invalid camera timestamp"); return }
            if let current = active, let start = current.writer.firstVideoTime, pts - start >= 10 {
                finishActive()
                guard pendingFinishes < 2 else {
                    stopOnQueue(reason: "Movie finalization fell behind capture")
                    return
                }
            }
            if active == nil {
                do { try beginSegment(sessionID: sessionID, at: pts) }
                catch { stopOnQueue(reason: error.localizedDescription); return }
            }
            guard let current = active else { return }
            switch current.writer.appendVideo(sampleBuffer) {
            case .accepted:
                consecutiveVideoDrops = 0
                if !hasRecordedFrame {
                    hasRecordedFrame = true
                    message = useAudio ? "Recording" :
                        (audioRequested ? "Recording video only; microphone access denied or unavailable" : "Recording video only")
                    publish()
                }
            case .dropped:
                droppedFrames += 1
                consecutiveVideoDrops += 1
                if consecutiveVideoDrops >= 90 { stopOnQueue(reason: "Video encoder is not keeping up") }
                else { summarizeDrops() }
            case .failed(let error):
                logger.error("Video writer append failed: \(error.localizedDescription, privacy: .public)")
                stopOnQueue(reason: error.localizedDescription)
            }
        } else if output === audioOutput, let current = active {
            if case .failed(let error) = current.writer.appendAudio(sampleBuffer) {
                logger.error("Audio writer append failed: \(error.localizedDescription, privacy: .public)")
                stopOnQueue(reason: error.localizedDescription)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output === videoOutput, recording, !stopping else { return }
        droppedFrames += 1
        consecutiveVideoDrops += 1
        if consecutiveVideoDrops >= 90 { stopOnQueue(reason: "Camera dropped 90 consecutive video frames") }
        else { summarizeDrops() }
    }

    private func summarizeDrops() {
        if droppedFrames == 1 || droppedFrames % 30 == 0 {
            logger.warning("Video frame drops this session: \(self.droppedFrames)")
            publish()
        }
    }

    private func beginSegment(sessionID: UUID, at time: Double) throws {
        do { try store.prune(sessionID: sessionID, now: time) }
        catch { latchStorageFault(error); throw error }
        try prepareStorage()
        let record: SegmentRecord
        do { record = try store.beginSegment(sessionID: sessionID, start: time) }
        catch { latchStorageFault(error); throw error }
        do {
            let writer = try SegmentWriter(url: store.segmentURL(record), audioEnabled: useAudio)
            active = (record, writer)
            logger.info("Opened movie segment \(record.id.uuidString, privacy: .public)")
            publish()
        } catch {
            markDamaged(record.id, reason: error.localizedDescription)
            throw error
        }
    }

    private func finishActive() {
        guard let current = active else { return }
        active = nil
        pendingFinishes += 1
        current.writer.finish { [self] result in
            self.captureQueue.async {
                self.pendingFinishes -= 1
                switch result {
                case .success:
                    var committed = false
                    do {
                        let size = try FileManager.default.attributesOfItem(atPath: current.writer.url.path)[.size] as? NSNumber
                        guard let bytes = size?.int64Value, bytes > 0,
                              let start = current.writer.firstVideoTime,
                              let end = current.writer.lastVideoEnd else { throw SegmentWriterError.noVideo }
                        try self.store.finishSegment(id: current.record.id, end: end,
                                                     byteCount: bytes, actualStart: start)
                        committed = true
                        self.logger.info("Finalized segment \(current.record.id.uuidString, privacy: .public), bytes: \(bytes)")
                        if let sessionID = self.sessionID {
                            try self.store.prune(sessionID: sessionID, now: self.hostTime())
                        }
                    } catch {
                        // Leave uncertain media on disk and stop; never delete on persistence failure.
                        self.report(error.localizedDescription)
                        self.logger.error("Segment persistence/finalization failed: \(error.localizedDescription, privacy: .public)")
                        self.latchStorageFault(error)
                        if !committed { self.markDamaged(current.record.id, reason: error.localizedDescription) }
                        if self.recording { self.stopOnQueue(reason: error.localizedDescription) }
                    }
                case .failure(let error):
                    self.markDamaged(current.record.id, reason: error.localizedDescription)
                    self.report(error.localizedDescription)
                    self.logger.error("Writer finalization failed: \(error.localizedDescription, privacy: .public)")
                    if self.recording { self.stopOnQueue(reason: error.localizedDescription) }
                }
                self.completeStopIfReady()
                self.publish()
            }
        }
    }

    func saveIncident(source: IncidentSource) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.recording, let sessionID = self.sessionID else {
                self.report(CaptureServiceError.noRecording.localizedDescription)
                return
            }
            do {
                let incident = try self.store.triggerIncident(sessionID: sessionID, at: self.hostTime(), source: source)
                self.logger.notice("Incident \(incident.id.uuidString, privacy: .public) durably registered, source: \(source.rawValue, privacy: .public)")
                self.message = "Incident saved. Preserving the following 30 seconds."
                self.publish()
            } catch {
                self.latchStorageFault(error)
                self.stopOnQueue(reason: "Incident protection could not be persisted")
            }
        }
    }

    func stop(reason: String = "user", completion: (() -> Void)? = nil) {
        captureQueue.async { [weak self] in
            guard let self = self else { DispatchQueue.main.async { completion?() }; return }
            if let completion = completion { self.stopCompletions.append(completion) }
            self.stopOnQueue(reason: reason)
        }
    }

    func simulateFailure(reason: String = "Developer simulated interruption") {
        stop(reason: reason)
    }

    private func stopOnQueue(reason: String) {
        startGeneration += 1 // Cancel any outstanding permission response.
        starting = false
        if !recording && !stopping {
            message = storageFault == nil ? (reason == "user" ? "Ready to record." : reason)
                : "Storage metadata needs recovery; restart before recording again."
            drainCompletions()
            publish()
            return
        }
        guard !stopping else { return }
        stopping = true
        recording = false
        stopReason = reason
        logger.notice("Stopping capture: \(reason, privacy: .public); pending writer finalizations: \(self.pendingFinishes)")
        watchdog?.cancel()
        watchdog = nil
        if captureSession.isRunning { captureSession.stopRunning() }
        finishActive()
        if pendingFinishes > 0 { startFinalizationWarning() }
        message = "Finalizing movies…"
        publish()
        completeStopIfReady()
    }

    private func completeStopIfReady() {
        guard stopping, pendingFinishes == 0, active == nil else { return }
        finalizationWarning?.cancel()
        finalizationWarning = nil
        if let sessionID = sessionID {
            do {
                try store.finishSession(sessionID: sessionID, at: hostTime(), reason: stopReason,
                                        preserveUnprotected: storageFault != nil)
            }
            catch { latchStorageFault(error) }
        }
        sessionID = nil
        hasRecordedFrame = false
        startedHostTime = nil
        lastVideoHostTime = nil
        stopping = false
        message = storageFault == nil
            ? (stopReason == "user" ? "Recording stopped." : "Stopped: \(stopReason)")
            : "Storage metadata needs recovery; restart before recording again."
        logger.info("Capture stopped: \(self.stopReason, privacy: .public)")
        drainCompletions()
        publish()
    }

    private func drainCompletions() {
        let completions = stopCompletions
        stopCompletions.removeAll()
        DispatchQueue.main.async { completions.forEach { $0() } }
    }

    private func markDamaged(_ id: UUID, reason: String) {
        do { try store.failSegment(id: id, reason: reason) }
        catch { latchStorageFault(error) }
    }

    private func latchStorageFault(_ error: Error) {
        if storageFault == nil {
            storageFault = error.localizedDescription
            logger.fault("Recording store fault latched: \(error.localizedDescription, privacy: .public)")
            report("Recording store needs recovery. Existing files are retained. Restart the app before recording again. \(error.localizedDescription)")
        }
    }

    func incidentSegmentURLs(id: UUID, completion: @escaping (Result<[URL], Error>) -> Void) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<[URL], Error>
            do {
                guard !self.recording, !self.starting, !self.stopping, self.pendingFinishes == 0
                else { throw CaptureServiceError.busy }
                let snapshot = self.store.snapshot()
                if let incident = snapshot.incidents.first(where: { $0.id == id }),
                   snapshot.segments.contains(where: { segment in
                       segment.sessionID == incident.sessionID && segment.state == .damaged &&
                       segment.start < incident.windowEnd &&
                       (segment.end ?? .infinity) > incident.windowStart
                   }) {
                    throw CaptureServiceError.incompleteIncident
                }
                let segments = try self.store.incidentSegments(id: id)
                guard !segments.isEmpty else { throw CaptureServiceError.incompleteIncident }
                let urls = segments.map(self.store.segmentURL)
                guard zip(segments, urls).allSatisfy({ pair in
                    let (segment, url) = pair
                    if case .ready = segment.state { return FileManager.default.fileExists(atPath: url.path) }
                    return false
                }) else { throw CaptureServiceError.incompleteIncident }
                result = .success(urls)
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func deleteIncident(id: UUID, completion: @escaping (Result<Void, Error>) -> Void) {
        captureQueue.async { [weak self] in
            guard let self = self else { return }
            let result: Result<Void, Error>
            do {
                guard !self.recording, !self.starting, !self.stopping, self.pendingFinishes == 0
                else { throw CaptureServiceError.busy }
                try self.store.deleteIncident(id: id)
                result = .success(())
                self.publish()
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func prepareStorage() throws {
        // Require room for the next movie as well as a 250 MiB operating reserve.
        let hasReserve: Bool
        do {
            hasReserve = try store.hasRecordingReserve(estimatedNextBytes: 16 * 1024 * 1024,
                                                       reserveBytes: 250 * 1024 * 1024)
        } catch {
            logger.error("Could not query storage reserve: \(error.localizedDescription, privacy: .public)")
            throw CaptureServiceError.unavailableCapacity
        }
        guard hasReserve else {
            logger.error("Storage reserve denied new movie segment")
            throw CaptureServiceError.lowCapacity
        }
    }

    private func hostTime() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }

    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.recording else { return }
            let since = self.hostTime() - (self.lastVideoHostTime ?? self.startedHostTime ?? self.hostTime())
            if since > 8 {
                self.logger.error("Video sample watchdog elapsed: \(since) seconds")
                self.stopOnQueue(reason: "No camera video for eight seconds")
            }
        }
        watchdog = timer
        timer.resume()
    }

    private func startFinalizationWarning() {
        finalizationWarning?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + 20)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.stopping, self.pendingFinishes > 0 else { return }
            self.logger.error("AVAssetWriter finalization has not completed after 20 seconds; open media remains registered for recovery")
            self.report("Finalizing is taking longer than expected. Keep the app open if possible; open media is retained for recovery.")
        }
        finalizationWarning = timer
        timer.resume()
    }

    private func failStart(_ error: Error) { failStartMessage(error.localizedDescription) }

    private func failStartMessage(_ text: String) {
        starting = false
        message = text
        logger.error("Capture startup failed: \(text, privacy: .public)")
        report(text)
        publish()
    }

    private func report(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(text) }
    }

    private func publish() {
        let state = CaptureStatus(isRecording: recording && hasRecordedFrame,
                                  isBusy: starting || stopping || (recording && !hasRecordedFrame),
                                  isStarting: starting || (recording && !hasRecordedFrame),
                                  isStopping: stopping,
                                  message: message, droppedFrames: droppedFrames,
                                  snapshot: store.snapshot())
        DispatchQueue.main.async { [weak self] in self?.onUpdate?(state) }
    }
}
