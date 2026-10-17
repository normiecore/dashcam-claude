# Hassy Natural native iPhone app

Native SwiftUI/AVFoundation/Core Image application developed alongside the HNCS investigation. Separate app identity: `com.normiecore.hassynatural`; this is not a Dashcam update.

The app opens directly to the camera in Simple mode, using a black/amber interface influenced by Hasselblad cameras and Phocus. Frame, tap to focus, select a physical lens and shoot. Camera controls offers Advanced mode for live ISO/shutter/aperture, exposure compensation, RAW/JPEG and a composition grid. The mode and save/framing preferences are remembered.

Native framing uses the camera’s maximum supported photo dimensions without cropping or upscaling. Optional 4:3, 3:2, 16:9 and 1:1 ratios centrally crop only the processed result, respecting portrait orientation. Original + processed is the default automatic Camera Roll save: an untouched ProRAW original where supported (otherwise JPEG), plus the processed full-resolution/cropped sRGB JPEG as separate assets. Either copy alone can be selected in Camera controls. Photos permission is requested on first save. Originals also remain in Files → On My iPhone → Hassy Natural → Originals; a failed Photos save retains any developed copy in Processed and reports the failure. Captures keep the camera open; the thumbnail opens review and Camera resumes shooting. Imports support original JPEG/HEIC/RAW files. Processing stays on the phone; this release captures in portrait orientation.

The app renderer combines recovered chroma arithmetic, an explicit native fallback profile and the recovered Standard film curve, with a documented linear-sRGB phone adapter. A custom Metal Core Image kernel evaluates the 2D chroma and 1D film tables directly, avoiding RGB cube resampling. These are independently verified stages, not proof of an end-to-end Phocus or iPhone color match. The earlier web app’s independent treatment is not the selected native renderer. Resource manifests preserve hashes and provenance. Details and executed comparisons live in the research workspace.

## Install the internal beta

Open TestFlight using the already enrolled Apple account, select **Hassy Natural**, and update to **0.1.1 (20261016.2356)**. Apple processing is VALID, the existing internal group has access, and its state is IN_BETA_TESTING.

The app opens in Simple camera mode. Native resolution/framing and automatic **original + processed** saving to Photos are the defaults. Allow Photos access on your first capture. On supported cameras the original is ProRAW; otherwise it is JPEG. Tap the sliders button for Advanced mode or to save either copy alone. Tap Native for standard crop ratios; only the processed result is cropped. Tap the thumbnail for review and Camera to return to shooting.

Verified application source: `5365cfa6f202c023132ab4fd6cb95d4859d3564f`. [Verification](https://github.com/normiecore/dashcam-claude/actions/runs/38983140789) passed nine image/unit tests, five UI journeys, and the production Release archive/bundle checks. This includes actual 48 MP ProRAW export and crop dimensions. [Signed upload and Apple processing/group-access confirmation](https://github.com/normiecore/dashcam-claude/actions/runs/38983940384) passed. Simulator UI fixtures cannot capture; physical acceptance still requires a phone capture and confirmation of both Photos assets. Originals also remain in Files → On My iPhone → Hassy Natural → Originals.

The external-eligible build is assigned to BetaX, but public installation is still pending actual review-contact/feedback metadata and Apple Beta App Review. An enabled invitation link alone does not establish public availability.

## Build

On a Mac: `cd ios && brew install xcodegen && xcodegen generate`, then open `HassyNatural.xcodeproj`. The GitHub Actions Hassy Natural workflow performs simulator tests and an unsigned production device archive on hosted macOS; no local Mac is required.

For TestFlight, the repository already uses `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, and `APPLE_TEAM_ID`. The dedicated workflow checks their presence without printing values. The separate App Store Connect record exists for `com.normiecore.hassynatural` (app ID `6823073017`). Internal tester enrollment uses only the explicitly requested existing team account; no email address or Apple credential is stored in source. After verification, run the dedicated workflow with upload enabled or add `natural-testflight` to its pull request. The ordinary `testflight` label belongs to Dashcam.

Simulator evidence is not physical camera acceptance. Signing/upload and Apple processing must be reported separately from compilation and image-processing checks.
