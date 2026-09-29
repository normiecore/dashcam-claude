# Dashcam — 0.1.0-dev.1

Native iPhone dashcam implementation candidate: SwiftUI, AVFoundation and durable segmented storage. **Hosted Xcode Debug/Release simulator builds and all 16 XCTest cases pass.** Physical iPhone acceptance has not been completed. The portable C retention engine also passes Linux checks. Do not treat this build as qualified evidence capture until the device acceptance gate passes.

## Implemented source

- Rear-camera preview during recording, start/stop and microphone opt-in.
- 720p H.264 at a target 30 fps / 4 Mbps, ten-second independently finalized MOV files, one-second fragments.
- Approximately five minutes of ordinary rolling footage; incident preservation includes the preceding window and a 30-second tail, rounded to whole segments.
- Durable incident registration before success is reported, protected future segments, overlapping incidents, serial cleanup, and a storage reserve.
- Saved-incident playback, combined export/share, confirmed removal of incident protection.
- Foreground/background, thermal and capture-interruption handling; incomplete tails are identified. Uncertain files remain for recovery.
- Debug incident/interruption injection, structured system logs, portable policy tests, storage XCTest, synthetic video XCTest, and Mac/CI verification scripts.

Recording requires the app to remain open and the iPhone unlocked. Automatic Apple Crash Detection is **not enabled**. Footage stays on this device and is excluded from backup; export important incidents. Deleting the app removes its private files.

## Hosted verification

The private [GitHub repository](https://github.com/normiecore/dashcam-claude) has a [draft pull request](https://github.com/normiecore/dashcam-claude/pull/2) for the hosted macOS gate. The [passing Actions run](https://github.com/normiecore/dashcam-claude/actions/runs/36592919853) tested code commit `f3d7b8e68c50ba909a8c8337431ec5f1ea3ba018` with Xcode 26.6. Pull requests and manual workflow dispatch run the Linux policy checks and macOS simulator builds/tests. See [Hosted Mac verification](Docs/HostedMac.md) for evidence and limitations.

GitHub Actions provides an ephemeral build/test runner, not an interactive Mac desktop. The simulator build disables code signing and needs no Apple account credentials. Installing on a physical iPhone later requires an Apple development team and signing setup (or a TestFlight distribution setup); never paste signing credentials into chat.

## Optional local Mac build and device test

1. Extract the project, install the latest stable Xcode compatible with the iPhone's iOS, and launch Xcode once to finish installing its components. Install an iOS Simulator runtime when prompted.
2. In Terminal, enter the extracted `Dashcam` folder. Run:

   ```sh
   bash Tools/test-core.sh
   bash Tools/verify-mac.sh
   ```

   The second command compiles Debug and Release, runs simulator XCTest and writes logs/results under `build/verification`. A failure stops the script.
3. Open `Dashcam.xcodeproj`. Select the Dashcam target → Signing & Capabilities, choose your Apple development team, and change `com.daz.dashcam.dev` to an available bundle identifier if needed. No SafetyKit entitlement is needed for this build.
4. Connect an iPhone, trust the Mac, enable Developer Mode on the iPhone if requested, and select it as Xcode's run destination. Build and run.
5. In the app, start recording, grant camera access, and point the rear camera at a clock while stationary. Record six minutes, tap **Save Incident**, wait 40 seconds, stop, then play and export the incident. Inspect segment boundaries and verify the expected five-minute pre-event and 30-second post-event coverage.
6. Follow [DeviceAcceptance.md](Docs/DeviceAcceptance.md) before any mounted-road qualification. Return the compiler/test log or `.xcresult` if a build/test fails; do not delete the app to troubleshoot footage recovery.

The project has a shared scheme and no third-party packages. The optional `swift test` package runs the storage tests on a Mac without the iOS camera target; it is not a substitute for the full verification script.

## Development and version control

Source is in the private [normiecore/dashcam-claude repository](https://github.com/normiecore/dashcam-claude). Review the hosted Mac work in the [draft pull request](https://github.com/normiecore/dashcam-claude/pull/2) before merging.

Use `main` for reviewable milestones, small feature branches for later work, and semantic versions. The current pre-release is `0.1.0-dev.1`; retain version `0.1.0` / build `1` in the Xcode bundle until a new build is needed. Reserve a `v0.1.0` release tag for a successful physical acceptance run. Commits use a neutral project-local identity; set your own Git author for future commits.

The included workflow provides Linux policy and macOS iOS verification gates for pull requests and manual dispatch. Check the workflow result and uploaded evidence; a passing simulator gate does not replace physical-device acceptance.

## Read next

- [Architecture and plan](Docs/Architecture.md)
- [Apple API corrections and sources](Docs/AppleReview.md)
- [Verification results and remaining gates](Docs/Verification.md)
- [Hosted Mac verification](Docs/HostedMac.md)
- [Physical-device test instructions](Docs/DeviceAcceptance.md)
- [Changelog](CHANGELOG.md)

Important limits: no SafetyKit or Core Motion detector, no GPS, no background/locked camera capture, no cloud upload, no guaranteed recovery of the current unfinished fragment. Export concatenates retained segments; keep originals and the manifest if timing gaps matter. Damaged overlapping media blocks normal export and is retained for manual recovery.
