import Foundation
import DashcamCore

/// Finalized footage still held by automatic retention. Each writer run is kept separate,
/// so a background interruption never appears as recorded footage between two runs.
struct RecentDrive: Identifiable {
    let run: RunID
    let segments: [Segment]
    var id: RunID { run }
    var start: Date { segments.first!.startTime }
    var end: Date { segments.last!.endTime }
    /// Count the actual media intervals, rather than wall-clock time across interruptions.
    var duration: TimeInterval {
        segments.reduce(0) { $0 + max(0, $1.duration) }
    }
    var bytes: Int64 { segments.reduce(0) { $0 + $1.byteCount } }

    static func grouped(from segments: [Segment]) -> [RecentDrive] {
        let media = segments.filter { $0.kind == .media && $0.isComplete }
        return Dictionary(grouping: media, by: { $0.id.run }).map { run, parts in
            RecentDrive(run: run, segments: parts.sorted { $0.startTime < $1.startTime })
        }.sorted { $0.start > $1.start }
    }
}
