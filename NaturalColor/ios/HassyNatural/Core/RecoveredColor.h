#ifndef HN_RECOVERED_COLOR_H
#define HN_RECOVERED_COLOR_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* White-balanced linear sRGB D65 -> linear sRGB D65, no film/tone/transfer.
 * cbcr is row-major height*width*2 float pairs. cbStart/crStart equal shader
 * uStartCbCr: the actual profile bounds (e.g. -20,-32). Success=1, invalid argument=0.
 * nativeScale only controls recovered desaturation threshold15500/scale;
 * it does not apply exposure or phone sensor calibration. Caller chooses it.
 * Output can be outside[0,1]; clip/gamut-map at export, not in this operator.
 * Exact black returns zero: explicit finite production policy, whereas the
 * original fragment's gray calculation is undefined at exactblack. */
int hn_recovered_pixel(const float rgb[3], const float* cbcr,
    size_t width, size_t height, float cbStart, float crStart,
    float div, float nativeScale, float out[3]);
/* Standard film in nativeRGB, then explicit native gamma2.19921875 decode,
 * then linear-sRGB postmatrix. film must contain65536 normalized samples. */
int hn_recovered_pixel_with_curve(const float rgb[3], const float* cbcr,
    size_t width, size_t height, float cbStart, float crStart, float div,
    float nativeScale, const float* film, size_t filmCount, float out[3]);
/* Core Image cube: red varies fastest, alpha1; capacity counts floats.
 * Strength blends in linear sRGB. Final cube storage clamps RGBto[0,1]. */
int hn_make_reference_cube(float* rgba, size_t capacity, unsigned n, float strength,
    const float* table, size_t width, size_t height, float cbStart, float crStart,
    float div, float nativeScale, const float* film, size_t filmCount);
/* Shaped input coordinates: app applies pow(linearRGB,1/inputPower) before
 * cube lookup; nodes evaluate pow(q,inputPower). Strength still blends linear. */
int hn_make_reference_cube_shaped(float* rgba, size_t capacity, unsigned n, float strength,
    const float* table, size_t width, size_t height, float cbStart, float crStart,
    float div, float nativeScale, const float* film, size_t filmCount, float inputPower);
#ifdef __cplusplus
}
#endif
#endif
