# Dashcam project — read first

Last updated: **2026-10-08, Australia/Perth**.

## Active checkpoint — documentary build uploaded; merge awaiting approval

The owner made the repository public on 8 October after exhausting private-repository
Actions minutes. Hosted runners now execute normally. The documentary implementation
is on `codex/documentary-workflow-20261007`, [PR #8](https://github.com/normiecore/dashcam-claude/pull/8).
Verified source is `31ef969d8fccae7f0187f798813b818ad630a238`; later checkpoint edits are documentation only.
`main` remains unchanged.

Apple accepted version **0.1.0**, build **20261008.408**, at 12:11 Perth on 8 October.
[TestFlight run 37725988703](https://github.com/normiecore/dashcam-claude/actions/runs/37725988703)
passed secrets preflight, Release archive, bundle checks, cloud signing and upload.
This is an internal-testing-only build. Apple processing, tester assignment,
installation and physical camera acceptance have not been confirmed.

Implemented: camera-first adaptive Record screen, contextual Save clip, dated full-colour
archive, Standard (default)/Space Saver/High Detail quality presets, storage estimates,
five-minute saved-clip pre-roll separate from six-hour/four-GB default rolling history,
Shortcuts start/stop/save URLs and CarPlay/Bluetooth automation guidance.
The production target supports iPhones on iOS 18 or later with adaptive dimensions,
safe areas and orientation. Camera recording remains foreground/unlocked only.

[CI 37724913174](https://github.com/normiecore/dashcam-claude/actions/runs/37724913174) passes:
61 Swift core tests, 22 production app unit tests, all five UI journeys on iPhone 17,
portrait/landscape reachability on iPhone 17e and iPhone 18 Pro Max, production
Release device archive/bundle checks, simulator preview and unsigned IPA packaging.
[Verification 37724913182](https://github.com/normiecore/dashcam-claude/actions/runs/37724913182)
passes portable C retention checks (400,036 normally and with sanitizers), policy simulation,
16 alternate-project simulator tests, and alternate unsigned device archive checks.
These are simulator/policy results, not physical-device tests.

The first resumed CI attempt exceeded its 30-minute job limit while starting the second
phone-size check, after app unit tests and compact layout passed. CI now gives each
phone-size check an independent runner/job, disables parallel simulator clones, and
allows the main unit/UI/archive job 45 minutes. Both size checks and the complete main
suite passed with this setup; app code did not change during this repair.

Automatic approval review rejected the squash merge into main, stating that deployment
had been authorized but merging into the default branch had not been explicitly authorized.
Do not bypass that rejection or merge through another method. The concrete reviewed
PR and accepted TestFlight build are ready; ask the owner for explicit permission
to merge PR #8 into main.

Next: obtain explicit merge permission; inspect App Store Connect app 6820104006,
TestFlight version 0.1.0/build 20261008.408 after processing; resolve only evidenced
compliance prompts; install via TestFlight and follow docs/TESTING.md on a physical iPhone.
Do not repeat the successful upload merely because Apple processing is pending.
Do not qualify/tag v0.1.0 before physical acceptance.

## Current position

**Earlier first signed iPhone upload succeeded.** The production foundation app uses
`com.normiecore.dashcam`. Apple accepted version `0.1.0`, build `20261007.1334`,
from source `fcec715dbfd50093b523a176ed9ecbc83e4c8ccd` in
[TestFlight run 37629540786](https://github.com/normiecore/dashcam-claude/actions/runs/37629540786).
The secrets preflight, release archive, cloud signing and upload all passed.
Apple processing and installation have not been confirmed; physical capture
acceptance is still outstanding. The workflow uploads internal-testing-only builds.

The owner created the Normiecore Dashcam App Store Connect record and configured
four GitHub Actions signing secrets. Never request or store the private key in
chat. PR #2 is merged; `main` is canonical. The separate root Astra checkpoint
uses `com.normiecore.dashcam.dev` and has not been distributed.

**Android UI refinement complete — `0.1.0-dev.2`, version code 2.** The native
dark/mint interface has context-aware Start/Save controls, a separate Stop button,
portrait/landscape layouts, camera onboarding, Saved/Recent/Recovery browsing,
thumbnail rows, precise clip times, playback/share sheets, persistent audio settings
and explicit pending/partial-tail feedback. Capture, retention and durable storage
behavior is preserved; RecordingService only gains read-only UI metadata.

Android development started first; the owner has now resumed the iPhone path after
joining the Apple Developer Program. Android PRs #3 and #7 were merged into
integration PR #2. Both platforms need physical-device acceptance; the first production iPhone
TestFlight upload has succeeded.

Verified build commit: `0651518568001b0cabbee858107a41ffe7d57925`.
[Passing hosted run](https://github.com/normiecore/dashcam-claude/actions/runs/37281099291).
Debug/Release and instrumentation compilation pass, lint has no errors, and Android
retention/storage tests pass **200,647 assertions**, locally and on hosted JDK 17.
**Ten Android 15 emulator tests pass**: native directory fsync, read-only provider,
activity launch, accessible Recorder/Footage navigation, denied camera start,
synthetic MP4 segment/incident/30-second-tail capture using UI Start/Save/Stop,
activity recreation retaining the recording service and live preview, saved library,
landscape action visibility, incident-sheet navigation and persistent audio settings.
Seven real emulator screenshots were exported and visually reviewed: ready, empty
library, recording, saved library, landscape, incident details and settings.
These checks do not establish physical camera/audio/screen-off reliability.

[Installable debug APK artifact](https://github.com/normiecore/dashcam-claude/actions/runs/37281099291/artifacts/11332392247):
`app-debug.apk` at ZIP root; app is **120,898 bytes (118.1 KiB)**.
APK SHA256: `7f7343a3d67cf2099be9044f7bf0c1baa150ca268de025dd50094bc51fc7d6cb`.
[Emulator reports and screenshots](https://github.com/normiecore/dashcam-claude/actions/runs/37281099291/artifacts/11331959306).
Local downloads: `/workspace/dashcam-android-polished.apk`,
`/workspace/dashcam-android-polished-install.zip` (app + INSTALL.txt only),
and screenshots in `/workspace/dashcam-ui-review/ui-screenshots/`.
Workspace files may not persist. App artifact expires 4 November 2026.
The final documentation-only commit does not change the verified binary.
Release compilation passes, but its APK is unsigned; use the debug APK for acceptance.

**Upgrade caveat:** GitHub Actions debug-key caches are branch-scoped. The new UI
branch missed the old branch's cache and created a new prototype signing identity.
Its key was successfully restored on subsequent builds. It differs from the old
69 KiB APK: export/check wanted footage from the old app before uninstalling it,
then install this APK. Uninstalling or clearing data removes private footage.
New certificate SHA256:
`2baad557df2596cdcc2f9bebea537e788f2df1bf540ae3a8b602ee695d87c135`.
Stable release signing remains unconfigured; cache expiry/loss can change identity.

No Seeker physical tests performed. MediaRecorder stops/restarts between ten-second
clips and may introduce gaps. Export shares original MP4 clips without joining them.
Uncertain files remain retained without repair; explicit deletion remains outstanding.
Android minimum API 28, compile/target API 35. Remaining lint warnings do not prevent
compilation; no release tag, Play upload or final `v0.1.0` qualification performed.

Next concrete actions: wait for Apple processing, create an internal TestFlight
group, add the owner and build, install from TestFlight, then follow the physical
iPhone checklist in `docs/TESTING.md`. On Android, confirm the Seeker version and
run the six-minute incident/tail test from `Android/README.md`. Do not qualify
`v0.1.0` before physical phone acceptance.

The goal remains a reliable phone dashcam: segmented recording, about five minutes
of rolling footage, manual incident preservation plus a 30-second tail, playback,
export, recovery and safe storage cleanup. Original intent is in
[`AstraDocs/OriginalBrief.md`](AstraDocs/OriginalBrief.md). Challenge platform assumptions;
do not promise automatic collision detection or background access without evidence.

## Where the work lives

### Integration history — 5–7 October 2026

Android foundation PR #3 and UI PR #7 were merged into integration PR #2.
PR #2 reconciles the foundation Swift 6 package, Android app and two distinct
iOS projects. XcodeGen produces `App/Dashcam.xcodeproj` for production/TestFlight;
the root `Dashcam.xcodeproj` is a separate Astra development checkpoint.
The earlier Astra `Docs/` moved to `AstraDocs/` to avoid case collisions on Macs.
Foundation simulator preview changes from PRs #5 and #6 on `main` survive the
integration merge. See README for build paths and PR #2 for the reviewed merge.
The merge verification itself did not establish signing or physical-device
qualification. The subsequent successful signed upload is recorded above.

- Public repository (owner changed visibility on 8 October): https://github.com/normiecore/dashcam-claude
- Integration review: https://github.com/normiecore/dashcam-claude/pull/2
- Canonical source: `main`; PR #2 merged on 7 October 2026.
- Android version: `0.1.0-dev.2`, code `2`; iPhone marketing version `0.1.0`,
  build `1` in source (TestFlight assigns a fresh build number).
- Earlier scratch checkout: `/workspace/scratch/7b8755d64a71/Dashcam` is
  stale; GitHub is the durable source. Do not force-push its unrelated ancestry.

## User context and decisions

- User works from iPad/iPhone and wants cloud development without buying a Mac.
- A GitHub-hosted Mac already compiles/tests this project; it is an ephemeral CI
  runner, not an interactive desktop or a connected physical phone.
- Apple Developer membership, registered production App ID, App Store Connect
  record and GitHub signing secrets are now established by the successful upload.
- User owns an iPhone and **Solana Seeker** Android phone. Seeker Android version
  is unknown. A friend can test a phone described as **“razer”**: clarify whether
  Razer Phone/Phone 2 or Motorola Razr, and obtain Android version.
- Android was chosen first for Seeker, followed by the friend's device; the owner
  has now resumed iPhone distribution setup. Neither platform has physical capture
  acceptance yet.
- Prioritize footage preservation; compile/test continuously, investigate failures,
  keep a short changelog, and use appropriate lower-cost subagents for scoped work.

## Astra checkpoint: implemented and verified

iPhone implementation: SwiftUI, AVFoundation, serial capture/storage operations,
720p30 target, H.264 4 Mbps, ten-second MOV segments, one-second fragments,
optional microphone, durable JSON manifest, overlap-safe incident pinning,
recovery retention, library/playback/export, lifecycle/thermal handling and debug
incident/interruption simulation. Originals are in Application Support, excluded
from backup. Uncertain footage is retained rather than silently deleted.

Authoritative latest tested implementation/tooling commit:
`511ac398d1e6fc04ae20959afc8f3cbe37165ee4`.

| Check | Actual result |
| --- | --- |
| Hosted Xcode 26.6 Debug and Release simulator builds | PASS |
| Simulator XCTest | 16 passed, zero failures |
| Release iPhoneOS arm64 archive, icon/privacy/permissions/dSYM checks | PASS, **unsigned** |
| Portable production C retention policy | 400,036 assertions pass normally and with ASan/UBSan |
| Accelerated 12-hour policy simulation | PASS; policy only, not a camera soak |
| Physical recording, signing/install, TestFlight upload | **Not performed** |

Evidence: [passing hosted run](https://github.com/normiecore/dashcam-claude/actions/runs/36671496781),
[logs and unsigned archive](https://github.com/normiecore/dashcam-claude/actions/runs/36671496781/artifacts/11077823897).
Artifacts can expire. Later documentation-only commits do not imply a new tested binary.

Real failures fixed: sparse final frames inflated movie/export duration; writer
now explicitly ends the session at accepted video coverage, with regression checks.
The first archive check had incorrect `lipo` argument order; fixed and rerun.

## Astra checkpoint limits and shared acceptance

- iPhone recording is foreground/unlocked only. No SafetyKit entitlement or
  integration, no motion classifier, no GPS, no cloud upload.
- iPhone-only app target; using an iPad to manage development does not mean iPad
  recording support is implemented.
- The Astra checkpoint is unsigned. The foundation's first signed TestFlight
  upload is recorded above; neither implementation has physical camera, audio,
  heat, battery, lock or recovery acceptance.
- Physical acceptance is mandatory: six-minute pre/post incident test, interruptions,
  low space, termination/recovery, audio/orientation and prolonged recording.
- Legacy orientation/export callback compiler warnings remain in Swift 5 mode.
- Damaged-media repair and recovery-item deletion UI remain outstanding.
- Debug simulation controls are absent in Release; manual Save Incident invokes
  the same preservation pipeline for eventual TestFlight acceptance.
- Do not tag `v0.1.0` as qualified until physical acceptance is complete.

## If the user resumes with Android

1. Open `main`; read `Android/README.md` and this checkpoint. Preserve the separate
   iOS implementations and the configured TestFlight workflow.
2. Confirm Seeker Android version, install the latest verified debug APK, and follow
   the six-minute incident/tail acceptance test in `Android/README.md`.
3. Validate switching apps/screen-off, actual segment gaps, audio/orientation,
   low space, thermal/battery behavior and interrupted-write recovery on Seeker.
4. Resolve observed capture/lifecycle failures before expanding. Seamless segment
   writing, joined export, safe explicit saved/recovery deletion and damaged-media
   repair remain future work. Do not guarantee screen-off reliability upfront.
5. Clarify the friend's exact phone model/Android version before secondary testing.

Research as of 5 October: Android documents a camera foreground service that can
continue camera access in the background, but launching it generally requires the
app to be visible and permission granted. Google Pixel Personal Safety provides
crash detection on supported devices; no documented public crash-event API was
found for our app. Do not assume Seeker or the friend's phone provides one.
Manual incidents remain the baseline; any custom detector needs separate validation.

Sources to recheck:
- https://developer.android.com/develop/background-work/services/fgs/service-types
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://support.google.com/pixelphone/answer/7055029
- https://developers.google.com/location-context/activity-recognition
- https://developer.android.com/developer-verification

## If the user resumes with iPhone

Open `main`. Use the foundation project (`App/project.yml`, `App/Dashcam/`) and
`docs/TESTING.md` for TestFlight installation and physical acceptance. Signing is
configured and the first upload succeeded; check Apple processing before uploading
again. The separate `com.normiecore.dashcam.dev` checkpoint remains undistributed.
Keep private keys/passwords in suitable secret storage, never chat or Git.

## Session procedure and file map

Start by reading this file, checking Git status/current branch and comparing any
new user direction with this checkpoint. Do not rerun successful expensive builds
for a documentation-only change. Test meaningful code changes and record actual
results, commit/run identifiers and unverified limits before ending the session.

- `App/Dashcam/`: production foundation iOS app distributed through TestFlight.
- `App/` also contains legacy Astra sources; follow each project's target membership.
- `Core/RecordingStore.swift` (Astra checkpoint): durable manifest, retention integration and recovery.
- `Core/RetentionPolicy.c`: production interval/protection/deletion policy.
- `Tests/`: C policy, Swift storage and synthetic media tests.
- `Tools/test-core.sh`, `Tools/verify_project.py`: Linux checks.
- `Tools/verify-mac.sh`: simulator builds and XCTest.
- `Tools/verify-device-archive.sh`: unsigned iPhone archive checks.
- `.github/workflows/verify.yml`: hosted verification on PR changes/manual dispatch.
- `AstraDocs/Architecture.md`, `AstraDocs/AppleReview.md`, `AstraDocs/Verification.md`: detailed design and evidence.
- `CHANGELOG.md`: completed work and significant decisions.
- `Android/`: native Java Android app, durable storage, core tests and device tests.
- `.github/workflows/android.yml`: Android compilation/lint, emulator tests and APK artifact.
- `Android/app/src/main/java/com/daz/dashcam/Ui.java`, `res/values/`: native design system.
- `Android/verify-emulator.sh`: test execution and valid screenshot collection.
- `App/project.yml`, `App/Dashcam/`, `Sources/`, `docs/`: iOS foundation from main,
  with its own Swift package and XcodeGen build/test paths. Details are in README.

Suggested new-session prompt: **“Read AGENTS.md and HANDOVER.md first, inspect the
current branch, and resume the dashcam project with [Android / iPhone]. Preserve
existing work and verify changes as you go.”**
