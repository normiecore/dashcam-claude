# Changelog

## Documentary TestFlight build and CI repair — 2026-10-08

- Apple accepted version `0.1.0`, build `20261008.408`, from verified source `31ef969d8fccae7f0187f798813b818ad630a238`; [TestFlight run 37725988703](https://github.com/normiecore/dashcam-claude/actions/runs/37725988703) passed signed upload. Apple processing, installation and physical acceptance remain unconfirmed.
- Resumed hosted Actions after the owner made the repository public. Fixed the main simulator job exceeding its time budget by moving compact/large iPhone layout checks to independent jobs, disabling parallel simulator clones, and retaining the full unit/UI/archive gates.
- [CI 37724913174](https://github.com/normiecore/dashcam-claude/actions/runs/37724913174) passes 61 core tests, 22 production app unit tests, all five UI journeys, both size/orientation checks and the production unsigned Release device archive. [Verification 37724913182](https://github.com/normiecore/dashcam-claude/actions/runs/37724913182) passes C policy checks, 16 alternate-project simulator tests and alternate archive verification.
- Following the owner's explicit approval, [PR #8](https://github.com/normiecore/dashcam-claude/pull/8) was squash-merged into `main` at `d95aabf4f82c2fd9eaf11595702a54ae1b3cbad5`. The earlier automatic approval block is resolved; the accepted TestFlight build remains unchanged.

## iPhone documentary workflow implementation — 2026-10-08

- Opened [PR #8](https://github.com/normiecore/dashcam-claude/pull/8) with the selected neutral documentary design: a quieter camera-first Record screen, contextual Save clip action, dated full-colour clip archive, restrained warnings and adaptive portrait/landscape layout.
- Added Space Saver, Standard (default) and High Detail quality presets; storage estimates; a six-hour/four-GB default rolling-history policy independent of the five-minute saved-clip pre-roll; and protected saved/recovered clips.
- Added car automation guidance and `dashcam://start`, `dashcam://stop` and `dashcam://save` URLs for Shortcuts triggered by CarPlay or the selected car Bluetooth connection. Camera recording remains foreground-only under iOS.
- Added adaptive layout coverage that rotates during active recording and is configured to run on compact iPhone 17e and large iPhone 18 Pro Max simulators. The first iPhone 17 run compiled and passed the rotation/reachability test plus four other UI journeys; it exposed and led to fixes for an old one-minute retention harness assumption and a denied-camera assertion.
- The corrected head is `9b748612fde278daddf56326a7519652da5979a5`. Subsequent CI, verification and TestFlight attempts failed before checkout with no runner steps or logs. TestFlight run `37652027764` did not archive or upload. Those original runner failures were resolved by the public-repository change; successful verification and upload are recorded above.

## First signed TestFlight upload — 2026-10-07

- Apple accepted foundation version `0.1.0`, build `20261007.1334`, from source `fcec715dbfd50093b523a176ed9ecbc83e4c8ccd`; [run 37629540786](https://github.com/normiecore/dashcam-claude/actions/runs/37629540786) passed secrets preflight, release archive, cloud signing and upload. Apple processing, installation and physical recording acceptance are pending. Build is internal-testing-only; no public release.

## Integration readiness — 2026-10-07

- Reconciled live README, handover and implementation plan with the owner's active iPhone TestFlight setup and Android device testing. Verified PR #2's merge candidate retains the simulator preview workflow, Android app, both separate iOS projects and `com.normiecore.dashcam`; hosted iOS, core and Android checks are green. No signed upload or physical acceptance yet.

## iOS bundle identity — 2026-10-07

- Chose `com.normiecore.dashcam` for the production iOS/TestFlight target and `com.normiecore.dashcam.dev` for the separate Astra development target. Updated test identifiers, source namespaces, generator/checker and Apple setup instructions. No Apple signing or physical-device test has occurred.

## Android 0.1.0-dev.2 UI refinement — 2026-10-05

- Added a consistent native dark/mint theme, adaptive launcher icon, large recording
  controls, clear idle/recording states and persistent Recorder/Footage navigation.
- Replaced nested library menus with Saved/Recent/Recovery browsing, thumbnails,
  direct playback/share, live incident-tail status and explanatory empty states.
- Added audio/privacy/storage settings, saved audio preference, camera onboarding,
  permission-dialog state restoration and confirmation before stopping an incident tail.
- Verified Debug/Release and test compilation, lint, 200,647 storage assertions
  and ten Android 15 emulator checks, including actual recording and accessible
  incident/settings interactions. Reviewed seven clean emulator screenshots.
- Final verified build: `0651518568001b0cabbee858107a41ffe7d57925`,
  hosted run `37281099291`; installable APK artifact `11332392247`.
- APK is 120,898 bytes; source remains native Java with no UI dependency bundle.
  New branch has a different debug signing key: export old footage before reinstalling.
  Physical Seeker acceptance and production signing remain pending.

- Reconciled concurrent integration-branch updates while preserving both iPhone
  implementations; Android app source matches the verified build exactly.

## Branch reconciliation — 2026-10-05

- Resolved PR #2's shared README, changelog, Package.swift and gitignore conflicts with main; retained Android and both iPhone implementations.
- Kept the foundation Swift 6 root package and its generated App/Dashcam.xcodeproj separate from the checked-in root Astra Xcode project and XCTest.
- Relocated earlier Astra documentation to AstraDocs to avoid case-insensitive Mac filename collisions; updated links and the handover.
- Made the foundation Linux CI and Makefile test pipelines propagate Swift test failures.
- Physical acceptance and signing remain deferred; conflict resolution does not qualify a release.

## Astra / Android milestones

## Android 0.1 prototype — 2026-10-05

- Separated the installable app artifact from the AndroidTest APK after download
  size confusion; provided an app-only installer ZIP containing the verified binary.

- User chose Android first, deferring iPhone signing/TestFlight.
- Added isolated native Android preview/foreground recording, ten-second MP4 segments,
  rolling retention, durable manual incident protection, recovery, playback and sharing.
- Added storage/retention tests and hosted build/emulator verification workflow.
- Verified 200,647 Android core assertions and five Android 15 emulator tests,
  including synthetic MP4 segment/incident/tail recording. Debug/Release compilation,
  device-test compilation and lint passed; physical Seeker recording remains untested.
- Fixed actual compiler errors in native directory sync and share Intent calls.
  Added media fsync, conservative write-failure stop, partial-tail status, thermal/
  storage stops, monotonic recording timestamps, bounded renewable wake lock and
  API 30 guards for camera/microphone service types.
- Prototype signing key is cached outside source control; cache survival is required
  for future updates to preserve signing identity. Production signing remains deferred.
- MediaRecorder boundaries may have gaps; physical Seeker acceptance remains required.
- Preserved iPhone source and its implementation branch.
- Final verified Android build: `98c6eaaf1a2013bfd210f64f468e97434d1ca670`;
  hosted run `37272375031`, installable debug APK artifact `11329275709`.

## Session handover — 2026-10-05

- Paused implementation/signing at the user's request; preserved the iPhone candidate.
- Recorded potential Android direction, Solana Seeker availability, unconfirmed second phone model and Android versions.
- Recorded reported Apple enrollment with activation/access still unconfirmed.
- Added root HANDOVER.md and AGENTS.md startup/maintenance instructions; linked from README.
- Documentation only; no new application build or physical testing claimed.

## 0.1.0-dev.1 — packaging follow-up, 2026-09-30

- Added an opaque app icon asset and a deterministic, dependency-free generator.
- Added a hosted Release iPhoneOS archive gate checking arm64 output, icon compilation, privacy manifest, permission strings and debug symbols.
- Documented the iPad/iPhone account steps for later signed TestFlight distribution. No signing credentials are stored in the repository.
- Local project and portable retention checks pass. Hosted Debug/Release simulator builds, all 16 XCTest cases and the unsigned arm64 device archive checks pass in run `36671496781`. Fixed the archive checker’s `lipo` argument order after its first real execution. Device installation and physical acceptance still require Apple signing.

## 0.1.0-dev.1 — 2026-09-29

Implemented source:

- Native SwiftUI app, rear wide-camera capture, optional microphone, segmented MOV writer and large manual incident control.
- Five-minute rolling policy, 30-second incident tails, durable manifests, overlap-safe protection, file validation and two-phase cleanup.
- Retained crash/storage-fault buffers, quarantined uncertain media, fail-closed metadata errors, bounded writer finalization and dropped-frame monitoring.
- Saved-incident playback, derivative export/share, confirmed incident deletion, debug incident/interruption injection, OSLog diagnostics.
- Xcode project/shared scheme, privacy manifest, Git history, Mac/CI scripts, portable production-policy tests and 16 Apple XCTest methods.

Verified here: C compiler/warnings, 400,036 checks in normal and ASan/UBSan builds, accelerated 12-hour policy simulation, PBX grammar/graph, plists, scripts and whitespace.

Hosted verification: Xcode 26.6 Debug and Release simulator builds and all 16 XCTest cases pass. The first hosted test exposed inflated sparse-segment duration; explicitly ending the writer session at the last accepted frame fixes it. Added assertions for original segment duration and retained the export duration regression. Source and hosted workflow are in private GitHub draft PR #2; see `Docs/Verification.md` for evidence.

Not verified: actual camera/hardware encoder output, signing/install, interruption behavior and physical soak. This is not a release build.

Decisions: foreground/unlocked only; 720p30 target; audio off by default; no SafetyKit entitlement or motion classifier; originals in Application Support; backup excluded; preserve uncertain footage even at the cost of refusing further recording. C is a small production policy boundary enabling native execution on this Linux host, not a duplicate test implementation.

Outstanding: Apple signing/distribution, physical acceptance, recovery/repair UX, SafetyKit eligibility and eventual integration. Compiler warnings remain for legacy orientation and export callback APIs. No `v0.1.0` release tag until mandatory gates pass.


## iOS foundation milestones (from main)

All notable changes to this project are recorded here. The format follows Keep a Changelog and
the project uses semantic versioning. Entries under "Unreleased" become 0.1.0 once the first
physical-device validation pass is complete.

## [Unreleased] - target 0.1.0

### Changed
- Set the production iOS/TestFlight bundle ID to `com.normiecore.dashcam` and the iOS test IDs to matching suffixes. Align the alternate Astra development project under `com.normiecore.dashcam.dev` on the integration branch; remove unrelated company identity from setup instructions.
- TestFlight builds start from Actions > TestFlight > Run workflow on `main` now that the workflow
  is on the default branch; the `testflight` label still builds an open pull request. The label
  already exists, so docs/TESTING.md drops the step that created it.

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
  driven by a fake camera (now `SimulatedCaptureService`) through the new `CaptureControlling` seam, covering
  stop flushing the final partial segment, Save Incident before, after and during a stop, two
  simultaneous taps, pause and resume, Stop during an interruption, calls that keep or stop video,
  orientation rotation, storage-critical stop and restart, runtime errors during a rotation,
  media-services reset, and failure followed by restart.
- Simulated camera in Debug builds (`SimulatedCaptureService`, moved from the tests into the app):
  the Debug app records synthetic video and audio in the Simulator, so the screens, incidents and
  clips can be used there. Launch arguments `--ui-testing` (own settings and storage, wiped each
  launch, short segments and post-roll), `--skip-onboarding`, `--simulated-camera` and
  `--camera-denied`; Release builds ignore them.
- `DashcamUITests` (XCUITest): first-run consent, start and stop, Save Incident, the clip library,
  clip detail and delete, dimmed mode (REC indicator, hold to save, tap to wake), Simulate Crash
  from the developer menu, and the camera-denied screen. Accessibility identifiers on the controls
  they use.
- Coordinator test that records past the 1 minute buffer with an incident still collecting: its
  oldest footage leaves the buffer index and buffer directory while the incident's links keep it,
  the exported clip starts with that footage, the buffer holds about its target length, and no
  buffer file outlives its index entry.
- CI builds the Release configuration for a generic iOS device after the Simulator tests.
- Install without a Mac. `.github/workflows/testflight.yml` archives a Release build, signs it with
  Apple's cloud-managed distribution certificate through an App Store Connect team API key and
  uploads it for internal TestFlight testing; it starts when the `testflight` label is added to the
  pull request, and a Linux preflight job checks the four secrets first. CI also archives an unsigned
  Release build, checks it with `scripts/check-app-bundle.sh` and attaches `Dashcam-unsigned.ipa`
  for free-account sideloading from a PC. docs/TESTING.md has both routes step by step for an owner
  with only an iPhone and a browser, and the checklist no longer assumes a Mac.
  A review of the workflow and the instructions (Opus agents, each finding verified) led to: a
  build number from the clock, so re-running an older run cannot upload a lower number; the
  concurrency group on the upload job, so unrelated label events cannot replace a waiting upload;
  an icon check that reads only what actool writes; and corrected owner steps (Enroll Now and the
  ID, name and payment requirements, Account Holder-only steps on an existing team, creating the
  `testflight` label, accepting the first TestFlight invitation, and what a missed 7-day re-sign
  does to footage).
- The free-space query no longer blocks the segment store. On Apple platforms it can take seconds
  while the system computes purgeable space, and it ran on the store actor twice per segment, so a
  run start (which prepares its directory through the store) could wait behind it. It now runs on a
  dispatch queue, concurrent callers share one query, and the coordinator reuses retention's reading
  while recording. Slow file operations (free-space query, run directory, indexing, segment writes
  over 0.5 s) are logged as storage warnings. Found by two coordinator tests that timed out on a
  loaded CI machine; they now check their property (footage continues in a new run; recovery comes
  from the recorded intent, not the watchdog) instead of a tight deadline. Segments are now written
  at userInitiated rather than utility priority (until it is on disk a segment exists only in memory),
  a segment that waits over 0.5 s for the I/O queue is logged, and the coordinator tests print run
  notices and warnings so passing CI runs show where time goes.
- App icon (asset catalog, 1024 px, no alpha), required for any App Store Connect upload.
- The app target is iPhone only. XcodeGen's iOS preset had set the target's device family to iPhone
  and iPad, overriding the project setting, which would have failed App Store Connect's iPad
  orientation rules.
- CFBundleVersion and CFBundleShortVersionString now come from CURRENT_PROJECT_VERSION and
  MARKETING_VERSION, so each upload can carry a new build number (they were fixed literals).
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
- Simulator preview without a Mac. The UI tests attach a screenshot of each screen they reach, and
  the Xcode 27 CI lane records the Simulator's screen while they run. Each pull request run
  publishes both to the `simulator-preview` branch, viewable on GitHub from a phone, and attaches
  them as the `simulator-preview` artifact. The lane now builds for testing once and runs the unit
  tests and the UI tests separately, so the recording covers only the UI tests. The UI tests still
  run when a unit test fails, and a run whose UI tests fail still publishes its preview, marked as
  failed, with only the tests' own screenshots (not Xcode's failure attachments).

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
- Xcode 27 / iOS 27.0: the 20 unit tests (including the 78 s buffer rollover test) and the 4 UI
  tests pass, and the Release configuration builds for a generic iOS device. CI skips the
  simulator diagnostics collection that xcodebuild attempted after the UI tests, which spent its
  full 600 s timeout on a passing run.
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
