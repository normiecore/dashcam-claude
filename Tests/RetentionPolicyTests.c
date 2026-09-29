#include "RetentionPolicy.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>

static unsigned long checks;
#define CHECK(x) do { ++checks; if (!(x)) { \
    fprintf(stderr, "FAILED %s:%d: %s\n", __FILE__, __LINE__, #x); return 1; \
} } while (0)

static uint32_t rng = UINT32_C(0xD45C4A);
static uint32_t next_random(void) {
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return rng;
}

int main(void) {
    RPWindow incident[] = {{60, 390}, {380, 710}};
    CHECK(rp_interval_overlaps(60, 70, 60, 390));
    CHECK(rp_interval_overlaps(50, 61, 60, 390));
    CHECK(!rp_interval_overlaps(50, 60, 60, 390));
    CHECK(!rp_interval_overlaps(390, 400, 60, 390));
    CHECK(!rp_interval_overlaps(1, 1, 0, 5));
    CHECK(!rp_interval_overlaps(2, 1, 0, 5));
    CHECK(!rp_interval_overlaps(NAN, 1, 0, 5));
    CHECK(!rp_interval_overlaps(0, INFINITY, 0, 5));
    CHECK(rp_segment_protected(380, 400, false, incident, 2));
    CHECK(rp_segment_protected(1, 0, true, incident, 2));
    CHECK(!rp_segment_protected(710, 0, true, incident, 2));
    CHECK(rp_segment_protected(10, 0, false, incident, 2));
    CHECK(rp_segment_protected(NAN, 20, false, incident, 2));
    CHECK(rp_segment_protected(1, 2, false, NULL, 1));
    RPWindow malformed[] = {{NAN, 30}, {20, 10}};
    CHECK(rp_segment_protected(1, 2, false, malformed, 2));
    CHECK(!rp_segment_protected(1, 2, false, NULL, 0));
    for (unsigned ready = 0; ready < 2; ready++) {
        for (unsigned protected = 0; protected < 2; protected++) {
            for (unsigned uncertain = 0; uncertain < 2; uncertain++) {
                CHECK(rp_may_delete(ready != 0, protected != 0, uncertain != 0)
                      == (ready && !protected && !uncertain));
            }
        }
    }
    CHECK(!rp_is_expired(10, 309.999, 300));
    CHECK(rp_is_expired(10, 310, 300));
    CHECK(!rp_is_expired(10, 9, 300));
    CHECK(!rp_is_expired(10, INFINITY, 300));
    CHECK(!rp_is_expired(NAN, 1000, 300));
    CHECK(!rp_is_expired(10, 1000, 0));
    CHECK(!rp_is_expired(10, 1000, -1));
    CHECK(rp_has_recording_reserve(300, 50, 250));
    CHECK(!rp_has_recording_reserve(299, 50, 250));
    CHECK(!rp_has_recording_reserve(10, UINT64_MAX, 1));
    CHECK(!rp_has_recording_reserve(UINT64_MAX, UINT64_MAX, 1));
    CHECK(rp_has_recording_reserve(UINT64_MAX, UINT64_MAX - 1, 1));

    /* Independent integer arithmetic oracle, not another copy of production C. */
    for (unsigned i = 0; i < 100000; i++) {
        int a = (int)(next_random() % 20000);
        int b = a + 1 + (int)(next_random() % 1000);
        int x = (int)(next_random() % 20000);
        int y = x + 1 + (int)(next_random() % 1000);
        int left = a > x ? a : x;
        int right = b < y ? b : y;
        CHECK(rp_interval_overlaps(a, b, x, y) == (right - left > 0));
        CHECK(rp_interval_overlaps(a, b, x, y) == rp_interval_overlaps(x, y, a, b));
        RPWindow window = {(double)x, (double)y};
        bool pin = rp_segment_protected(a, b, false, &window, 1);
        CHECK(!pin || !rp_may_delete(true, pin, false));
        uint64_t available = next_random();
        uint64_t next = next_random();
        uint64_t reserve = next_random();
        CHECK(rp_has_recording_reserve(available, next, reserve)
              == (available >= next + reserve)); /* sum fits uint64 */
    }
    printf("PASS: %lu retention/protection/reserve checks (100000 randomized cases)\n", checks);
    return 0;
}
