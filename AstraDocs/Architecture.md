# Dashcam V0.1 architecture

Status: implementation candidate, not device qualified. Deployment target: iOS 17.0; Swift 5 language mode, current stable Xcode. Version: 0.1.0-dev.1.

## Scope and defaults

Rear wide camera; fixed landscape-right 1280×720 H.264, target 30 fps, 4 Mbps. Ten-second independently playable MOV segments with 1-second movie fragments. Five minutes before an incident plus 30 seconds after it, at whole-segment granularity. Audio opt-in, off by default; denied microphone permission leaves video operational. Foreground and unlocked only. Keep screen awake during active recording, stop and finalize on background/interruption/serious thermal pressure, require explicit restart. No background modes or SafetyKit entitlement in V0.1.

## Ownership

One serial capture queue owns the AVCaptureSession, sample callbacks, AVAssetWriters, and RecordingStore mutations. SwiftUI receives immutable snapshots on the main queue. Delegate sample callbacks are delivered directly to the serial queue; bounded writer finalizations prevent unbounded memory growth. Preview uses AVCaptureVideoPreviewLayer. No startRunning on the main thread.

`AVCaptureVideoDataOutput` (+ optional audio output) → `SegmentWriter` → atomic disk-backed `RecordingStore` → `RetentionPolicy.c`.

All triggers enter `saveIncident(source:)`. The store persists the incident before acknowledging success. The protection predicate also applies to open files and future segments. Export is a derivative; original protected segments remain the source of truth. Never automatically delete protected or uncertain/recovery files. Stop when safe cleanup cannot leave a recording reserve.

## Time, durability, and recovery

Use host-clock seconds for interval logic, scoped to a UUID recording session. Use Date only for human labels. Never compare host times across sessions or use adjustable wall time for retention. Register an open segment durably before its writer starts. On finalize, persist ready state and actual sample end. Atomic manifest writes precede deletion decisions; recheck protection on the owning queue before removing files. If metadata is unreadable, fail closed: do not clean up or overwrite it. Unknown and unfinished files are quarantined and surfaced for recovery, never silently removed. Unexpected termination may lose the current fragment/segment; no zero-loss guarantee. fsync/atomic metadata replacement reduces, but cannot eliminate, power-loss risk.

## Shared interfaces

Core/RecordingStore.swift defines `IncidentSource`, `SegmentRecord`, `IncidentRecord`, `StoreSnapshot`, and `RecordingStore`. Store accessed only on the service's serial queue. All mutators throw. Store root is Application Support/Dashcam (excluded from backup, completeUntilFirstUserAuthentication file protection); media files are relative UUID filenames under `segments/`, never temporary/cache storage. Session IDs prevent reboot or wall-clock discontinuities from corrupting interval logic.

`RecordingStore(root:) throws`; `beginSession(at: Date) throws -> UUID`; `beginSegment(sessionID:start:) throws -> SegmentRecord`; `segmentURL(_:) -> URL`; `finishSegment(id:end:byteCount:actualStart:) throws` (actualStart defaults to provisional start); `failSegment(id:reason:) throws`; `triggerIncident(sessionID:at:source:) throws -> IncidentRecord`; `finishSession(sessionID:at:reason:preserveUnprotected:) throws` (preservation defaults false); `prune(sessionID:now:) throws`; `snapshot() -> StoreSnapshot`; `incidentSegments(id:) throws -> [SegmentRecord]`; `deleteIncident(id:) throws`; `recover() throws` (marks unfinished sessions/incident tails interrupted, quarantines uncertain files, no AV repair).

Unexpectedly terminated sessions and sessions with a journal/storage fault retain all remaining media for review, including an ordinary buffer whose incident trigger could not be persisted. Clean, stopped sessions relinquish unprotected finalized media at the next start. This avoids both cross-session accumulation during normal use and silent loss following an uncertain save.

Models: SegmentRecord { id UUID, sessionID UUID, filename String, start Double, end Double?, byteCount Int64, state SegmentState }; SegmentState {writing, ready, damaged}. IncidentRecord { id UUID, sessionID UUID, createdAt Date, eventTime Double, windowStart Double, windowEnd Double, source IncidentSource, state IncidentState, note String? }; IncidentState {collecting, saved, interrupted}; IncidentSource {manual, developer, safetyKit, motion}. StoreSnapshot { segments [SegmentRecord], incidents [IncidentRecord], totalBytes Int64, recoveryMessages [String] }. Store may add internal fields/defaulted parameters but preserve these names.

The app bridge imports `RetentionPolicy.h` directly. C functions own production interval/protection and reserve decisions; portable tests compile the same source, not a reimplementation. Swift persistence and Apple frameworks require the Mac test gate.

## Delivery gates

1. Compile C policy with warnings-as-errors and sanitizers; boundary, randomized, interrupted-tail, overlap and pressure tests.
2. Xcode compile Debug and Release; XCTest storage/recovery and synthetic AVAssetWriter pipeline tests; simulator UI smoke.
3. Physical iPhone: permissions, rear preview, record six minutes, trigger, wait 40 seconds, stop, play/export every segment boundary, restart and verify pins.
4. Interruption, lock, low storage, thermal, forced termination, and 60–120 minute mounted soak. No release tag until physical acceptance. No actual collision tests.

## Staged implementation

First implement policy + store + one camera-to-file path. Then rolling rotation and incident protection. Then library playback/export, storage checks, interrupted recovery, debug injection, and logs. Keep each meaningful change in a focused commit and track unverified claims explicitly.
