#!/usr/bin/env python3
"""Generate the simple, opaque App Store icon with Python's standard library."""

from pathlib import Path
import json
import math
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "App/Assets.xcassets/AppIcon.appiconset"
SIZE = 1024


def rounded_rect(x, y, left, top, right, bottom, radius):
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    return radius - math.hypot(x - cx, y - cy)


def circle(x, y, cx, cy, radius):
    return radius - math.hypot(x - cx, y - cy)


def blend(base, color, coverage):
    a = min(1.0, max(0.0, coverage + 0.5))
    return tuple(round(b * (1 - a) + c * a) for b, c in zip(base, color))


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def main():
    DEST.mkdir(parents=True, exist_ok=True)
    rows = bytearray()
    for py in range(SIZE):
        rows.append(0)  # PNG filter: none
        y = py + 0.5
        for px in range(SIZE):
            x = px + 0.5
            # Opaque indigo field, camera silhouette, and a road in its lens.
            color = (20, 37, 59)
            color = blend(color, (226, 241, 244), rounded_rect(x, y, 170, 278, 854, 730, 92))
            color = blend(color, (226, 241, 244), rounded_rect(x, y, 246, 224, 432, 340, 32))
            color = blend(color, (42, 151, 165), circle(x, y, 512, 506, 194))
            color = blend(color, (20, 64, 86), circle(x, y, 512, 506, 166))
            lens = circle(x, y, 512, 506, 158)
            if lens > -1:
                # Perspective road, clipped to the round lens.
                progress = max(0.0, min(1.0, (y - 383) / 264))
                half_width = 28 + 117 * progress
                road = min(x - (512 - half_width), (512 + half_width) - x, lens)
                color = blend(color, (56, 125, 139), road)
                if 416 < y < 634 and abs(x - 512) < 5 + 3 * progress:
                    dash = ((int(y) - 416) // 45) % 2 == 0
                    if dash:
                        color = blend(color, (239, 246, 229), lens)
            rows.extend(color)

    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")
    (DEST / "AppIcon.png").write_bytes(png)
    contents = {"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}
    (DEST / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n")


if __name__ == "__main__":
    main()
