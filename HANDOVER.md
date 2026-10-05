# Dashcam project — read first

Last updated: **2026-10-05, Australia/Perth**.

## Current position

**Work is paused at the user's request.** Preserve the working iPhone implementation.
The user is considering Android next and asked for this persistent handover before
pausing. No Android implementation has started. Do not resume iPhone signing or
start an Android port solely because an older plan says to continue autonomously.
When the user resumes, establish whether they want the Android prototype or the
iPhone/TestFlight path; the most recent discussion leaned toward Android.

The goal remains a reliable phone dashcam: segmented recording, about five minutes
of rolling footage, manual incident preservation plus a 30-second tail, playback,
export, recovery and safe storage cleanup. Original intent is in
[`Docs/OriginalBrief.md`](Docs/OriginalBrief.md). Challenge platform assumptions;
do not promise automatic collision detection or background access without evidence.

## Where the work lives

- Private repository: https://github.com/normiecore/dashcam-claude
- Implementation branch: `astra/hosted-macos-v0.1`.
- Open draft PR: https://github.com/normiecore/dashcam-claude/pull/2
- At this checkpoint, the implementation is **not merged into remote `main`**.
  A fresh session must open this branch or PR to see the app and this handover.
- Existing `claude/v0.1-foundation` branch was preserved.
- Version: `0.1.0-dev.1`; Xcode marketing version `0.1.0`, build `1`.
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
- Android discussion: potentially easier build tooling and background recording.
  Proposed initial target is Seeker, followed by the friend's device. This is a
  proposed direction, not a completed port or a hardware compatibility claim.
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

1. Confirm target phone models/Android versions and the decision to proceed.
2. Keep iOS intact; isolate Android work on a dedicated branch/directory after
   checking the live repository state. Do not blindly copy Swift media code.
3. Revalidate current CameraX/Camera2, MediaCodec/MediaMuxer, camera/microphone
   foreground-service and installation rules for those Android versions.
4. Build the smallest installable slice: rear preview, user-started recording,
   short segments and manual incident pinning. Reuse retention principles/tests;
   evaluate reuse of the C policy without forcing an unnecessary native bridge.
5. Compile and test before expanding. Validate on Seeker, then the second phone:
   screen-off/switch-app recording, segment gaps, thermal/storage behavior and
   interrupted-write recovery. Do not guarantee screen-off reliability upfront.

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
Follow [`Docs/HostedMac.md`](Docs/HostedMac.md) and
[`Docs/DeviceAcceptance.md`](Docs/DeviceAcceptance.md).

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
- `Docs/Architecture.md`, `Docs/AppleReview.md`, `Docs/Verification.md`: detailed design and evidence.
- `CHANGELOG.md`: completed work and significant decisions.

Suggested new-session prompt: **“Read AGENTS.md and HANDOVER.md first, inspect the
current branch, and resume the dashcam project with [Android / iPhone]. Preserve
existing work and verify changes as you go.”**
