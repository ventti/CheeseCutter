"""Read DMC structure using code operands and the traced order/pattern reads.

Format: https://github.com/anarkiwi/pydmcsid/blob/main/docs/format.md
This is a structure-only decoder, independently implemented from that format
and its player transcription. No SID sound engine or external dependency is
used. Call indices are ct2util play calls; subtunes are one-based.
"""
import re
import struct
from dataclasses import dataclass

from .hints import NoteHint, StructureHints, VoiceHints
from .sidid import identify, sid_payload


class _Invalid(ValueError):
    pass


@dataclass(frozen=True)
class _Layout:
    base: int
    kind: str
    orders: int
    low: int
    high: int
    instruments: int
    stride: int
    marker: int


def _image(raw, subtune):
    payload = sid_payload(raw)
    offset, load, _, _, songs = struct.unpack_from('>5H', raw, 6)
    if not 1 <= subtune <= songs or subtune > 32:
        raise _Invalid('Invalid subtune')
    if not load:
        load = int.from_bytes(raw[offset:offset + 2], 'little')
    if load + len(payload) > 65536:
        raise _Invalid('Image wraps')
    mem = bytearray(65536)
    mem[load:load + len(payload)] = payload
    return mem, load, load + len(payload)


def _locate(mem, start, end):
    def word(a):
        return mem[a] | mem[a + 1] << 8

    # Reuse the tuning extractor's dispatch -> DEC base+$718 anchor.
    # The later bodies need their own confirmed startup/tempo code.
    for base in range(start, min(end - 6, start + 0x1000)):
        if mem[base] != 0x4c or mem[base + 3] != 0x4c:
            continue
        play = word(base + 4)
        kind = None
        if start <= play < end - 3 and mem[play] == 0xce and word(play + 1) == base + 0x718:
            kind = 'classic'
        elif play == base + 0xa1 and mem[play:play + 8] == bytes.fromhex('a5 f8 48 a5 f9 48 a2 00'):
            if mem[play + 8] == 0xad and word(play + 9) == base + 0x842 and mem[play + 19] == 0xce and word(play + 20) == base + 0x13:
                kind = 'a1'
        elif play == base + 0x95 and mem[play:play + 7] == bytes.fromhex('a5 fa 48 a5 fb 48 ce') and word(play + 7) == base + 0x16:
            kind = '95'
        if kind is None or base + 0x900 > end:
            continue
        plo, phi, inst, work, stride = {
            'classic': (0x102, 0x107, 0x226, 0x707, 11),
            'a1': (0x14e, 0x153, 0x2cb, 0x7cf, 8),
            '95': (0x146, 0x14b, 0x338, 0x7d9, 8),
        }[kind]
        zp = 0xfa if kind == '95' else 0xf8
        # LDA low,Y / STA zp / LDA high,Y / STA zp+1.
        if (mem[base + plo] != 0xb9 or mem[base + phi] != 0xb9
                or mem[base + plo + 3:base + plo + 5] != bytes((0x85, zp))
                or mem[base + phi + 3:base + phi + 5] != bytes((0x85, zp + 1))
                or mem[base + inst] != 0xb9):
            continue
        store = base + work
        sig = re.compile(rb'\xb9(..)\x9d' + re.escape(store.to_bytes(2, 'little')), re.S)
        hits = list(sig.finditer(mem, base, base + 0x900))
        if len(hits) != 1:
            continue
        marker = mem[base + 0x126] if kind == 'classic' else 0xfe
        if kind == 'classic' and (mem[base + 0x125] != 0xc9 or marker not in (0xfe, 0x7e)):
            continue
        return _Layout(base, kind, int.from_bytes(hits[0][1], 'little'),
                       word(base + plo + 1), word(base + phi + 1),
                       word(base + inst + 1), stride, marker)
    return None


def extract(sid_bytes, subtune, frames, memtrace) -> StructureHints | None:
    """Recover rows, notes, order lists and raw instruments, or decline safely.

    Requires parsed ``memtrace.Call`` objects. Reads confirm each row, so init
    wrappers and startup delays need no emulation. Unknown or modified formats
    return None instead of guessing. ``frames`` bounds the hint timeline; gate
    rises are deliberately never used to select or discard source notes.
    """
    try:
        if not any('DMC' in name for name in identify(sid_bytes)):
            return None
        mem, start, end = _image(sid_bytes, subtune)
        layout = _locate(mem, start, end)
        if layout is None or not frames or not memtrace:
            return None
        if len(memtrace) != len(frames) or any(c.index != i for i, c in enumerate(memtrace)):
            return None
        return _extract(mem, start, end, layout, subtune, frames, memtrace)
    except (ValueError, IndexError, struct.error):
        return None


