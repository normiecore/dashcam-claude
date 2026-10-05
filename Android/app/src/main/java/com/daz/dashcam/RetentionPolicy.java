package com.daz.dashcam;

/** Platform-independent retention rules. All times are epoch milliseconds. */
public final class RetentionPolicy {
    public static final long ROLLING_MS = 300_000L;
    public static final long TAIL_MS = 30_000L;
    public static final long SEGMENT_MS = 10_000L;
    private RetentionPolicy() { }

    public static boolean overlaps(long start, long end, long windowStart, long windowEnd) {
        return start <= windowEnd && end >= windowStart;
    }

    public static boolean canDelete(long start, long end, boolean complete,
            boolean uncertain, boolean protectedFootage, long now) {
        return complete && !uncertain && !protectedFootage && start >= 0
                && now >= ROLLING_MS && end >= start
                && end < now - ROLLING_MS;
    }
}
