# Standard film curve: implemented static recovery

This pass reconstructs the actual `CGradation` Standard initialization route, including its fixed base table and natural cubic spline. It replaces no stage with an assumed S curve. The target APK and native library were not executed. Runtime/native bitwise equivalence and default selection for every camera remain unmeasured.

The source is Phocus Android 1.1.0 `libcrosssdk.so`, SHA-256 `d757237554529f8ab485f88f2c5e5399fbc8d56035c79b8e057b41a40fd055e4`. Focused instruction evidence, code hashes, transformed controls and output anchors are retained in `evidence/standard-curve-recovery.json`. Earlier evidence remains in `native-film-functions.asm`.

## Exact observed contracts

`InitGradationCurves` at `0x3694040` calls `CGradation(bool,double*,double*,int,bool,bool)` at `0x3694a54` with `gamma=true`, the six default control points, `count=6`, `linear=false`, and final bool false. Its 65,536 unsigned-16 samples become integer-valued float32 at `0x4e93a34`. The same constructor with final bool true produces `0x4ed3a34`. These are the observed Standard gamma and alternate L* branches. Their selection is the enum-dependent behavior already recorded in FILM-CURVE.md; this does not prove which enum Apple phone input should use.

The sample coordinate is `i/65536`, `i=0..65535`. The last processing result is multiplied by 65,536, clamped to `[0,65535]`, truncated toward zero and stored as unsigned 16 bits. The film filter subsequently normalizes by float32 `1/65535`.

The constructor is more than a spline over six points:

1. Transform the coordinate through two piecewise quadratics, each split at 0.25.
2. Interpolate a **literal 1025-double base table** copied from VA `0x31871a8` by initializer `0x36957f8` into global vector `0x4f93aa0`. The 8,200-byte table is file-backed; the initializer performs `memcpy`, not an analytic generation. For positive input above `1e-7`, mix 25% of this lookup raised to 1.8 with 75% of the input. Native code expresses this as a gain division followed by multiplication.
3. Transform by a third piecewise quadratic, split at 0.25.
4. Raise to `0.4547069271758437` when the constructor gamma flag is true.
5. Evaluate a **natural cubic spline** over the transformed control points, again using spline/input as a gain. `CCubicSpline::init` at `0x3673d04` passes `9.9e31` for both endpoint derivatives; `spline` at `0x36739dc` treats that sentinel as natural zero second derivatives. `splint` at `0x3673c1c` implements the cubic interpolation and boundary segment extrapolation.
6. For the final bool true route, raise the spline output to `2.19921875`, then encode normalized CIE L*: below/equal `0.008856451679035631`, multiply by `903.2962962962963/100`; otherwise `1.16*cbrt(v)-0.16`.
7. Quantize as above.

The six original x coordinates are `[0,.125,.25,.5,.75,1]`, y `[0,.0859375,.21875,.5,.76171875,1]`. Except the zero origin, native code maps x to `x*.9170589313597891` below `.45852946567989455`, otherwise `x*1.0829410686402108-.08294106864021078`, and replaces y by `new_x*old_y/old_x`.

The three preparatory functions, with the high branch expressed as `a*v*v+b*v+c`, are:

| Stage | low branch (v≤.25) | high a | high b | high c |
|---|---:|---:|---:|---:|
| 1 | `v*1.2201699047004935` | -.3914131639119884 | 1.4158764866564877 | -.02446332274449925 |
| 2 | `v*1.4142135623730951` | -.736379666441058 | 1.782403395593624 | -.04602372915256603 |
| 3 | `v*.8195579944626342` | .32078578762198356 | .6591651006516425 | .020049111726374025 |

The fixed base table is required to reproduce this route. No generating formula was recovered. It is retained as mathematical samples with byte identity in `evidence/standard-curve-base.json`; it is not silently substituted with an invented analytic function.

## Implementation and checks

`standard_curve_reference.py` independently implements these mathematical operations in NumPy. `scripts/recover_standard_curve.py` verifies the exact source ELF SHA-256, extracts the literal base table, retains the focused disassembly and generates two independently computed 65,536-sample LUT files. It never loads or calls target code.

Six focused tests pass. In addition to shape, quantization, monotonicity and fixed-table identity checks, the reconstructed cubic interpolator matches SciPy's independently implemented natural CubicSpline at 2,049 points, including extrapolation, within `8e-16`. This validates the mathematical translation, not execution parity with Hasselblad.

The app has an independent C++ implementation in `Core/StandardCurve.cpp`. Its public C function requires an explicit base table, 65,536 destination samples and an L* flag; it has no approximation fallback. Built on this Linux host with C++17 and floating point contraction disabled, its generated normalized outputs match the Python outputs **at all 65,536 samples in both branches**. Evidence: `evidence/standard-curve-cpp-check.json`. Neither implementation executes the target.

For immediate app consumption, `Resources/StandardCurve.f32` contains the independently generated normalized Standard gamma LUT, little-endian float32, 262,144 bytes, SHA-256 `b3324e976976df34b5f6ecbd4c4e6830a68b1b1a75c573a0800ef6f144e29598`. The sibling provenance JSON identifies source, flags, domain and limits. The executable ELF is not an app resource.

Useful integer sample anchors for the Standard gamma route: index 0→0; 256→3479; 4096→19619; 8192→30312; 16384→43922; 32768→57326; 49152→63076; 65535→65535.

## Integration limits

The input coordinate belongs to the native film stage. This is not an instruction to apply the curve directly to an already display-encoded sRGB photograph. An app must establish its working transfer function and where the film stage sits relative to camera matrix, LUT color correction and final output encoding. Native constructor flag `gamma=true` is observed; the appropriate phone adaptation and per-photo curve selection are separate application decisions.

ARM64 fused multiply-add and native `pow` implementations can change values near truncation boundaries. Agreement between independent Python and C++ implementations on this host does not establish bitwise parity with the proprietary ARM64 runtime. HDR gradation, Original curve generation, native hue recovery and sensor calibration are separate stages. The model-specific HNCS camera tables remain required for a camera-calibrated match; this curve alone is not HNCS equivalence.
