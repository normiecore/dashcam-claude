# Hosted Mac verification

The private repository's [draft pull request #2](https://github.com/normiecore/dashcam-claude/pull/2) exercises the [verification workflow](../.github/workflows/verify.yml). The [passing macOS run](https://github.com/normiecore/dashcam-claude/actions/runs/36592919853) built Debug and Release and passed all 16 XCTest cases using Xcode 26.6. The first run exposed an overlong final-frame duration; the writer fix and regression assertions passed in this second run. Download the [build logs and XCTest evidence](https://github.com/normiecore/dashcam-claude/actions/runs/36592919853/artifacts/11045135729) while the artifact is retained by GitHub.

On pull requests or manual dispatch, the `core` job checks project structure and the portable C policy on Linux. The `ios` job uses a GitHub-hosted `macos-26` runner and runs `bash Tools/verify-mac.sh`: project checks, Debug and Release iOS Simulator builds, then XCTest on an available iPhone simulator running iOS 17 or later. It uploads `build/verification` as the `dashcam-xcode-evidence` artifact, including build/test logs and the `.xcresult` bundle when produced. A failed step can leave partial evidence; inspect the job log as well as the artifact.

This runner is temporary build/test infrastructure, not an interactive remote desktop or a connected physical iPhone. The simulator commands set `CODE_SIGNING_ALLOWED=NO`, so no Apple account or signing credentials are needed for this gate. To install on a real iPhone, configure an Apple development team, bundle ID and signing in Xcode; distributing through TestFlight requires its own Apple account and distribution setup. Keep credentials out of chat.

For local Mac and physical-device steps, see the [README](../README.md) and [device acceptance checklist](DeviceAcceptance.md). Simulator success cannot establish camera behavior, long recordings, mounted-road performance or recovery on a physical device.

## Device archive gate

After simulator verification, CI runs `bash Tools/verify-device-archive.sh` to compile Release against the iPhoneOS SDK and produce an **unsigned** arm64 archive. The script checks the packaged app icon, privacy manifest, permission strings and debug symbols. The archive is included in the evidence artifact. This catches device-SDK and packaging problems; it cannot be installed or uploaded to TestFlight until signing and export are configured. This new gate is awaiting its first hosted result.

## Next action from iPad or iPhone

1. Open [Apple Developer Account](https://developer.apple.com/account/) and sign in to the Apple Account that will own this project.
2. Check whether Apple Developer Program membership is active. If not, Apple supports [enrollment using its Developer app on iPhone or iPad](https://developer.apple.com/help/account/membership/enrolling-in-the-app). A free developer login and beta-OS access do not establish paid program membership.
3. Tell the project maintainer whether membership is active. Once active, the next setup will register an available bundle identifier, create the App Store Connect app record, and configure signing/upload credentials through private CI secrets. Do not paste passwords, private keys or signing certificates in chat.

TestFlight distribution uses Apple Developer Program membership. The alternative free Personal Team route requires Xcode and access to the physical device; it is not the current hosted-only installation path. Apple documents these options in [Choosing a Membership](https://developer.apple.com/support/compare-memberships/). No membership purchase or Apple account change has been made by this project.

The application remains iPhone-only. An iPad can manage this hosted workflow and account setup; it is not an additional supported recording target for V0.1. Release builds omit the debug simulation controls; their manual Save Incident control exercises the same incident pipeline during TestFlight acceptance.
