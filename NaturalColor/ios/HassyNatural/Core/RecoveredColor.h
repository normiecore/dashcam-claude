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
/* Scene tone stage, applied to white-balanced linear sRGB before the recovered
 * operator (application policy, documented in SCENE-TONE.md; not recovered
 * Phocus code). exposure scales the decode into the Standard curve's design
 * domain, where 0.125 renders as display middle grey and 1.0 as white.
 * compression folds that many stops of measured highlight range into the
 * film shoulder using a hue-preserving max(R,G,B) gain; shadowFill lifts lower
 * midtones by up to that many EV and leaves middle grey and blacks alone.
 * The identity is {1, 0, 0}. */
typedef struct {
    float exposure;
    float compression;
    float shadowFill;
} hn_scene_tone;
/* Robust statistics of a decoded RAW image, measured before edit exposure.
 * white: 99.5th percentile of max(R,G,B); darkFraction: share of pixels more
 * than 2.5 stops below 0.18 luminance. */
typedef struct {
    float white;
    float darkFraction;
} hn_scene_stats;
#define HN_FILM_MIDDLE_GREY 0.125f
#define HN_SCENE_MIDDLE_GREY 0.18f
/* Exposure applied to Apple's decode (BaselineExposure included). 1 keeps the
 * 0.1.1 placement. Apple's ProRAW gain table carries part of its exposure
 * intent, so where an 18% card lands is unmeasured; a grey-card calibration
 * may later justify HN_FILM_MIDDLE_GREY/HN_SCENE_MIDDLE_GREY instead. */
#define HN_RAW_FILM_EXPOSURE 1.0f
#define HN_MAX_COMPRESSION 2.5f
#define HN_MAX_SHADOW_FILL 0.6f
/* Gain-scaled rgb; out may alias rgb. Success=1, invalid argument=0. */
int hn_apply_scene_tone(const float rgb[3], const hn_scene_tone* tone, float out[3]);
/* rgba: count pixels of 4 floats in linear sRGB. Non-finite pixels are ignored. */
int hn_measure_scene(const float* rgba, size_t count, hn_scene_stats* out);
/* Chooses the tone for a RAW decode measured by hn_measure_scene, given the
 * user's edit exposure in EV (applied before this stage). */
int hn_choose_scene_tone(const hn_scene_stats* stats, float exposureEV, hn_scene_tone* out);
/* hn_apply_scene_tone followed by hn_recovered_pixel_with_curve. */
int hn_toned_pixel_with_curve(const float rgb[3], const hn_scene_tone* tone, const float* cbcr,
    size_t width, size_t height, float cbStart, float crStart, float div,
    float nativeScale, const float* film, size_t filmCount, float out[3]);
#ifdef __cplusplus
}
#endif
#endif
