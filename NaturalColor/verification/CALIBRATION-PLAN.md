# Natural 0.1.4 sample collection and calibration plan

Prepared 19 October 2026, Australia/Perth. Collection will run over the next few
days. Use Natural 0.1.4 (20261019.613) throughout this round so a changing app build
does not confound lighting, lens and scene differences. No new release is needed
before collecting these samples.

## Collection

Use the normal camera workflow, HEIC Medium, native framing and default finishing.
Temporarily enable Save RAW original on supported lenses. Keep both the untouched
DNG and the finished HEIC from each useful shot. Unsupported cameras can still
provide useful finished-photo feedback; mark those as processed input rather than
assuming a RAW exists. A handful of representative scenes matters more than volume:

- Bright sky with a shaded foreground; include a scene that looks too dark.
- Foliage, flowers or other saturated natural colours.
- Skin in daylight and, if convenient, indoor light.
- Neutral grey/white surfaces under daylight and artificial light.
- A quiet, evenly lit scene that already looks good.

Shoot normally. If comparing with Apple Camera, photograph the same scene close
in time with the same physical lens and framing where possible. Those are separate
exposures and are contextual comparisons, not pixel-aligned calibration truth.
A grey/colour chart is optional for this round; a white wall is not a calibrated
neutral target. Do not change several camera/edit settings to fix one scene unless
the change is noted.

Keep a short note only when useful: what looked wrong or especially good, the lens,
and whether the concern appeared in Natural preview, Photos, SDR or HDR viewing.
The optional CSV template is `calibration-sample-notes.csv`. Private photographs,
filenames and populated notes stay outside Git. The template contains no user data.

When sharing, send original files through a file transfer rather than screenshots
or recompressed chat images. Preserve source filenames when possible; otherwise
keep each DNG/HEIC pair together. Do not assume Photos export names or sequential
file numbers alone establish a pairing. If pairing is ambiguous, mark it unresolved.

## Metadata already available

The inventory below is checked against PhotoEngine.exportProperties in build
20261019.613. Finished-photo EXIF UserComment contains JSON schema
`natural-render-v1`; source EXIF/GPS/names/capture dates are not copied by that code.

| Information | Current source | Use |
| --- | --- | --- |
| App version/build and renderer | Finished HEIC/JPEG provenance | Identify the exact rendering implementation. |
| RAW versus processed input | Finished-photo provenance | Avoid treating Apple-processed input as an unrendered RAW baseline. |
| Strength, exposure adjustment and aspect ratio | Finished-photo provenance | Reproduce user edit settings and crops. |
| RAW decoder version, baseline exposure, white balance and effective decoder settings | `rawDevelopment` when RAW decoding succeeds | Separate decoder/WB/exposure placement from the creative colour stage. |
| Scene white percentile and dark-pixel fraction | `sceneStats` when measurement succeeds | Explain why adaptive tone was selected. |
| Tone exposure, compression and shadow fill | `sceneTone` | Reproduce the actual highlight/shadow policy. |
| Actual codec, output colour space, compression and gain-map flag | `output` | Separate finishing from file encoding and display behaviour. |
| Camera/lens, ISO, shutter, aperture and focal length where present | Original DNG capture metadata | Group comparisons by camera and capture conditions. These are not currently copied into finished-photo provenance. |
| Phone/OS information where present | Original DNG metadata or a one-time tester note | Identify possible hardware/decoder environment differences. No claim that every file contains these fields. |

Missing values remain unknown. For example, a JPEG fallback is not HEIC merely
because HEIC was selected, a missing RAW is not evidence of a specific capture
path, and absent chart/reference data cannot be inferred from metadata.

## Review when samples arrive

1. Keep the originals privately and establish DNG/finished-photo pairs. Assign
   local generic sample labels; retain any filename-to-label mapping privately.
2. Read the embedded app provenance and the relevant capture metadata. Separate
   other builds, unsupported/processed lenses, crops, user exposure edits and
   missing provenance before comparing appearance. Check embedded ICC profiles
   and HDR auxiliary data rather than assuming a file extension proves either.
3. Visually review the actual finished files with colour management. Evaluate SDR
   and HDR presentation separately; an SDR screenshot does not represent Photos
   HDR. Record which scenes succeed as well as which fail.
4. Replay each selected DNG through the unmodified accepted 0.1.4 Apple RAW/app
   pipeline. Preserve exposure, white balance, framing and export settings. Record
   the actual runner/OS/decoder environment; a hosted replay is not a phone capture.
   LibRaw or an embedded preview is not a substitute for the Apple decoder baseline.
5. Compare candidate changes using that same RAW/decode. Change one parameter
   family at a time: exposure placement, highlight shoulder, shadow fill, then
   colour/illumination response. Use the successful scenes as regression controls.
   Do not fit global saturation or white balance to unrelated photographs.
6. Check full-file ICC-managed SDR comparisons with identical resizing; do not
   compare codec-specific thumbnails. Quantify neutral balance, shadow detail,
   highlight transitions and chroma separately. Reuse mandatory native macOS
   readback for actual saved HDR files because simulator HDR decoding is limited.
7. Produce labelled before/after boards from actual native outputs, state the
   source/build/settings, and keep aesthetic preference separate from calibrated
   colour error. Verify any proposed new build before a further TestFlight upload.

This real-world sample round assesses useful photographic behaviour. A verified
X2D II 100C match still needs controlled reference captures with known camera/
Phocus settings and, ideally, grey/colour targets under known illumination.
Metadata helps reproduce a result; it does not establish the correct colour.

## Nonintrusive diagnostics

No telemetry, automatic upload, background library scan, account link or persistent
user/device identifier is required. Reports should contain only an explicit
allowlist of numeric rendering/capture settings and generic sample labels. Do not
copy GPS, dates, filenames/paths, serial numbers, owner fields, MakerNotes blobs or
arbitrary source metadata into a shareable report. Original files themselves can
retain capture metadata and remain private inputs, not public report artifacts.

An optional on-device Share calibration report action remains a possible later
feature, not an existing 0.1.4 control or a prerequisite for these test shots.
Any future implementation should use explicit sharing and keep photo inclusion
separate. The present workflow is manual and uses existing file metadata.
