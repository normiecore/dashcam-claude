#ifndef NATURAL_COLOR_H
#define NATURAL_COLOR_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Linear sRGB input/output. Original independent Hassy Natural v0.2.2 treatment.
void hn_natural_pixel(const float input[3], float strength, float output[3]);
// Core Image cube order: red varies fastest, followed by green, then blue.
int hn_make_cube(float *rgba, size_t capacity, unsigned dimension, float strength);
#ifdef __cplusplus
}
#endif
#endif
