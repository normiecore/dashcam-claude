import AVFoundation
import Foundation
import UniformTypeIdentifiers
import DashcamCore

/// Writes one continuous "run" of footage as fragmented MP4 segments using AVAssetWriter's
/// segmented output mode (`AVAssetWriterDelegate`, iOS 14+).
///
/// Why this and not AVCaptureMovieFileOutput: on iOS a movie file output cannot switch files
/// without stopping (a gap of a few hundred milliseconds at every boundary), whereas segmented
/// AVAssetWriter output keeps one encoder session running and hands the app a complete
/// `moof`+`mdat` chunk every `segmentInterval` seconds, with the encoder forced to emit a sync
/// sample at each boundary. Footage lost on abrupt termination is bounded by one segment interval.
///
/// The first callback delivers the initialization segment (`ftyp`+`moov`), which is stored as
/// `init.mp4`; concatenating it with any consecutive media segments yields a playable fMP4 file.
///
/// Threading: `appendVideo`/`appendAudio`/`finish` must be called from one serial queue (the capture
/// data queue). Segment persistence happens on a private I/O queue; `onSegment` fires there.
final class SegmentWriter: NSObject {
    struct Configuration {
        var runID: RunID
        /// Buffer root; the run directory is `bufferRoot/<runID>` and must already exist.
        var bufferRoot: URL
        var segmentInterval: TimeInterval
        var videoSettings: [String: Any]
        var audioSettings: [String: Any]?
        /// Display transform for the video track (rotation for the mount orientation at run start).
        var transform: CGAffineTransform = .identity
        var clock: WallClock = SystemWallClock()
        /// Clock the capture PTS values are on (`AVCaptureSession.synchronizationClock`). Apple only
        /// promises that the sync clock is *usually* the host clock, so PTS values are converted before
        /// they are mapped to wall-clock time. nil means "assume host clock".
        var sourceClock: CMClock?
    }

    enum State: Equatable {
        case awaitingFirstFrame
        case writing
        /// `finish()` was called; no more samples are accepted. There is no separate "finished" state
        /// because completion is reported through the `finish` callback.
        case finishing
        case failed(String)
    }

    let configuration: Configuration
    private(set) var state: State = .awaitingFirstFrame
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let ioQueue = DispatchQueue(label: "com.matrixengineered.dashcam.segment.io", qos: .utility)
    private let logger: DashcamLogger

    private var sessionStartPTS: CMTime?
    private var runStartDate: Date?
    private var nextSequence = 1
    private var lastSegmentEnd: Date?
    private var loggedTimeline = false
    private(set) var droppedVideoFrames = 0
    private(set) var droppedAudioBuffers = 0
    private(set) var appendedVideoFrames = 0
    private(set) var lastVideoPTS: CMTime?

    /// Fired on the I/O queue after the segment file is durably on disk.
    var onSegment: ((Segment) -> Void)?
    /// Fired once, on the calling queue, if the writer fails. The coordinator should start a new run.
    var onFailure: ((Error) -> Void)?

    init(configuration: Configuration, logger: DashcamLogger) throws {
        self.configuration = configuration
        self.logger = logger
        guard let contentType = UTType(AVFileType.mp4.rawValue) else {
            throw CaptureError.configurationFailed("mp4 content type unavailable")
        }
        writer = AVAssetWriter(contentType: contentType)
        // Apple HLS fragmented-MP4 profile, not CMAF: the CMAF profile allows exactly one track per
        // writer ("More than one track is not allowed for file type profile MPEG4CMAFCompliant",
        // AVFoundation -11875), and a dash cam run carries video and audio in one file.
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: configuration.segmentInterval, preferredTimescale: 600)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: configuration.videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = configuration.transform
        guard writer.canAdd(videoInput) else { throw CaptureError.configurationFailed("cannot add video input: \(String(describing: writer.error))") }
        writer.add(videoInput)

