## RAW-saving rendering fix — TestFlight upload authorised, 18 October 2026

The owner requested pushing the verified fix through to TestFlight. Release workflow now pins app-tree equality to verified source 0d405590144995297c5d4ab1faa9bb2beebccc66 (successful Xcode run 39103434989); the app implementation and marketing version 0.1.3 are unchanged from that source. Upload will generate a new build number and use the existing internal/external groups. Beta notes describe RAW-toggle parity and retention checks. Upload/Apple processing are pending; do not duplicate an accepted upload. No merge or production App Store submission is requested.

## Consistent rendering with RAW saving off — 18 October 2026

The owner reported harsher HEIC rendering with Save RAW original off and identified draft PR #11 / branch codex/natural-color-ios-20261015. Confirmed cause: CameraPreview passed save mode into CameraService.capture, switching between ProRAW and Apple-processed HEIC/JPEG. PhotoEngine disables RAW tone boosts/local tone mapping/gamut mapping before the recovered renderer, whereas processed inputs already contain Apple rendering.

Candidate removes the RAW-request parameter: capture selects available Apple ProRAW independently of save mode, retaining the codec fallback for unsupported cameras. Existing per-shot save selection and cleanup keep only the finished Photos asset in processed-only mode and delete pending originals after success; failures retain recovery files. RAW capture/development costs and temporary review files remain. Renderer, assets, format/compression defaults, Dashcam app code and main are unchanged. The public 48 MP regression now exercises exportCapture and asserts processed-only versus paired Photos resource selection.

Verification: local diff checks passed. Hosted Xcode image/unit and UI tests, production iPhone Release archive and restored-resource checksum audit passed in https://github.com/normiecore/dashcam-claude/actions/runs/39103434989, testing source 0d405590144995297c5d4ab1faa9bb2beebccc66. Simulator verification is not device acceptance. Physical iPhone RAW-toggle comparisons, single-asset versus pair, failed-save recovery, repeated captures and lens switches remain necessary. No new TestFlight upload or merge performed.

## Accepted rendering rollback — 17 October 2026

**0.1.3 (20261017.1525) is uploaded, Apple VALID, existing internal group access True and IN_BETA_TESTING.** Release run https://github.com/normiecore/dashcam-claude/actions/runs/39044915216; release helper commit 6820f4d56f95de0cb109c7227bd07d7cdbe98d18. The upload guard proves app sources/project are identical to verified source 2e9bbe8d2a3c3223784b5216fe17aa18c086a791. Production archive and resource checksum audit passed again during signing. Do not duplicate this upload.

The user explicitly requested restoring the renderer used for the samples, superseding the independent replacement. Original 0.1.1 RAW development/kernel/tables/preview are restored; newer HEIC Medium / RAW-off defaults, optional RAW saving and camera/storage fixes remain. Working display name stays Natural. Phone acceptance requires updating through the existing TestFlight app and taking fresh photographs. No physical phone capture or private 0.1.3 rendering comparison was performed here.

External Beta App Review was submitted successfully and the build is assigned to the existing public group. Public availability still depends on Apple's approval; no production App Store submission was made. Prior 0.1.2 render previews describe the superseded look. See NaturalColor/verification/release/0.1.3-rollback.md. Historical entries below remain for provenance.

## Rendering rollback requested — 17 October 2026

The user rejected the near-neutral 0.1.2 replacement and explicitly requested the rendering used for their supplied samples. Candidate 0.1.3 restores the exact 0.1.1 RAW decoder settings, recovered Metal operator, profile/chroma/film tables and sRGB preview, based on verified source 5365cfa6f202c023132ab4fd6cb95d4859d3564f. Existing kernel/core/assets are byte-identical to that source. The current HEIC Medium / RAW-off defaults, optional RAW pair, capture orientation, save cleanup and camera UI fixes remain. HEIC uses tagged Display P3 and JPEG uses sRGB; file encoding differs from 0.1.1's high-quality JPEG, so encoded files are not claimed byte-identical.

Re-enable the original three renderer regression tests; exclude the superseded analytic kernel/tests. The production archive audit now requires and hashes the restored tables rather than forbidding them. This supersedes the independent-pipeline shipping direction below. It does not establish redistribution rights or App Store readiness. No new marketing claims or App Store submission are authorised by the rollback.

Hosted verification passed: 13 image/unit tests, five UI journeys and production iPhone archive/bundle checksum checks in https://github.com/normiecore/dashcam-claude/actions/runs/39044267142. Candidate app source is 2e9bbe8d2a3c3223784b5216fe17aa18c086a791. Signed external-eligible TestFlight upload is next, with app-tree equality pinned to this verified source. The currently installed 0.1.2 is unchanged until a new accepted build is installed. Never overwrite the historical 0.1.2 evidence as if it tested this candidate.

## Verified imagery and revised naming — 17 October 2026

User requested stronger aesthetic selections, actual rendered outputs and name explanations/a different naming direction. Completed native render run https://github.com/normiecore/dashcam-claude/actions/runs/39037816177: four original private RAWs → actual 0.1.2 Medium HEIC exports, all 6048×8064, 2.58–7.07 MB. App inputs were guarded against accepted source 9744adf493c837c32f8663ac14f5aef04511ff5f. Presentation JPEGs were decoded from the final HEICs without extra grading/cropping. Original-source/output checksums and dimensions verified locally. This is simulator RAW rendering, not phone capture.

