# Round 3 colour reassessment — 18 October 2026

The owner confirms Round 3 was captured with Natural **0.1.3 (20261018.629)**.
That matters: two materially different implementations were distributed with
the marketing version 0.1.3. The earlier RAW-saving bug cannot be used by itself
to explain this round.

## What changed

| Stage | Preferred 0.1.1 | Independent 0.1.2 | First 0.1.3 rollback | Build 20261018.629 |
| --- | --- | --- | --- | --- |
| Capture default | ProRAW where available | Apple-processed image with RAW saving off | Apple-processed image with RAW saving off | ProRAW where available, independent of saving |
| RAW development | Apple global/shadow boosts and local tone map off; gamut mapping off | Apple defaults | Original settings restored | Original settings restored |
| Colour/tone operator | Recovered chroma table and per-channel Standard film curve | Small analytic luminance finish | Original operator restored | Original operator restored |
| Default output | High-quality sRGB JPEG, 0.96 | Display P3 HEIC, 0.78 | Display P3 HEIC, 0.78 | Display P3 HEIC, 0.78 |

Relevant sources: preferred baseline `5365cfa6f202c023132ab4fd6cb95d4859d3564f`,
independent renderer `9744adf493c837c32f8663ac14f5aef04511ff5f`,
first rollback `2e9bbe8d2a3c3223784b5216fe17aa18c086a791`,
RAW-selection repair `0d405590144995297c5d4ab1faa9bb2beebccc66`.

The independent replacement changed the appearance deliberately: its small
luminance polynomial could not reproduce the removed chroma transform or
Standard curve. The first rollback restored those stages but retained the
new capture default, feeding an already rendered image to a pipeline whose RAW
path disables Apple's tone stages first. The subsequent repair separates RAW
capture/development from whether its original is retained.

The restored Metal operator, C++ operator, profile, chroma and Standard assets
are byte-identical to the preferred baseline. The current RAW decoder, filtering
and preview code also match it. This is source evidence; same-input native
rendering and inspection of the supplied output files are separate checks.
The first accepted 0.1.0 source `a29eab0` uses the same RAW and recovered colour
stages; the 0.1.1 additions are framing/capture workflow changes. Native framing
therefore provides a consistent colour baseline for both early versions.

## What the HNCS research establishes

