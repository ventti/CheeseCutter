#!/usr/bin/env python3
"""Render C64 Pro Mono into CheeseCutter's font.psf at a configurable cell size.

Preserves the EXACT character order of the existing font.psf: that file is a PSF1
font whose Unicode table maps every glyph index -> codepoint. We keep that table
verbatim and only regenerate the glyph bitmaps, rendering each index's primary
codepoint from the OTF. Rendering the box-drawing / block Unicode codepoints from
C64 Pro Mono yields the authentic PETSCII line/block graphics.

The cell size is `WxH` (default 8x14). Each glyph is rendered at its native 8x8
(crisp, 1-bit) and then the 8 rows are NEAREST-NEIGHBOUR scaled to H rows. This
fills the cell (so vertical-line / block graphics span the whole cell and tile
into solid window frames), never clips descenders, and stays crisp: H=8 is the
native glyph, H=16 a clean 2x, H=14 an even pixel-doubling. PSF1 (and CheeseCutter's
renderer) packs one byte per row, so width is always 8 (keep W=8).
After regenerating, set FONT_Y in src/com/fb.d to H.

Requires freetype-py (`pip install freetype-py`).
Usage: python3 tools/mk-font.py [in.psf] [otf] [out.psf] [WxH]
"""
import sys
import struct
import freetype

ROW_BITS = 8  # PSF1 is always 8 px wide (one byte per row)


def parse_psf1(path):
    d = open(path, "rb").read()
    assert d[0] == 0x36 and d[1] == 0x04, "not PSF1"
    mode, charsize = d[2], d[3]
    nglyphs = 512 if (mode & 0x01) else 256
    has_tab = bool(mode & 0x06)
    glyph_end = 4 + nglyphs * charsize
    tab_bytes = d[glyph_end:] if has_tab else b""
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


def render_native8(face, cp, baseline):
    """Render cp at native 8x8 -> list of 8 row bytes (MSB=leftmost), or None."""
    if cp is None or cp == 0:
        return None
    if face.get_char_index(cp) == 0:
        return None
    face.load_char(cp, freetype.FT_LOAD_RENDER | freetype.FT_LOAD_TARGET_MONO)
    g = face.glyph
    bm = g.bitmap
    rows = [0] * 8
    top = baseline - g.bitmap_top
    left = g.bitmap_left
    clipped = False
    for r in range(bm.rows):
        cy = top + r
        rowbits = bm.buffer[r * bm.pitch:(r + 1) * bm.pitch]
        if cy < 0 or cy >= 8:
            if any(rowbits):
                clipped = True
            continue
        acc = 0
        for x in range(bm.width):
            if (rowbits[x // 8] >> (7 - (x % 8))) & 1:
                cx = left + x
                if 0 <= cx < ROW_BITS:
                    acc |= 1 << (7 - cx)
                else:
                    clipped = True
        rows[cy] = acc
    return rows, clipped


def scale_rows(rows8, ch):
    """Nearest-neighbour scale 8 source rows to `ch` output rows."""
    return bytes(rows8[(y * 8) // ch] for y in range(ch))


def main():
    inpsf = sys.argv[1] if len(sys.argv) > 1 else "src/font/font.psf"
    otf = sys.argv[2] if len(sys.argv) > 2 else \
        "/Users/teppo.keitaanniemi/personal/Dropbox (Personal)/git/github.com/ventti/CheeseCutter/teppo/C64_Pro_Mono-STYLE.otf"
    out = sys.argv[3] if len(sys.argv) > 3 else "src/font/font.psf"
    size = sys.argv[4] if len(sys.argv) > 4 else "8x14"
    cw, ch = (int(x) for x in size.lower().split("x"))
    if cw != ROW_BITS:
        print(f"NOTE: width {cw} != 8; PSF1 rows are 8px wide, output clipped to 8.")

    info = parse_psf1(inpsf)
    face = freetype.Face(otf)
    face.set_pixel_sizes(0, 8)            # render glyphs at native 8x8, then scale rows
    baseline = face.size.ascender >> 6    # = 7 for C64 Pro Mono at 8px
    print(f"in: charsize={info['charsize']} nglyphs={info['nglyphs']} tab={len(info['tab_bytes'])}B")
    print(f"cell={cw}x{ch} (native 8x8 -> {ch} rows, baseline={baseline})")

    glyphs = bytearray()
    rendered = blank = clipped_n = 0
    for i in range(info["nglyphs"]):
        res = render_native8(face, info["prim"].get(i), baseline)
        if res is None:
            glyphs += bytes(ch); blank += 1
        else:
            rows8, clip = res
            glyphs += scale_rows(rows8, ch); rendered += 1
            if clip:
                clipped_n += 1
                print(f"  WARN idx {i} cp={info['prim'].get(i):#x} clipped at 8px")

    new = bytes([0x36, 0x04, info["mode"], ch]) + bytes(glyphs) + info["tab_bytes"]
    open(out, "wb").write(new)
    print(f"out: {out} ({len(new)}B) charsize={ch} rendered={rendered} "
          f"blank={blank} clipped={clipped_n}")
    print(f"-> set FONT_Y = {ch} in src/com/fb.d")


if __name__ == "__main__":
    main()
