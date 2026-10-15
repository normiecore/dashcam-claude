#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Independent static reconstruction, not execution of Hasselblad code.
// 65536 native film-stage inputs i/65536 -> normalized integer output /65535.
// base contains the 1025 recovered double samples. lstar=0 is Standard gamma.
// Returns 0 on success, -1 on invalid shape/input. No implicit approximation.
int hn_make_standard_curve(float *dest, size_t count,
                           const double *base, size_t base_count, int lstar);
#ifdef __cplusplus
}
#endif
