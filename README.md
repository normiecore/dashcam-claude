# Dashcam — V0.1 prototypes

**Read [HANDOVER.md](HANDOVER.md) first when starting a session.**
[`AGENTS.md`](AGENTS.md) describes how to maintain the checkpoint.

Android and iPhone prototypes are both in active testing. The owner has Apple
Developer Program access and the iPhone TestFlight route is ready for account
setup. The Android prototype has hosted build and emulator evidence; physical
Solana Seeker acceptance remains outstanding. See [Android setup and testing](Android/README.md).
No implementation is yet qualified for reliable incident capture on physical phones.

## Repository layout

The repository combines the iOS foundation with the Astra iOS checkpoint and
Android prototype. Both iPhone implementations remain available;
they have different defaults and storage layouts, and must be tested separately.

| Component | Entry point | Verification |
| --- | --- | --- |
| Android prototype | `Android/` | `bash Android/core-tests/run.sh`; `.github/workflows/android.yml` |
| iOS foundation from main | `App/project.yml`, `App/Dashcam/` | `swift test`; `.github/workflows/ci.yml` |
| Foundation portable Swift core/simulator | `Sources/DashcamCore`, `Sources/DashcamSim` | `swift test`; `swift run dashcam-sim drive --hours 2 --incidents 1200,4000` |
| Astra iOS checkpoint | Root `Dashcam.xcodeproj`, `App/*.swift`, `Core/` | `bash Tools/test-core.sh`; `bash Tools/verify-mac.sh`; `bash Tools/verify-device-archive.sh` |

The root `Package.swift` belongs to the foundation Swift 6 core. Astra storage and
synthetic media tests remain in the root Xcode project. Root `swift test` does not
run those tests. XcodeGen generates **`App/Dashcam.xcodeproj`** for the foundation;
it does not replace the checked-in root project. Their bundle IDs are respectively
`com.normiecore.dashcam` and `com.normiecore.dashcam.dev`; the TestFlight workflow
builds the foundation project.

Foundation documentation: [platform review](docs/PLATFORM_REVIEW.md),
[architecture](docs/ARCHITECTURE.md), [plan](docs/PLAN.md), [testing](docs/TESTING.md).
Astra documentation: [architecture](AstraDocs/Architecture.md),
[Apple API review](AstraDocs/AppleReview.md), [verification](AstraDocs/Verification.md),
[hosted Mac](AstraDocs/HostedMac.md), [physical acceptance](AstraDocs/DeviceAcceptance.md).
The earlier `Docs/` files were relocated to `AstraDocs/` so they do not collide with
foundation `docs/` filenames on case-insensitive Macs.

## Android acceptance next

Confirm the Seeker's Android version, install the verified debug APK described in
`Android/README.md`, and complete its six-minute incident/tail test. Check actual
segment gaps, screen-off/switch-app behavior, microphone, heat/storage and restart
recovery before broadening the feature set. The friend's phone described as “razer”
still needs an exact model and Android version. Automatic crash detection is not
implemented in the Android prototype.

## iPhone development and installation

Recording remains foreground-only on iPhone. Both implementations require physical
camera, audio, thermal and recovery acceptance. The foundation's optional motion
heuristic is not a validated collision detector; SafetyKit requires restricted
approval and is flag-gated. The Astra checkpoint has neither detector enabled.

For the foundation on a Mac, install Xcode/XcodeGen, run `swift test` at the root,
then `cd App && xcodegen generate` and open `App/Dashcam.xcodeproj`. Optional team
configuration: `DASHCAM_TEAM_ID=YOURTEAMID xcodegen generate` inside `App`.

For the Astra checkpoint, run `python3 Tools/verify_project.py`,
`bash Tools/test-core.sh`, `bash Tools/verify-mac.sh` and
`bash Tools/verify-device-archive.sh`, then open the root `Dashcam.xcodeproj`.

GitHub Actions supplies hosted build/simulator machines. Foundation installation
options and its TestFlight workflow are documented in `docs/TESTING.md`; Astra's
unsigned archive and account setup are documented in `AstraDocs/HostedMac.md`.
No signed upload has been performed. Keep signing keys
and passwords in private secret storage, not chat or source control.

## Version control

Repository: https://github.com/normiecore/dashcam-claude.
Integration history: https://github.com/normiecore/dashcam-claude/pull/2.
Android PRs #3 and #7 joined the integration branch before PR #2. After PR #2
merges, `main` is the canonical source for both platforms.
Update `HANDOVER.md` and `CHANGELOG.md` when project state changes. Reserve a
qualified `v0.1.0` tag for successful physical-device acceptance.

License: TBD.
