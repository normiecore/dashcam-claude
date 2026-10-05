# Dashcam project — read first

Last updated: **2026-10-05, Australia/Perth**.

## Current position

**Android UI refinement complete — `0.1.0-dev.2`, version code 2.** The native
dark/mint interface has context-aware Start/Save controls, a separate Stop button,
portrait/landscape layouts, camera onboarding, Saved/Recent/Recovery browsing,
thumbnail rows, precise clip times, playback/share sheets, persistent audio settings
and explicit pending/partial-tail feedback. Capture, retention and durable storage
behavior is preserved; RecordingService only gains read-only UI metadata.

Android is the active platform at the user's request: “Let’s start on the android
and I’ll come back to apple later. Let’s get to working 0.1.” iPhone signing and
TestFlight remain deferred. The original Android foundation PR #3 was merged into
the working iPhone branch, then its feature branch was deleted. UI refinement lives
on `astra/android-ui-polish`, based on merged checkpoint
`b3eaaa555487bd3d5afd3370255a503d7c0af1d5`; no iPhone source was changed.

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

Next concrete action: confirm Seeker Android version, install this debug APK,
record six minutes, save an incident at minute five, continue at least 35 seconds,
stop and inspect/share the saved original segments. Then check screen-off/switch-app
continuity and measure segment gaps. Do not qualify `v0.1.0` before phone acceptance.

The goal remains a reliable phone dashcam: segmented recording, about five minutes
of rolling footage, manual incident preservation plus a 30-second tail, playback,
export, recovery and safe storage cleanup. Original intent is in
[`AstraDocs/OriginalBrief.md`](AstraDocs/OriginalBrief.md). Challenge platform assumptions;
do not promise automatic collision detection or background access without evidence.

## Where the work lives

### Integration update — 5 October 2026

PR #3 has been merged into `astra/hosted-macos-v0.1`, so that branch now contains
the Android prototype. PR #2's conflicts with main are being resolved by preserving
both iPhone implementations and Android. The four shared files (README, changelog,
Package.swift and gitignore) are reconciled: the root Swift 6 package belongs to
`Sources/DashcamCore`; Astra XCTest remains in the root Xcode project. Foundation
XcodeGen produces `App/Dashcam.xcodeproj`. Keep these build entry points distinct.
The earlier Astra `Docs/` files are now `AstraDocs/` to avoid case collisions with
foundation `docs/` on Macs. See README for all build/test commands. Physical phone
acceptance remains the next product step; no signing/upload is part of this merge.

- Private repository: https://github.com/normiecore/dashcam-claude
- iPhone implementation branch: `astra/hosted-macos-v0.1` (preserved).
- Active Android UI refinement branch: `astra/android-ui-polish`.
- Android foundation PR: https://github.com/normiecore/dashcam-claude/pull/3
  was merged into `astra/hosted-macos-v0.1` at
  `b3eaaa555487bd3d5afd3370255a503d7c0af1d5`; old Android feature branch removed.
- Android UI draft PR: https://github.com/normiecore/dashcam-claude/pull/7
  based on the integration branch. Latest integration changes were merged into the
  UI review branch; the verified Android app source remains identical.
- iPhone draft PR: https://github.com/normiecore/dashcam-claude/pull/2
- At this checkpoint, the implementation is **not merged into remote `main`**.
  A fresh session must open this branch or PR to see the app and this handover.
- Existing `claude/v0.1-foundation` branch was preserved.
- Android version: `0.1.0-dev.2`, code `2`; iPhone remains `0.1.0-dev.1`
  with Xcode marketing version `0.1.0`, build `1`.
- Historical scratch checkout: `/workspace/scratch/7b8755d64a71/Dashcam`.
  Do not depend on this path surviving a new session; GitHub is the durable source.
- Local scratch Git commits and GitHub commits have different ancestry because
  source was transferred through the GitHub connector. Prefer a fresh checkout of
  the remote implementation branch; do not force-push the scratch `main` over it.

## User context and decisions

- User works from iPad/iPhone and wants cloud development without buying a Mac.
- A GitHub-hosted Mac already compiles/tests this project; it is an ephemeral CI
  runner, not an interactive desktop or a connected physical phone.
- User reported enrolling in Apple Developer Program on 5 October. Activation,
  Team ID and App Store Connect access have **not** been confirmed. No Apple
  signing credentials or upload connection have been configured.
- User owns an iPhone and **Solana Seeker** Android phone. Seeker Android version
  is unknown. A friend can test a phone described as **“razer”**: clarify whether
  Razer Phone/Phone 2 or Motorola Razr, and obtain Android version.
- Android is now the chosen implementation path, initially for Seeker, followed by
  the friend's device. Neither phone has been physically tested with this app.
- Prioritize footage preservation; compile/test continuously, investigate failures,
  keep a short changelog, and use appropriate lower-cost subagents for scoped work.

## Implemented and verified

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

## Limits and open issues

- iPhone recording is foreground/unlocked only. No SafetyKit entitlement or
  integration, no motion classifier, no GPS, no cloud upload.
- iPhone-only app target; using an iPad to manage development does not mean iPad
  recording support is implemented.
- No signed/installable IPA or TestFlight build exists. Unsigned archive success
  does not demonstrate camera, audio, heat, battery, lock or recovery reliability.
- Physical acceptance is mandatory: six-minute pre/post incident test, interruptions,
  low space, termination/recovery, audio/orientation and prolonged recording.
- Legacy orientation/export callback compiler warnings remain in Swift 5 mode.
- Damaged-media repair and recovery-item deletion UI remain outstanding.
- Debug simulation controls are absent in Release; manual Save Incident invokes
  the same preservation pipeline for eventual TestFlight acceptance.
- Do not tag `v0.1.0` as qualified until physical acceptance is complete.

## If the user resumes with Android

1. Open `astra/android-ui-polish`; read `Android/README.md` and this checkpoint. Keep iOS
   intact and Apple signing deferred unless the user changes direction.
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

Confirm active membership, Team ID and App Store Connect access. Then register the
chosen bundle ID/app record and configure secure signing/export/upload. Current
`com.daz.dashcam.dev` is a development identifier, not confirmed registered.
Keep private keys/passwords in suitable secret storage, never chat or Git.
Follow [`AstraDocs/HostedMac.md`](AstraDocs/HostedMac.md) and
[`AstraDocs/DeviceAcceptance.md`](AstraDocs/DeviceAcceptance.md).

## Session procedure and file map

Start by reading this file, checking Git status/current branch and comparing any
new user direction with this checkpoint. Do not rerun successful expensive builds
for a documentation-only change. Test meaningful code changes and record actual
results, commit/run identifiers and unverified limits before ending the session.

- `App/`: iOS capture, writer, UI, export and debug simulation.
- `Core/RecordingStore.swift`: durable manifest, retention integration and recovery.
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