def _extract(mem, start, end, layout, subtune, frames, calls):
    def byte(a):
        if not start <= a < end:
            raise _Invalid('Data outside loaded image')
        return mem[a]

    def word(a):
        return byte(a) | byte(a + 1) << 8

    modern = layout.kind != 'classic'
    record = layout.orders + (subtune - 1) * (2 if layout.kind == '95' else 8)
    period = byte(record + 6) + 1
    hints = StructureHints('DMC', '5' if modern else '4' if layout.marker == 0x7e else None, tuple(VoiceHints() for _ in range(3)),
                           tempo_calls=[period])
    order_ptrs = [word(record + v * 2) for v in range(3)]
    states = []
    for voice, ptr in enumerate(order_ptrs):
        entries, positions, seen, transpose, pos = [], {}, set(), 0, 0
        vh = hints.voices[voice]
        for _ in range(256):
            if pos in seen:
                vh.loop_index = positions.get(pos)
                break
            seen.add(pos)
            positions.setdefault(pos, len(entries))
            value = byte(ptr + pos)
            if value == 0xfe:
                break
            if value == 0xff:
                pos = byte(ptr + pos + 1) if modern else 0
                continue
            if modern and value in (0xfc, 0xfd):
                transpose = byte(ptr + pos + 1) * (-1 if value == 0xfc else 1)
                pos += 2
                continue
            if not modern and value >= 0x80:
                transpose = value - 0xa0 if value >= 0xa0 else -(value & 31)
                pos += 1
                continue
            if value >= 0x80:
                raise _Invalid('Unknown order command')
            positions[pos] = len(entries)
            entries.append((pos, value, transpose))
            pos += 1
        else:
            raise _Invalid('Order does not terminate')
        vh.orderlist = [(pat, trans) for _, pat, trans in entries]
        states.append(dict(entries=entries, entry=0, offset=0, instrument=0, tie=False,
                           last_note=0, seen=set(), loop_call=None, stopped=not entries))
    gate_toggle = False
    for call in calls:
        if not 0 <= call.index < len(frames):
            raise _Invalid('Trace/frame mismatch')
        def read(a):
            return any(lo <= a <= hi for lo, hi in call.reads)
        for v, state in enumerate(states):
            if state['stopped']:
                continue
            vh = hints.voices[v]
            entries = state['entries']
            pos, pat, trans = entries[state['entry']]
            ptr = byte(layout.low + pat) | byte(layout.high + pat) << 8
            offset = state['offset']
            if not read(order_ptrs[v] + pos) or not read(ptr + offset):
                continue
            # Row-fetch calls are independent evidence of timing, even rests.
            vh.row_calls.append(call.index)
            if offset == 0:
                vh.pattern_calls.append(call.index)
                if state['entry'] in state['seen'] and vh.loop_index == state['entry'] and state['loop_call'] is None:
                    state['loop_call'] = call.index
                state['seen'].add(state['entry'])
            note, command, instrument = None, None, None
            for _ in range(256):
                address = ptr + offset
                value = byte(address)
                if not read(address):
                    raise _Invalid('Unconfirmed pattern read')
                offset = (offset + 1) & 255
                if modern:
                    if value < 0x80:
                        note = value
                        break
                    if value in (0xfe, 0xf4):
                        gate_toggle |= value == 0xf4
                        break
                    if value == 0xf5:
                        state['tie'] = not state['tie']
                        continue
                    count = 3 if value == 0xfb else 2 if value == 0xfa else 1
                    if value not in range(0xef, 0xfe):
                        raise _Invalid('Unknown pattern command')
                    params = tuple(byte(ptr + ((offset + n) & 255)) for n in range(count))
                    if not all(read(ptr + ((offset + n) & 255)) for n in range(count)):
                        raise _Invalid('Unconfirmed command read')
                    offset = (offset + count) & 255
                    if value == 0xfc:
                        state['instrument'] = instrument = params[0]
                    elif value in (0xfb, 0xfa):
                        command = (value, *params)
                        if value == 0xfb:
                            note = params[1]
                        break
                    elif value != 0xfd:
                        command = (value, *params)
                else:
                    if layout.marker == 0x7e and value == 0x7c:
                        state['tie'] = not state['tie']
                        continue
                    if value in (layout.marker, layout.marker - 1):
                        gate_toggle |= value == layout.marker - 1
                        break
                    if value < 0x60:
                        note = value
                        break
                    if value < 0x80:
                        state['instrument'] = instrument = value & 31
                    elif value < 0xc0 or (layout.marker == 0x7e and value >= 0xf0):
                        continue
                    else:
                        count = 1 if value & 0x10 else 2
                        params = tuple(byte(ptr + ((offset + n) & 255)) for n in range(count))
                        if not all(read(ptr + ((offset + n) & 255)) for n in range(count)):
                            raise _Invalid('Unconfirmed slide')
                        offset = (offset + count) & 255
                        command = (value, *params)
                        if count == 2:
                            note = params[0]
                        break
            else:
                raise _Invalid('Pattern has no row')
            if note is not None:
                state['last_note'] = (note + trans) & 255
                sounding = call.index + (0 if modern else 1)
                if sounding < len(frames):
                    vh.notes.append(NoteHint(sounding, state['last_note'], instrument,
                                             state['tie'], command))
                inst = state['instrument']
                addr = layout.instruments + ((inst * layout.stride) & 255)
                hints.instruments[inst] = {'raw': tuple(byte(addr + n) for n in range(layout.stride))}
            marker = 0xff if modern or layout.marker == 0xfe else 0x7f
            if byte(ptr + offset) == marker:
                offset = 0
                state['tie'] = False
                state['entry'] += 1
                if state['entry'] == len(entries):
                    if vh.loop_index is None:
                        state['stopped'] = True
                    else:
                        state['entry'] = vh.loop_index
            state['offset'] = offset
    loop_calls = [s['loop_call'] for s in states]
    if None not in loop_calls and len(set(loop_calls)) == 1:
        hints.loop_call = loop_calls[0]
    if not any(v.notes for v in hints.voices):
        return None
    for vh in hints.voices:
        if any((b - a) % period for a, b in zip(vh.row_calls, vh.row_calls[1:])):
            raise _Invalid('Row reads disagree with source tempo')
    if not modern:
        hints.warnings.append('row_calls are data-fetch calls; classic note attacks follow one call later.')
    hints.warnings.append('StructureHints has no rest or effect-only event field; these rows retain boundaries only.')
    if gate_toggle:
        hints.warnings.append('Gate-toggle rows have no separate field in StructureHints; their row boundaries are retained.')
    return hints
