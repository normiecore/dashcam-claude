#!/usr/bin/env python3
"""Accelerated policy simulation using the app's compiled C engine.

This does NOT encode video, execute Swift persistence, or simulate Apple hardware.
It stresses policy decisions for a 12-hour drive, overlapping incidents, a stop,
an unfinished file, and quota pressure. Run Tools/test-core.sh first.
"""
import ctypes as c
import json
import platform
from pathlib import Path

root = Path(__file__).resolve().parents[1]
suffix = "dylib" if platform.system() == "Darwin" else "so"
policy = c.CDLL(str(root / f".build/portable/libretention.{suffix}"))


class Window(c.Structure):
    _fields_ = [("start", c.c_double), ("end", c.c_double)]


policy.rp_is_expired.argtypes = [c.c_double] * 3
policy.rp_is_expired.restype = c.c_bool
policy.rp_segment_protected.argtypes = [c.c_double, c.c_double, c.c_bool, c.POINTER(Window), c.c_size_t]
policy.rp_segment_protected.restype = c.c_bool
policy.rp_may_delete.argtypes = [c.c_bool] * 3
policy.rp_may_delete.restype = c.c_bool
policy.rp_has_recording_reserve.argtypes = [c.c_uint64] * 3
policy.rp_has_recording_reserve.restype = c.c_bool

windows = []
segments = []
deleted = set()
max_unprotected = 0
trigger_times = {360, 370, 21600, 43000}
for now in range(10, 43201, 10):
    segments.append((now - 10, now))
    if now in trigger_times:
        windows.append((now - 300, now + 30))
    array = (Window * len(windows))(*(Window(*w) for w in windows))
    survivors = []
    unprotected = 0
    for start, end in segments:
        protected = policy.rp_segment_protected(start, end, False, array, len(windows))
        if policy.rp_is_expired(end, now, 300) and policy.rp_may_delete(True, protected, False):
            deleted.add((start, end))
        else:
            survivors.append((start, end))
            unprotected += not protected
    segments = survivors
    max_unprotected = max(max_unprotected, unprotected)
    assert unprotected <= 30, f"rolling window exceeded at {now}"

# Every segment intersecting an incident survives all later cleanup passes.
expected = {(s, s + 10) for s in range(0, 43200, 10)
            if any(max(s, a) < min(s + 10, b) for a, b in windows)}
assert expected.issubset(set(segments)), "incident footage was deleted"
assert expected.isdisjoint(deleted)
assert not policy.rp_may_delete(False, False, False), "open file was deletable"
assert not policy.rp_may_delete(True, False, True), "uncertain file was deletable"

# Interrupted tail still pins existing footage; future data is not invented.
interrupted = (Window * 1)(Window(0, 330))
assert policy.rp_segment_protected(290, 0, True, interrupted, 1)
assert not policy.rp_has_recording_reserve(249 * 1024**2, 10 * 1024**2, 250 * 1024**2)
assert not policy.rp_has_recording_reserve(2**64 - 1, 2**64 - 1, 250 * 1024**2)

report = dict(simulated_hours=12, input_segments=4320, incidents=len(windows),
              protected_segments=len(expected), remaining_segments=len(segments),
              deleted_unprotected_segments=len(deleted), max_unprotected_segments=max_unprotected,
              result="PASS", scope="production C policy only; no Swift/media/device execution")
print(json.dumps(report, indent=2))
(root / ".build/portable/simulation.json").write_text(json.dumps(report, indent=2) + "\n")
