# Changelog

All notable changes to this project are recorded here. The format follows Keep a Changelog and
the project uses semantic versioning. Entries under "Unreleased" become 0.1.0 once the first
physical-device validation pass is complete.

## [Unreleased] - target 0.1.0

### Added
- DashcamCore Swift package (Linux and Apple platforms): segment model with wall-clock timing,
  retention planner (age window, byte cap, free-space floor), sidecar-persisted segment store with
  crash reconcile, incident manager that hard-links footage on trigger and recovers interrupted
  incidents at launch, rolling buffer coordinator, recorder state machine, Core Motion impact
  heuristic with CSV trace replay, fMP4 box tools with fragment timestamp rebasing, clip assembler,
  fan-out logger. 54 Swift Testing tests including a simulated two-hour drive.
- iOS app (XcodeGen spec, iOS 18+): AVCaptureSession capture service with explicit 1080p30 format,
  AVAssetWriter segmented CMAF writer (4 s segments, HEVC, atomic per-segment files), recording
  coordinator (lifecycle, interruptions, media-services recovery, thermal throttling, frame
  watchdog, ordered ingestion, incident assembly), manual/motion/SafetyKit(flag-gated)/developer
  incident sources, clip export (rebased concatenation plus passthrough remux) and Photos saving,
  privacy manifest and usage strings.
- Simulator test that drives the real segmented writer with synthetic frames and verifies that
  whole-run and mid-run clips load with the expected duration.
- `dashcam-sim` developer CLI (`swift run dashcam-sim drive --hours 2 --incidents 1200,4000`):
  simulates multi-hour drives with incidents and storage pressure against the real core in
  seconds and checks the retention and incident invariants; `replay` runs a motion trace through
  the impact detector.
- CI: Linux `swift test` lane and an on-demand macOS Simulator lane.
- Capture turns iOS 18 automatic frame rate off before pinning frame durations, since a frame-duration
  write throws while it is on.
- One-minute motion sample ring saved as `motion.csv` alongside each incident.

### Decisions
- Segmented AVAssetWriter (fMP4/CMAF) instead of AVCaptureMovieFileOutput: iOS cannot switch
  movie files without stopping, and file outputs stop on backgrounding.
- Recording is foreground-only. iOS prohibits camera use in the background and locking the screen
  backgrounds the app, so the app keeps the screen awake and offers a dimmed mode instead.
- Incident protection is done by hard-linking buffer segments into the incident directory the
  moment a trigger arrives; the buffer can then be trimmed freely. Pre-roll defaults to the whole
  buffer (5 min), post-roll to 60 s; overlapping triggers extend the same incident.
- SafetyKit is an optional adapter behind the DASHCAM_SAFETYKIT flag. It needs the restricted
  `com.apple.developer.severe-vehicular-crash-event` entitlement, only one app per device can hold
  it, and events arrive after Emergency SOS finishes, so the adapter protects footage retroactively.
- Thermal handling reduces frame rate (24 fps at serious, 15 fps at critical) rather than stopping
  the camera at critical as Apple suggests; to be validated in the soak test.
- Deployment target iOS 18.0 for reach; developed against the iOS 27 SDK.

### Verified in CI
- The app target builds with Xcode 26.6 (iOS 26.5 SDK, iOS 18 deployment target) and the Simulator
  tests pass: the segmented writer produces an initialization segment plus media segments, a
  mid-run clip loads with the right duration after timestamp rebasing, and the passthrough remux
  succeeds on synthetic H.264 frames.

### Outstanding
- The capture path has not run on a physical iPhone: camera, microphone, HEVC hardware encoding,
  interruptions, thermal behaviour and battery are all device-only (docs/TESTING.md checklist).
- fMP4 concatenation and remux are verified on the Simulator with H.264; confirm with the device's
  HEVC output and with audio.
- Product decisions pending: pre-roll length, incident clips in iCloud backup, SafetyKit
  entitlement application, paid developer account, bundle identifier.
- GPS metadata, overlays, configurable buffer beyond 1-10 min, cloud upload: later.
- Xcode 27 replaced the Devices and Simulators window with Device Hub; whether the thermal Device
  Condition still exists there is unverified (docs/TESTING.md step 8).
- Legal review: California Vehicle Code 26708 defines a "video event recorder" with a 30-second
  storage limit; whether a phone app with a 5-minute loop is in that class is for counsel.
