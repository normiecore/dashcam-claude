import Foundation
import XCTest
#if SWIFT_PACKAGE
@testable import DashcamCore
#else
@testable import Dashcam
#endif

final class RecordingStoreTests: XCTestCase {
    func testUnexpectedTerminationRetainsUnprotectedReadyBufferOnNextStart() throws {
        let root = try temporaryRoot()
        var store: RecordingStore? = try RecordingStore(root: root)
        let session = try store!.beginSession(at: Date())
        let segment = try ready(store!, session: session, start: 100, end: 110)
        let url = store!.segmentURL(segment)
        store = nil // no orderly finishSession: process died or metadata failed
        let recovered = try RecordingStore(root: root)
        _ = try recovered.beginSession(at: Date())
        try recovered.prune(sessionID: session, now: 1000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(recovered.snapshot().recoveryMessages.isEmpty)
    }

    func testStorageFaultRetainsUnprotectedBufferEvenAfterOrderlyFinish() throws {
        let root = try temporaryRoot()
        let store = try RecordingStore(root: root)
        let session = try store.beginSession(at: Date())
        let segment = try ready(store, session: session, start: 100, end: 110)
        try store.finishSession(sessionID: session, at: 120, reason: "Incident journal failed",
                                preserveUnprotected: true)
        let reopened = try RecordingStore(root: root)
        _ = try reopened.beginSession(at: Date())
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.segmentURL(segment).path))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DashcamStore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func ready(_ store: RecordingStore, session: UUID, start: Double, end: Double) throws -> SegmentRecord {
        let segment = try store.beginSegment(sessionID: session, start: start)
        let data = Data(repeating: 0x46, count: 64)
        try data.write(to: store.segmentURL(segment))
        try store.finishSegment(id: segment.id, end: end, byteCount: Int64(data.count))
        return segment
    }

    func testTriggerIsDurableAndPinsPastAndFutureAcrossRestart() throws {
        let root = try temporaryRoot()
        var store: RecordingStore? = try RecordingStore(root: root)
        let session = try store!.beginSession(at: Date())
        let past = try ready(store!, session: session, start: 90, end: 100)
        let overlapping = try ready(store!, session: session, start: 100, end: 110)
        let incident = try store!.triggerIncident(sessionID: session, at: 105, source: .manual)
        XCTAssertEqual(incident.state, .collecting)
        XCTAssertThrowsError(try store!.incidentSegments(id: incident.id))
        let middle = try ready(store!, session: session, start: 110, end: 125)
        let future = try ready(store!, session: session, start: 125, end: 140)
        XCTAssertEqual(store!.snapshot().incidents.first?.state, .saved)
        // End exactly at the retention cutoff: unprotected media may expire, protected media may not.
        try store!.prune(sessionID: session, now: 500)
        XCTAssertEqual(Set(store!.snapshot().segments.map(\.id)), Set([past.id, overlapping.id, middle.id, future.id]))
        store = nil
        let recovered = try RecordingStore(root: root)
        XCTAssertEqual(recovered.snapshot().incidents.first?.id, incident.id)
        XCTAssertEqual(Set(try recovered.incidentSegments(id: incident.id).map(\.id)),
                       Set([past.id, overlapping.id, middle.id, future.id]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.segmentURL(future).path))
    }

