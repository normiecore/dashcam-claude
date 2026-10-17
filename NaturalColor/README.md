# Natural camera for iPhone

A native SwiftUI, AVFoundation and Core Image camera. It opens directly to Simple mode: frame, tap to focus, choose a physical lens and shoot. Advanced mode adds live exposure readings, compensation and a composition grid.

The 0.1.3 candidate saves a finished photo to Photos by default, using HEIC at Medium compression. Camera controls offers JPEG, High/Small compression and optional RAW + processed saving on supported cameras. Native framing preserves the selected camera’s maximum supported photo dimensions; standard ratios crop without upscaling. Quality changes compression, not resolution. JPEG is the fallback if HEIC encoding is unavailable.

Each capture owns its save operation. Pending capture and processed recovery files survive a failed Photos transaction; successful transactions remove these intermediate copies. Temporary review/import files are cleared on the next launch. Existing originals from earlier releases are retained. File orientation follows the held device; the interface remains portrait.

The 0.1.3 rollback candidate restores the colour/tone renderer and RAW development settings used in 0.1.1, at the user's request. This includes the preserved recovered research resources; the independent 0.1.2 luminance finish is excluded. HEIC uses tagged Display P3; JPEG and previews use sRGB. This restores rendering behaviour, not byte-identical encoded files. Redistribution rights have not been established by this change; App Store publication remains separate.

Working display name: Natural. The existing bundle identifier and Xcode target remain unchanged for installation/update compatibility. The final App Store name is awaiting selection; the existing App Store Connect name has not yet been changed.

## Status

0.1.3 restores the preferred earlier renderer. Verification/upload are pending; the 0.1.2 evidence below is historical and does not verify the rollback.

**0.1.2 (20261017.1315) is available to the existing internal TestFlight group.** Apple processing is VALID and the internal state is IN_BETA_TESTING. Update through the existing listing; the installed display name is Natural.

[Verification](https://github.com/normiecore/dashcam-claude/actions/runs/39035011122) passed 12 image/unit tests, five UI journeys and the production device archive/bundle audit. [Signed upload and Apple processing/group confirmation](https://github.com/normiecore/dashcam-claude/actions/runs/39035815264) passed. Verified application inputs: `9744adf493c837c32f8663ac14f5aef04511ff5f`; the release guard proves the uploaded app matches those inputs. The dedicated camera workflow now uses independent display labels.

Defaults are HEIC Medium, RAW off, Simple mode and native framing. Camera controls changes format/quality/RAW. On a physical iPhone, confirm a single finished HEIC appears in Photos at the supported native dimensions, portrait/both landscape orientations behave correctly, and enabling RAW creates the expected pair. Simulator checks do not establish camera or Photos acceptance.

The [name shortlist](app-store/names.md) and [store copy](app-store/listing.md) are drafts awaiting final selection and publishing details. Private store-direction previews and test photographs remain outside this repository.

The public invitation link exists and this build was successfully submitted for Apple Beta App Review. External installation awaits Apple’s approval. App Store publication requires a separate submission. The draft [store package](app-store/listing.md) includes listing copy, privacy/support text, screenshot direction and remaining release fields. Private assessment photographs and personal details are excluded.

## Build and verify

On a Mac: `cd ios && brew install xcodegen && xcodegen generate`, then open `HassyNatural.xcodeproj`. Hosted GitHub Actions runs simulator image/UI tests and a production device archive. `scripts/check_bundle.py` audits display name, permissions, privacy manifest, icon, Metal library and checksums of the restored rendering tables.

The existing GitHub signing secrets are used only in Actions. Upload only a verified application implementation. The dedicated natural-testflight trigger is separate from the Dashcam app. Apple processing and group access must be checked after upload. Physical camera and Photos acceptance requires a phone; a simulator does not establish it.
