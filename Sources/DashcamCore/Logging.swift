import Foundation

public enum LogLevel: Int, Comparable, Sendable, Codable, CaseIterable {
    case debug = 0, info, notice, warning, error, fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO"
        case .notice: return "NOTICE"
        case .warning: return "WARN"
        case .error: return "ERROR"
        case .fault: return "FAULT"
        }
    }
}

public enum LogCategory: String, Sendable, Codable, CaseIterable {
    case app, capture, recorder, buffer, incident, storage, motion, export, ui, test
}

public struct LogEntry: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String

    public init(timestamp: Date, level: LogLevel, category: LogCategory, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }

    public var formatted: String {
        "\(LogEntry.timestampFormatter.string(from: timestamp)) [\(level.label)] \(category.rawValue): \(message)"
    }

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public protocol LogSink: Sendable {
    func write(_ entry: LogEntry)
}

/// Fan-out logger. Sinks are responsible for their own thread safety. On iOS the app adds an
/// `os.Logger` sink; on Linux tests use the in-memory sink.
public final class DashcamLogger: Sendable {
    private let sinks: [LogSink]
    private let clock: WallClock
    public let minimumLevel: LogLevel

    public init(sinks: [LogSink], minimumLevel: LogLevel = .debug, clock: WallClock = SystemWallClock()) {
        self.sinks = sinks
        self.minimumLevel = minimumLevel
        self.clock = clock
    }

    public static let disabled = DashcamLogger(sinks: [], minimumLevel: .fault)

    /// Sinks of a given concrete type (for example to flush the file sink before sharing it).
    public func sinksOfType<T: LogSink>(_ type: T.Type) -> [T] {
        sinks.compactMap { $0 as? T }
    }

    public func log(_ level: LogLevel, _ category: LogCategory, _ message: @autoclosure () -> String) {
        guard level >= minimumLevel, !sinks.isEmpty else { return }
        let entry = LogEntry(timestamp: clock.now(), level: level, category: category, message: message())
        for sink in sinks { sink.write(entry) }
    }

    public func debug(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.debug, category, message()) }
    public func info(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.info, category, message()) }
    public func notice(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.notice, category, message()) }
    public func warning(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.warning, category, message()) }
    public func error(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.error, category, message()) }
    public func fault(_ category: LogCategory, _ message: @autoclosure () -> String) { log(.fault, category, message()) }
}

/// Ring buffer of recent entries, for the in-app diagnostics screen and for tests.
public final class InMemoryLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var head = 0
    public let capacity: Int

    public init(capacity: Int = 2_000) {
        self.capacity = max(1, capacity)
    }

    public func write(_ entry: LogEntry) {
        lock.lock(); defer { lock.unlock() }
        if buffer.count < capacity {
            buffer.append(entry)
        } else {
            buffer[head] = entry
            head = (head + 1) % capacity
        }
    }

    /// Entries in chronological order.
    public func entries() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        if buffer.count < capacity { return buffer }
        return Array(buffer[head...] + buffer[..<head])
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        buffer.removeAll()
        head = 0
    }
}

/// Appends formatted lines to a log file and rotates it once (`name.log` -> `name.1.log`) past `maxBytes`.
public final class FileLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private let maxBytes: Int
    private var handle: FileHandle?
    private var currentSize: Int = 0

    public init(url: URL, maxBytes: Int = 2 * 1_048_576) {
        self.url = url
        self.maxBytes = maxBytes
    }

    public var rotatedURL: URL {
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base).1").appendingPathExtension(ext)
    }

    public func write(_ entry: LogEntry) {
        lock.lock(); defer { lock.unlock() }
        guard let data = (entry.formatted + "\n").data(using: .utf8) else { return }
        do {
            try openIfNeeded()
            if currentSize + data.count > maxBytes {
                try rotate()
            }
            _ = try handle?.seekToEnd()
            try handle?.write(contentsOf: data)
            currentSize += data.count
        } catch {
            // Logging must never take the app down; drop the line. (The throwing FileHandle API is used
            // because the legacy one raises an uncatchable exception when the disk is full.)
        }
    }

    public func flush() {
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
    }

    private func openIfNeeded() throws {
        if handle != nil { return }
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            _ = fm.createFile(atPath: url.path, contents: nil)
        }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        currentSize = (attributes[.size] as? Int) ?? Int((attributes[.size] as? Int64) ?? 0)
        handle = try FileHandle(forWritingTo: url)
    }

    private func rotate() throws {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        if fm.fileExists(atPath: rotatedURL.path) {
            try fm.removeItem(at: rotatedURL)
        }
        try fm.moveItem(at: url, to: rotatedURL)
        currentSize = 0
        try openIfNeeded()
    }
}

/// Prints to standard output. Useful for `swift test` and the Linux simulator.
public struct PrintLogSink: LogSink {
    public init() {}
    public func write(_ entry: LogEntry) { print(entry.formatted) }
}
