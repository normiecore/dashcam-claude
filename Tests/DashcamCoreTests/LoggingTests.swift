import Foundation
import Testing
@testable import DashcamCore

@Suite("Logging")
struct LoggingTests {
    @Test("Ring buffer keeps the newest entries in order")
    func ringBuffer() {
        let sink = InMemoryLogSink(capacity: 3)
        let clock = ManualWallClock()
        let logger = DashcamLogger(sinks: [sink], clock: clock)
        for i in 1...5 {
            logger.info(.test, "m\(i)")
            clock.advance(by: 1)
        }
        #expect(sink.entries().map(\.message) == ["m3", "m4", "m5"])
        sink.clear()
        #expect(sink.entries().isEmpty)
    }

    @Test("Minimum level filters and the formatted line contains level and category")
    func levels() {
        let sink = InMemoryLogSink()
        let logger = DashcamLogger(sinks: [sink], minimumLevel: .warning)
        logger.debug(.buffer, "hidden")
        logger.error(.buffer, "shown")
        let entries = sink.entries()
        #expect(entries.count == 1)
        #expect(entries[0].formatted.contains("[ERROR] buffer: shown"))
        #expect(LogLevel.debug < LogLevel.fault)
    }

    @Test("File sink appends and rotates once past the size limit")
    func fileSink() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dashcam.log")
        let sink = FileLogSink(url: url, maxBytes: 400)
        let logger = DashcamLogger(sinks: [sink])
        for i in 0..<20 { logger.info(.test, "line \(i) padded to make it longer") }
        sink.flush()
        let current = try String(contentsOf: url, encoding: .utf8)
        let rotated = try String(contentsOf: sink.rotatedURL, encoding: .utf8)
        #expect(!current.isEmpty)
        #expect(!rotated.isEmpty)
        #expect(current.contains("line 19"))
        #expect(current.utf8.count <= 400)
    }
}
