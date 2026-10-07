#ifndef DASHCAM_RETENTION_POLICY_H
#define DASHCAM_RETENTION_POLICY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    double start;
    double end;
} RPWindow;

/* Monotonic times must be from the same recording session. Intervals are [start, end). */
bool rp_interval_overlaps(double start, double end, double window_start, double window_end);

/* An open segment has an unknown end and can still grow into a future window. */
bool rp_segment_protected(double start, double end, bool is_open,
                          const RPWindow *windows, size_t window_count);

/* Only complete, unprotected, certain media may be considered for rolling deletion. */
bool rp_may_delete(bool is_ready, bool is_protected, bool is_uncertain);

bool rp_is_expired(double end, double now, double retention_seconds);

/* Saturating comparison: never allow integer overflow to grant recording capacity. */
bool rp_has_recording_reserve(uint64_t available_bytes,
                              uint64_t estimated_next_bytes,
                              uint64_t reserve_bytes);

#endif
