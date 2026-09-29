import AVFoundation
import CoreVideo
import XCTest
@testable import Dashcam

final class SegmentWriterTests: XCTestCase {
    @MainActor
    func testSyntheticVideoIncidentPersistsAndExportsWithoutRemovingOriginals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root)
        let session = try store.beginSession(at: Date())
        // Sparse synthetic frames keep this test fast. It checks integration and
        // timestamps, not real-time capture throughput or a hardware encoder soak.
        let first = try store.beginSegment(sessionID: session, start: 0)
        try await writeSyntheticSegment(first, store: store, times: [0, 10, 20])
        let incident = try store.triggerIncident(sessionID: session, at: 1, source: .developer)
        let second = try store.beginSegment(sessionID: session, start: 20 + 1.0 / 30.0)
        try await writeSyntheticSegment(second, store: store,
                                        times: [20 + 1.0 / 30.0, 30 + 1.0 / 30.0, 40 + 1.0 / 30.0])
        XCTAssertEqual(store.snapshot().incidents.first?.state, .saved)
        try store.finishSession(sessionID: session, at: 41, reason: "Synthetic test")
        let restored = try RecordingStore(root: root)
        let urls = try restored.incidentSegments(id: incident.id).map { restored.segmentURL($0) }
        XCTAssertEqual(urls.count, 2)
        let originalBytes = try urls.map { try Data(contentsOf: $0) }
        let exporter = ClipExportService()
        let exported = try await exporter.export(urls: urls, incidentID: incident.id)
        defer { try? FileManager.default.removeItem(at: exported) }
        let asset = AVURLAsset(url: exported)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertGreaterThan(duration.seconds, 39)
        XCTAssertLessThan(duration.seconds, 42)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
        try restored.prune(sessionID: session, now: 1000)
        XCTAssertEqual(try urls.map { try Data(contentsOf: $0) }, originalBytes)
    }

    private func writeSyntheticSegment(_ segment: SegmentRecord, store: RecordingStore,
                                       times: [Double]) async throws {
        let url = store.segmentURL(segment)
        let writer = try SegmentWriter(url: url, audioEnabled: false)
        for time in times {
            let sample = try makeSample(at: CMTime(seconds: time, preferredTimescale: 30_000))
            var accepted = false
            for _ in 0..<100 {
                switch writer.appendVideo(sample) {
                case .accepted: accepted = true
                case .dropped: try await Task.sleep(nanoseconds: 10_000_000)
                case .failed(let error): throw error
                }
                if accepted { break }
            }
            guard accepted else { throw SegmentWriterError.appendFailed }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            writer.finish { continuation.resume(with: $0) }
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        try store.finishSegment(id: segment.id, end: XCTUnwrap(writer.lastVideoEnd),
                                byteCount: XCTUnwrap(size?.int64Value), actualStart: writer.firstVideoTime)
    }

    func testSyntheticFramesFinalizePlayableMovie() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("movie.mov")
        let writer = try SegmentWriter(url: url, audioEnabled: false)
        XCTAssertNil(writer.firstVideoTime)
        for frame in 0..<6 {
            let sample = try makeSample(at: CMTime(value: Int64(frame), timescale: 30))
            var accepted = false
            for _ in 0..<100 {
                switch writer.appendVideo(sample) {
                case .accepted: accepted = true
                case .dropped:
                    if frame == 0 { XCTAssertNil(writer.firstVideoTime) }
                    Thread.sleep(forTimeInterval: 0.01)
                case .failed(let error): throw error
                }
                if accepted { break }
            }
            XCTAssertTrue(accepted, "Encoder remained backpressured on frame \(frame)")
            if frame == 0 { XCTAssertEqual(writer.firstVideoTime, 0) }
        }
        let done = expectation(description: "MOV finalization")
        var finishResult: Result<Void, Error>?
        writer.finish { result in finishResult = result; done.fulfill() }
        wait(for: [done], timeout: 20)
        try finishResult?.get()
        XCTAssertEqual(writer.videoFrameCount, 6)
        XCTAssertGreaterThan(try XCTUnwrap(writer.lastVideoEnd), 0.19)
        XCTAssertGreaterThan(try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue), 0)
        XCTAssertFalse(AVURLAsset(url: url).tracks(withMediaType: .video).isEmpty)
    }

    func testFinishingWithoutVideoReportsFailure() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SegmentWriter(url: url, audioEnabled: false)
        let done = expectation(description: "Empty MOV result")
        writer.finish { result in
            if case .success = result { XCTFail("No video must not be marked ready") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testVideoTimestampMovingBackwardFailsBeforeAppend() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try SegmentWriter(url: url, audioEnabled: false)
        let first = try makeSample(at: CMTime(value: 60, timescale: 30))
        var accepted = false
        for _ in 0..<100 {
            switch writer.appendVideo(first) {
            case .accepted: accepted = true
            case .dropped: Thread.sleep(forTimeInterval: 0.01)
            case .failed(let error): throw error
            }
            if accepted { break }
        }
        XCTAssertTrue(accepted)
        XCTAssertEqual(writer.firstVideoTime, 2.0)
        let earlier = try makeSample(at: CMTime(value: 59, timescale: 30))
        if case .failed(let error) = writer.appendVideo(earlier) {
            XCTAssertEqual(error.localizedDescription,
                           SegmentWriterError.nonMonotonicTimestamp.localizedDescription)
            XCTAssertEqual(writer.videoFrameCount, 1)
        } else {
            XCTFail("Writer accepted a backward video timestamp")
        }
        let done = expectation(description: "Finalize after rejected sample")
        writer.finish { _ in done.fulfill() }
        wait(for: [done], timeout: 20)
    }

    private func makeSample(at time: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let result = CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720,
                                         kCVPixelFormatType_32BGRA, attributes as CFDictionary,
                                         &pixelBuffer)
        XCTAssertEqual(result, kCVReturnSuccess)
        let image = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        if let address = CVPixelBufferGetBaseAddress(image) {
            memset(address, 0x80, CVPixelBufferGetDataSize(image))
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        var format: CMVideoFormatDescription?
        let formatResult = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                                        imageBuffer: image,
                                                                        formatDescriptionOut: &format)
        XCTAssertEqual(formatResult, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30),
                                        presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let sampleResult = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                                    imageBuffer: image,
                                                                    formatDescription: try XCTUnwrap(format),
                                                                    sampleTiming: &timing,
                                                                    sampleBufferOut: &sample)
        XCTAssertEqual(sampleResult, noErr)
        return try XCTUnwrap(sample)
    }
}
