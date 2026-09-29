import AVFoundation
import Foundation
import UIKit
import DashcamCore

/// Receives raw sample buffers on the capture data queue. Implementations must return quickly.
protocol CaptureSampleSink: AnyObject {
    func captureService(_ service: CameraCaptureService, didOutputVideo sampleBuffer: CMSampleBuffer)
    func captureService(_ service: CameraCaptureService, didOutputAudio sampleBuffer: CMSampleBuffer)
    func captureService(_ service: CameraCaptureService, didDropVideoFrameWithReason reason: String)
}

enum CaptureEvent {
    case interrupted(AVCaptureSession.InterruptionReason?)
    case interruptionEnded
    case runtimeError(Error, mediaServicesWereReset: Bool)
    case systemPressure(AVCaptureDevice.SystemPressureState.Level)
    case didStartRunning
    case didStopRunning
}

struct CaptureConfigurationSummary: Equatable {
    var deviceName: String
    var width: Int32
    var height: Int32
    var frameRate: Int
    var codec: String
    var stabilization: String
    var audioEnabled: Bool
    var usingPreset: Bool
}

enum CaptureError: LocalizedError {
    case cameraUnavailable
    case cameraAccessDenied
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable: return "No rear camera is available on this device."
        case .cameraAccessDenied: return "Camera access is denied. Enable it in Settings."
        case .configurationFailed(let reason): return "Camera configuration failed: \(reason)"
        }
    }
}

/// Owns the AVCaptureSession. All session mutation happens on `sessionQueue`; sample buffers are
/// delivered on `dataQueue`. This class knows nothing about files or incidents.
final class CameraCaptureService: NSObject {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.matrixengineered.dashcam.capture.session")
    private let dataQueue = DispatchQueue(label: "com.matrixengineered.dashcam.capture.data", qos: .userInitiated)
    private let logger: DashcamLogger

    weak var sink: CaptureSampleSink?
    /// Delivered on the main queue.
    var eventHandler: ((CaptureEvent) -> Void)?

    private(set) var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var notificationObservers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?
    private(set) var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private(set) var configuration: CaptureConfigurationSummary?
    private var isConfigured = false
    private var configuredQuality: VideoQualityTier?
    private var configuredAudio = false

    init(logger: DashcamLogger) {
        self.logger = logger
        super.init()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Runs `block` on the sample-delivery queue, serialized with `captureOutput` callbacks.
    func onDataQueue(_ block: @escaping () -> Void) {
        dataQueue.async(execute: block)
    }

    // MARK: Permissions

    static func cameraAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func microphoneAuthorization() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: Lifecycle

    /// Configures (if needed) and starts the session. Returns the effective configuration.
    func configureAndStart(quality: VideoQualityTier, audioEnabled: Bool, stabilization: Bool) async throws -> CaptureConfigurationSummary {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CaptureConfigurationSummary, Error>) in
            sessionQueue.async {
                do {
                    let summary = try self.configureIfNeeded(quality: quality, audioEnabled: audioEnabled, stabilization: stabilization)
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume(returning: summary)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                continuation.resume()
            }
        }
    }

