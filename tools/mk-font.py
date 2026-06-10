#!/usr/bin/env python3
"""Render C64 Pro Mono into CheeseCutter's font.psf as a true 8x8 charset.

Preserves the EXACT character order of the existing font.psf: that file is a PSF1
font whose Unicode table maps every glyph index -> codepoint. We keep that table
verbatim and only regenerate the glyph bitmaps, rendering each index's primary
codepoint from the OTF at 8x8 (1-bit). Rendering the box-drawing / block Unicode
codepoints from C64 Pro Mono yields the authentic PETSCII line/block graphics, and
at 8 rows tall they tile into solid window frames.

Requires freetype-py (`pip install freetype-py`).
Usage: python3 tools/mk-font.py [in.psf] [otf] [out.psf]
"""
import sys
import struct
import freetype

CELL = 8  # 8x8 cell

def parse_psf1(path):
    d = open(path, "rb").read()
    assert d[0] == 0x36 and d[1] == 0x04, "not PSF1"
    mode, charsize = d[2], d[3]
    nglyphs = 512 if (mode & 0x01) else 256
    has_tab = bool(mode & 0x06)
    glyph_end = 4 + nglyphs * charsize
    tab_bytes = d[glyph_end:] if has_tab else b""
    # primary codepoint per glyph index
    prim = {}
    if has_tab:
        i, idx = glyph_end, 0
        while i + 1 < len(d) and idx < nglyphs:
            cp = None
            while i + 1 < len(d):
                v = struct.unpack_from("<H", d, i)[0]; i += 2
                if v == 0xFFFF:
                    break
                if v == 0xFFFE:
                    continue
                if cp is None:
                    cp = v
            prim[idx] = cp
            idx += 1
    return dict(mode=mode, charsize=charsize, nglyphs=nglyphs,
                tab_bytes=tab_bytes, prim=prim)


def render_glyph(face, cp, baseline):
    """Return 8 bytes (MSB=leftmost) for codepoint cp, or None if no glyph."""
    if cp is None or cp == 0:
        return None
    if face.get_char_index(cp) == 0:
        return None
    face.load_char(cp, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_MONO)
    g = face.glyph
    bm = g.bitmap
    rows = [0] * CELL
    top = baseline - g.bitmap_top      # cell row of the glyph's first pixel row
    left = g.bitmap_left
    clipped = False
    for r in range(bm.rows):
        cy = top + r
        if cy < 0 or cy >= CELL:
            if any(bm.buffer[r * bm.pitch:(r + 1) * bm.pitch]):
                clipped = True
            continue
        rowbits = bm.buffer[r * bm.pitch:(r + 1) * bm.pitch]
        acc = 0
        for x in range(bm.width):
            if (rowbits[x // 8] >> (7 - (x % 8))) & 1:
                cx = left + x
                if 0 <= cx < CELL:
                    acc |= 1 << (7 - cx)
                else:
                    clipped = True
        rows[cy] = acc
    return bytes(rows), clipped


def main():
    inpsf = sys.argv[1] if len(sys.argv) > 1 else "src/font/font.psf"
    otf = sys.argv[2] if len(sys.argv) > 2 else \
        "/Users/teppo.keitaanniemi/personal/Dropbox (Personal)/git/github.com/ventti/CheeseCutter/teppo/C64_Pro_Mono-STYLE.otf"
    out = sys.argv[3] if len(sys.argv) > 3 else "src/font/font.psf"

    info = parse_psf1(inpsf)
    face = freetype.Face(otf)
    face.set_pixel_sizes(0, CELL)
    baseline = face.size.ascender >> 6  # = 7 for C64 Pro Mono at 8px
    print(f"in: mode={info['mode']:#04x} charsize={info['charsize']} "
          f"nglyphs={info['nglyphs']} baseline={baseline} tab={len(info['tab_bytes'])}B")

    glyphs = bytearray()
    rendered = blank = clipped_n = 0
    for i in range(info["nglyphs"]):
        res = render_glyph(face, info["prim"].get(i), baseline)
        if res is None:
            glyphs += bytes(CELL); blank += 1
        else:
            gb, clip = res
            glyphs += gb; rendered += 1
            if clip:
                clipped_n += 1
                print(f"  WARN idx {i} cp={info['prim'].get(i):#x} clipped")

    new = bytes([0x36, 0x04, info["mode"], CELL]) + bytes(glyphs) + info["tab_bytes"]
    open(out, "wb").write(new)
    print(f"out: {out} ({len(new)}B) rendered={rendered} blank={blank} clipped={clipped_n}")


if __name__ == "__main__":
    main()
