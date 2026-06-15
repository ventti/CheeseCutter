#!/usr/bin/env python3
"""Convert the splash PNG into src/font/splash.dat.

Output is a raw 320x200 array of CheeseCutter PALETTE indices (one ubyte per
pixel), embedded into the binary via D's import() (string-import path
-J./src/font). Each pixel is mapped to the nearest of the 16 C64 colors used by
src/com/fb.d's PALETTE. The artwork is already 16-color, so the mapping should
be exact.

Usage: python3 tools/mk-splash.py [CheeseCutterEXT.png] [src/font/splash.dat]
"""
import sys
import zlib
import struct

# First 16 PALETTE entries from src/com/fb.d (Colodore/Pepto C64 palette).
PALETTE = [
    (0x00, 0x00, 0x00),   # 0  black
    (0xfe, 0xfe, 0xfe),   # 1  white
    (0x81, 0x33, 0x37),   # 2  red
    (0x75, 0xce, 0xc8),   # 3  cyan
    (0x8d, 0x3b, 0x97),   # 4  purple
    (0x55, 0xac, 0x4d),   # 5  green
    (0x2d, 0x2b, 0x9a),   # 6  blue
    (0xed, 0xf0, 0x71),   # 7  yellow
    (0x8d, 0x50, 0x29),   # 8  orange
    (0x54, 0x37, 0x00),   # 9  brown
    (0xc4, 0x6c, 0x71),   # 10 light red
    (0x49, 0x49, 0x49),   # 11 dark grey
    (0x7b, 0x7b, 0x7b),   # 12 medium grey
    (0xa9, 0xfe, 0x9f),   # 13 light green
    (0x6f, 0x6d, 0xeb),   # 14 light blue
    (0xb1, 0xb1, 0xb1),   # 15 light grey
]

W, H = 320, 200


def decode_png_rgba(path):
    """Minimal PNG decoder for 8-bit truecolor-with-alpha (colortype 6)."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos = 8
    width = height = bitdepth = colortype = None
    idat = bytearray()
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos:pos + 4])
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b"IHDR":
            width, height, bitdepth, colortype = struct.unpack(">IIBB", chunk[:10])
        elif ctype == b"IDAT":
            idat += chunk
        elif ctype == b"IEND":
            break
        pos += 12 + length
    assert bitdepth == 8 and colortype == 6, \
        f"expected 8-bit RGBA, got bitdepth={bitdepth} colortype={colortype}"
    raw = zlib.decompress(bytes(idat))
    bpp = 4  # RGBA
    stride = width * bpp
    out = bytearray(stride * height)
    prev = bytearray(stride)
    rp = 0
    for y in range(height):
        ft = raw[rp]; rp += 1
        line = bytearray(raw[rp:rp + stride]); rp += stride
        if ft == 0:
            pass
        elif ft == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xff
        elif ft == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xff
        elif ft == 3:  # Average
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xff
        elif ft == 4:  # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xff
        else:
            raise ValueError(f"unknown filter {ft}")
        out[y * stride:(y + 1) * stride] = line
        prev = line
    return width, height, bytes(out)


def nearest(r, g, b):
    best_i, best_d = 0, 1 << 30
    for i, (pr, pg, pb) in enumerate(PALETTE):
        d = (r - pr) ** 2 + (g - pg) ** 2 + (b - pb) ** 2
        if d < best_d:
            best_d, best_i = d, i
    return best_i, best_d


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "CheeseCutterEXT.png"
    dst = sys.argv[2] if len(sys.argv) > 2 else "src/font/splash.dat"
    w, h, px = decode_png_rgba(src)
    assert (w, h) == (W, H), f"expected {W}x{H}, got {w}x{h}"
    out = bytearray(W * H)
    maxd = 0
    for i in range(W * H):
        r, g, b = px[i * 4], px[i * 4 + 1], px[i * 4 + 2]
        idx, d = nearest(r, g, b)
        out[i] = idx
        maxd = max(maxd, d)
    open(dst, "wb").write(out)
    print(f"wrote {dst} ({len(out)} bytes); max color distance^2 = {maxd}")


if __name__ == "__main__":
    main()