    func testOverlappingIncidentsKeepSharedMediaUntilBothAreRemoved() throws {
        let store = try RecordingStore(root: temporaryRoot())
        let session = try store.beginSession(at: Date())
        let shared = try ready(store, session: session, start: 100, end: 110)
        let first = try store.triggerIncident(sessionID: session, at: 105, source: .manual)
        let second = try store.triggerIncident(sessionID: session, at: 108, source: .developer)
        try store.deleteIncident(id: first.id)
        try store.prune(sessionID: session, now: 500)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(shared).path))
        try store.deleteIncident(id: second.id)
        try store.prune(sessionID: session, now: 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.segmentURL(shared).path))
        XCTAssertTrue(store.snapshot().segments.isEmpty)
    }

    func testNewSessionCleansOnlyUnprotectedFinalizedOldSessionWithoutComparingClocks() throws {
        let root = try temporaryRoot()
        let store = try RecordingStore(root: root)
        let firstSession = try store.beginSession(at: Date())
        let disposable = try ready(store, session: firstSession, start: 600, end: 610)
        let pinned = try ready(store, session: firstSession, start: 940, end: 950)
        let incident = try store.triggerIncident(sessionID: firstSession, at: 945, source: .manual)
        let tail = try ready(store, session: firstSession, start: 950, end: 980)
        let unfinished = try store.beginSegment(sessionID: firstSession, start: 981)
        try Data([9]).write(to: store.segmentURL(unfinished))
        try store.failSegment(id: unfinished.id, reason: "Simulated writer failure")
        try store.finishSession(sessionID: firstSession, at: 985, reason: "user")

        // This can be a new boot: its monotonic host seconds may be far smaller.
        let secondSession = try store.beginSession(at: Date())
        XCTAssertNotEqual(secondSession, firstSession)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.segmentURL(disposable).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(pinned).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(tail).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(unfinished).path))
        XCTAssertEqual(store.snapshot().incidents.first?.id, incident.id)
        try store.prune(sessionID: secondSession, now: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(pinned).path))
    }

    func testCrashQuarantinesUnfinishedAndUnknownMediaAndInterruptsTail() throws {
        let root = try temporaryRoot()
        var store: RecordingStore? = try RecordingStore(root: root)
        let session = try store!.beginSession(at: Date())
        let writing = try store!.beginSegment(sessionID: session, start: 200)
        try Data([1, 2, 3]).write(to: store!.segmentURL(writing))
        let incident = try store!.triggerIncident(sessionID: session, at: 201, source: .manual)
        let stray = root.appendingPathComponent("segments/stray.mov")
        try Data([4, 5]).write(to: stray)
        store = nil
        let recovered = try RecordingStore(root: root)
        XCTAssertEqual(recovered.snapshot().segments.first?.state, .damaged)
        XCTAssertEqual(recovered.snapshot().incidents.first?.state, .interrupted)
        XCTAssertEqual(recovered.snapshot().incidents.first?.id, incident.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.segmentURL(writing).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stray.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("recovery").path).isEmpty)
        try recovered.prune(sessionID: session, now: 1000)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.segmentURL(writing).path))
    }

    func testIncidentSelectionRejectsDamagedMediaInsteadOfReturningIncompleteReadySet() throws {
        let store = try RecordingStore(root: temporaryRoot())
        let session = try store.beginSession(at: Date())
        _ = try ready(store, session: session, start: 98, end: 105)
        let incident = try store.triggerIncident(sessionID: session, at: 100, source: .manual)
        let bad = try store.beginSegment(sessionID: session, start: 105)
        try Data([3]).write(to: store.segmentURL(bad))
        try store.failSegment(id: bad.id, reason: "Synthetic write failure")
        try store.finishSession(sessionID: session, at: 110, reason: "interruption")
        XCTAssertEqual(store.snapshot().incidents.first?.state, .interrupted)
        XCTAssertThrowsError(try store.incidentSegments(id: incident.id))
    }

    func testCorruptOrMissingManifestWithMediaFailsClosed() throws {
        let root = try temporaryRoot()
        let store = try RecordingStore(root: root)
        let session = try store.beginSession(at: Date())
        let segment = try ready(store, session: session, start: 10, end: 20)
        let manifest = root.appendingPathComponent("manifest.json")
        try Data("{invalid".utf8).write(to: manifest)
        XCTAssertThrowsError(try RecordingStore(root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(segment).path))
        try FileManager.default.removeItem(at: manifest)
        XCTAssertThrowsError(try RecordingStore(root: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.segmentURL(segment).path))
    }

    func testFailedManifestReplacementDoesNotAcknowledgeIncidentOrMutateSnapshot() throws {
        let root = try temporaryRoot()
        let store = try RecordingStore(root: root)
        let session = try store.beginSession(at: Date())
        let manifest = root.appendingPathComponent("manifest.json")
        let parked = root.appendingPathComponent("parked-manifest")
        try FileManager.default.moveItem(at: manifest, to: parked)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: manifest)
            try? FileManager.default.moveItem(at: parked, to: manifest)
        }
        XCTAssertThrowsError(try store.triggerIncident(sessionID: session, at: 100, source: .manual))
        XCTAssertTrue(store.snapshot().incidents.isEmpty)
    }

    func testPendingIncidentOnlySavedAfterFinalizedPostWindow() throws {
        let store = try RecordingStore(root: temporaryRoot())
        let session = try store.beginSession(at: Date())
        let prior = try ready(store, session: session, start: 95, end: 120)
        let incident = try store.triggerIncident(sessionID: session, at: 100, source: .manual)
        let open = try store.beginSegment(sessionID: session, start: 120)
        try Data([7]).write(to: store.segmentURL(open))
        XCTAssertEqual(store.snapshot().incidents.first?.state, .collecting)
        try store.finishSegment(id: open.id, end: 130, byteCount: 1)
        XCTAssertEqual(store.snapshot().incidents.first?.state, .saved)
        XCTAssertEqual(try store.incidentSegments(id: incident.id).map(\.id), [prior.id, open.id])
    }

    func testActualAcceptedStartPreventsFalseIncidentCoverageAndProtection() throws {
        let store = try RecordingStore(root: temporaryRoot())
        let session = try store.beginSession(at: Date())
        let earlyIncident = try store.triggerIncident(sessionID: session, at: 50, source: .developer)
        let registered = try store.beginSegment(sessionID: session, start: 70)
        try Data([1, 2]).write(to: store.segmentURL(registered))
        try store.finishSegment(id: registered.id, end: 110, byteCount: 2, actualStart: 100)
        XCTAssertEqual(store.snapshot().segments.first?.start, 100)
        XCTAssertEqual(store.snapshot().incidents.first?.state, .collecting)
        try store.finishSession(sessionID: session, at: 120, reason: "user")
        XCTAssertEqual(store.snapshot().incidents.first?.id, earlyIncident.id)
        XCTAssertTrue(try store.incidentSegments(id: earlyIncident.id).isEmpty)
        try store.prune(sessionID: session, now: 500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.segmentURL(registered).path))
    }

    func testInvalidAcceptedStartLeavesRegisteredWriterUnchanged() throws {
        let store = try RecordingStore(root: temporaryRoot())
        let session = try store.beginSession(at: Date())
        let registered = try store.beginSegment(sessionID: session, start: 100)
        try Data([8]).write(to: store.segmentURL(registered))
        XCTAssertThrowsError(try store.finishSegment(id: registered.id, end: 105, byteCount: 1,
                                                     actualStart: 99))
        XCTAssertEqual(store.snapshot().segments.first?.start, 100)
        XCTAssertEqual(store.snapshot().segments.first?.state, .writing)
    }
}