        if let audioSettings = configuration.audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                logger.warning(.recorder, "Writer rejected audio settings; recording video only")
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
        super.init()
        writer.delegate = self
    }

    var runDirectory: URL {
        configuration.bufferRoot.appendingPathComponent(configuration.runID.rawValue, isDirectory: true)
    }

    // MARK: Appending (capture data queue)

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        switch state {
        case .awaitingFirstFrame:
            guard pts.isValid else { return }
            writer.initialSegmentStartTime = pts
            guard writer.startWriting() else {
                fail(writer.error ?? CaptureError.configurationFailed("startWriting returned false"))
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStartPTS = pts
            runStartDate = SegmentWriter.wallClockDate(forPTS: pts, sourceClock: configuration.sourceClock, clock: configuration.clock)
            lastSegmentEnd = runStartDate
            state = .writing
            logger.notice(.recorder, "Run \(configuration.runID) started at PTS \(pts.seconds)")
            append(sampleBuffer, to: videoInput, isVideo: true)
        case .writing:
            append(sampleBuffer, to: videoInput, isVideo: true)
            lastVideoPTS = pts
        case .finishing, .failed:
            return
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard state == .writing, let audioInput, let start = sessionStartPTS else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts >= start else { return }
        append(sampleBuffer, to: audioInput, isVideo: false)
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput, isVideo: Bool) {
        guard input.isReadyForMoreMediaData else {
            // An AVAssetWriter can fail on its own (encoder error, media services reset, disk full) without
            // any append returning false; from then on the input never becomes ready again. Treat that as
            // a failure so the coordinator rotates to a new run instead of silently dropping every frame.
            if writer.status == .failed || writer.status == .cancelled {
                fail(writer.error ?? CaptureError.configurationFailed("writer status \(writer.status.rawValue) while appending"))
                return
            }
            if isVideo { droppedVideoFrames += 1 } else { droppedAudioBuffers += 1 }
            if (isVideo ? droppedVideoFrames : droppedAudioBuffers) % 30 == 1 {
                logger.warning(.recorder, "Writer not ready; dropped \(isVideo ? "video" : "audio") (\(isVideo ? droppedVideoFrames : droppedAudioBuffers) total)")
            }
            return
        }
        if input.append(sampleBuffer) {
            if isVideo { appendedVideoFrames += 1 }
        } else {
            fail(writer.error ?? CaptureError.configurationFailed("append returned false"))
        }
    }

    /// Finalizes the run. The last partial segment is delivered through the delegate before
    /// `completion` runs (on the I/O queue), so callers can rely on every appended frame being on disk.
    func finish(completion: @escaping () -> Void) {
        switch state {
        case .awaitingFirstFrame:
            state = .finishing
            if writer.status == .writing { writer.cancelWriting() }
            ioQueue.async(execute: completion)
        case .writing:
            state = .finishing
            // markAsFinished/finishWriting on a writer that already failed raises an exception.
            guard writer.status == .writing else {
                logger.error(.recorder, "finish: writer status \(writer.status.rawValue) (\(String(describing: writer.error))); nothing more to flush")
                state = .failed((writer.error ?? CaptureError.configurationFailed("writer status \(writer.status.rawValue) at finish")).localizedDescription)
                ioQueue.async(execute: completion)
                return
            }
            videoInput.markAsFinished()
            audioInput?.markAsFinished()
            // `state` stays `.finishing`; it is only ever mutated on the caller's queue, and the
            // completion is enqueued behind any segment persistence already queued on ioQueue.
            writer.finishWriting { [self] in
                if writer.status == .failed {
                    logger.error(.recorder, "finishWriting failed: \(String(describing: writer.error))")
                } else {
                    logger.notice(.recorder, "Run \(configuration.runID) finished: \(appendedVideoFrames) frames, dropped \(droppedVideoFrames) video / \(droppedAudioBuffers) audio")
                }
                ioQueue.async(execute: completion)
            }
        case .finishing, .failed:
            ioQueue.async(execute: completion)
        }
    }

    private func fail(_ error: Error) {
        guard case .failed = state else {
            state = .failed(error.localizedDescription)
            logger.error(.recorder, "Writer failed: \(error)")
            onFailure?(error)
            return
        }
    }

    // MARK: Time mapping

    /// Maps a capture PTS to wall-clock time so retention and incident windows can use `Date`. The PTS is
    /// converted from the session's synchronization clock to the host clock first. Falls back to "now" if
    /// the offset looks unreasonable (more than 5 s of pipeline latency, or a clock we cannot relate).
    static func wallClockDate(forPTS pts: CMTime, sourceClock: CMClock?, clock: WallClock) -> Date {
        let hostPTS = sourceClock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        return wallClockDate(forHostTime: hostPTS, clock: clock)
    }

    static func wallClockDate(forHostTime pts: CMTime, clock: WallClock) -> Date {
        let now = clock.now()
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let elapsed = CMTimeSubtract(hostNow, pts).seconds
        if elapsed.isFinite, elapsed >= 0, elapsed < 5 {
            return now.addingTimeInterval(-elapsed)
        }
        return now
    }
}

