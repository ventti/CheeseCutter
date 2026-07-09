#!/usr/bin/env python3
"""Convert the window-icon PNG into src/font/icon.dat.

Output is a raw ICON_W x ICON_H array of RGBA bytes (4 per pixel, R,G,B,A),
embedded into the binary via D's import() (string-import path -J./src/font) and
handed to SDL_SetWindowIcon() at window creation (see src/com/fb.d). SDL uses
this for the title-bar/taskbar icon on Windows and Linux; macOS ignores it and
takes the Dock icon from the .app bundle's ct.icns instead.

Accepts 8-bit truecolor PNGs with (colortype 6) or without (colortype 2) an
alpha channel; a missing alpha channel is filled opaque.

Usage: python3 tools/mk-icon.py [icons/ccext.png] [src/font/icon.dat]
"""
import sys
import zlib
import struct

ICON_W, ICON_H = 96, 96


def decode_png_rgba(path):
    """Minimal PNG decoder for 8-bit truecolor with (6) or without (2) alpha."""
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
    assert bitdepth == 8 and colortype in (2, 6), \
        f"expected 8-bit RGB/RGBA, got bitdepth={bitdepth} colortype={colortype}"
    bpp = 4 if colortype == 6 else 3
    raw = zlib.decompress(bytes(idat))
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
    # Normalize to RGBA (opaque alpha when the source had none).
    if bpp == 4:
        return width, height, bytes(out)
    rgba = bytearray(width * height * 4)
    for i in range(width * height):
        rgba[i * 4:i * 4 + 3] = out[i * 3:i * 3 + 3]
        rgba[i * 4 + 3] = 0xff
    return width, height, bytes(rgba)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else "icons/ccext.png"
    dst = sys.argv[2] if len(sys.argv) > 2 else "src/font/icon.dat"
    w, h, px = decode_png_rgba(src)
    assert (w, h) == (ICON_W, ICON_H), f"expected {ICON_W}x{ICON_H}, got {w}x{h}"
    open(dst, "wb").write(px)
    print(f"wrote {dst} ({len(px)} bytes, {w}x{h} RGBA)")


if __name__ == "__main__":
    main()
