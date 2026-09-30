#if DEBUG
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// Debug builds only. Stands in for the camera in the Simulator (which has none), in UI tests and in
// the coordinator tests, so the whole recording pipeline can run without an iPhone.

/// Stands in for `CameraCaptureService`. Produces 30 fps of synthetic 320x240 frames, plus 44.1 kHz
/// audio when the "microphone" is configured, on a serial data queue with host-clock timestamps like
/// a real capture session, and offers controls to simulate the session events the coordinator must
/// survive. Events are delivered on the main queue, as the real service delivers them.
final class SimulatedCaptureService: CaptureControlling, @unchecked Sendable {
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
    private let dataQueue = DispatchQueue(label: "dashcam.simulated-capture.data", qos: .userInitiated)
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
        tone = try! SyntheticToneSource(sampleRate: SimulatedCaptureService.sampleRate)
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
        return CaptureConfigurationSummary(deviceName: "Simulated camera", width: 320, height: 240, frameRate: 30, codec: "pending", stabilization: "off", audioEnabled: withAudio, usingPreset: false)
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
            AVSampleRateKey: SimulatedCaptureService.sampleRate,
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
            let pts = CMTimeAdd(start, CMTime(value: audioSamplesSent, timescale: CMTimeScale(SimulatedCaptureService.sampleRate)))
            if let chunk = try? tone.makeSampleBuffer(presentationTime: pts, frameCount: SimulatedCaptureService.samplesPerTick) {
                audioSamplesSent += Int64(SimulatedCaptureService.samplesPerTick)
                target.captureDidOutputAudio(chunk)
            }
        } else {
            audioStart = nil
        }
    }
}

// MARK: - Synthetic sources

/// Produces NV12 ('420v') frames with a moving bar so the encoder has something to encode.
struct SyntheticFrameSource {
    let width: Int
    let height: Int
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int) throws {
        self.width = width
        self.height = height
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let pool else { throw NSError(domain: "SyntheticFrameSource", code: Int(status)) }
        self.pool = pool
    }

    func makeSampleBuffer(presentationTime: CMTime, duration: CMTime, frameIndex: Int) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            throw NSError(domain: "SyntheticFrameSource", code: -1)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let barX = (frameIndex * 7) % width
            for y in 0..<height {
                let row = luma.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    row[x] = abs(x - barX) < 16 ? 235 : UInt8(16 + (y * 200) / height)
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            memset(chroma, 128, stride * (height / 2))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription) == noErr, let formatDescription else {
            throw NSError(domain: "SyntheticFrameSource", code: -2)
        }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription, sampleTiming: &timing, sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { throw NSError(domain: "SyntheticFrameSource", code: Int(status)) }
        return sampleBuffer
    }
}

/// Produces 16-bit mono PCM sample buffers with a 440 Hz tone, on the same timeline as the frames.
final class SyntheticToneSource {
    private let sampleRate: Int
    private let formatDescription: CMAudioFormatDescription
    private var phase = 0.0

    init(sampleRate: Int) throws {
        self.sampleRate = sampleRate
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        guard status == noErr, let format else { throw NSError(domain: "SyntheticToneSource", code: Int(status)) }
        formatDescription = format
    }

    func makeSampleBuffer(presentationTime: CMTime, frameCount: Int) throws -> CMSampleBuffer {
        var samples = [Int16](repeating: 0, count: frameCount)
        let step = 2.0 * Double.pi * 440.0 / Double(sampleRate)
        for index in 0..<frameCount {
            samples[index] = Int16(sin(phase) * 12_000)
            phase += step
        }
        let byteCount = frameCount * 2
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else { throw NSError(domain: "SyntheticToneSource", code: Int(status)) }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == noErr else { throw NSError(domain: "SyntheticToneSource", code: Int(status)) }
        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            presentationTimeStamp: presentationTime,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw NSError(domain: "SyntheticToneSource", code: Int(status)) }
        return sampleBuffer
    }
}
#endif
