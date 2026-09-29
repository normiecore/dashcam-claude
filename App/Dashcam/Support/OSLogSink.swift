import Foundation
import os
import DashcamCore

/// Forwards core log entries to the unified logging system so they show up in Console.app,
/// `log collect`, and sysdiagnose alongside the file log.
final class OSLogSink: LogSink {
    private let loggers: [LogCategory: Logger]

    init(subsystem: String = Bundle.main.bundleIdentifier ?? "com.matrixengineered.dashcam") {
        var loggers: [LogCategory: Logger] = [:]
        for category in LogCategory.allCases {
            loggers[category] = Logger(subsystem: subsystem, category: category.rawValue)
        }
        self.loggers = loggers
    }

    func write(_ entry: LogEntry) {
        guard let logger = loggers[entry.category] else { return }
        let message = entry.message
        switch entry.level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        case .fault: logger.fault("\(message, privacy: .public)")
        }
    }
}
