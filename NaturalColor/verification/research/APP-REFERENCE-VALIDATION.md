# Application operator public-reference reality check

The portable application core was run directly on all three previously acquired and registered official Hasselblad RAW/companion pairs. No color, exposure, white-balance, or curve parameters were fitted to the companions. Input was the previously registered LibRaw baseline, decoded from sRGB to linear sRGB. Output used the selected recovered fallback chroma table, nativeScale1, recovered native-domain Standard film with **floor indexing**, declared native gamma decoding, nativeRGB-to-linear-sRGB bridge, and ordinary sRGB export. This directly evaluates the C++ per-pixel operator, without RGB-cube interpolation.

| Pair | Baseline median DE76 | Recovered median DE76 | Baseline median absΔL | Recovered median absΔL | Baseline median ab distance | Recovered median ab distance |
|---|---:|---:|---:|---:|---:|---:|
| x1d-II-sample-02 | 15.164 | 10.879 | 12.586 | 7.817 | 7.284 | 7.247 |
| x1d-II-sample-06 | 23.308 | 16.661 | 22.547 | 13.102 | 5.933 | 10.334 |
| x1d-ii-xcd45p-01 | 9.293 | 4.917 | 8.059 | 3.511 | 2.988 | 2.860 |

These are descriptive residuals against published appearances, not color-chart accuracy or controlled Phocus equivalence. A larger recovered residual means this fixed shared model moved that scene farther from the published rendering; a smaller one establishes only a closer appearance for that particular scene. No parameters were changed in response to the results.

The source processing settings are undocumented; sample02 has Photoshop metadata. LibRaw calibration differs from Phocus. The chosen2007 fallback profile is not a modern camera-specific profile. Prior downsampling, 8-bit sRGB rounding and grayscale-based alignment remain baked into the input arrays. The app's gamma/Bradford bridge is an explicit adaptation. Consequently these results cannot isolate the proprietary stages or establish HNCS equality.

Complete metrics, component residuals, source metadata and panel paths are in `/workspace/hassy-natural/verification/public-image-results.json`. Panels show published companion, LibRaw baseline, and recovered model from left to right in `/workspace/hassy-natural/verification/public-comparisons/`. Reproduce with `python3 /workspace/hassy-natural/verification/compare_public_hncs.py --lab /workspace/hncs-lab`. Requires numpy, Pillow, SciPy, a C++17 compiler and the existing lab arrays.

## RGB cube approximation

The direct public-image results above evaluate the portable operator. RGB cubes were investigated as an alternative; the current app instead evaluates the 2D chroma and film tables directly with a Metal Core Image kernel. The following measurements document the rejected approximation route. A separate seeded numerical check evaluates 8,192 random colors, 4,096 shadow colors in linearRGB[0,.02], and a4,097-point neutral ramp against the direct C++ operator. For a65³ cube, shaping grid input with power2 reduces shadow p95 maximum-channel encoded-sRGB error from4.615 to0.293 8-bit levels, and shadow maximum error from6.931 to0.885 levels. Neutral p95 error is0.077 levels. Random-color p95 error is0.157 levels, with a rare maximum9.680 levels near nonlinear/clipped/boundary regions. These are approximation errors, not color-accuracy measurements.

A128³ shaped cube reduces random p95 error to0.046 levels and maximum to2.018 levels; shadow p95 is0.087 and maximum0.609 levels. Core Image's actual interpolation, color handling and GPU precision still require iOS validation. An implementation using the alternative cube must apply `pow(linearRGB,.5)` before a power2-shaped cube; its cube samples evaluate the recovered operator at `linearRGB=q²`. Strength blends the original linear RGB with the recovered result before cube storage. The measured source operator preserves the fragment's unusual boundary discontinuities, which no smooth RGB cube reproduces exactly. Reproduce using `/workspace/hassy-natural/verification/verify_cube_approximation.py`; complete results are in `cube-approximation-results.json` beside that script.
