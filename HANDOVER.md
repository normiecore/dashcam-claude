# Dashcam project — read first

Last updated: **2026-10-05, Australia/Perth**.

## Current position

**UI refinement in progress (Android `0.1.0-dev.2`):** replacing the prototype
screen and nested library dialogs with a native dark/mint interface, context-aware
Start/Save primary action, persistent navigation, thumbnail footage rows, playback,
settings and explicit pending/partial-tail states. Recording and retention pipeline
is preserved; the service only gains read-only UI metadata. Hosted verification
and visual screenshot review are pending for this revision. The verified build
below remains the previous dev.1 binary until that verification completes.

**Android work resumed at the user's request:** “Let’s start on the android and
I’ll come back to apple later. Let’s get to working 0.1.” Preserve the working
iPhone implementation; iPhone signing/TestFlight remains deferred.

Android implementation lives in `Android/` on dedicated branch `astra/android-v0.1`,
based on remote iOS checkpoint `4ac15f234bb23d4d382b357f38c9b316e21703dc`.
Native Java Camera2/MediaRecorder prototype: preview, foreground recording,
ten-second MP4 segments, five-minute rolling window, manual incident +30s tail,
durable manifest/recovery, playback and per-clip sharing. See `Android/README.md`.

Android retention/storage tests pass **200,647 assertions**, locally and on hosted
JDK 17. Hosted Debug/Release compilation, Android test compilation and lint pass.
Five Android 15 emulator tests pass, including native directory fsync, read-only
sharing provider, activity launch, permission-denied start and synthetic camera
segment/incident/30-second-tail recording with MP4 sample validation and durable pins.
Latest verified Android implementation/build commit:
`98c6eaaf1a2013bfd210f64f468e97434d1ca670`.
[Passing hosted run](https://github.com/normiecore/dashcam-claude/actions/runs/37272375031)
and [debug APK plus lint reports](https://github.com/normiecore/dashcam-claude/actions/runs/37272375031/artifacts/11329275709).
APK SHA256: `e380a3ea0a3f2fa168b81918db160d26fa8ca0e9d56aa36cbfca6fb474bed24b`.
Local downloadable APK: `/workspace/dashcam-android-0.1.apk` (workspace may not persist).
App size is 70,329 bytes (68.7 KiB); the 30,050-byte AndroidTest APK is only tests.
A clean local installer ZIP, `/workspace/dashcam-android-0.1-install.zip`, contains
the verified app and brief installation instructions. CI packaging now separates
the app artifact from AndroidTest/diagnostic files to prevent installing the wrong APK.
This packaging-only update does not change the verified binary; no rebuild was run.
The final docs-only commit does not change the tested binary. APK artifact expires
4 November 2026; obtain or rebuild before then. Release compilation passed but its
APK is unsigned; use the installable debug APK for phone acceptance.

No Seeker physical tests performed. Segmentation currently stops/restarts
MediaRecorder and can introduce gaps. Incident export shares original MP4 segments,
without joining them. Incomplete/uncertain footage is retained without repair.
The prototype debug key is cached outside Git to support updates; stable release
signing is not configured. Cache loss can still change signing identity: export
footage before any uninstall. Android minimum API 28, compile/target API 35.
Actual signing-cache save succeeded in the passing build. Earlier builds used
different ephemeral signing keys; use this latest APK as the starting phone build.
Lint has zero errors and remaining warnings for target API age, storage allocation
guidance and untranslated English UI strings. Camera service API guards and
unbounded-wake-lock warnings were fixed. No release tag or Play upload performed.

Next concrete action: confirm Seeker Android version, install this debug APK,
record six minutes, save an incident at minute five, continue at least 35 seconds,
stop and inspect/share the saved original segments. Then check screen-off/switch-app
continuity and measure segment gaps. Do not qualify `v0.1.0` before phone acceptance.

The goal remains a reliable phone dashcam: segmented recording, about five minutes
of rolling footage, manual incident preservation plus a 30-second tail, playback,
export, recovery and safe storage cleanup. Original intent is in
[`Docs/OriginalBrief.md`](Docs/OriginalBrief.md). Challenge platform assumptions;
do not promise automatic collision detection or background access without evidence.

## Where the work lives

- Private repository: https://github.com/normiecore/dashcam-claude
- iPhone implementation branch: `astra/hosted-macos-v0.1` (preserved).
- Active Android UI refinement branch: `astra/android-ui-polish`.
- Android foundation PR: https://github.com/normiecore/dashcam-claude/pull/3
  was merged into `astra/hosted-macos-v0.1` at
  `b3eaaa555487bd3d5afd3370255a503d7c0af1d5`; old Android feature branch removed.
  UI refinement is based on that merged checkpoint, with a new review PR pending.
- iPhone draft PR: https://github.com/normiecore/dashcam-claude/pull/2
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

1. Open `astra/android-v0.1`; read `Android/README.md` and this checkpoint. Keep iOS
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
- `Android/`: native Java Android app, durable storage, core tests and device tests.
- `.github/workflows/android.yml`: Android compilation/lint, emulator tests and APK artifact.

Suggested new-session prompt: **“Read AGENTS.md and HANDOVER.md first, inspect the
current branch, and resume the dashcam project with [Android / iPhone]. Preserve
existing work and verify changes as you go.”**
