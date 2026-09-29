import AVFoundation

/// One independently playable, fragmented movie. All methods except the finish callback
/// are called on CameraCaptureService's serial queue.
final class SegmentWriter {
    enum AppendResult {
        case accepted
        case dropped
        case failed(Error)
    }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private(set) var firstVideoTime: Double?
    private(set) var lastVideoEnd: Double?
    private var lastVideoTime: Double?
    private(set) var videoFrameCount = 0
    private var finishing = false
    private var sessionStarted = false

    init(url: URL, audioEnabled: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1280,
            AVVideoHeightKey: 720,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 4_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ])
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw SegmentWriterError.cannotAddVideo }
        writer.add(videoInput)

        if audioEnabled {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw SegmentWriterError.cannotAddAudio }
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    func appendVideo(_ sample: CMSampleBuffer) -> AppendResult {
        guard !finishing, CMSampleBufferDataIsReady(sample) else { return .dropped }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let seconds = CMTimeGetSeconds(pts)
        guard pts.isValid, seconds.isFinite else { return .failed(SegmentWriterError.invalidTimestamp) }
        if let prior = lastVideoTime, seconds <= prior {
            return .failed(SegmentWriterError.nonMonotonicTimestamp)
        }

        if writer.status == .unknown {
            guard writer.startWriting() else {
                return .failed(writer.error ?? SegmentWriterError.cannotStart)
            }
        }
        guard writer.status == .writing else {
            return .failed(writer.error ?? SegmentWriterError.writerFailed)
        }
        guard videoInput.isReadyForMoreMediaData else { return .dropped }
        if !sessionStarted {
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }
        guard videoInput.append(sample) else {
            return .failed(writer.error ?? SegmentWriterError.appendFailed)
        }
        if firstVideoTime == nil { firstVideoTime = seconds }
        videoFrameCount += 1
        lastVideoTime = seconds
        let duration = CMSampleBufferGetDuration(sample)
        let sampleDuration = duration.isValid && CMTimeGetSeconds(duration).isFinite && CMTimeGetSeconds(duration) > 0
            ? CMTimeGetSeconds(duration) : 1.0 / 30.0
        lastVideoEnd = seconds + sampleDuration
        return .accepted
    }

    func appendAudio(_ sample: CMSampleBuffer) -> AppendResult {
        guard !finishing, let input = audioInput else { return .dropped }
        guard let start = firstVideoTime else { return .dropped }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        guard time.isFinite, time >= start else { return .dropped }
        guard writer.status == .writing else {
            return .failed(writer.error ?? SegmentWriterError.writerFailed)
        }
        guard input.isReadyForMoreMediaData else { return .dropped }
        guard input.append(sample) else { return .failed(writer.error ?? SegmentWriterError.appendFailed) }
        return .accepted
    }

    /// Completion may arrive on any queue. An unstarted writer has no movie to finish.
    func finish(_ completion: @escaping (Result<Void, Error>) -> Void) {
        guard !finishing else { completion(.failure(SegmentWriterError.alreadyFinishing)); return }
        finishing = true
        guard firstVideoTime != nil else {
            completion(.failure(SegmentWriterError.noVideo))
            return
        }
        guard writer.status == .writing else {
            completion(.failure(writer.error ?? SegmentWriterError.writerFailed))
            return
        }
        // Bound presentation to accepted video coverage. Without an explicit end,
        // the encoder can infer a long final-frame duration from sparse timestamps.
        // Audio past this point is retained in the file but not presented.
        if let lastVideoEnd {
            writer.endSession(atSourceTime: CMTime(seconds: lastVideoEnd, preferredTimescale: 1_000_000_000))
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [writer] in
            if writer.status == .completed {
                completion(.success(()))
            } else {
                completion(.failure(writer.error ?? SegmentWriterError.writerFailed))
            }
        }
    }
}

enum SegmentWriterError: LocalizedError {
    case cannotAddVideo, cannotAddAudio, cannotStart, invalidTimestamp, nonMonotonicTimestamp, writerFailed
    case appendFailed, alreadyFinishing, noVideo

    var errorDescription: String? {
        switch self {
        case .cannotAddVideo: return "Cannot add the H.264 video encoder."
        case .cannotAddAudio: return "Cannot add the AAC audio encoder."
        case .cannotStart: return "Cannot start writing the movie."
        case .invalidTimestamp: return "Camera sample has an invalid timestamp."
        case .nonMonotonicTimestamp: return "Camera video timestamp moved backward."
        case .writerFailed: return "The movie writer failed."
        case .appendFailed: return "Cannot append a camera sample."
        case .alreadyFinishing: return "Movie is already finalizing."
        case .noVideo: return "No video frame arrived for this movie."
        }
    }
}
