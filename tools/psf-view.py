#!/usr/bin/env python3

from pathlib import Path
from PIL import Image, ImageDraw
import math
import struct
import sys


def load_psf(path):
    data = Path(path).read_bytes()

    # PSF1
    if data[:2] == b"\x36\x04":
        mode = data[2]
        charsize = data[3]
        glyph_count = 512 if (mode & 0x01) else 256
        width = 8
        height = charsize
        offset = 4

    # PSF2
    elif data[:4] == b"\x72\xb5\x4a\x86":
        (
            magic,
            version,
            headersize,
            flags,
            glyph_count,
            charsize,
            height,
            width,
        ) = struct.unpack_from("<IIIIIIII", data, 0)
        offset = headersize

    else:
        raise ValueError("Not a PSF1 or PSF2 font")

    glyphs = []
    bytes_per_row = (width + 7) // 8

    for glyph_index in range(glyph_count):
        start = offset + glyph_index * charsize
        glyph_data = data[start : start + charsize]
        glyphs.append(glyph_data)

    return width, height, bytes_per_row, glyphs


def render_psf(path, out_path):
    width, height, bytes_per_row, glyphs = load_psf(path)

    scale = 4
    padding = 2
    columns = 32
    rows = math.ceil(len(glyphs) / columns)

    cell_w = width * scale + padding * 2
    cell_h = height * scale + padding * 2

    img = Image.new("RGB", (columns * cell_w, rows * cell_h), "white")
    draw = ImageDraw.Draw(img)

    for index, glyph in enumerate(glyphs):
        gx = (index % columns) * cell_w + padding
        gy = (index // columns) * cell_h + padding

        for y in range(height):
            row = glyph[y * bytes_per_row : (y + 1) * bytes_per_row]

            for x in range(width):
                byte = row[x // 8]
                bit = 7 - (x % 8)

                if byte & (1 << bit):
                    x0 = gx + x * scale
                    y0 = gy + y * scale
                    draw.rectangle(
                        [x0, y0, x0 + scale - 1, y0 + scale - 1],
                        fill="black",
                    )

    img.save(out_path)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} FONT.psf preview.png", file=sys.stderr)
        sys.exit(2)

    render_psf(sys.argv[1], sys.argv[2])
