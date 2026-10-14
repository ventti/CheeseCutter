"""Build tiny synthetic CT songs (one active voice) for testing the SID effect fitters."""
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

from sid2ct.native import native_song

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'ct2util'
ORDER = 65536 + 256 + 5 + 160 + 2048


def template():
    """Decompressed-ready CC2 template made by ct2util init (None if ct2util is missing)."""
    if not TOOL.is_file():
        return None
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / 't.ct'
        subprocess.run([str(TOOL), 'init', str(ROOT / 'src/c64/player.bin'), '-o', str(out)],
                       cwd=ROOT, check=True, capture_output=True)
        return out.read_bytes()


def _patch(data, index, values):
    addr = struct.unpack_from('<H', data, 0xFA0 + index * 2)[0]
    data[addr:addr + len(values)] = bytes(values)


def wave_program(kind, **p):
    """Wave/control rows for instrument 1 (placed at row 2); returns (wave, control)."""
    if kind == 'plain':
        return [0, 126], [0x41, 0]
    if kind == 'arp':
        step = p.get('step', 1)
        return [0, 0, 127], [0x41, step - 1, 3]
    if kind == 'abs':
        notes, delays = p['notes'], p['delays']
        wave = [0x80 | n for n in notes] + [126]
        control = [0x41] + list(delays[1:]) + [0]
        return wave, control
    raise ValueError(kind)


def synth(tmpl, rows, *, wave=('plain', {}), commands=(), chord=None, filt=None,
          adsr=(0x09, 0xF0), speed=4, multiplier=1, length=12, restart=0, extra=None):
    """Return a decompressed CC2 image.

    rows: [(note, super, tie)] on voice 0, each row held `length` sequence rows
    (a row is `speed` base ticks). commands: [(op, hi, lo)] starting at index 1.
    chord: bytes for the chord table. filt: filter table (flat list of bytes).
    extra: {row index: super} put on otherwise blank rows (delayed effects, filter starts).
    """
    seed = bytearray(25)
    seed[0:2] = bytes((0x68, 0x11))
    seed[4:7] = bytes((0x41, 0x12, 0xA8))
    seed[24] = 15
    song, _ = native_song(tmpl, [bytes(seed)] * 32, 1, 4, ['Synth', '', ''])
    data = bytearray(zlib.decompress(song[3:]))
    w, c = wave_program(wave[0], **wave[1])
    wv, ct = [0, 126] + w, [0, 0] + c
    wv += [0] * (256 - len(wv))
    ct += [0] * (256 - len(ct))
    _patch(data, 14, wv)
    _patch(data, 15, ct)
    inst = [0] * 384
    for col, value in enumerate([adsr[0], adsr[1], restart, 0, 0, 0, 0, 2]):
        inst[col * 48 + 1] = value
    _patch(data, 18, inst)
    table = [0] * 256
    table[64] = 0
    for i, (op, hi, lo) in enumerate(commands, 1):
        table[i], table[64 + i], table[128 + i] = op, hi, lo
    _patch(data, 24, table)
    chord_bytes = list(chord or [0, 0x80])
    _patch(data, 30, chord_bytes + [0] * (128 - len(chord_bytes)))
    filt_table = list(filt or [0, 0, 255, 127])
    _patch(data, 16, filt_table + [0] * (256 - len(filt_table)))
    _patch(data, 17, [0, 0, 255, 127] + [0] * 252)
    freq = struct.unpack_from('<H', data, 0xFA0 + 12 * 2)[0]
    if freq == struct.unpack_from('<H', data, 0xFA0 + 13 * 2)[0]:
        freq += 1
    data[freq] = data[freq + 96] = 0
    raw = []
    for note, sup, tie in rows:
        raw += [0xC1, 0x5F if tie else 0xF0, 0x60 + note, sup]
        raw += [0xF0, 0xF0, 0x60, 0] * (length - 1)
    for index, sup in (extra or {}).items():
        raw[index * 4 + 3] = sup
    raw.append(0xBF)
    silent = [0xC0, 0xF0, 0x60, 0, 0xBF]
    lo = struct.unpack_from('<H', data, 0xFA0 + 22 * 2)[0]
    hi = struct.unpack_from('<H', data, 0xFA0 + 23 * 2)[0]
    for seq, body in ((1, raw), (2, silent)):
        addr = data[lo + seq] | data[hi + seq] << 8
        data[addr:addr + 256] = bytes(body).ljust(256, b'\0')
    for voice in range(3):
        order = bytes([0xA0, 1 if voice == 0 else 2, 0xF0, 0]).ljust(1024, b'\0')
        data[ORDER + voice * 1024:ORDER + (voice + 1) * 1024] = order
        _patch(data, 19 + voice, order)
    data[65538] = multiplier
    data[65541] = speed
    return bytes(data)
