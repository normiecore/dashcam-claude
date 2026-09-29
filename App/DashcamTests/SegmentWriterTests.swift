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
        XCTAssertEqual(media.map(\.id.sequence), Array(1...media.count), "sequence numbers are contiguous")
        for segment in segments {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(segment.relativePath).path), "\(segment.relativePath) on disk")
        }
        for (earlier, later) in zip(media, media.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.startTime, later.startTime)
        }
        let totalDuration = media.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(totalDuration, Double(seconds), accuracy: 1.0)

        let initURL = root.appendingPathComponent(inits[0].relativePath)
        let mediaURLs = media.map { root.appendingPathComponent($0.relativePath) }

        // Whole run: init + every media segment.
        let full = root.appendingPathComponent("full.mp4")
        try FMP4ClipAssembler.writeClip(initialization: initURL, mediaSegments: mediaURLs, to: full)
        let fullAsset = AVURLAsset(url: full)
        let fullDuration = try await fullAsset.load(.duration)
        XCTAssertEqual(fullDuration.seconds, Double(seconds), accuracy: 1.0)
        XCTAssertEqual(try await fullAsset.loadTracks(withMediaType: .video).count, 1)

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
