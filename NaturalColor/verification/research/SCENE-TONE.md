# Scene tone stage and HNCS HDR-style output (Round 4)

Round 4 adds an application stage in front of the recovered HNCS chroma and
Standard film stages. It is **application policy, not recovered Phocus code**.
Its job is to give iPhone ProRAW the dynamic-range behaviour documented for the
Hasselblad X2D II 100C while keeping the accepted 0.1.1 colour rendering intact.
Portable source: `ios/HassyNatural/Core/RecoveredColor.cpp`; GPU mirror:
`ios/HassyNatural/Imaging/RecoveredKernel.ci.metal`.

## Why

| Observation | Evidence |
|---|---|
| The decoder discarded highlights before the renderer saw them | Public iPhone 17 Pro DNG on the hosted simulator: brightest pixel 1.18 at `extendedDynamicRangeAmount` 0 (the default) versus 2.40 at 1, with mean midtone difference 6e-6. Value 2 only adds reconstructed data (3.62). Simulator decode, not a phone capture. |
| The kernel clamped linear input at 1.0 before the curve | Everything above about +2.5 EV over a 0.18 grey rendered as flat white (`RecoveredKernel.ci.metal` before Round 4). |
| The kernel clamped output to sRGB before Display P3 HEIC encoding | 19% of random saturated colours leave sRGB after the HNCS chroma stage; 97% of those lie inside P3. A teal test patch loses 23 P3 code values of saturation when clamped. |
| Backlit foregrounds rendered dark | Round 3 reassessment. With Apple's local tone map off, ProRAW keeps its global exposure but loses the shadow lift Apple designs it to rely on (WWDC21 session 10160). On the public DNG, Apple's gain table lifts the median 0.9 stops at half strength and 1.5 at full. |

What the X2D II does instead of local tone mapping, as documented or reported:
global HNCS processing, scene-adaptive exposure in its HDR mode with a global
shadow and midtone lift, a highlight roll-off, and HNCS HDR, an ISO 21496-1 gain
map with "linear response and a roll-off in the highlights", up to +3 stops, on
a Display P3 base (Hasselblad X2D II FAQ and press material; DPReview in-depth
review; Greg Benz HDR analysis). No in-camera local tone mapping is documented.

## What the stage does

For RAW input only. Processed HEIC/JPEG input keeps the original operator.

1. **Decode headroom.** `CIRAWFilter.extendedDynamicRangeAmount = 1`, with the
   rest of the 0.1.1 decoder settings unchanged.
2. **Scene measurement.** A reduced decode with identical settings (long edge
   512, then 256 by Lanczos) gives `white`, the 99.5th percentile of
   max(R,G,B), and `darkFraction`, the share of pixels more than 2.5 stops below
   0.18 luminance. It is measured once per decode, so preview and full-size export
   choose the same tone. A failed measurement never blocks a photo.
3. **Exposure.** `HN_RAW_FILM_EXPOSURE = 1`: Apple's BaselineExposure placement
   is kept, as in 0.1.1. The Standard curve's design point is film input 0.125 →
   display 0.1835 (sRGB 119), so an exposure of 0.125/0.18 would be correct only
   if an 18% card lands at 0.18 after BaselineExposure. Apple's gain table
   carries part of its exposure intent, so that is unmeasured. A grey-card
   calibration on a phone must decide it (see below).
4. **Highlight shoulder.** `compression = clamp(log2(white × 2^editEV), 0, 2.5)`.
   In t = log2(max(R,G,B)/0.125), values above a knee at t = 1 (+1 EV over
   film grey) follow a rational shoulder t′ = 1 + 2Ru/(1 + (R − 1)u), with
   u = (t − 1)/(2 + c) and R = (2 + c)/2. It has slope 1 at the knee, and the
   measured white lands exactly on film white. Applied as a shared gain on
   max(R,G,B), so hue is kept and no channel clips before the per-channel film
   curve. With a calibrated exposure and 2.5 stops of compression, the grey ladder
   is 119/172/214/236/247/253 for 0 to +5 EV (uncompressed: 119/172/224/255).
