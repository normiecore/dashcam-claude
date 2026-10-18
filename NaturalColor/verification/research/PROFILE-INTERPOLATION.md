# Recovered native profile interpolation

`profile_interpolation.py` implements the observed modern XML matrix and CbCr-table interpolation branches. This replaces the earlier interpolation hypothesis with bounded static evidence. It does not identify which sensor profile belongs to an iPhone, turn a Hasselblad sensor matrix into an RGB look, or establish a complete renderer.

Evidence is the official Phocus Android 1.1.0 ARM64 ELF SHA-256 `d757237554529f8ab485f88f2c5e5399fbc8d56035c79b8e057b41a40fd055e4`. REA's investigation workflow was used with the already recovered archive/layout evidence and Capstone fallback because a native decompiler provider is unavailable. New evidence files are custom static records, not REA Evidence IDs. No APK/native target code was executed.

## Matrix contract

`CXMLLut::CalculateMatrix` is VA `0x350444c`, 1716 bytes. `profile-interpolation-disassembly.json` retains original instruction bytes and verified PLT relocations. Version strings are compared literally with `3.0`; the portable implementation accepts only the three observed versions, `1.0`, `2.0`, `3.0`.

The inputs are the decoded XML plist dictionary and signed integer Kelvin. Selected matrix fields are affine-decoded as `0.5*x+1`, once. The result has nine doubles in original coefficient order. This function neither transposes the matrix nor asserts its input/output color-space semantics.

For `tlt != tt`, the native path clamps input Kelvin to `[2000,8000]`, or `[2000,10000]` for Version 3, then selects:

| Effective temperature | Low matrix / anchor | High matrix / anchor |
|---|---|---|
| T < tt | mlt / tlt | mt / tt |
| T >= tt, earlier versions | mt / tt | mf / tf |
| tt <= T < tf, Version 3 | mt / tt | mf / tf |
| T >= tf, Version 3 | mf / tf | mh / th |

Branch setup is visible at `0x3504554..0x3504648` and high-temperature setup at `0x3504a50..0x3504a9c`. Interpolation at `0x35048ec..0x35049b4` uses **Kelvin**, not reciprocal temperature: slope `(Mhi-Mlo)/(Thi-Tlo)`, intercept `Mhi-slope*Thi`, result `slope*T+intercept`. There is no clipping of the blend weight to `[0,1]`: temperatures below `tlt` or above the final anchor extrapolate, subject to the input cap.

When `tlt` is absent, `DecodeFrom` copies `tt` to `tlt` and `mt` to `mlt` at `0x3506524..0x3506548`. For the `tt == tlt` branch, native code uses only mt/tt and mf/tf and consults `cplowlimit` / `cpnolowlimit`. The implementation's `equal_anchor_low_limit` must reflect an explicitly selected policy: `None` means no lower cap; an integer enables that lower cap. This is not a claim about the application's preference defaults. At equal `tf == tt`, native code copies mt (`0x35049dc..0x3504a20`).

The math is equivalent at float64 precision; ARM64 fused operations and NumPy separated operations can differ in final bits. Do not claim bit-exact native execution from the independent reference.

## LUT contract and important differences

`CXMLLut::CalculateLUT` is VA `0x3504b00`, 2532 bytes. `reproduction=False` selects FlashStd/TSStd/HTStd; true selects Repro variants (`0x3504b80..0x3504ba0`, `0x3504df0..0x3504e1c`). Arrays contain consecutive pairs of doubles; they do **not** receive the matrix affine decode.

Version 3 jumps directly from the version test at `0x3504cd0..0x3504d00` to `0x3504df0`. This bypasses the preference-dependent gate used by earlier versions. It clamps Kelvin to `[2000,10000]`. Below tf it interpolates TS/tt and Flash/tf; at and above tf it interpolates Flash/tf and HT/th. It uses neither tlt nor a separate low-temperature table. The arithmetic at `0x3505138..0x3505190` and `0x3505198..0x35051f0` is direct Kelvin linear interpolation, with extrapolation allowed by the input bounds.

For earlier versions, the caller must supply the already resolved boolean result of `CPInterpolateLUT` / `CPNoInterpolateLUT` as the required `interpolate` keyword. False copies Flash unchanged. True blends TS/tt and Flash/tf, but **clamps Kelvin to `[2000,6200]`**, not the matrix's 8000 maximum (`0x3504d28..0x3504d40`). An exact original input of `tf` bypasses the blend and copies Flash (`0x3504d04..0x3504d14`). Equal tf/tt on the blending route copies TS; the exact-tf bypass still takes precedence. Preference defaults and mutation of the base-object flag at offset +9 have not been established, so no implicit preference default is invented.

## Verified grid layout

The result is passed into `Scaled2DLUT::FromCbCrData` (`0x369a440`, 568 bytes), recorded in `evidence/profile-lut-layout-disassembly.json`. Its arguments are source pointer, CbS, CbE, CrS, CrE, DivFactor. It allocates width `CbE-CbS+1`, height `CrE-CrS+1`, and copies source pairs row by row without flipping or arithmetic (`0x369a4f8..0x369a5d0`). Therefore the verified portable array shape is `[Cr_count, Cb_count, 2]`, with Cb moving fastest. Object metadata stores offsets `(-CbS,-CrS)` and scale fields equal to DivFactor (`0x369a46c..0x369a4a4`). The native conversion does not divide table values by DivFactor.

This proves the CPU table layout before GPU upload. Subsequent texture encoding, shader coordinate behavior, output matrix preparation and sensor calibration remain separate stages. The existing shader reference documents their own evidence boundaries.

## Verification and boundaries

Eight tests in `tests/test_profile_interpolation.py` cover hand-derived matrix branches, Kelvin rather than reciprocal weighting, clamping versus extrapolation, missing low-anchor fallback, equal-anchor behavior, explicit low-limit policy, Version 3 preference bypass, standard/reproduction selection, verified grid order and strict refusal of malformed selected tables.

The full local corpus run exercises all 22 modern profiles at nine temperatures, with matrices and both LUT modes. `evidence/profile-interpolation-corpus.json` records source hashes, selected anchors, effective temperatures, weights, shapes and output hashes. Only the already documented malformed `atrsjhfdpwin6lcabrqg` selected TS tables fail, as intended. Four legacy profiles are excluded. This is consistency/regression coverage of the static reconstruction, not a native-runtime or Phocus-image oracle.

Reproduce focused tests with `python3 -m unittest discover -s tests -p test_profile_interpolation.py -v` from the lab directory. Recreate static records with `PYTHONPATH=analysis-tools python3 scripts/native_disassemble.py artifacts/libcrosssdk.so evidence/profile-interpolation-disassembly.json CalculateMatrix CalculateLUT` and the same command selecting `FromCbCrData` into `evidence/profile-lut-layout-disassembly.json`.
