# Recovered native chroma matrix contract

This is static recovery from the SHA-pinned Phocus Android 1.1.0 library, using the REA-established artifact inventory and bounded Capstone disassembly. No target native code is loaded or executed. Run `python3 scripts/trace_hncs_matrix_contract.py` to reproduce the constants and derived matrices in `evidence/hncs-matrix-contract.json`.

## Actual matrix composition

The ordinary XML-profile route in `CRawColorCorrection::InitCRawColorCorrection` uses row-major matrices and column vectors. `Matrix3x3::Row` at `0x369b028` selects three contiguous doubles; multiplication at `0x369b660` calculates the ordinary product `left @ right`.

The constant at `0x314ed90` is:

```
C = [[ 0.2989,  0.5866,  0.1145],
     [-0.1687, -0.3312,  0.5000],
     [ 0.5000, -0.4183, -0.0816]]
```

The native RGB conversion at `0x3150f00` is:

```
A = [[ 1.768049, -0.490119, -0.260191],
     [-0.805970,  1.750069,  0.032788],
     [ 0.034066, -0.093962,  1.286342]]
```

Its inverse maps neutral native RGB to approximately XYZ `(0.96420012, 1.00000014, 0.82490937)`. This numerical white is consistent with a D50 working white. It is not the D65 white of linear sRGB. No standard RGB space name is assigned to A from numerical similarity alone.

At `0x34c5824..0x34c5894` the matrix returned by `GetRawRGB2XYZMatrix` has its columns multiplied by the three native white-balance values. At `0x34c589c`, A multiplies that matrix. At `0x34c58d0`, C multiplies the result. At `0x34c58f8` a scalar from raw-correction `+0xb8` multiplies it. Therefore the input matrix on this route is:

```
input = C @ A @ M(T) @ diag(native_wb) * scale
```

There are alternate paths, including calibration overrides, a 1.7 scalar, and a sensor-conditioned adjustment to the output matrix; the expression is not asserted for every enum or mode. XML `SetupCC` at `0x34c8c50` copies its two matrix arguments to correction `+0x08` and `+0x50`. Its separate `CalculateMatrix` result goes to `+0xf0`; it does not apply an additional sensor matrix to those copies at setup.

`GetRawRGB2XYZMatrix(T,...)` calls `CXMLLut::CalculateMatrix` for nonzero T (`0x34cab94`). Thus the profile mf/mt/etc interpolation is a sensor calibration front end into XYZ, not a creative look to apply after an existing phone RAW decoder. When T is zero it calls `GetColorMatrixDNG`. The 32-byte getter at `0x350394c` copies nine doubles from XML object `+0x168`, the field loaded from **mfd**. This establishes a distinct DNG matrix path; mfd must not be substituted for the interpolated matrix indiscriminately.

The output starts with `inverse(C)` and is multiplied by `GetColorSpaceChangeMatrix(working_enum)` at `0x34c596c`. GPU preparation divides its two chroma columns by the LUT divisor. Actual generic output-space constants are present in `evidence/hncs-matrix-functions.json`, but human enum labels and all runtime global initialization are not inferred here.

## Explicit phone integration contract

A decoder returning **white-balanced linear sRGB D65** has already performed sensor calibration. Applying a Hasselblad M or native sensor WB to it would be unsupported double calibration. A defensible shared chroma model can instead:

1. Convert documented linear sRGB to XYZ and Bradford-adapt its white to the recovered native white.
2. Apply A and C, using the selected recovered chroma table, its actual start, dimensions and divisor.
3. Reconstruct native RGB using the recovered fragment's inverse-C chroma columns divided by that divisor.
4. Apply a separate full matrix from native RGB back to the original linear-sRGB domain.

`phone_adapter.input_matrix_rows`, `shader_native_output_rows` and `post_shader_native_rgb_to_linear_srgb_rows` contain those coefficients. Pad rows with zero for vec4 uniforms; divide the shader-native-output chroma columns by the resource divisor. The adaptation is a declared standards-based integration choice, **not a recovered Apple calibration or proof of phone HNCS equivalence**. A selected Hasselblad chroma table is a chosen shared color model until calibrated/validated on phone images. Keep its model identity explicit.

The fragment has an important quirk: it ignores output matrix column zero and adds Y directly to each output channel. C's chroma rows sum to 0.0001, so inverse(C)'s luminance column is only approximately one. An ordinary inverse-matrix round trip is not proof of fragment identity. With the native forced `[1,1,1]` luminance column, the no-table effective matrix differs from identity by up to **0.000103879** per coefficient. Preserve that behavior when matching the fragment. Combining every conversion into a single inverse adapter and assuming a full matrix dot product silently changes the recovered shader. Separate native reconstruction and post-conversion preserve its arithmetic contract.

## Verification and remaining limits

The extraction script checks the complete ELF SHA, reads constants through ELF64 PT_LOAD mappings, and produces reproducible numeric inverses; the algebraic adapter inverse round trip has maximum error below 3e-16. This is matrix verification, not an image-quality score. The previously isolated CPU/GPU shader comparison remains separate evidence.

This contract removes the need to guess a sensor matrix for already color-managed phone RAW decoding. Remaining image-fidelity limits are the decoder's actual linear output/white balance, LUT selection and illumination defaults, exposure normalization, tone/film processing, enum-specific routes, and comparison with controlled Phocus output. They must be reported rather than hidden behind a generic saturation or warmth filter.