New private selection: palm fronds, circular sculpture, red pennants, tower framed by branches. Board/standalone gallery/native export ZIP/proof are under /workspace/private-photo-assessment/current-output; the board is rendered-selection.png and the download is native-heic-outputs.zip. These replace the older-build art study for current previews. No photographs, source identifiers or authenticated URLs are committed. CI transfers are encrypted; the stale encrypted input is removed from the active branch after the run. First attempt’s native test passed, but output lookup used a shut-down simulator; corrected collector succeeded using the test-reported directory.

Naming brief now explains Heldlight/Daymere/Stillfold/Lumenry/Mereframe and offers the distinct looking/recording direction Particular (preferred suggestion), Regarding, An Aside, Register, Ordinary. Public AU/US searches found no exact names for the new shortlist, with similar uses noted; these are not cleared/reserved names. Final name remains unselected and the app working name remains Natural. See app-store/names.md. Shipping beta remains the accepted 0.1.2 (20261017.1315); this imagery task does not upload another build or submit store artwork.

## Accepted 0.1.2 — 17 October 2026

**0.1.2 (20261017.1315) uploaded, Apple VALID, existing internal group access confirmed, IN_BETA_TESTING.** Release workflow https://github.com/normiecore/dashcam-claude/actions/runs/39035815264; release-helper commit f1cfaaa3f98de899d8ba6df7a01cbf349e120910. Verified application source `9744adf493c837c32f8663ac14f5aef04511ff5f` and run https://github.com/normiecore/dashcam-claude/actions/runs/39035011122: 12 image/unit + 5 UI tests, production Release archive, independent-resource bundle audit. Upload workflow pins and compares app inputs to that verified source. Do not repeat this upload.

The production renderer is now independently authored; the user explicitly approved this direction. Shipping code uses native Apple RAW development plus a small analytic finish, with Display P3 HEIC / sRGB JPEG. No recovered tables/profile/core/kernel are built or bundled. Research/provenance remains archived in source. New independent-invariant tests replace old renderer goldens in the production scheme; archived tests continue to describe the previous renderer only.

Processed-only HEIC Medium is default, including upgrade from 0.1.1 via the V2 preference. RAW is not requested unless enabled; unsupported lenses use processed-only. Format/quality controls and optional RAW pair remain accessible without Advanced mode. Native resolution is preserved, quality changes compression, standard crops do not upsample. Files follow held-device orientation. Successful Photos saves remove durable intermediates after review loads; failed saves retain Pending Captures/Processed. Existing historical Originals are preserved. Settings/grid/EV targets are actually 44pt; the fixed settings-reopen regression passed.

55 private originals were assessed, including successful full-sensor decoding of the late 94.9 MB RAW. Aggregate findings are in NaturalColor/verification/release/0.1.2-assessment.md. Private images, metadata and the standalone store-direction preview remain outside the repository in /workspace/private-photo-assessment. Do not publish them as store assets without final selection. Local QA screenshots from the accepted run are in verification/release/screenshots-0.1.2; the public CI artifact contains the same fixtures. These are simulator INTERFACE PREVIEW screenshots, not photographed camera output.

Working name Natural. Screened suggestions: Heldlight (recommended), Daymere, Stillfold, Lumenry, Mereframe; no exact AU/US public-search listings, not reservation or trademark clearance. Final App Store Connect name still awaits selection. Existing bundle identifier is retained for updates. Store listing/privacy/support/screenshot drafts and a release checklist are under NaturalColor/app-store. Remaining publication steps: final name and aligned title/assets, live support/privacy pages, production review/publisher fields, phone acceptance and final screenshots. Beta review/feedback contacts are already populated. No production App Store submission has been made. The release workflow confirmed beta review/feedback fields were present and successfully submitted this build for Apple Beta App Review. Public installation remains pending Apple approval; an enabled link alone does not establish public availability.

Earlier entries below are historical and include previous defaults/renderers. The accepted 0.1.2 status above supersedes them.

0.1.2 first verification run 39034089846: all 12 image/unit tests and 4/5 UI journeys passed. The Simple→Advanced→settings reopen journey exposed an icon-only hit target (21×16pt despite an outer frame). Settings/grid/exposure now place the 44pt target inside the button label with an explicit content shape. UI regression asserts the actual settings target size and awaits the sheet. Reverification and production archive pending; no new build uploaded yet.

## 0.1.2 in progress — 17 October 2026

User approved an independent rendering pipeline, replacing the recovered research implementation in the shipping target. The research sources and provenance remain archived in the repository; Xcode excludes them and the production bundle audit rejects recovered assets. New tests cover the analytic finish; archived goldens describe the previous renderer only.

New default: processed photo only, HEIC Medium (ImageIO quality 0.78), source pixels preserved. JPEG, High/Small compression and optional RAW + processed are available in Camera controls. V2 save preference deliberately establishes RAW-off on upgrade. RAW is not requested unless enabled. Pending captures survive failed Photos transactions; successfully saved intermediate copies are removed. Apple native RAW development replaces forced tone-map/gamut overrides. Capture files follow held-device orientation while camera UI stays portrait.

Test shots remain private, outside the repository. Full native image/export and UI verification is pending hosted Xcode CI; do not describe this candidate as shipped yet. Working display name Natural; final brand is not selected. Existing bundle ID is retained for update compatibility.

# Dashcam project — read first

## Hassy Natural Simple camera UI — 2026-10-17, Australia/Perth