// MARK: - AVAssetWriterDelegate

extension SegmentWriter: AVAssetWriterDelegate {
    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        // Capture what we need; the report is only read on the I/O queue.
        let videoReport = segmentReport?.trackReports.first { $0.mediaType == .video }
        let earliest = videoReport?.earliestPresentationTimeStamp
        let reportedDuration = videoReport?.duration
        ioQueue.async {
            self.persist(segmentData, type: segmentType, earliestPTS: earliest, reportedDuration: reportedDuration)
        }
    }

    private func persist(_ data: Data, type: AVAssetSegmentType, earliestPTS: CMTime?, reportedDuration: CMTime?) {
        let run = configuration.runID
        let startDate = runStartDate ?? configuration.clock.now()
        let segment: Segment
        switch type {
        case .initialization:
            let path = Segment.initializationPath(run: run)
            segment = Segment(id: .init(run: run, sequence: 0), kind: .initialization, startTime: startDate, duration: 0, byteCount: Int64(data.count), relativePath: path)
        case .separable:
            let sequence = nextSequence
            nextSequence += 1
            let path = Segment.relativePath(run: run, sequence: sequence, fileExtension: "m4s")
            // Apple does not document which timeline `earliestPresentationTimeStamp` is on. Handle both:
            // source (capture) time, which is at or after the session start PTS, and movie time, which
            // starts at zero. Anything else falls back to chaining from the previous segment's end.
            var start = lastSegmentEnd ?? startDate
            if let earliestPTS, earliestPTS.isValid {
                if let sessionStartPTS, earliestPTS >= sessionStartPTS {
                    let offset = CMTimeSubtract(earliestPTS, sessionStartPTS).seconds
                    if offset.isFinite, offset < 86_400 { start = startDate.addingTimeInterval(offset) }
                } else if earliestPTS.seconds >= 0, earliestPTS.seconds < 86_400 {
                    start = startDate.addingTimeInterval(earliestPTS.seconds)
                }
                if !loggedTimeline {
                    loggedTimeline = true
                    logger.notice(.recorder, "First segment PTS \(earliestPTS.seconds) vs session start \(sessionStartPTS?.seconds ?? -1): timeline is \(sessionStartPTS.map { earliestPTS >= $0 } == true ? "source" : "movie")")
                }
            }
            var duration = configuration.segmentInterval
            if let reportedDuration, reportedDuration.isValid, reportedDuration.seconds > 0 {
                duration = reportedDuration.seconds
            }
            lastSegmentEnd = start.addingTimeInterval(duration)
            segment = Segment(id: .init(run: run, sequence: sequence), kind: .media, startTime: start, duration: duration, byteCount: Int64(data.count), relativePath: path)
        @unknown default:
            logger.warning(.recorder, "Ignoring unknown segment type \(type.rawValue)")
            return
        }

        let url = configuration.bufferRoot.appendingPathComponent(segment.relativePath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic: Foundation writes to a temporary file and renames, so a kill mid-write leaves nothing partial.
            try data.write(to: url, options: .atomic)
            // The index sidecar is written here too, right behind the media, rather than only when the
            // main-actor ingest loop gets to this segment: a kill in between would otherwise leave a
            // complete media file that the next launch deletes as an orphan. The store rewrites it
            // idempotently when it indexes the segment.
            let sidecar = url.deletingPathExtension().appendingPathExtension(SegmentStore.sidecarExtension)
            try SegmentStore.makeEncoder().encode(segment).write(to: sidecar, options: .atomic)
            onSegment?(segment)
        } catch {
            // A segment that cannot be written is footage lost; the coordinator should rotate to a new run
            // rather than keep feeding a writer whose output is being discarded. `state` belongs to the
            // capture queue, so only the callback is used here.
            logger.error(.recorder, "Failed to persist segment \(segment.relativePath): \(error)")
            onFailure?(error)
        }
    }
}