    /// Tears down inputs/outputs so the next start rebuilds everything. Used after media-services resets.
    func reset() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                if self.session.isRunning { self.session.stopRunning() }
                self.session.beginConfiguration()
                for input in self.session.inputs { self.session.removeInput(input) }
                for output in self.session.outputs { self.session.removeOutput(output) }
                self.session.commitConfiguration()
                self.pressureObservation = nil
                self.rotationCoordinator = nil
                self.videoDevice = nil
                self.videoDeviceInput = nil
                self.audioDeviceInput = nil
                self.isConfigured = false
                self.configuration = nil
                continuation.resume()
            }
        }
    }

    /// Thermal mitigation: lowers the frame rate within the active format's supported range.
    func setFrameRate(_ fps: Int) {
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            let ranges = device.activeFormat.videoSupportedFrameRateRanges
            let maxSupported = ranges.map(\.maxFrameRate).max() ?? 30
            let minSupported = ranges.map(\.minFrameRate).min() ?? 1
            let clamped = min(max(Double(fps), minSupported), maxSupported)
            do {
                try device.lockForConfiguration()
                let duration = CMTime(value: 1, timescale: CMTimeScale(clamped.rounded()))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
                self.configuration?.frameRate = Int(clamped.rounded())
                self.logger.notice(.capture, "Frame rate set to \(Int(clamped.rounded())) fps")
            } catch {
                self.logger.error(.capture, "Could not change frame rate: \(error)")
            }
        }
    }

    // MARK: Encoder settings (valid after configuration)

    /// Recommended writer settings for the current session. Prefers HEVC; falls back to H.264.
    func recommendedVideoSettings(quality: VideoQualityTier, segmentInterval: TimeInterval) -> (settings: [String: Any], codec: AVVideoCodecType)? {
        var codec = AVVideoCodecType.hevc
        var settings = videoOutput.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mp4)
        if settings == nil {
            codec = .h264
            settings = videoOutput.recommendedVideoSettings(forVideoCodecType: .h264, assetWriterOutputFileType: .mp4)
        }
        guard var result = settings else { return nil }
        var compression = (result[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
        compression[AVVideoAverageBitRateKey] = codec == .hevc ? quality.averageBitrate : quality.h264AverageBitrate
        compression[AVVideoMaxKeyFrameIntervalDurationKey] = segmentInterval
        compression[AVVideoExpectedSourceFrameRateKey] = quality.frameRate
        compression[AVVideoAllowFrameReorderingKey] = false
        result[AVVideoCompressionPropertiesKey] = compression
        return (result, codec)
    }

    func recommendedAudioSettings() -> [String: Any]? {
        guard configuredAudio, audioDeviceInput != nil else { return nil }
        return audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
    }

    /// Angle (degrees) to rotate captured video so the horizon is level for the current device orientation.
    var horizonLevelCaptureAngle: CGFloat {
        rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 0
    }

    // MARK: Configuration (sessionQueue)

    private func configureIfNeeded(quality: VideoQualityTier, audioEnabled: Bool, stabilization: Bool) throws -> CaptureConfigurationSummary {
        if isConfigured, configuredQuality == quality, configuredAudio == audioEnabled, let configuration {
            return configuration
        }
        guard CameraCaptureService.cameraAuthorization() == .authorized else { throw CaptureError.cameraAccessDenied }

        // Rebuild from scratch so quality/audio changes are consistent.
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw CaptureError.cameraUnavailable
        }
        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CaptureError.configurationFailed("video input: \(error.localizedDescription)")
        }
        guard session.canAddInput(videoInput) else { throw CaptureError.configurationFailed("cannot add camera input") }
        session.addInput(videoInput)
        videoDevice = device
        videoDeviceInput = videoInput

        // Format: explicit activeFormat when a matching one exists, otherwise a session preset.
        var usingPreset = false
        if let format = CameraCaptureService.selectFormat(for: device, quality: quality) {
            session.sessionPreset = .inputPriority
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(quality.frameRate))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                if device.isSmoothAutoFocusSupported { device.isSmoothAutoFocusEnabled = true }
                // SDR output: video HDR costs ISP power and yields HLG files some players mishandle.
                if format.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = false
                    device.isVideoHDREnabled = false
                }
                device.unlockForConfiguration()
            } catch {
                throw CaptureError.configurationFailed("format: \(error.localizedDescription)")
            }
        } else {
            usingPreset = true
            let preset: AVCaptureSession.Preset = quality == .hd1080p30 ? .hd1920x1080 : .hd1280x720
            session.sessionPreset = session.canSetSessionPreset(preset) ? preset : .high
            logger.warning(.capture, "No explicit \(quality.width)x\(quality.height)@\(quality.frameRate) format; using preset \(session.sessionPreset.rawValue)")
        }

        // Video data output.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else { throw CaptureError.configurationFailed("cannot add video output") }
        session.addOutput(videoOutput)

        var stabilizationName = "off"
        if let connection = videoOutput.connection(with: .video) {
            if stabilization, connection.isVideoStabilizationSupported {
                let mode = CameraCaptureService.preferredStabilization(for: device.activeFormat)
                connection.preferredVideoStabilizationMode = mode
                stabilizationName = CameraCaptureService.name(for: mode)
            } else {
                connection.preferredVideoStabilizationMode = .off
            }
        }

        // Audio (optional).
        configuredAudio = false
        audioDeviceInput = nil
        if audioEnabled, CameraCaptureService.microphoneAuthorization() == .authorized, let mic = AVCaptureDevice.default(for: .audio) {
            do {
                let audioInput = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(audioInput) {
                    session.addInput(audioInput)
                    audioDeviceInput = audioInput
                    audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
                    if session.canAddOutput(audioOutput) {
                        session.addOutput(audioOutput)
                        configuredAudio = true
                    }
                }
            } catch {
                logger.warning(.capture, "Microphone unavailable, recording video only: \(error)")
            }
        }
        // Let navigation/music keep playing while we record.
        session.automaticallyConfiguresApplicationAudioSession = true
        if #available(iOS 18.0, *) {
            session.configuresApplicationAudioSessionToMixWithOthers = true
        }

        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        installObservers(for: device)

        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let summary = CaptureConfigurationSummary(
            deviceName: device.localizedName,
            width: usingPreset ? quality.width : dims.width,
            height: usingPreset ? quality.height : dims.height,
            frameRate: quality.frameRate,
            codec: "pending",
            stabilization: stabilizationName,
            audioEnabled: configuredAudio,
            usingPreset: usingPreset
        )
        configuration = summary
        configuredQuality = quality
        isConfigured = true
        logger.notice(.capture, "Configured \(summary.deviceName) \(summary.width)x\(summary.height)@\(summary.frameRate) stabilization=\(stabilizationName) audio=\(configuredAudio) preset=\(usingPreset)")
        return summary
    }

    static func selectFormat(for device: AVCaptureDevice, quality: VideoQualityTier) -> AVCaptureDevice.Format? {
        let target = Double(quality.frameRate)
        let candidates = device.formats.filter { format in
            let description = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(description)
            guard dims.width == quality.width, dims.height == quality.height else { return false }
            guard CMFormatDescriptionGetMediaSubType(description) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return false }
            guard format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= target && $0.maxFrameRate >= target }) else { return false }
            return true
        }
        // Prefer the least capable format that still meets the target: lower max frame rate means
        // lower sensor/ISP cost, which matters for a device baking on a windshield.
        return candidates.min { lhs, rhs in
            let lhsMax = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let rhsMax = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            if lhsMax != rhsMax { return lhsMax < rhsMax }
            return lhs.isVideoBinned && !rhs.isVideoBinned
        }
    }

    static func preferredStabilization(for format: AVCaptureDevice.Format) -> AVCaptureVideoStabilizationMode {
        if #available(iOS 26.0, *), format.isVideoStabilizationModeSupported(.lowLatency) {
            return .lowLatency
        }
        if format.isVideoStabilizationModeSupported(.standard) { return .standard }
        return .off
    }

    static func name(for mode: AVCaptureVideoStabilizationMode) -> String {
        switch mode {
        case .off: return "off"
        case .standard: return "standard"
        case .cinematic: return "cinematic"
        case .cinematicExtended: return "cinematicExtended"
        case .previewOptimized: return "previewOptimized"
        case .cinematicExtendedEnhanced: return "cinematicExtendedEnhanced"
        case .auto: return "auto"
        @unknown default: return "mode\(mode.rawValue)"
        }
    }

    // MARK: Observers

    private func installObservers(for device: AVCaptureDevice) {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers.removeAll()
        let center = NotificationCenter.default

        notificationObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            var reason: AVCaptureSession.InterruptionReason?
            if let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
                reason = AVCaptureSession.InterruptionReason(rawValue: raw)
            }
            self.logger.warning(.capture, "Session interrupted: \(reason.map(CameraCaptureService.describe) ?? "unknown")")
            self.eventHandler?(.interrupted(reason))
        })
        notificationObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            self?.logger.notice(.capture, "Session interruption ended")
            self?.eventHandler?(.interruptionEnded)
        })
        notificationObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            guard let self else { return }
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError ?? NSError(domain: AVFoundationErrorDomain, code: -1)
            let reset = error.domain == AVFoundationErrorDomain && error.code == AVError.mediaServicesWereReset.rawValue
            self.logger.error(.capture, "Session runtime error: \(error.localizedDescription) (code \(error.code)) mediaServicesReset=\(reset)")
            self.eventHandler?(.runtimeError(error, mediaServicesWereReset: reset))
        })
        notificationObservers.append(center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: .main) { [weak self] _ in
            self?.logger.info(.capture, "Session started running")
            self?.eventHandler?(.didStartRunning)
        })
        notificationObservers.append(center.addObserver(forName: AVCaptureSession.didStopRunningNotification, object: session, queue: .main) { [weak self] _ in
            self?.logger.info(.capture, "Session stopped running")
            self?.eventHandler?(.didStopRunning)
        })

        pressureObservation = device.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            let state = device.systemPressureState
            let level = state.level
            self.logger.notice(.capture, "System pressure \(CameraCaptureService.describe(level)) factors=\(state.factors.rawValue)")
            DispatchQueue.main.async { self.eventHandler?(.systemPressure(level)) }
        }
    }

    static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "camera unavailable in background"
        case .audioDeviceInUseByAnotherClient: return "audio in use by another app (call or alarm)"
        case .videoDeviceInUseByAnotherClient: return "camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "camera unavailable with multiple foreground apps"
        case .videoDeviceNotAvailableDueToSystemPressure: return "camera shut down due to system pressure"
        @unknown default: return "reason \(reason.rawValue)"
        }
    }

    static func describe(_ level: AVCaptureDevice.SystemPressureState.Level) -> String {
        switch level {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        case .shutdown: return "shutdown"
        default: return level.rawValue
        }
    }
}

// MARK: - Sample buffer delegates (dataQueue)

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sink else { return }
        if output === videoOutput {
            sink.captureService(self, didOutputVideo: sampleBuffer)
        } else if output === audioOutput {
            sink.captureService(self, didOutputAudio: sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard output === videoOutput else { return }
        var reason = "unknown"
        if let attachment = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) {
            reason = String(describing: attachment)
        }
        sink?.captureService(self, didDropVideoFrameWithReason: reason)
    }
}
