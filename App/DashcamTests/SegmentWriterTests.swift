import AVFoundation
import CoreMedia
import CoreVideo
import XCTest
import DashcamCore
@testable import Dashcam

/// Runs on the iOS Simulator (no camera needed): synthetic frames are pushed through the real
/// AVAssetWriter segmented path, and the resulting segments are assembled and loaded back with
/// AVFoundation. This is the off-device proof that the recording/assembly design holds together.
final class SegmentWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("segment-writer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSegmentedRunAssemblesIntoPlayableClips() async throws {
        let run = RunID(rawValue: "run-test")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(run.rawValue), withIntermediateDirectories: true)
        let width = 640, height = 480, frameRate = 30, seconds = 10
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let configuration = SegmentWriter.Configuration(runID: run, bufferRoot: root, segmentInterval: 2, videoSettings: videoSettings, audioSettings: nil)
        let writer = try SegmentWriter(configuration: configuration, logger: .disabled)
        let collector = SegmentCollector()
        writer.onSegment = { collector.append($0) }
        writer.onFailure = { XCTFail("writer failed: \($0)") }

        let source = try SyntheticFrameSource(width: width, height: height)
        let feedQueue = DispatchQueue(label: "test.feed")
        let frameCount = frameRate * seconds
        feedQueue.sync {
            for index in 0..<frameCount {
                let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
                let sample = try! source.makeSampleBuffer(presentationTime: pts, duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)), frameIndex: index)
                writer.appendVideo(sample)
                usleep(4_000) // pace the encoder a little; drops are tolerated below
            }
        }
        let finished = expectation(description: "finishWriting")
        feedQueue.async { writer.finish { finished.fulfill() } }
        await fulfillment(of: [finished], timeout: 30)

        let segments = collector.segments
        let inits = segments.filter { $0.kind == .initialization }
        let media = segments.filter { $0.kind == .media }
        XCTAssertEqual(inits.count, 1, "exactly one initialization segment per run")
        XCTAssertGreaterThanOrEqual(media.count, 4, "10 s at a 2 s interval should yield at least 4 media segments")
        let initSegment = try XCTUnwrap(inits.first, "no initialization segment; the writer did not start")
        XCTAssertEqual(media.map(\.id.sequence), Array(1...media.count), "sequence numbers are contiguous")
        for segment in segments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(segment.relativePath).path), "\(segment.relativePath) on disk")
        }
        for (earlier, later) in zip(media, media.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.startTime, later.startTime)
        }
        let totalDuration = media.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(totalDuration, Double(seconds), accuracy: 1.0)

        let initURL = root.appendingPathComponent(initSegment.relativePath)
        let mediaURLs = media.map { root.appendingPathComponent($0.relativePath) }

        // Whole run: init + every media segment.
        let full = root.appendingPathComponent("full.mp4")
        try FMP4ClipAssembler.writeClip(initialization: initURL, mediaSegments: mediaURLs, to: full)
        let fullAsset = AVURLAsset(url: full)
        let fullDuration = try await fullAsset.load(.duration)
        XCTAssertEqual(fullDuration.seconds, Double(seconds), accuracy: 1.0)
        let videoTracks = try await fullAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(videoTracks.count, 1)

        // Mid-run range (what an incident export uses): must start at zero, not at the run offset.
        let range = Array(mediaURLs[1...2])
        let partial = root.appendingPathComponent("partial.mp4")
        let plan = try FMP4ClipAssembler.writeClip(initialization: initURL, mediaSegments: range, to: partial)
        XCTAssertNotNil(plan, "writer output must be parseable fMP4 so timestamps can be rebased")
        XCTAssertGreaterThan(plan?.originSeconds ?? 0, 1.0, "second segment starts after the first")
        let partialDuration = try await AVURLAsset(url: partial).load(.duration)
        XCTAssertEqual(partialDuration.seconds, media[1].duration + media[2].duration, accuracy: 0.5)

        // Passthrough remux to a conventional MP4 through the app's export service.
        let exporter = ClipExportService(logger: .disabled)
        let assemblyPlan = ClipAssemblyPlan(groups: [.init(run: run, initialization: initURL, media: range, startTime: Date(), duration: partialDuration.seconds)])
        let outputs = try await exporter.assemble(assemblyPlan, into: root.appendingPathComponent("export"), baseName: "clip")
        XCTAssertEqual(outputs, ["clip.mp4"])
        let exported = AVURLAsset(url: root.appendingPathComponent("export/clip.mp4"))
        let exportedDuration = try await exported.load(.duration)
        XCTAssertEqual(exportedDuration.seconds, partialDuration.seconds, accuracy: 0.5)
    }

    /// Audio and video together: the writer muxes both tracks into each segment, the rebase plan
    /// carries one delta per track, and the remuxed clip keeps both tracks the same length. This is
    /// the off-device check for the "A/V alignment after remux" item in the platform review.
    func testAudioAndVideoSegmentsRebaseAndRemuxTogether() async throws {
        let run = RunID(rawValue: "run-av")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(run.rawValue), withIntermediateDirectories: true)
        let width = 320, height = 240, frameRate = 30, seconds = 8, sampleRate = 44_100
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 600_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoExpectedSourceFrameRateKey: frameRate,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ]
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
        ]
        let configuration = SegmentWriter.Configuration(runID: run, bufferRoot: root, segmentInterval: 2, videoSettings: videoSettings, audioSettings: audioSettings)
        let writer = try SegmentWriter(configuration: configuration, logger: .disabled)
        let collector = SegmentCollector()
        writer.onSegment = { collector.append($0) }
        writer.onFailure = { XCTFail("writer failed: \($0)") }

        let video = try SyntheticFrameSource(width: width, height: height)
        let audio = try SyntheticToneSource(sampleRate: sampleRate)
        let feedQueue = DispatchQueue(label: "test.feed.av")
        let frameCount = frameRate * seconds
        let samplesPerFrame = sampleRate / frameRate
        feedQueue.sync {
            for index in 0..<frameCount {
                let pts = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
                let frame = try! video.makeSampleBuffer(presentationTime: pts, duration: CMTime(value: 1, timescale: CMTimeScale(frameRate)), frameIndex: index)
                writer.appendVideo(frame)
                // One audio buffer per frame, on the same timeline, starting at the same instant.
                let audioPTS = CMTime(value: CMTimeValue(index * samplesPerFrame), timescale: CMTimeScale(sampleRate))
                let tone = try! audio.makeSampleBuffer(presentationTime: audioPTS, frameCount: samplesPerFrame)
                writer.appendAudio(tone)
                usleep(4_000)
            }
        }
        let finished = expectation(description: "finishWriting")
        feedQueue.async { writer.finish { finished.fulfill() } }
        await fulfillment(of: [finished], timeout: 30)

        let segments = collector.segments
        let inits = segments.filter { $0.kind == .initialization }
        let media = segments.filter { $0.kind == .media }
        XCTAssertEqual(inits.count, 1)
        XCTAssertGreaterThanOrEqual(media.count, 3)
        let initSegment = try XCTUnwrap(inits.first, "no initialization segment; the writer did not start")
        let initURL = root.appendingPathComponent(initSegment.relativePath)
        let mediaURLs = media.map { root.appendingPathComponent($0.relativePath) }

        // Two tracks in the initialization segment, so the rebase plan must carry two deltas.
        let timescales = try FMP4.trackTimescales(initializationSegment: Data(contentsOf: initURL))
        XCTAssertEqual(timescales.count, 2, "video and audio tracks")

        // Mid-run range with both tracks: both must start near zero and end together.
        let range = Array(mediaURLs[1...2])
        let partial = root.appendingPathComponent("partial-av.mp4")
        let plan = try FMP4ClipAssembler.writeClip(initialization: initURL, mediaSegments: range, to: partial)
        let unwrappedPlan = try XCTUnwrap(plan, "two-track segments must still be parseable fMP4")
        XCTAssertEqual(unwrappedPlan.deltas.count, 2, "one delta per track")
        XCTAssertGreaterThan(unwrappedPlan.originSeconds, 1.0)
        let partialAsset = AVURLAsset(url: partial)
        let partialDuration = try await partialAsset.load(.duration)
        XCTAssertEqual(partialDuration.seconds, media[1].duration + media[2].duration, accuracy: 0.5)
        let audioTracks = try await partialAsset.loadTracks(withMediaType: .audio)
        let videoTracks = try await partialAsset.loadTracks(withMediaType: .video)
        XCTAssertEqual(audioTracks.count, 1)
        XCTAssertEqual(videoTracks.count, 1)
        let audioRange = try await XCTUnwrap(audioTracks.first).load(.timeRange)
        let videoRange = try await XCTUnwrap(videoTracks.first).load(.timeRange)
        // AAC carries encoder priming (about 2 048 samples, 46 ms at 44.1 kHz) which the muxer signals
        // for the player to trim, so allow a little slack at both ends.
        XCTAssertLessThan(abs(audioRange.start.seconds - videoRange.start.seconds), 0.15, "tracks start together")
        XCTAssertLessThan(abs(audioRange.end.seconds - videoRange.end.seconds), 0.15, "tracks end together")

        // Remux keeps both tracks and the duration.
        let exporter = ClipExportService(logger: .disabled)
        let assemblyPlan = ClipAssemblyPlan(groups: [.init(run: run, initialization: initURL, media: range, startTime: Date(), duration: partialDuration.seconds)])
        let outputs = try await exporter.assemble(assemblyPlan, into: root.appendingPathComponent("export-av"), baseName: "clip")
        XCTAssertEqual(outputs, ["clip.mp4"])
        let exported = AVURLAsset(url: root.appendingPathComponent("export-av/clip.mp4"))
        let exportedDuration = try await exported.load(.duration)
        XCTAssertEqual(exportedDuration.seconds, partialDuration.seconds, accuracy: 0.5)
        let exportedAudio = try await exported.loadTracks(withMediaType: .audio)
        let exportedVideo = try await exported.loadTracks(withMediaType: .video)
        XCTAssertEqual(exportedAudio.count, 1)
        XCTAssertEqual(exportedVideo.count, 1)
        let exportedAudioRange = try await XCTUnwrap(exportedAudio.first).load(.timeRange)
        let exportedVideoRange = try await XCTUnwrap(exportedVideo.first).load(.timeRange)
        XCTAssertLessThan(abs(exportedAudioRange.start.seconds - exportedVideoRange.start.seconds), 0.15)
        XCTAssertLessThan(abs(exportedAudioRange.end.seconds - exportedVideoRange.end.seconds), 0.15)
    }

    func testFinishBeforeFirstFrameProducesNothing() throws {
        let run = RunID(rawValue: "run-empty")
        let configuration = SegmentWriter.Configuration(runID: run, bufferRoot: root, segmentInterval: 2, videoSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ], audioSettings: nil)
        let writer = try SegmentWriter(configuration: configuration, logger: .disabled)
        let collector = SegmentCollector()
        writer.onSegment = { collector.append($0) }
        let finished = expectation(description: "finish")
        writer.finish { finished.fulfill() }
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(collector.segments.isEmpty)
        XCTAssertEqual(writer.state, .finishing)
    }
}

// MARK: - Helpers

final class SegmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Segment] = []

    func append(_ segment: Segment) {
        lock.lock(); defer { lock.unlock() }
        storage.append(segment)
    }

    var segments: [Segment] {
        lock.lock(); defer { lock.unlock() }
        return storage.sorted { ($0.kind == .initialization ? 0 : 1, $0.id.sequence) < ($1.kind == .initialization ? 0 : 1, $1.id.sequence) }
    }
}

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
