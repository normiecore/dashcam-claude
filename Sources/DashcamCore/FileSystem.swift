import Foundation

/// Minimal file-system surface used by the buffer and incident stores. Abstracted so tests can
/// inject failures (full disk, missing files) and so the iOS layer can add file-protection attributes.
public protocol SegmentFileSystem: Sendable {
    func fileExists(at url: URL) -> Bool
    func isDirectory(at url: URL) -> Bool
    func createDirectory(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func removeItem(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    /// Hard-links `source` to `destination`; implementations fall back to a copy when linking is unsupported.
    func linkItem(at source: URL, to destination: URL) throws
    func fileSize(at url: URL) throws -> Int64
    /// Atomic write (temporary file + rename) so readers never observe a partial file.
    func write(_ data: Data, to url: URL) throws
    func read(from url: URL) throws -> Data
    func availableCapacity(forVolumeContaining url: URL) throws -> Int64
}

public struct DefaultFileSystem: SegmentFileSystem {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    public func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func moveItem(at source: URL, to destination: URL) throws {
        try FileManager.default.moveItem(at: source, to: destination)
    }

    public func linkItem(at source: URL, to destination: URL) throws {
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    public func fileSize(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? Int64 { return size }
        if let size = attributes[.size] as? Int { return Int64(size) }
        if let size = attributes[.size] as? NSNumber { return size.int64Value }
        throw DashcamCoreError.fileSystem("Unable to read size of \(url.lastPathComponent)")
    }

    public func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
    }

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url)
    }

    public func availableCapacity(forVolumeContaining url: URL) throws -> Int64 {
        #if canImport(Darwin)
        // On Apple platforms prefer the "important usage" figure: it includes space the system can
        // reclaim by purging caches, which is what matters when deciding whether recording can continue.
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let important = values.volumeAvailableCapacityForImportantUsage {
            return important
        }
        #endif
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: url.path)
        if let free = attributes[.systemFreeSize] as? Int64 { return free }
        if let free = attributes[.systemFreeSize] as? Int { return Int64(free) }
        if let free = attributes[.systemFreeSize] as? NSNumber { return free.int64Value }
        throw DashcamCoreError.fileSystem("Unable to determine free space for \(url.path)")
    }
}
