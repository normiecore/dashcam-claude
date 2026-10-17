# Natural camera for iPhone

A native SwiftUI, AVFoundation and Core Image camera. It opens directly to Simple mode: frame, tap to focus, choose a physical lens and shoot. Advanced mode adds live exposure readings, compensation and a composition grid.

The 0.1.2 candidate saves a finished photo to Photos by default, using HEIC at Medium compression. Camera controls offers JPEG, High/Small compression and optional RAW + processed saving on supported cameras. Native framing preserves the selected camera’s maximum supported photo dimensions; standard ratios crop without upscaling. Quality changes compression, not resolution. JPEG is the fallback if HEIC encoding is unavailable.

Each capture owns its save operation. Pending capture and processed recovery files survive a failed Photos transaction; successful transactions remove these intermediate copies. Temporary review/import files are cleared on the next launch. Existing originals from earlier releases are retained. File orientation follows the held device; the interface remains portrait.

The shipping renderer uses native Apple RAW development and an independently authored small analytic luminance adjustment in linear light. HEIC exports use tagged Display P3; compatible JPEG uses sRGB. This is a standard-dynamic-range export, with no HDR or calibrated colour-match claim. No recovered camera profiles/tables are part of the production target. Earlier research is retained separately for provenance and is not the shipping rendering specification.

Working display name: Natural. The existing bundle identifier and Xcode target remain unchanged for installation/update compatibility. The final App Store name is awaiting selection; the existing App Store Connect name has not yet been changed.

## Status

0.1.1 (20261016.2356) is the last confirmed internal TestFlight build. The 0.1.2 candidate is undergoing hosted Xcode verification; see HANDOVER/CHANGELOG for the final accepted source and upload result. Do not mistake source changes for a shipped update.

The public invitation link exists, but external installation awaits complete review/feedback contacts and Apple Beta App Review. App Store publication requires a separate submission. The draft [store package](app-store/listing.md) includes listing copy, privacy/support text, screenshot direction and remaining release fields. Private assessment photographs and personal details are excluded.

## Build and verify

On a Mac: `cd ios && brew install xcodegen && xcodegen generate`, then open `HassyNatural.xcodeproj`. Hosted GitHub Actions runs simulator image/UI tests and a production device archive. `scripts/check_bundle.py` audits display name, permissions, privacy manifest, icon, Metal library and exclusion of archived research assets.

The existing GitHub signing secrets are used only in Actions. Upload only a verified application implementation. The dedicated natural-testflight trigger is separate from the Dashcam app. Apple processing and group access must be checked after upload. Physical camera and Photos acceptance requires a phone; a simulator does not establish it.
