# Plan

Status as of 2026-09-29. Versions follow semantic versioning; 0.1.0 is cut when M2 is complete and M3 has passed on at least one physical iPhone.

## Milestones

### M0 Foundations (done)

`DashcamCore` builds and tests on Linux and Apple platforms: segment model, retention planner, sidecar-persisted segment store with crash reconcile, incident manager, rolling buffer coordinator, recorder state machine, motion heuristic with trace replay, fMP4 box tools with timestamp rebasing, clip assembler, logger. 60 Swift Testing tests pass, including a simulated two-hour drive. `dashcam-sim` simulates drives with incidents and storage pressure in seconds.

### M1 Vertical slice (code complete, compiled by CI, not yet run on a device)

Rear-camera preview, start and stop, segmented recording into the rolling buffer, automatic deletion, the Save Incident button, pre-roll and post-roll preservation, clip export, clips library with playback, sharing and Save to Photos. The XcodeGen project and the app target compile in CI, and the Simulator suite runs the coordinator and the screens against a simulated camera; nothing has run on hardware.

### M2 V0.1 hardening (mostly in code, needs device runs)

Storage floor and critical-storage stop; permission handling and Settings deep link; interruption handling per reason, media-services recovery, watchdog; thermal throttling; developer menu (Simulate Crash, interruption, media services reset, writer failure, storage floor, motion trace replay, live stats, log export); first-run consent; privacy manifest and guard tests; Simulator writer test. Remaining: the first build on a Mac with a signing team, and fixes for whatever the device shows.

### M3 Device validation (needs the owner)

The checklist in TESTING.md: 10 minute driveway test, Save Incident, clip playback, lock and unlock, phone call, Camera app takeover, Reset Media Services, thermal via Device Conditions, low storage, force quit and relaunch recovery, a 60 minute mounted soak on a charger, and a drive with impact detection on to count false positives. Success is the brief's definition: continuous recording for an extended drive, only the rolling window retained, and the manual or test trigger reliably preserving footage before and after the event.

### M4 Automatic detection

Calibrate the motion heuristic on real traces (measure the accelerometer clip level, tune thresholds per sensitivity, decide whether GPS speed gating is needed). Apply for the SafetyKit entitlement if the owner decides to; the adapter is written and flag-gated. Consider CMSensorRecorder for post-hoc traces.

### Later

GPS route metadata and speed or timestamp overlay (Core Location, When-In-Use only), front camera option, configurable options beyond the current ranges, emergency contact workflow, cloud backup and automatic upload. Background or locked-screen recording is not possible on iOS and is removed from the roadmap. CarPlay has no camera category and is out of scope.

## What can be tested where

| Tier | How | What it covers |
|---|---|---|
| Linux or Mac, no Xcode | `swift test`, `swift run dashcam-sim drive` | Retention, store reconcile, incident linking and recovery, retroactive triggers, fMP4 rebasing, motion heuristic on traces, state machine, logging, multi-hour simulations |
| iOS Simulator | `xcodebuild test` (CI macOS lanes, Xcode 26.6 and Xcode 27) | App target compiles against both SDKs; real `AVAssetWriter` segmented output with synthetic video and audio; concatenation, rebasing and passthrough remux load in AVFoundation; the recording coordinator's lifecycle, incident, interruption, recovery, storage, buffer rollover and failure paths against a simulated camera; the screens driven by XCUITest (consent, record, Save Incident, clips, delete, dimmed mode, Simulate Crash, camera denied); privacy manifest and usage strings present; the Release configuration compiles for a device |
| Physical iPhone | Manual checklist in TESTING.md | Camera capture, audio, HEVC hardware encoding, preview rotation, interruptions, backgrounding, thermal pressure, storage pressure, battery, motion sensors, Photos saving, SafetyKit (entitled builds only) |

## Open product decisions

Pre-roll defaults to the whole buffer (5 minutes) and post-roll to 60 s. Overlapping triggers extend the same incident. Audio is on by default. Incident clips are included in iCloud backup while the buffer is excluded. Recording continues at 15 fps at thermal critical rather than stopping. The bundle identifier prefix is `com.matrixengineered`. Whether to apply for the SafetyKit entitlement and whether to use the paid Apple Developer Program are the owner's calls.
