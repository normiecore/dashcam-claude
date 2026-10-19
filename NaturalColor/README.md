# Natural camera for iPhone

Current internal TestFlight build: **0.1.4 (20261019.613)**. Apple processing is VALID and existing internal group access is confirmed (IN_BETA_TESTING). External Beta App Review was submitted; approval was still pending at the recorded checkpoint. [Release and access confirmation](https://github.com/normiecore/dashcam-claude/actions/runs/39207824311) · [Verification evidence](verification/release/0.1.4-evidence.md).

The owner is collecting sample photographs over the next few days. Keep this round on 0.1.4 and retain DNG + finished HEIC pairs where supported. The [collection and calibration plan](verification/CALIBRATION-PLAN.md) inventories the existing diagnostics and defines the controlled same-RAW review. No telemetry or new app release is needed for collection. The [first Round 4 photo review](verification/release/round-4-reassessment.md) confirms the current metadata is usable and records the slight-darkness feedback and controlled next experiments.

A native SwiftUI, AVFoundation and Core Image camera. It opens directly to Simple mode: frame, tap to focus, choose a physical lens and shoot. Advanced mode adds live exposure readings, compensation and a composition grid.

**Round 4 rendering shipped in 0.1.4:** RAW photos keep Apple's highlight headroom and pass through a measured [scene tone stage](verification/research/SCENE-TONE.md) before the recovered HNCS colour and Standard film stages. Highlights that would clip fold into the film shoulder above +1 EV with a neutral path to white, and backlit scenes get a gentle global shadow fill. Display P3 HEIC keeps colours outside sRGB, and high-contrast HEIC on iOS 26+ carries an ISO HDR gain map. Quiet scenes render as before. A grey-card calibration and before/after comparisons on the owner's photographs are still outstanding.

[Round 3 reassessment](verification/release/round-3-reassessment.md) compares the supplied photo rounds with the original research and rollback history. The diagnostic work now included in 0.1.4 records the build/rendering path and tests decoded JPEG/HEIC colour conversion. The preferred rendering baseline remains the basis of the scene-tone stage.

The current app saves a finished photo to Photos by default, using HEIC at Medium compression. Camera controls offers JPEG, High/Small compression and optional RAW + processed saving on supported cameras. Native framing preserves the selected camera’s maximum supported photo dimensions; standard ratios crop without upscaling. Quality changes compression, not resolution. JPEG is the fallback if HEIC encoding is unavailable.

On ProRAW-capable cameras, both save settings capture and develop ProRAW so the finished image uses the same rendering path. “Save RAW original” controls whether Photos also receives the DNG. With it off, the pending DNG is removed after a successful Photos save; failed saves retain recovery files. Cameras without ProRAW use the processed HEIC/JPEG fallback. RAW processing time and temporary storage still apply.

Each capture owns its save operation. Pending capture and processed recovery files survive a failed Photos transaction; successful transactions remove these intermediate copies. Temporary review/import files are cleared on the next launch. Existing originals from earlier releases are retained. File orientation follows the held device; the interface remains portrait.

The earlier 0.1.3 rollback restored the colour/tone renderer and RAW development settings used in 0.1.1, at the user's request. This includes the preserved recovered research resources; the independent 0.1.2 luminance finish is excluded. HEIC uses tagged Display P3; JPEG and previews use sRGB. This restores rendering behaviour, not byte-identical encoded files. Redistribution rights have not been established by this change; App Store publication remains separate.

Working display name: Natural. The existing bundle identifier and Xcode target remain unchanged for installation/update compatibility. The final App Store name is awaiting selection; the existing App Store Connect name has not yet been changed.

## Earlier release history

**0.1.3 (20261017.1525) restores the preferred earlier renderer and is available to the existing internal TestFlight group.** Apple processing is VALID and internal state IN_BETA_TESTING. [Verification](https://github.com/normiecore/dashcam-claude/actions/runs/39044267142) and [signed upload/access confirmation](https://github.com/normiecore/dashcam-claude/actions/runs/39044915216) passed. External Beta App Review submitted; physical phone acceptance remains pending. The 0.1.2 evidence below is historical and does not verify the rollback.

Historical release: **0.1.2 (20261017.1315)** was available to the existing internal TestFlight group. Apple processing is VALID and the internal state is IN_BETA_TESTING. Update through the existing listing; the installed display name is Natural.

[Verification](https://github.com/normiecore/dashcam-claude/actions/runs/39035011122) passed 12 image/unit tests, five UI journeys and the production device archive/bundle audit. [Signed upload and Apple processing/group confirmation](https://github.com/normiecore/dashcam-claude/actions/runs/39035815264) passed. Verified application inputs: `9744adf493c837c32f8663ac14f5aef04511ff5f`; the release guard proves the uploaded app matches those inputs. The dedicated camera workflow now uses independent display labels.

Defaults are HEIC Medium, RAW off, Simple mode and native framing. Camera controls changes format/quality/RAW. On a physical iPhone, confirm a single finished HEIC appears in Photos at the supported native dimensions, portrait/both landscape orientations behave correctly, and enabling RAW creates the expected pair. Simulator checks do not establish camera or Photos acceptance.

The [name shortlist](app-store/names.md) and [store copy](app-store/listing.md) are drafts awaiting final selection and publishing details. Private store-direction previews and test photographs remain outside this repository.

The public invitation link exists and this build was successfully submitted for Apple Beta App Review. External installation awaits Apple’s approval. App Store publication requires a separate submission. The draft [store package](app-store/listing.md) includes listing copy, privacy/support text, screenshot direction and remaining release fields. Private assessment photographs and personal details are excluded.

## Build and verify

On a Mac: `cd ios && brew install xcodegen && xcodegen generate`, then open `HassyNatural.xcodeproj`. Hosted GitHub Actions runs simulator image/UI tests and a production device archive. `scripts/check_bundle.py` audits display name, permissions, privacy manifest, icon, Metal library and checksums of the restored rendering tables.

The existing GitHub signing secrets are used only in Actions. Upload only a verified application implementation. The dedicated natural-testflight trigger is separate from the Dashcam app. Apple processing and group access must be checked after upload. Physical camera and Photos acceptance requires a phone; a simulator does not establish it.
