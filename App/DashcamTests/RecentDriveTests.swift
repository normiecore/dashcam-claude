import Foundation
import XCTest
import DashcamCore
@testable import Dashcam

final class RecentDriveTests: XCTestCase {
    func testGroupingExcludesInitializationAndIncompleteFootageAndDoesNotCountIdleGap() {
        let first = RunID(rawValue: "first"), second = RunID(rawValue: "second")
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func part(_ run: RunID, _ sequence: Int, _ offset: Double, complete: Bool = true, kind: SegmentKind = .media) -> Segment {
            Segment(id: .init(run: run, sequence: sequence), kind: kind, startTime: start.addingTimeInterval(offset), duration: kind == .media ? 4 : 0, byteCount: 100, relativePath: "test", isComplete: complete)
        }
        let drives = RecentDrive.grouped(from: [part(first, 0, 0, kind: .initialization), part(first, 1, 0), part(first, 2, 4), part(first, 3, 8, complete: false), part(second, 1, 3_600)])
        XCTAssertEqual(drives.count, 2)
        XCTAssertEqual(drives.first?.run, second)
        XCTAssertEqual(drives.last?.duration, 8)
        XCTAssertEqual(drives.last?.bytes, 200)
    }
}