5. **Path to white.** Only when compression is active, pixels whose peak is in
   [0.9, 1] blend toward neutral with a smoothstep weight. This avoids the
   pink/magenta clipped highlights reported for older Phocus renders.
6. **Shadow fill.** `0.6 × smoothstep(0.15, 0.45, darkFraction) ×
   smoothstep(0.5, 1, white)` EV at most, so only backlit scenes (dark content
   *and* highlights near film white) are filled; a dim low-key scene keeps its
   mood. The public fixture (white 0.40, 29% dark) gets none. Applied on a sin² bump in log2 luminance. It peaks 2.5 stops below film grey, is zero at
   grey and fades to under 0.02 EV by −6 stops, so blacks stay put. This
   mirrors Phocus Shadow Fill / DRC "As Shot" (global and content-adaptive).
7. **Output gamut.** The kernel no longer clamps its output. HEIC is encoded in
   Display P3 and keeps colours outside sRGB; JPEG and preview clip once in sRGB.
8. **HNCS HDR-style gain map.** For HEIC on iOS 18+, when compression > 0, the
   HDR rendition is the finished SDR pixel × 2^ev, where ev is the stops the
   shoulder removed (capped at 3). Core Image's `.hdrImage` writer computes the
   ISO gain map. Below the knee the two renditions are identical. Quiet scenes,
   JPEG and older systems write SDR only.

A RAW scene whose measured white fits the film domain and that has few dark
pixels renders exactly as before; the native test
`testQuietRawSceneKeepsOriginalRenderingAndHighlightsRollOff` checks byte
equality with the original operator.

## Verification

- `verification/verify_scene_tone.py` (Linux, compiles the app's C++): exact
  identity, monotonic tone for every allowed setting (minimum log–log slope
  0.175), measured white → film white, hue preservation below the path to white,
  neutral film white, the grey anchors, HDR gain restoring the folded stops, and
  scene measurement and choice.
- `HassyNaturalTests/SceneToneTests.swift` (hosted simulator): Metal kernel ↔
  C++ agreement across headroom and settings, quiet-scene byte equality,
  roll-off, shadow fill, P3 retention, the gain-map HEIC (presence, provenance,
  SDR/HDR values) and public-RAW measurement.
- `HassyNaturalTests/DecoderHeadroomTests.swift` logs decoder headroom, local
  tone map and shadow-bias effects for the public fixture.

These are simulator and portable checks. They are not phone captures and do
not establish calibrated HNCS equivalence.

## Limits and next steps

- **Grey-card calibration (phone).** Photograph an 18% card filling the centre
  in even daylight with ProRAW. Read the linear value at the card after
  BaselineExposure (the app's provenance records BaselineExposure). If it lands
  near 0.18, set `HN_RAW_FILM_EXPOSURE` to 0.125/0.18 so the card renders at
  sRGB 118–119 as on Hasselblad Standard. If it lands near 0.125, keep 1.
- **Parameters** (knee, 2.5-stop cap, fill strength and thresholds) are research
  starting points. Tune them against the owner's photographs with before/after
  boards rendered through the actual app on the hosted simulator.
- **Local adaptation** (edge-aware, gated by scene contrast) and a partial Apple
  `localToneMapAmount` are deliberately not shipped. The X2D documents no local
  tone mapping, and both risk an HDR look. Evaluate them on real backlit scenes
  first.
- The 2007 fallback chroma table and fixed illumination model are unchanged.
  The illumination-interpolation research (`PROFILE-INTERPOLATION.md`) needs
  the original lab's tungsten/daylight tables, which are not in this repository.
- `shadowBias` stays at Apple's per-image default (Apple's linear recipe sets
  0); the hosted probe reports its effect for the public fixture.
