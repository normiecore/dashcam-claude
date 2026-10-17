# Standard curve integration and conditional HDR gamma

The post-film gamma filter is **not an unconditional SDR stage**. Static reconstruction of `CameraImageAndroid::AddHNCSFilters` at `0x34bb504` resolves the previously listed call order into a conditional route. No proprietary code was executed.

Source ELF SHA-256: `d757237554529f8ab485f88f2c5e5399fbc8d56035c79b8e057b41a40fd055e4`. Focused disassembly with validated PLT names is `evidence/native-gamma-integration.json`; its call summary is `evidence/native-gamma-integration-calls.txt`. This is static Capstone evidence, not a claim of REA runtime observation. The matching existing gamma fragment is `evidence/shaders/shader-030ffce0.glsl`.

## Recovered route selection

At `0x34bb560..0x34bb574`, the builder reads the correction integer at `+0x428` and byte at `+0x2b0`. It stores this exact Boolean gate:

```
extended_route = (correction.integer_at_0x428 > 3) &&
                 (correction.byte_at_0x2b0 != 0)
```

At `0x34bb728..0x34bb72c`, a false gate jumps to `0x34bb7e4`, skipping all post-film gamma construction. A true gate reaches `CGammaFilter` construction at `0x34bb768`; its constructor bool is `(correction.integer_at_0xe4 == 1)`. Another condition inserts a highlight-strength filter for film enums 2 and 4 before returning to gamma construction, but does not change the gate.

`CFilmCurveFilter::CreateLinearCurve` uses the **same two-field gate** at `0x34c20d4..0x34c20e4`. True calls `GetGradationCurveHDR` at `0x34c2144`. False calls the ordinary `GetGradationCurve` at `0x34c2194`, then normalizes the selected integer-valued table by float32 `1/65535`. Thus the ordinary Standard LUT and the separately observed post-film gamma are not evidence that normal Standard processing needs two encodings.

## Actual gamma math

`CGammaFilter::HasselbladGamma` at `0x3369d50` computes `pow(x, .4547069271758437)`, where the exponent is the same constant used before the Standard spline; its reciprocal is exactly `2.19921875` in binary arithmetic.

The CPU filter normalizes its uint16 input by 65535, multiplies by `49.26108374384236`, calls the selected gamma function and divides by `5.8829245141`, then rounds to nearest with ties away from zero, clamps and stores uint16. For the power gamma branch, `49.26108374384236 ** .4547069271758437 / 5.8829245141` is approximately `0.9999999999940665`; the gain/normalization preserve the power curve while supporting the extended domain.

The GPU route supplies literal shader keys `gamma_hasselblad` or `gamma_lstar` based on the stored bool. Its `uGammaHasselbladRgb` is float32 `2.19921875`; the recovered matching shader uses `pow(pixProc, vec3(1.0 / uGammaHasselbladRgb))`. Its two gain uniforms are float32 versions of the CPU constants. The L* branch supplies epsilon `.008856452070176601` and kappa `903.2963256835938`; its independent CPU function uses the same L* piecewise mapping recovered in STANDARD-CURVE.md.

## App integration contract

For the chosen ordinary Standard gamma route, the generated Standard LUT already emits gamma-companded **native working RGB** values. Its spline is not a plain linear-to-linear contrast map. Applying those encoded values as if they were linear RGB into an sRGB matrix or a linear Core Image context would produce erroneous tone and color, followed by another output encoding.

The app's explicit adaptation for a linear Core Image working pipeline is:

1. Decode the source through Core Image into linear sRGB, with any Apple RAW preprocessing separately recorded.
2. Convert into the reconstructed native working RGB basis and perform the recovered chroma stage.
3. Apply the ordinary Standard LUT per native RGB channel.
4. Raise the nonnegative Standard result to `2.19921875` **before** the matrix from native working RGB to linear sRGB.
5. Let the output color-management path perform the requested final display encoding once.

Step 4 is the inverse transfer adaptation required by the app's linear working-space contract. It is not a newly discovered proprietary post-film filter, and it does not imply that the ordinary native route invokes `CGammaFilter`. This pipeline still relies on the native working RGB interpretation and chosen SDR enum; phone calibration, caller defaults and complete proprietary output-color-management behavior are separate evidence boundaries.

If using the L* Standard resource instead, inverse-power decoding is wrong: invert normalized L* with its own piecewise transfer. Do not silently swap the two resources or apply both the recovered gamma filter and automatic output encoding.

## Film lookup is per channel and discrete

The `filmcurve_fragmentShaderSource` pointer at VA `0x37d7c50` has a relative relocation addend `0x30cec42`. Its exact null-terminated source is retained in `evidence/shaders/filmcurve-30cec42.glsl`. Another legacy `filmCurveShader` pointer at `0x37d6968` points to `0x3128ee7`; its corresponding source is also retained separately.

The matching fragment performs `rgb.rgb /= uGain`, then looks up R, G and B independently. It calculates `index = clamp(rgb * (width*height), 0, width*height-1)` and uses `floor` in both texture coordinates to select the integer sample center. Thus it is **per-channel mapping, not luminance-preserving RGB scaling**, and the intended coordinate behavior is discrete lookup rather than interpolation across neighboring scalar samples. The LUT texture is constructed 2048×32, giving 65,536 entries. Ordinary SDR initialization explicitly sets filter field `+0x78` (the supplied `uGain`) to float32 1 at `0x34c2168..0x34c2170`; the extended route computes a gain reduction instead.

For a native-like SDR lookup use `floor(clamp(channel*65536,0,65535))`. Earlier tentative advice to interpolate neighboring samples would be an application smoothing choice, not this recovered shader's exact rule. The CPU route indexes by its uint16 pixel coordinate and has different intermediate quantization; claiming CPU/GPU bitwise equality would be unsupported.
