# Round 4 supplied-photo review — 19 October 2026, Australia/Perth

## Scope and method

The owner supplied seven DNG captures and eight finished HEICs from the new beta,
with feedback that some edits are very slightly dark. All 15 files were downloaded
without changing Drive contents, size-checked and recorded with local SHA256s.
Photos, identifying filenames, source IDs/URLs, original metadata and the contact
sheet remain outside Git under `/workspace/photo-audit-round4`.

Reviewed all eight finished files after embedded-profile conversion to sRGB with
LittleCMS, using a consistent thumbnail pipeline. This is an SDR appearance review,
not an emulation of Photos HDR. Read each finished file's actual EXIF provenance
and the original DNG capture metadata. No DNG pixel development, native replay,
new candidate rendering, chart measurement or reference-camera comparison was
performed for this batch.

## What the files establish

- All eight finished files identify Natural **0.1.4 (20261019.613)** and
  `recovered-standard-scene-v1`, with RAW input and strength 1.
- All are native 6048 x 8064, tagged Display P3, HEIC High (compression 0.95).
  A codec/quality/profile change between these files is not supported as an
  explanation for their different brightness.
- Seven finished files record edit EV 0; a second rendition of one capture records
  **+0.7 EV**. Its decoder and scene-measurement values match the corresponding
  unadjusted rendition; the exposure change also selects stronger compression.
  This is a useful same-source edit comparison, not a controlled calibration target.
- The originals identify the same phone/OS/main-camera family and capture exposure
  compensation 0. BaselineExposure and white balance vary with the capture; they
  must not be blindly reset to make the files look alike.
- Three files declare HDR gain maps and five declare SDR. Their HEIF tone-map
  compatibility branding agrees with those branches. This container check is not
  a native expanded-HDR pixel validation of these new owner photographs.

## Appearance and likely adjustment direction

The three food scenes have relatively heavy lower/mid tones in the managed SDR
renditions. Their recorded **compression is 0 and shadowFill is 0**. Thus the
Round 4 highlight shoulder and HDR gain map cannot explain darkness in those
particular outputs: they pass through the baseline colour/film response without
adaptive shadow fill. The dim-scene gate deliberately keeps fill off there.

The brighter portrait and some other scene regions need less lifting. The
+0.7-EV portrait rendition visibly lifts the subject compared with its unadjusted
version; this does not establish +0.7 as a suitable new global default. The
review supports a scene-dependent brightness refinement and does not establish a
universal exposure error, new cast, or missing ICC profile.

No global exposure reduction exists in the shipping defaults: edit EV is 0 and
HN_RAW_FILM_EXPOSURE is 1. Code inspection confirms that the shoulder only reduces
pixels above max RGB 0.25 linear. Existing shadow fill peaks near 0.022 linear,
fades through lower mids, and reaches zero at 0.125. Its scene gate depends on
both dark-pixel fraction and scene white; raising its maximum alone would not
help the food scenes whose gate is off.

## Concrete next experiment

Keep the accepted app and the remaining collection round on 0.1.4. Before changing
shipping defaults, use representative darker scenes plus the successful brighter
control through the actual Apple/native app pipeline:

1. Reproduce the accepted output from the same DNG and settings.
2. Compare tiny edit-exposure increases **+0.10 and +0.20 EV** (approximately
   7% and 15% linear exposure), recomputing scene tone normally.
3. Compare a restrained lower-mid/shadow lift in affected scenes, with the existing
   maximum fill preserved. The current gate needs explicit evaluation for dim
   scenes; changing only the cap would be ineffective for these examples.
4. Preserve the preferred colour response and evaluate subject brightness,
   black depth and bright regions separately. Do not choose a white-balance or
   saturation correction from uncontrolled, differently lit scenes.
5. Compare actual exported files in managed SDR and supported native HDR. Confirm
   where the owner notices darkness: Natural preview/editor, Photos or shared/Drive
   presentation. That viewing context has not yet been established.

Those values are conservative experiment points, not a measured correct
calibration or tested candidate. No comparison board purporting to show an
unimplemented/native-rendered change has been authored. No private photographs
were sent to a hosted GitHub runner in this review. A native private replay needs
the existing approved private-data workflow and appropriate transfer authorisation.

No application code, tests, resources, release defaults or TestFlight build changed
in this review. Controlled X2D II equivalence and physical acceptance remain
outstanding. The metadata is already proving useful for distinguishing the actual
edit/decoder/tone path without adding telemetry to end users.
