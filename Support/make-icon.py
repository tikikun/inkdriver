#!/usr/bin/env python3
"""Generate the 8-bit app icon for InkDriver.

Pure stdlib: the pixel art is drawn as text and scaled with nearest-neighbour so
it stays crisp, written as PNGs, then packed into .icns with iconutil.

Usage: Support/make-icon.py [output.icns]     (default Support/AppIcon.icns)
"""

import os
import struct
import subprocess
import sys
import tempfile
import zlib

# A 16x16 stylus with a brass nib, drawn on a transparent canvas.
# '.' transparent, letters index PALETTE.
ART = [
    "................",
    ".........######.",
    "........#bbbbbb#",
    ".......#bbbbbb#.",
    "......#bbbbbb#..",
    ".....#bbbbbb#...",
    "....#bbbbbb#....",
    "...#bbbbbb#.....",
    "..#bbbbbb#......",
    ".#bbbbbb#.......",
    ".#bbbbb#........",
    ".#cccc#.........",
    "..#cc#..........",
    "..#.#...........",
    "..##............",
    "................",
]

PALETTE = {
    "b": (0x4A, 0x6B, 0xE8, 0xFF),   # body blue
    "c": (0xF2, 0xB8, 0x4B, 0xFF),   # brass tip
    "#": (0x1B, 0x1F, 0x2B, 0xFF),   # outline
}

SRC = len(ART)


def png_bytes(width, height, rows):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag, data):
        payload = tag + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def render(size):
    """Nearest-neighbour scale of ART to size x size. size must divide by 16."""
    assert size % SRC == 0, "size must be a multiple of %d" % SRC
    scale = size // SRC
    rows = []
    for y in range(size):
        src_row = ART[y // scale]
        row = bytearray()
        for x in range(size):
            row += bytes(PALETTE.get(src_row[x // scale], (0, 0, 0, 0)))
        rows.append(bytes(row))
    return rows


def main():
    for row in ART:
        assert len(row) == SRC, "art rows must be %d wide" % SRC

    out = sys.argv[1] if len(sys.argv) > 1 else "Support/AppIcon.icns"
    with tempfile.TemporaryDirectory() as tmp:
        iconset = os.path.join(tmp, "AppIcon.iconset")
        os.makedirs(iconset)
        # (points, scale factor) -> pixel size; iconutil requires these names.
        for points, factor in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
                               (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]:
            pixels = points * factor
            name = "icon_%dx%d%s.png" % (points, points, "@2x" if factor == 2 else "")
            with open(os.path.join(iconset, name), "wb") as handle:
                handle.write(png_bytes(pixels, pixels, render(pixels)))
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print("wrote " + out)


if __name__ == "__main__":
    main()
