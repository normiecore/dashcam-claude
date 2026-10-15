# Hassy Natural native iPhone app

Native SwiftUI/AVFoundation/Core Image application developed alongside the HNCS investigation. Separate app identity: `com.normiecore.hassynatural`; this is not a Dashcam update.

The app imports original JPEG/HEIC/RAW files, captures full-resolution JPEG or ProRAW when the physical camera supports it, compares edits, and exports full-resolution sRGB JPEG copies. Photos are processed on the phone. The camera release is portrait-only.

The app renderer combines recovered chroma arithmetic, an explicit native fallback profile and the recovered Standard film curve, with a documented linear-sRGB phone adapter. A custom Metal Core Image kernel evaluates the 2D chroma and 1D film tables directly, avoiding RGB cube resampling. These are independently verified stages, not proof of an end-to-end Phocus or iPhone color match. The earlier web app’s independent treatment is not the selected native renderer. Resource manifests preserve hashes and provenance. Details and executed comparisons live in the research workspace.

## Build

On a Mac: `cd ios && brew install xcodegen && xcodegen generate`, then open `HassyNatural.xcodeproj`. The GitHub Actions Hassy Natural workflow performs simulator tests and an unsigned production device archive on hosted macOS; no local Mac is required.

For TestFlight, the repository already uses `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, and `APPLE_TEAM_ID`. The dedicated workflow checks their presence without printing values. Create a separate App Store Connect app record for `com.normiecore.hassynatural`; existing Dashcam identity must never be reused. After verification, run the dedicated workflow with upload enabled or add `natural-testflight` to its pull request. The ordinary `testflight` label belongs to Dashcam.

Simulator evidence is not physical camera acceptance. Signing/upload and Apple processing must be reported separately from compilation and image-processing checks.
