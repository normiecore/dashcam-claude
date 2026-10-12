import ActivityKit
import Foundation

/// Shared by the app and its WidgetKit extension; contains no camera or storage access.
struct DriveActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case recording, paused, starting, stopped, failed }
        var phase: Phase
        var recordedSeconds: Int
        var detail: String
        var updatedAt: Date
    }
    var startedAt: Date
}
