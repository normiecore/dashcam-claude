# Release readiness

## Implemented in the 0.1.2 candidate

- Simple camera launch; native dimensions/aspect by default; standard optional crops.
- Processed photo auto-save; HEIC Medium by default; optional RAW + processed, JPEG and compression choices.
- Independent analytic finishing and Apple native RAW decode; research code/resources excluded from production.
- Independent display name, wordmark, About/permission copy and store/beta copy.
- Add-only Photos access, system pickers, privacy manifest and on-device processing.

## Verify for the candidate

- Hosted Xcode unit/image and UI suite, real public 48 MP RAW export, Release archive and vendor-resource exclusion audit.
- Signed upload, Apple processing, internal tester group access.
- On a physical iPhone: new/upgrade defaults, single HEIC in Photos, native dimensions, portrait/both landscapes, optional RAW pair, repeated captures/lens switches, background/resume, denied Photos recovery, import and share. Simulator tests cannot establish these.
- Inspect the new output on the phone beside the original scene; no calibrated colour-target evidence currently supports a quantitative colour-accuracy claim.

## Before submitting to App Review

Choose and check the final name, then align display name, App Store Connect localised name, listing, screenshot headings and support pages. The old bundle identifier stays fixed for updates; it is a technical identifier, not product branding. The existing App Store Connect name must still be changed after final naming.

Publish privacy and support pages at working URLs with the publisher’s real contact. Supply copyright, review contacts, feedback contact, territories/price and accurate age-rating answers. App Privacy should reflect the shipped app’s lack of developer data collection; reassess if SDKs or services change.

Use real final-build screenshots and original cleared photography. Keep the earlier research archive/provenance outside the distributed app. An independent implementation removes the old tables from this build; no engineering check is a legal clearance of a final brand or visual design.

External TestFlight still requires complete review/feedback contacts and Apple Beta App Review. An enabled public invitation link alone does not make installations available. App Store publication is a separate submission; this task does not claim it has occurred.