[Hasselblad describes HNCS](https://www.hasselblad.com/learn/hasselblad-natural-colour-solution/)
as a complete system: camera calibration, a colour LUT, a Film Curve,
illumination-aware processing and managed working/output colour spaces. Its goal
includes rich natural colour, contrast and smooth tonal transitions.
The [Phocus manual](https://cdn.hasselblad.com/manuals/Phocus_Manual/V26/Phocus_User-Manual_v26_EN_updated.pdf)
distinguishes the Standard film response from linear reproduction modes and
documents reference-target calibration and colour-error evaluation.

The repository reconstructs particular native chroma/film mathematics and an
explicit phone colour-space bridge. It does **not** yet implement calibrated
iPhone HNCS or establish complete Phocus equivalence. The chosen 2007 FlashStd
fallback is fixed, with illumination interpolation disabled; it is not an iPhone
sensor profile. The three public appearance comparisons are uncontrolled and
one increases chroma residual despite improving total median difference.
See [matrix contract](../research/HNCS-MATRIX-CONTRACT.md),
[film integration](../research/STANDARD-CURVE-INTEGRATION.md),
[public comparison limits](../research/APP-REFERENCE-VALIDATION.md), and
[profile provenance](../../ios/HassyNatural/Resources/ReferenceProfile.json).

Two original limitations deserve separate improvements after baseline testing:
the kernel clamps extended linear input before the curve, and clamps output to
sRGB before P3 encoding. These can discard highlight or colour information.
They predate the update and therefore are not evidence of a new regression.
An output labelled P3 does not undo that earlier clipping.

## Investigation and acceptance

Private photographs, source filenames, Drive IDs, location metadata and download
credentials stay outside source control. All **87 distinct finished files** were
downloaded and visually reviewed after profile-aware conversion to sRGB:
40 in Round 1 (31 JPEG exports plus nine separate Apple-camera HEICs), six in
Round 2, and 41 in Round 3. Six duplicate folder entries in Round 3 contain three
repeated DNG names and three repeated HEIC names; they are not additional scenes.

The dominant visible problem is dark foregrounds in high-contrast scenes:
tree/deck against a pale building, buildings against sky, park/pond against
clouds, and an indoor cup against a brighter room. This varies with the scene;
many foliage and garden close-ups retain useful detail and colour. Strongly dark
sky-led foregrounds also occur among the original Round 1 direct-capture JPEGs.
They should not be described as a newly introduced, universal Round 3 cast.
Sampled grey surfaces are close to neutral in the managed renditions.

Every Round 2/3 export has a Display P3 ICC profile; missing ICC tagging is not
supported as their explanation. Thirty Round 1 JPEGs are untagged and one is
P3; sRGB interpretation of the untagged files is corroborated by the original
encoder source. All nine separate Apple-camera HEICs are P3 and retain Apple
capture metadata; HDR gain-map/auxiliary information is present. Their base-layer previews are
not an exact Photos HDR comparison. None of the app exports records the app
build or RAW development settings.

The rounds contain different viewpoints, lighting, capture paths and sometimes
resolutions. Similar-looking Apple-camera and app photographs are separate
exposures, not pixel-aligned source/output pairs. These observations establish
appearance concerns, not a controlled colour-error measurement. Drive folder
and sampled photo comments contained no additional written feedback.

Two matched Round 3 DNG/HEIC pairs were selected for a native same-input replay:
foliage and a dark tree/deck foreground. Both DNGs are linear ProRAW with Apple
colour/tone/gain metadata and zero recorded exposure compensation. Neither has
an extractable embedded JPEG preview. A LibRaw rendition is a different decoder
and must not be substituted for Apple Photos or Phocus ground truth.

A matched original dark tower/sky DNG and the two selected Round 3 DNGs all
identify an iPhone 17 Pro running **27.0.1**. The sampled files therefore do not
support a phone OS update as the round-to-round cause. They do differ in lens,
exposure, white balance and RAW normalization: the original uses the ultra-wide
camera while the selected Round 3 files use the main camera. Their recorded
BaselineExposure values range from about 0.20 to 1.94 EV and their automatic
white-balance temperatures differ. These are scene/input differences, not proof
of incorrect processing; do not blindly zero baseline exposure or white balance.

Keep the preferred recovered operator fixed while checking input, exposure,
profile conversion and codec differences. Compare identical DNGs using identical
sRGB JPEG settings first; test HEIC separately. Do not fit a new look to unrelated
scenes or treat successful numerical tests as photographic acceptance.

## Export diagnostics and contract verification

Candidate source `35d762f` records app version/build, versioned renderer identity,
RAW versus processed input, effective RAW decoder settings (including baseline
exposure and white balance), strength/exposure/crop, and actual output
format/profile/compression in the encoded EXIF comment. It does not copy source
EXIF or locations. Unavailable nonfinite diagnostics are recorded as null so
diagnostics cannot block an otherwise valid save.

[Hosted verification 39119224772](https://github.com/normiecore/dashcam-claude/actions/runs/39119224772)
passed **15 image/unit tests**, the unsigned production iPhone Release archive,
and the restored-resource checksum audit. The tests include actual 48 MP ProRAW
development/export, GPU/portable operator agreement, decoded JPEG/P3 HEIC
appearance/profile comparisons, diagnostic metadata round trips and exclusion of
source metadata. Flat neutral/saturated patches agree with the sRGB preview
within codec tolerances. This supports the output conversion contract; it does
not establish calibrated HNCS accuracy or acceptance of high-contrast scenes.

This candidate preserves the preferred rendering mathematics and decoder values.
There is no new TestFlight upload; the owner's installed build remains the
confirmed Round 3 build. The audit workflow has no signing or release job.

## Next colour work

For a calibrated next iteration, use paired, controlled phone and Phocus
references with a grey/colour target under daylight and artificial light; record
white balance, exposure and lens. Evaluate neutral balance, skin transitions,
chroma and highlight detail separately from aesthetic preference.

Prioritize the supplied-photo failure: retain visible foreground subjects while
preserving sky detail and the successful foliage colour. Separate exposure and
dynamic-range adaptation from the recovered creative stages; investigate early
clamping and the fixed illumination model against controlled references. A
blanket saturation/white-balance change is not supported by this review.
