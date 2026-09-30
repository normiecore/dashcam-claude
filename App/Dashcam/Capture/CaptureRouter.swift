import AVFoundation
import Foundation

/// Routes sample buffers from the capture data queue to the current `SegmentWriter`.
///
/// Swapping writers is done with `swap(_:)` *on the capture data queue* (see
/// `CameraCaptureService.onDataQueue`) so a writer is never finished while a frame is being appended.
/// The lock only guards the reference and the frame statistics read by the watchdog on the main thread.
final class CaptureRouter: CaptureSampleSink {
    private let lock = NSLock()
    private var writer: SegmentWriter?
    private var _lastVideoFrameHostSeconds: Double?
    private var _videoFrames = 0
    private var _droppedFrames = 0
    private var _audioMuted = false

    func swap(_ newWriter: SegmentWriter?) -> SegmentWriter? {
        lock.lock(); defer { lock.unlock() }
        let old = writer
        writer = newWriter
        return old
    }

    var current: SegmentWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }

    /// Seconds since the last video frame arrived, or nil if none has.
    var secondsSinceLastVideoFrame: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let last = _lastVideoFrameHostSeconds else { return nil }
        return CMClockGetTime(CMClockGetHostTimeClock()).seconds - last
    }

    var videoFrames: Int { lock.lock(); defer { lock.unlock() }; return _videoFrames }
    var droppedFrames: Int { lock.lock(); defer { lock.unlock() }; return _droppedFrames }

    /// When true, audio buffers are discarded (user turned audio off mid-session or audio device was taken).
    var audioMuted: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _audioMuted }
        set { lock.lock(); defer { lock.unlock() }; _audioMuted = newValue }
    }

    func resetStatistics() {
        lock.lock(); defer { lock.unlock() }
        _lastVideoFrameHostSeconds = nil
        _videoFrames = 0
        _droppedFrames = 0
    }

    func captureDidOutputVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        _lastVideoFrameHostSeconds = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        _videoFrames += 1
        let target = writer
        lock.unlock()
        target?.appendVideo(sampleBuffer)
    }

    func captureDidOutputAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let target = _audioMuted ? nil : writer
        lock.unlock()
        target?.appendAudio(sampleBuffer)
    }

    func captureDidDropVideoFrame(reason: String) {
        lock.lock()
        _droppedFrames += 1
        lock.unlock()
    }
}
