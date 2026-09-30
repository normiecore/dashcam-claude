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
  AVAssetWriter segmented fragmented-MP4 writer (Apple HLS profile, 4 s segments, HEVC, atomic
  per-segment files), recording
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
- CI: Linux `swift test` lane and a macOS Simulator lane on Xcode 27 (iOS 27 SDK) for pull requests;
  an Xcode 26.6 lane runs on manual dispatch.
- Fixed segment timestamps on the real capture clock: the writer decided which timeline a segment
  report used with a ">= session start" test, but reported timestamps are quantized to the track
  timescale, so the first segment of every run read as movie time and was stamped the device's
  uptime into the future. Such a segment never aged out of the buffer and fell outside every
  incident window. The timeline is now chosen once per run by which reading places the first
  segment where it must start. Found by the coordinator tests (the earlier writer tests used
  timestamps starting at zero, where both readings agree).
- Fixed a main-actor hang introduced in the third review round: two callers ending a run at the
  same moment (locking the phone, or Save Incident during Stop) could leave one of them re-awaiting
  an already finished teardown in a loop that never yields, freezing the app. Run teardowns are
  now chained, each caller waiting for the previous one without looping. Found by the new
  coordinator tests; CI now caps each test's run time and streams the build output so a hang shows
  where it stopped.
- `RecordingCoordinatorTests`: the real coordinator, writer, store, incident manager and export
  driven by a fake camera (`FakeCaptureService`) through the new `CaptureControlling` seam, covering
  stop flushing the final partial segment, Save Incident before, after and during a stop, two
  simultaneous taps, pause and resume, Stop during an interruption, calls that keep or stop video,
  orientation rotation, storage-critical stop and restart, runtime errors during a rotation,
  media-services reset, and failure followed by restart.
- Capture turns iOS 18 automatic frame rate off before pinning frame durations, since a frame-duration
  write throws while it is on.
- One-minute motion sample ring saved as `motion.csv` alongside each incident.
- Second adversarial review of the iOS layer (four lenses, 47 findings; 24 were independently
  verified by a second agent before a usage limit stopped the rest, which were confirmed by reading
  the code), fixes applied: storage-critical stop no longer deadlocks the ingest pipeline; concurrent run
  teardowns are shared so the background task is not released before the last segment is on disk;
  interruption-ended events that arrive mid-transition are honoured by a post-transition
  reconciliation; Stop tapped during a pause/resume is honoured; the watchdog no longer pauses video
  during audio-only interruptions and now also detects a writer that stops producing segments;
  `SegmentWriter` detects asynchronous `AVAssetWriter` failures and never finishes a failed writer;
  writer failures are rate limited; a failed session closes collecting incidents; the run is rotated
  on orientation change, audio interruption and audio setting changes; exports rebase fragment
  timestamps (fixes the fallback clip starting at the run offset); Photos saving retries through a
  remux; the preview layer attaches on the session queue and follows a published device; a failed
  capture rebuild can no longer leave a stale configuration; Core Motion publishes UI counters in
  batches; banners carry identities; Save Incident while stopped closes the incident immediately;
  delete is blocked during export; the consent screen cannot cover a live recording and auto-start
  waits for consent; the microphone prompt follows the audio setting.

### Decisions
- Segmented AVAssetWriter (fragmented MP4) instead of AVCaptureMovieFileOutput: iOS cannot switch
  movie files without stopping, and file outputs stop on backgrounding. The Apple HLS file type
  profile is used rather than CMAF: AVFoundation allows only one track per writer under the CMAF
  profile, which a Simulator test with synthetic audio and video caught (error -11875) before any
  device run.
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
- A phone call or alarm rotates the run to a video-only writer instead of feeding a writer whose
  audio input has gone silent (undocumented territory); an incident spanning the call gets two
  clip parts. Orientation changes and audio setting changes rotate the run for the same reason.
- Deployment target iOS 18.0 for reach; developed against the iOS 27 SDK.

### Verified in CI
- Both Simulator lanes (Xcode 26.6 / iOS 26.5 and Xcode 27 / iOS 27.0) pass the full suite,
  including the 14 coordinator tests against the fake camera.
- The app target builds with Xcode 26.6 (iOS 26.5 SDK, iOS 18 deployment target) and the Simulator
  tests pass: the segmented writer produces an initialization segment plus media segments, a
  mid-run clip loads with the right duration after timestamp rebasing, and the passthrough remux
  succeeds on synthetic H.264 frames.
- With synthetic audio and video fed together, every segment carries both tracks, a mid-run clip
  rebases one delta per track, and the audio and video tracks start and end within 150 ms of each
  other before and after the remux.
- Third review (Opus agents, four lenses, 28 findings, each confirmed by a code-path skeptic and a
  platform-facts skeptic), fixes applied: runtime errors and camera interruptions that arrive during
  a transition are recorded and acted on afterwards; a deferred rotation keeps its rebuild flag; a
  stale audio-interruption flag is cleared by the watchdog and the resume paths allow one video-only
  resume while only audio is interrupted; stop and failure teardowns hold a background task and the
  failure teardown takes the transition slot so a restart waits for it; Save Incident during a stop
  joins the writer flush before closing the incident; the frame rate is re-synced with the device
  after every configuration so a thermal throttle is neither lost by a rebuild nor kept after
  Stop/Start; the watchdog threshold follows the running writer's segment interval and a changed
  interval rotates the run; recovery exports no longer delay auto-start; the welcome screen's
  Continue starts recording only when bootstrap deferred it; SafetyKit marks an event handled only
  after the incident is recorded; the microphone is retried when it was requested but missing from
  the capture graph; the preview re-applies its rotation after every graph rebuild; opening a clip no
  longer interrupts other apps' audio and players survive tab switches; delete is offered only for
  finished incidents everywhere; layout priorities keep the HUD from scrolling while space is free.
  In DashcamCore: `IncidentManager.trigger` registers the incident before its store snapshot so
  concurrent triggers merge and concurrent segments attach; `segmentDidFinalize` never writes back
  a stale copy across its await; retention no longer credits hard-linked incident footage as freed
  space (`sharedStorage`, `reclaimedBytes`); clip and log writes use the throwing `FileHandle` API
  so a full disk fails the export instead of crashing the app; the writer stores each segment's
  index sidecar with the media so a kill between the two never orphans a complete segment.

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
- Whether video keeps flowing during a phone call (`audioDeviceInUseByAnotherClient`) is
  undocumented; Apple's AVCam treats it as a whole-session interruption. The code handles both:
  frames flowing means a video-only run, frames stopped means a pause that resumes after the call.
  Confirm on a device (checklist step 5).