Version 0.1.1 now opens straight to a black/amber Hasselblad/Phocus-influenced camera in Simple mode. Advanced mode is opt-in and persists, revealing live meter readings, EV, grid and RAW/JPEG controls. Native framing is the default and uses maximum supported dimensions; 4:3, 3:2, 16:9 and square crop only the processed copy at source-pixel resolution. Both original (ProRAW where supported, otherwise JPEG) and processed JPEG save automatically as separate Photos assets by default, with original-only/processed-only preferences. Per-shot save tasks cannot be cancelled by reviewing/importing a later image. Originals remain in Files/Originals; developed recovery copies remain in Files/Processed until Photos confirms saving. Denied Photos access reports an actionable error rather than success. Own-settings UserDefaults purpose is declared in the privacy manifest.

Verified application source: `5365cfa6f202c023132ab4fd6cb95d4859d3564f` (production application identical to `58dffd11bccb2ff541cf44b32c1c1e6a35ff1f19`). [Run 38983140789](https://github.com/normiecore/dashcam-claude/actions/runs/38983140789) passes all nine image/unit tests, all five UI journeys, and the Release iPhone archive/bundle checks. Native 48 MP RAW export, source-pixel crop sizes, save-resource selection and numerical goldens are covered. Simulator screenshots were inspected. The earlier two UI issues were fixed with a 44-point compare touch target/readiness wait and exposure direction/bounds plus exact readout-propagation checks. Hosted iOS 26 automation intermittently exceeded its original 120-second limit despite passing assertions; UI cases now have 240 seconds (workflow maximum 300). Image/unit default limits and all image/functional assertions remain unchanged.

Apple accepted **Hassy Natural 0.1.1 (20261016.2356)** at 23:58 UTC on 16 October / 07:58 Perth on 17 October in [release run 38983940384](https://github.com/normiecore/dashcam-claude/actions/runs/38983940384), release commit `34bf783832892baea641d87dff73fb0d16febb3a`. The app-tree equality check pins the verified source above. At 00:00 UTC / 08:00 Perth on 17 October, processing is VALID, existing internal group access is True, and internal state is IN_BETA_TESTING. The owner can update in TestFlight; no new invitation or duplicate upload is needed. Later documentation changes do not modify the verified binary.

The new APP_STORE_ELIGIBLE build is also assigned to BetaX with automatic notification enabled. Public review is NOT submitted: actual contactFirstName/contactLastName/contactPhone/contactEmail/feedbackEmail are still missing, so external state is READY_FOR_BETA_SUBMISSION. The distribution helper reports pending metadata cleanly while confirming internal access; its success does not imply public installation availability. Use the encrypted metadata workflow described below when the owner provides real contact details. Do not duplicate this accepted UI upload to resolve metadata. Phone acceptance still needs real capture/lens/focus/background checks and confirmation that Photos contains both the untouched original and processed copy. This capture release is portrait-only.

## Hassy Natural remaining review-contact entry — 2026-10-15, Australia/Perth

The owner asked to finish the external beta. Fresh distribution retry of run 38747500724 at 14:26 UTC still returns HTTP 422 MISSING_REQUIRED_DATA, with contactFirstName/contactLastName/contactPhone/contactEmail/feedbackEmail empty. The accepted external build remains 20261015.1353, VALID and assigned to BetaX; do not upload again. A concise async question asks for the actual contact name, country-code phone, review email and tester-feedback email (visible to testers). No answer has been supplied yet; do not invent these values.

Prepared `.github/workflows/natural-review-contact.yml` and `.github/scripts/natural_review_contact.py`. Successful setup run 38751858452 exposed only the public encryption recipient; no private key or contact was exported and no live metadata changed. Recipient public key is locally saved at `/workspace/review-contact-recipient-public.b64`. `/tmp/encrypt_natural_contact.py` encrypts a five-field contact JSON using ephemeral P-256 ECDH, HKDF-SHA256 and AES-GCM, authenticated to the Hassy Natural context and recipient fingerprint. The runner alone decrypts with its CI-bound private key. A throwaway-key/dummy-data round-trip verified recipient compatibility and API payload mapping without live Apple calls. No plaintext contact details may be committed or logged.

When the user supplies the missing information, privately write a chmod-600 temporary JSON with those five exact field names; encrypt it using the saved recipient into `.github/review-contact.enc.json`, remove the plaintext, then commit only the encrypted envelope. This triggers the contact workflow to fill Apple review/contact and feedback metadata and submit the EXISTING external build. Review contact API errors are redacted. Confirm actual Apple review state, and report public availability separately from successful submission. Remove the encrypted envelope after use so future runs do not replay it. The public link is https://testflight.apple.com/join/Ws45PaMV; it currently does not accept public testers. Main/application implementation remains unchanged.

## Hassy Natural public beta — 2026-10-15, Australia/Perth

The owner requested an external/public TestFlight build and created external group BetaX, ID `76b8c463-84c1-4657-952f-a2888903563e`. Public link enabled: https://testflight.apple.com/join/Ws45PaMV. At inspection, the public page says the beta is not accepting testers because no external build is available. The existing accepted 0.1.0 build 20261015.842 is INTERNAL_ONLY and cannot serve this group.

Dedicated `.github/workflows/natural-external.yml` reuses the verified application implementation (git diff against `a29eab0c81a3649fd79c114ee3841e953719b241` must be empty for app sources/project). Uploads are explicitly triggered only by an `[external-upload]` commit, with `NATURAL_EXTERNAL_TESTING=1`; export sets testFlightInternalTestingOnly=false. Normal metadata/distribution retries do not upload duplicate builds. Existing internal upload behavior remains the default. External build **0.1.0 (20261015.1353)** was accepted at 13:56 UTC / 21:56 Perth in [upload run 38746523725](https://github.com/normiecore/dashcam-claude/actions/runs/38746523725). Apple processing is VALID and buildAudienceType is APP_STORE_ELIGIBLE. [Distribution-only retry 38747500724](https://github.com/normiecore/dashcam-claude/actions/runs/38747500724) enabled autoNotifyEnabled and successfully assigned the build to BetaX. Apple rejected POST betaAppReviewSubmissions with HTTP 422, ENTITY_UNPROCESSABLE.MISSING_REQUIRED_DATA (Apple detail: Missing requied data.). Review contactFirstName/contactLastName/contactPhone/contactEmail and beta feedbackEmail remain blank. Description and What to Test have been populated; no login is required. External state remains READY_FOR_BETA_SUBMISSION. The public page still says it is not accepting testers. User has been given the public link and the observed Apple rejection. Need the owner to save review contact/feedback details in TestFlight Test Information, then rerun the failed distribution job in run 38747500724, whose upload is skipped by its commit trigger. Do not duplicate the accepted external upload. No application implementation changes were needed. No private contact values are printed or committed. The owner can share the generated link, but public installation readiness must be reported separately from link existence.

## Hassy Natural development — 2026-10-15, Australia/Perth

The owner requested a separate native HNCS research/photo app and explicitly selected this repository because its Apple signing secrets are configured. Work is isolated under `NaturalColor/`, branch `codex/natural-color-ios-20261015`, with a dedicated Hassy Natural workflow and bundle ID `com.normiecore.hassynatural`. Dashcam capture code and app identity are unchanged. Do not use the ordinary Dashcam `testflight` label for this app.

Native app source includes physical camera/ProRAW capability checks, original-file import, direct Metal/Core Image rendering, comparison, exposure/strength controls and full-resolution sRGB JPEG export. Captured originals persist in Files/Originals. The Apple app record exists (ID `6823073017`). Secrets remain CI-bound.

Recovered chroma arithmetic, the explicit 2007 native fallback profile and native Standard curve are integrated with hashes/provenance. The fallback is not an iPhone sensor calibration. Public companions improve overall median appearance residuals in three scenes, while one scene's chroma residual worsens; this is not proof of complete HNCS equivalence. Portable verification and 56 research tests passed. Apple CI already passed real iPhone 17 Pro DNG rendering, export/import, original/zero-strength color handling and two UI journeys. The precision tests caught reversed lookup-texture rows; the corrected renderer passed all seven unit/image tests and both UI journeys, plus the production Release archive and bundle checks in run 38703565784 (source `8af3d55d53d6ea06140d588cc9a4c67e57310895`). No numerical assertions were removed or relaxed.

Apple accepted **Hassy Natural 0.1.0, build 20261015.842**, at 08:44 UTC / 16:44 Perth in [upload run 38705206450](https://github.com/normiecore/dashcam-claude/actions/runs/38705206450) (retry attempt 2). Verified binary application source is `a29eab0c81a3649fd79c114ee3841e953719b241`; later changes add status checks/tests/documentation without modifying application code. The upload run passed all seven unit/image tests, both UI journeys, production Release archive/bundle validation, signing and upload. The separate [Apple status run 38705678511](https://github.com/normiecore/dashcam-claude/actions/runs/38705678511) confirmed processing `VALID`, internal-group build access, and `IN_BETA_TESTING` at 08:46 UTC. Do not repeat this successful upload.

The explicitly requested existing team account is enrolled in Hassy Natural Internal; no other account was added. The user's email is not stored in source or printed in logs. Atomic create/assignment resolves Apple's STATE_ERROR when reusing a tester from another app. The original upload attempt was canceled by a subsequent branch check before upload; retry attempt 2 completed successfully. Use only `natural-testflight` for future uploads; the ordinary `testflight` label belongs to Dashcam.

PR #11 remains open and main is unchanged. Installation and physical camera acceptance remain for the owner: TestFlight → Hassy Natural → Install, then capture with ProRAW where available, compare, save/share, and check the original under Files → On My iPhone → Hassy Natural → Originals. Simulator verification does not establish physical camera reliability or full HNCS equivalence. [Verification run 38708246055](https://github.com/normiecore/dashcam-claude/actions/runs/38708246055), test source `967186064a4038d35007148bd5af913c95b10d1f`, additionally passed actual 48 MP ProRAW full-resolution JPEG export and decoding, all seven unit/image tests, both UI journeys and the Release archive. Application code is identical to the accepted build. The owner confirmed receiving and accepting the TestFlight invitation; physical camera acceptance remains unconfirmed. Do not change Dashcam's release checkpoint below.

Last updated: **2026-10-12, Australia/Perth**.

## Active checkpoint - 0.1.1 accepted by TestFlight; PR #10 merge pending

Prepared and verified **2026-10-12, Australia/Perth** on
`codex/drive-history-live-activity-20261012`, [PR #10](https://github.com/normiecore/dashcam-claude/pull/10).
Verified application source: `801816b84e87e9c46d8fee905e929572921f36f1`.
Later checkpoint edits are documentation only and do not change the verified binary.

Apple accepted **0.1.1**, build **20261012.604**, at 14:08 Perth in
[TestFlight run 38210752423](https://github.com/normiecore/dashcam-claude/actions/runs/38210752423).
Release archive, bundle checks, app/extension signing and upload all passed.
Apple processing, tester installation and physical-device acceptance are unconfirmed.
Do not repeat this successful upload just because processing is pending.

Implemented: automatic Recent drives, historical Save drive using footage timestamps,
idle retention of the latest window with existing storage limits, a two-hour default
for new settings, export-space preflight with visible failure feedback, background
flush joined before foreground resume, and truthful recording/paused/stale Live Activity
status for Dynamic Island, Lock Screen and supported CarPlay systems. CarPlay disconnect
confirmation uses a Shortcuts automation opening `dashcam://disconnect`.
The extension App ID `com.normiecore.dashcam.activity` signed successfully.
The owner submitted Apple's camera eligibility inquiry; no answer is available here.
Capture remains foreground-only, with recorded footage kept across pauses.

[CI 38209125123](https://github.com/normiecore/dashcam-claude/actions/runs/38209125123) passes
67 core tests, 26 production app unit tests, all eight UI journeys, compact iPhone 17e
and large iPhone 18 Pro Max portrait/landscape checks, and production Release
archive/bundle validation. [Verification 38209125130](https://github.com/normiecore/dashcam-claude/actions/runs/38209125130)
passes portable policy checks, 16 alternate-project tests and its archive checks.
Reviewed Recent drives and saved-drive playback screenshots in the successful
[simulator preview](https://github.com/normiecore/dashcam-claude/tree/simulator-preview).
UI-test retention is shortened to one minute; this is not the release default.

The first complete UI run caught inherited save-button identifiers and library
selection/navigation resetting when pending-clip badges changed. These are fixed;
the entire UI suite passes after the fix. No failing tests were disabled.

**Main is unchanged.** Automatic approval review rejected squash-merging PR #10:
it changes the default branch and the conversation lacks direct authorization for
this specific PR. Do not bypass that rejection. The upload succeeded independently.
Next: obtain explicit approval to merge PR #10, then merge with an expected-head
check. Install build 20261012.604 after processing and follow the 0.1.1 checklist
in `docs/TESTING.md`: actual capture/playback, an hour-later save, rapid app
switch/resume/Stop, two-hour recording/storage, and Island/CarPlay presentations.
Do not describe simulator tests as physical recording or background-camera approval.

## Active checkpoint — library navigation and contrast repair

The owner supplied physical iPhone/TestFlight screenshots showing unreadable text on a
fixed cream background and oversized portrait thumbnails. This confirms installation
of a TestFlight app, but the screenshots do not identify its exact build or qualify
physical recording reliability.

[PR #9](https://github.com/normiecore/dashcam-claude/pull/9), branch
`codex/clips-navigation-20261008`, fixes the production SwiftUI library: adaptive
system backgrounds, readable date/title/empty state, compact bounded thumbnails,
Go to camera, clear tab selection and collapsed secondary clip details.
Source `f920ca2c1606ee713dc3c1ce8adef2a5e1d78d53` adds light/dark navigation journeys
and waits for settled landscape geometry before taking rotation screenshots.

[CI 37732544871](https://github.com/normiecore/dashcam-claude/actions/runs/37732544871)
and [verification 37732544869](https://github.com/normiecore/dashcam-claude/actions/runs/37732544869)
pass at the verified source above. CI includes 22 production unit tests, all seven UI
journeys, compact iPhone 17e / large iPhone 18 Pro Max recording-control rotation
checks, the unsigned Release archive and bundle validation.

Reviewed final light/dark screenshots for empty/populated library, clip actions and
settings. The explicit date text and teal switch/tab accents are clear. XCTest's
`app.screenshot()` still exports a cropped portrait-sized image after rotation, even
though the landscape bounds/reachability assertions pass. Verified the actual light
and dark landscape layouts in the simulator screen recording (about 188 s / 140 s):
full title, bounded clip row, safe areas and all three tabs are visible. This is an
evidence-capture limitation, not an observed layout failure. Preview is on the
`simulator-preview` branch, README source `f920ca2c1606ee713dc3c1ce8adef2a5e1d78d53`.
These checks are simulator evidence, not physical recording acceptance.

[TestFlight 37734103032](https://github.com/normiecore/dashcam-claude/actions/runs/37734103032)
passed Release archive, bundle checks, cloud signing and upload. Apple accepted
version **0.1.0**, build **20261008.547**, at 13:50 Perth on 8 October.
Apple processing and installation of this new build are not yet confirmed.

PR #9 remains open. Automatic approval review rejected its squash merge because the
owner's earlier explicit merge approval applied to PR #8, not this new main-branch
merge. Do not bypass the rejection; get explicit owner approval for PR #9 before
merging. The signed upload succeeded independently. Subsequent checkpoint edits are
documentation only.
No changes to capture, retention, incident protection or signing configuration.
Next: obtain explicit approval to merge PR #9 into main. Install build 20261008.547
once TestFlight processing completes and review on an actual iPhone. Do not repeat
the successful upload. Do not qualify/tag v0.1.0 before physical acceptance.

## Previous checkpoint — documentary build uploaded and merged

The owner made the repository public on 8 October after exhausting private-repository
Actions minutes. Hosted runners now execute normally. The documentary implementation
was developed on `codex/documentary-workflow-20261007` in [PR #8](https://github.com/normiecore/dashcam-claude/pull/8).
Verified source is `31ef969d8fccae7f0187f798813b818ad630a238`; later checkpoint edits are documentation only.
The owner explicitly authorized the merge on 8 October. PR #8 is squash-merged into
`main` at `d95aabf4f82c2fd9eaf11595702a54ae1b3cbad5`; `main` is canonical.

Apple accepted version **0.1.0**, build **20261008.408**, at 12:11 Perth on 8 October.
[TestFlight run 37725988703](https://github.com/normiecore/dashcam-claude/actions/runs/37725988703)
passed secrets preflight, Release archive, bundle checks, cloud signing and upload.
This is an internal-testing-only build. Apple processing, tester assignment,
installation and physical camera acceptance have not been confirmed.

Implemented: camera-first adaptive Record screen, contextual Save clip, dated full-colour
archive, Standard (default)/Space Saver/High Detail quality presets, storage estimates,
five-minute saved-clip pre-roll separate from six-hour/four-GB default rolling history,
Shortcuts start/stop/save URLs and CarPlay/Bluetooth automation guidance.
The production target supports iPhones on iOS 18 or later with adaptive dimensions,
safe areas and orientation. Camera recording remains foreground/unlocked only.

[CI 37724913174](https://github.com/normiecore/dashcam-claude/actions/runs/37724913174) passes:
61 Swift core tests, 22 production app unit tests, all five UI journeys on iPhone 17,
portrait/landscape reachability on iPhone 17e and iPhone 18 Pro Max, production
Release device archive/bundle checks, simulator preview and unsigned IPA packaging.
[Verification 37724913182](https://github.com/normiecore/dashcam-claude/actions/runs/37724913182)
passes portable C retention checks (400,036 normally and with sanitizers), policy simulation,
16 alternate-project simulator tests, and alternate unsigned device archive checks.
These are simulator/policy results, not physical-device tests.

The first resumed CI attempt exceeded its 30-minute job limit while starting the second
phone-size check, after app unit tests and compact layout passed. CI now gives each
phone-size check an independent runner/job, disables parallel simulator clones, and
allows the main unit/UI/archive job 45 minutes. Both size checks and the complete main
suite passed with this setup; app code did not change during this repair.

The earlier automatic approval block is resolved by the owner's explicit instruction:
"yeah merge into main please". The merge succeeded and GitHub confirms PR #8 is merged.
No app code changed after the verified TestFlight source; later edits only record results.

Next: inspect App Store Connect app 6820104006,
TestFlight version 0.1.0/build 20261008.408 after processing; resolve only evidenced
compliance prompts; install via TestFlight and follow docs/TESTING.md on a physical iPhone.
Do not repeat the successful upload merely because Apple processing is pending.
Do not qualify/tag v0.1.0 before physical acceptance.

## Current position

**Earlier first signed iPhone upload succeeded.** The production foundation app uses
`com.normiecore.dashcam`. Apple accepted version `0.1.0`, build `20261007.1334`,
from source `fcec715dbfd50093b523a176ed9ecbc83e4c8ccd` in
[TestFlight run 37629540786](https://github.com/normiecore/dashcam-claude/actions/runs/37629540786).
The secrets preflight, release archive, cloud signing and upload all passed.
Apple processing and installation have not been confirmed; physical capture
acceptance is still outstanding. The workflow uploads internal-testing-only builds.

The owner created the Normiecore Dashcam App Store Connect record and configured
four GitHub Actions signing secrets. Never request or store the private key in
chat. PR #2 is merged; `main` is canonical. The separate root Astra checkpoint
uses `com.normiecore.dashcam.dev` and has not been distributed.

**Android UI refinement complete — `0.1.0-dev.2`, version code 2.** The native
dark/mint interface has context-aware Start/Save controls, a separate Stop button,
portrait/landscape layouts, camera onboarding, Saved/Recent/Recovery browsing,
thumbnail rows, precise clip times, playback/share sheets, persistent audio settings
and explicit pending/partial-tail feedback. Capture, retention and durable storage
behavior is preserved; RecordingService only gains read-only UI metadata.

Android development started first; the owner has now resumed the iPhone path after
joining the Apple Developer Program. Android PRs #3 and #7 were merged into
integration PR #2. Both platforms need physical-device acceptance; the first production iPhone
TestFlight upload has succeeded.

Verified build commit: `0651518568001b0cabbee858107a41ffe7d57925`.
[Passing hosted run](https://github.com/normiecore/dashcam-claude/actions/runs/37281099291).
Debug/Release and instrumentation compilation pass, lint has no errors, and Android
retention/storage tests pass **200,647 assertions**, locally and on hosted JDK 17.
**Ten Android 15 emulator tests pass**: native directory fsync, read-only provider,
activity launch, accessible Recorder/Footage navigation, denied camera start,
synthetic MP4 segment/incident/30-second-tail capture using UI Start/Save/Stop,
activity recreation retaining the recording service and live preview, saved library,
landscape action visibility, incident-sheet navigation and persistent audio settings.
Seven real emulator screenshots were exported and visually reviewed: ready, empty
library, recording, saved library, landscape, incident details and settings.
These checks do not establish physical camera/audio/screen-off reliability.

[Installable debug APK artifact](https://github.com/normiecore/dashcam-claude/actions/runs/37281099291/artifacts/11332392247):
`app-debug.apk` at ZIP root; app is **120,898 bytes (118.1 KiB)**.
APK SHA256: `7f7343a3d67cf2099be9044f7bf0c1baa150ca268de025dd50094bc51fc7d6cb`.
[Emulator reports and screenshots](https://github.com/normiecore/dashcam-claude/actions/runs/37281099291/artifacts/11331959306).
Local downloads: `/workspace/dashcam-android-polished.apk`,
`/workspace/dashcam-android-polished-install.zip` (app + INSTALL.txt only),
and screenshots in `/workspace/dashcam-ui-review/ui-screenshots/`.
Workspace files may not persist. App artifact expires 4 November 2026.
The final documentation-only commit does not change the verified binary.
Release compilation passes, but its APK is unsigned; use the debug APK for acceptance.

**Upgrade caveat:** GitHub Actions debug-key caches are branch-scoped. The new UI
branch missed the old branch's cache and created a new prototype signing identity.
Its key was successfully restored on subsequent builds. It differs from the old
69 KiB APK: export/check wanted footage from the old app before uninstalling it,
then install this APK. Uninstalling or clearing data removes private footage.
New certificate SHA256:
`2baad557df2596cdcc2f9bebea537e788f2df1bf540ae3a8b602ee695d87c135`.
Stable release signing remains unconfigured; cache expiry/loss can change identity.

No Seeker physical tests performed. MediaRecorder stops/restarts between ten-second
clips and may introduce gaps. Export shares original MP4 clips without joining them.
Uncertain files remain retained without repair; explicit deletion remains outstanding.
Android minimum API 28, compile/target API 35. Remaining lint warnings do not prevent
compilation; no release tag, Play upload or final `v0.1.0` qualification performed.

Next concrete actions: wait for Apple processing, create an internal TestFlight
group, add the owner and build, install from TestFlight, then follow the physical
iPhone checklist in `docs/TESTING.md`. On Android, confirm the Seeker version and
run the six-minute incident/tail test from `Android/README.md`. Do not qualify
`v0.1.0` before physical phone acceptance.

The goal remains a reliable phone dashcam: segmented recording, about five minutes
of rolling footage, manual incident preservation plus a 30-second tail, playback,
export, recovery and safe storage cleanup. Original intent is in
[`AstraDocs/OriginalBrief.md`](AstraDocs/OriginalBrief.md). Challenge platform assumptions;
do not promise automatic collision detection or background access without evidence.

## Where the work lives

### Integration history — 5–7 October 2026

Android foundation PR #3 and UI PR #7 were merged into integration PR #2.
PR #2 reconciles the foundation Swift 6 package, Android app and two distinct
iOS projects. XcodeGen produces `App/Dashcam.xcodeproj` for production/TestFlight;
the root `Dashcam.xcodeproj` is a separate Astra development checkpoint.
The earlier Astra `Docs/` moved to `AstraDocs/` to avoid case collisions on Macs.
Foundation simulator preview changes from PRs #5 and #6 on `main` survive the
integration merge. See README for build paths and PR #2 for the reviewed merge.
The merge verification itself did not establish signing or physical-device
qualification. The subsequent successful signed upload is recorded above.

- Public repository (owner changed visibility on 8 October): https://github.com/normiecore/dashcam-claude
- Integration review: https://github.com/normiecore/dashcam-claude/pull/2
- Canonical source: `main`; PR #2 merged on 7 October 2026.
- Android version: `0.1.0-dev.2`, code `2`; iPhone marketing version `0.1.0`,
  build `1` in source (TestFlight assigns a fresh build number).
- Earlier scratch checkout: `/workspace/scratch/7b8755d64a71/Dashcam` is
  stale; GitHub is the durable source. Do not force-push its unrelated ancestry.

## User context and decisions

- User works from iPad/iPhone and wants cloud development without buying a Mac.
- A GitHub-hosted Mac already compiles/tests this project; it is an ephemeral CI
  runner, not an interactive desktop or a connected physical phone.
- Apple Developer membership, registered production App ID, App Store Connect
  record and GitHub signing secrets are now established by the successful upload.
- User owns an iPhone and **Solana Seeker** Android phone. Seeker Android version
  is unknown. A friend can test a phone described as **“razer”**: clarify whether
  Razer Phone/Phone 2 or Motorola Razr, and obtain Android version.
- Android was chosen first for Seeker, followed by the friend's device; the owner
  has now resumed iPhone distribution setup. Neither platform has physical capture
  acceptance yet.
- Prioritize footage preservation; compile/test continuously, investigate failures,
  keep a short changelog, and use appropriate lower-cost subagents for scoped work.

## Astra checkpoint: implemented and verified

iPhone implementation: SwiftUI, AVFoundation, serial capture/storage operations,
720p30 target, H.264 4 Mbps, ten-second MOV segments, one-second fragments,
optional microphone, durable JSON manifest, overlap-safe incident pinning,
recovery retention, library/playback/export, lifecycle/thermal handling and debug
incident/interruption simulation. Originals are in Application Support, excluded
from backup. Uncertain footage is retained rather than silently deleted.

Authoritative latest tested implementation/tooling commit:
`511ac398d1e6fc04ae20959afc8f3cbe37165ee4`.

| Check | Actual result |
| --- | --- |
| Hosted Xcode 26.6 Debug and Release simulator builds | PASS |
| Simulator XCTest | 16 passed, zero failures |
| Release iPhoneOS arm64 archive, icon/privacy/permissions/dSYM checks | PASS, **unsigned** |
| Portable production C retention policy | 400,036 assertions pass normally and with ASan/UBSan |
| Accelerated 12-hour policy simulation | PASS; policy only, not a camera soak |
| Physical recording, signing/install, TestFlight upload | **Not performed** |

Evidence: [passing hosted run](https://github.com/normiecore/dashcam-claude/actions/runs/36671496781),
[logs and unsigned archive](https://github.com/normiecore/dashcam-claude/actions/runs/36671496781/artifacts/11077823897).
Artifacts can expire. Later documentation-only commits do not imply a new tested binary.

Real failures fixed: sparse final frames inflated movie/export duration; writer
now explicitly ends the session at accepted video coverage, with regression checks.
The first archive check had incorrect `lipo` argument order; fixed and rerun.

## Astra checkpoint limits and shared acceptance

- iPhone recording is foreground/unlocked only. No SafetyKit entitlement or
  integration, no motion classifier, no GPS, no cloud upload.
- iPhone-only app target; using an iPad to manage development does not mean iPad
  recording support is implemented.
- The Astra checkpoint is unsigned. The foundation's first signed TestFlight
  upload is recorded above; neither implementation has physical camera, audio,
  heat, battery, lock or recovery acceptance.
- Physical acceptance is mandatory: six-minute pre/post incident test, interruptions,
  low space, termination/recovery, audio/orientation and prolonged recording.
- Legacy orientation/export callback compiler warnings remain in Swift 5 mode.
- Damaged-media repair and recovery-item deletion UI remain outstanding.
- Debug simulation controls are absent in Release; manual Save Incident invokes
  the same preservation pipeline for eventual TestFlight acceptance.
- Do not tag `v0.1.0` as qualified until physical acceptance is complete.

## If the user resumes with Android

1. Open `main`; read `Android/README.md` and this checkpoint. Preserve the separate
   iOS implementations and the configured TestFlight workflow.
2. Confirm Seeker Android version, install the latest verified debug APK, and follow
   the six-minute incident/tail acceptance test in `Android/README.md`.
3. Validate switching apps/screen-off, actual segment gaps, audio/orientation,
   low space, thermal/battery behavior and interrupted-write recovery on Seeker.
4. Resolve observed capture/lifecycle failures before expanding. Seamless segment
   writing, joined export, safe explicit saved/recovery deletion and damaged-media
   repair remain future work. Do not guarantee screen-off reliability upfront.
5. Clarify the friend's exact phone model/Android version before secondary testing.

Research as of 5 October: Android documents a camera foreground service that can
continue camera access in the background, but launching it generally requires the
app to be visible and permission granted. Google Pixel Personal Safety provides
crash detection on supported devices; no documented public crash-event API was
found for our app. Do not assume Seeker or the friend's phone provides one.
Manual incidents remain the baseline; any custom detector needs separate validation.

Sources to recheck:
- https://developer.android.com/develop/background-work/services/fgs/service-types
- https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start
- https://support.google.com/pixelphone/answer/7055029
- https://developers.google.com/location-context/activity-recognition
- https://developer.android.com/developer-verification

## If the user resumes with iPhone

Open `main`. Use the foundation project (`App/project.yml`, `App/Dashcam/`) and
`docs/TESTING.md` for TestFlight installation and physical acceptance. Signing is
configured and the first upload succeeded; check Apple processing before uploading
again. The separate `com.normiecore.dashcam.dev` checkpoint remains undistributed.
Keep private keys/passwords in suitable secret storage, never chat or Git.

## Session procedure and file map

Start by reading this file, checking Git status/current branch and comparing any
new user direction with this checkpoint. Do not rerun successful expensive builds
for a documentation-only change. Test meaningful code changes and record actual
results, commit/run identifiers and unverified limits before ending the session.

- `App/Dashcam/`: production foundation iOS app distributed through TestFlight.
- `App/` also contains legacy Astra sources; follow each project's target membership.
- `Core/RecordingStore.swift` (Astra checkpoint): durable manifest, retention integration and recovery.
- `Core/RetentionPolicy.c`: production interval/protection/deletion policy.
- `Tests/`: C policy, Swift storage and synthetic media tests.
- `Tools/test-core.sh`, `Tools/verify_project.py`: Linux checks.
- `Tools/verify-mac.sh`: simulator builds and XCTest.
- `Tools/verify-device-archive.sh`: unsigned iPhone archive checks.
- `.github/workflows/verify.yml`: hosted verification on PR changes/manual dispatch.
- `AstraDocs/Architecture.md`, `AstraDocs/AppleReview.md`, `AstraDocs/Verification.md`: detailed design and evidence.
- `CHANGELOG.md`: completed work and significant decisions.
- `Android/`: native Java Android app, durable storage, core tests and device tests.
- `.github/workflows/android.yml`: Android compilation/lint, emulator tests and APK artifact.
- `Android/app/src/main/java/com/daz/dashcam/Ui.java`, `res/values/`: native design system.
- `Android/verify-emulator.sh`: test execution and valid screenshot collection.
- `App/project.yml`, `App/Dashcam/`, `Sources/`, `docs/`: iOS foundation from main,
  with its own Swift package and XcodeGen build/test paths. Details are in README.

Suggested new-session prompt: **“Read AGENTS.md and HANDOVER.md first, inspect the
current branch, and resume the dashcam project with [Android / iPhone]. Preserve
existing work and verify changes as you go.”**


