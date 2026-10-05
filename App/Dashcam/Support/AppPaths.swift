import Foundation

/// On-disk layout under Library/Application Support/Dashcam.
///
/// The rolling buffer is excluded from backup (it is transient and large). Incident clips are the
/// user's data and stay eligible for backup. Nothing is written to tmp/ or Caches/ because iOS may
/// purge those between launches, and footage must survive a relaunch to be recoverable.
enum AppPaths {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Dashcam", isDirectory: true)
    }()

    static let buffer = root.appendingPathComponent("buffer", isDirectory: true)
    static let incidents = root.appendingPathComponent("incidents", isDirectory: true)
    static let logs = root.appendingPathComponent("logs", isDirectory: true)
    static let logFile = logs.appendingPathComponent("dashcam.log")

    /// Creates the directory tree and applies backup exclusions. Safe to call on every launch.
    static func prepare() throws {
        let fm = FileManager.default
        for url in [root, buffer, incidents, logs] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        for url in [buffer, logs] {
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try target.setResourceValues(values)
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
