#include "RetentionPolicy.h"

#include <math.h>

bool rp_interval_overlaps(double start, double end, double window_start, double window_end) {
    return isfinite(start) && isfinite(end) && isfinite(window_start) &&
           isfinite(window_end) && end > start && window_end > window_start &&
           start < window_end && window_start < end;
}

bool rp_segment_protected(double start, double end, bool is_open,
                          const RPWindow *windows, size_t window_count) {
    if (!isfinite(start) || (!is_open && (!isfinite(end) || end <= start)) ||
        (window_count > 0 && windows == NULL)) {
        return true; /* Invalid metadata is uncertain, so fail closed. */
    }
    for (size_t i = 0; i < window_count; ++i) {
        if (!isfinite(windows[i].start) || !isfinite(windows[i].end) ||
            windows[i].end <= windows[i].start) {
            return true;
        }
        if (is_open ? start < windows[i].end
                    : rp_interval_overlaps(start, end, windows[i].start, windows[i].end)) {
            return true;
        }
    }
    return false;
}

bool rp_may_delete(bool is_ready, bool is_protected, bool is_uncertain) {
    return is_ready && !is_protected && !is_uncertain;
}

bool rp_is_expired(double end, double now, double retention_seconds) {
    return isfinite(end) && isfinite(now) && isfinite(retention_seconds) &&
           retention_seconds > 0.0 && now >= end &&
           end <= now - retention_seconds;
}

bool rp_has_recording_reserve(uint64_t available_bytes,
                              uint64_t estimated_next_bytes,
                              uint64_t reserve_bytes) {
    return estimated_next_bytes <= available_bytes &&
           reserve_bytes <= available_bytes - estimated_next_bytes;
}
