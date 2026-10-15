# Hassy Natural native iPhone app

Native SwiftUI/AVFoundation/Core Image application developed alongside the HNCS investigation. Separate app identity: `com.normiecore.hassynatural`; this is not a Dashcam update.

The app imports original JPEG/HEIC/RAW files, captures full-resolution JPEG or ProRAW when the physical camera supports it, compares edits, and exports full-resolution sRGB JPEG copies. Photos are processed on the phone. Camera originals are retained in Files → On My iPhone → Hassy Natural → Originals. The camera release is portrait-only.

The app renderer combines recovered chroma arithmetic, an explicit native fallback profile and the recovered Standard film curve, with a documented linear-sRGB phone adapter. A custom Metal Core Image kernel evaluates the 2D chroma and 1D film tables directly, avoiding RGB cube resampling. These are independently verified stages, not proof of an end-to-end Phocus or iPhone color match. The earlier web app’s independent treatment is not the selected native renderer. Resource manifests preserve hashes and provenance. Details and executed comparisons live in the research workspace.

## Install the internal beta

Open TestFlight using the explicitly enrolled Apple account, select **Hassy Natural**, and install **0.1.0 (20261015.842)**. Apple processing is complete and the build is in internal beta testing. Start with ProRAW when the camera supports it. Hold the photo to compare, then Save to Photos or Share the edited JPEG. Captured originals are available in Files → On My iPhone → Hassy Natural → Originals.

Release application source: `a29eab0c81a3649fd79c114ee3841e953719b241`. [Upload verification](https://github.com/normiecore/dashcam-claude/actions/runs/38705206450) and [Apple processing/group-access confirmation](https://github.com/normiecore/dashcam-claude/actions/runs/38705678511) passed. Later tests/status/documentation do not modify that application implementation. [Additional 48 MP ProRAW export verification](https://github.com/normiecore/dashcam-claude/actions/runs/38708246055) also passes. Accept the invitation email to make the app appear in TestFlight. Physical camera acceptance remains a user check.

## Build

On a Mac: `cd ios && brew install xcodegen && xcodegen generate`, then open `HassyNatural.xcodeproj`. The GitHub Actions Hassy Natural workflow performs simulator tests and an unsigned production device archive on hosted macOS; no local Mac is required.

For TestFlight, the repository already uses `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, and `APPLE_TEAM_ID`. The dedicated workflow checks their presence without printing values. The separate App Store Connect record exists for `com.normiecore.hassynatural` (app ID `6823073017`). Internal tester enrollment uses only the explicitly requested existing team account; no email address or Apple credential is stored in source. After verification, run the dedicated workflow with upload enabled or add `natural-testflight` to its pull request. The ordinary `testflight` label belongs to Dashcam.

Simulator evidence is not physical camera acceptance. Signing/upload and Apple processing must be reported separately from compilation and image-processing checks.
