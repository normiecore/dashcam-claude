# Release readiness

## Implemented in the 0.1.2 candidate

- Simple camera launch; native dimensions/aspect by default; standard optional crops.
- Processed photo auto-save; HEIC Medium by default; optional RAW + processed, JPEG and compression choices.
- Independent analytic finishing and Apple native RAW decode; research code/resources excluded from production.
- Independent display name, wordmark, About/permission copy and store/beta copy.
- Add-only Photos access, system pickers, privacy manifest and on-device processing.

## Executed verification

[Hosted Xcode verification](https://github.com/normiecore/dashcam-claude/actions/runs/39035011122) passed all 17 tests and the Release archive/bundle audit for `9744adf493c837c32f8663ac14f5aef04511ff5f`. [Signed upload](https://github.com/normiecore/dashcam-claude/actions/runs/39035815264) accepted 0.1.2 (20261017.1315); Apple processing VALID and existing internal group IN_BETA_TESTING. These checks do not establish physical-device acceptance.

## Phone acceptance still required

- Hosted Xcode unit/image and UI suite, real public 48 MP RAW export, Release archive and vendor-resource exclusion audit.
- Signed upload, Apple processing, internal tester group access.
- On a physical iPhone: new/upgrade defaults, single HEIC in Photos, native dimensions, portrait/both landscapes, optional RAW pair, repeated captures/lens switches, background/resume, denied Photos recovery, import and share. Simulator tests cannot establish these.
- Inspect the new output on the phone beside the original scene; no calibrated colour-target evidence currently supports a quantitative colour-accuracy claim.

## Before submitting to App Review

Choose and check the final name, then align display name, App Store Connect localised name, listing, screenshot headings and support pages. The old bundle identifier stays fixed for updates; it is a technical identifier, not product branding. The existing App Store Connect name must still be changed after final naming.

Publish privacy and support pages at working URLs with the publisher’s real contact. Complete the production publisher/review fields, copyright, territories/price and age-rating answers. The beta review/feedback contacts are already populated; confirm the production review record uses the intended details. App Privacy should reflect the shipped app’s lack of developer data collection; reassess if SDKs or services change.

Use real final-build screenshots and original cleared photography. Keep the earlier research archive/provenance outside the distributed app. An independent implementation removes the old tables from this build; no engineering check is a legal clearance of a final brand or visual design.

External TestFlight 0.1.2 was successfully submitted for Apple Beta App Review after confirming the required beta review/feedback fields were present. Public installation awaits Apple approval; an enabled invitation link alone does not make installations available. App Store publication is a separate submission; this task does not claim it has occurred.
