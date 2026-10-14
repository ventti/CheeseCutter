"""Read DMC structure using code operands and the traced order/pattern reads.

Format: https://github.com/anarkiwi/pydmcsid/blob/main/docs/format.md
This is a structure-only decoder, independently implemented from that format
and its player transcription. No SID sound engine or external dependency is
used. Call indices are ct2util play calls; subtunes are one-based.
"""
import re
import struct
from dataclasses import dataclass

from .hints import NoteHint, SequenceInfo, StructureHints, VoiceHints, gate_rise_agreement
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


def _tables(mem, start, end, layout):
    """Resolve source table operands only at confirmed LDA ...,Y instructions."""
    operands = {
        'classic': {'wave': (0x59c, 0x5b9), 'filter_step': (0x3e7, 0x3ed)},
        'a1': {'wave': (0x386, 0x390), 'pulse': (0x3c1, 0x3c7),
               'filter': (0x3f0, 0x3f6)},
        '95': {'wave': (0x658, 0x65f), 'pulse': (0x4d0, 0x4c6),
               'filter': (0x496, 0x4a7)},
    }[layout.kind]
    tables = {}
    for name, offsets in operands.items():
        if any(mem[layout.base + offset - 1] != 0xb9 for offset in offsets):
            continue
        left, right = (int.from_bytes(mem[layout.base + offset:layout.base + offset + 2],
                                      'little') for offset in offsets)
        size = abs(right - left)
        if 0 < size <= 256 and start <= min(left, right) and max(left, right) + size <= end:
            tables[name] = {'address': left, 'right_address': right,
                            'left': bytes(mem[left:left + size]),
                            'right': bytes(mem[right:right + size])}
    if layout.kind == 'classic':
        singles = {}
        for name, offset in (('pulse', 0x358), ('filter', 0x296)):
            if mem[layout.base + offset - 1] == 0xb9:
                address = int.from_bytes(mem[layout.base + offset:layout.base + offset + 2], 'little')
                if start <= address < end:
                    singles[name] = address
        boundaries = sorted(set(singles.values()) | {a for t in tables.values()
                            for a in (t['address'], t['right_address'])} | {end})
        for name, address in singles.items():
            limit = next(a for a in boundaries if a > address)
            if limit - address <= 256:
                tables[name] = {'address': address, 'raw': bytes(mem[address:limit])}
    return tables


def _sequence(mem, ptr, modern, marker, start, end):
    """Skip command parameters when locating a pattern's end marker."""
    offset = 0
    terminator = 0xff if modern or marker == 0xfe else 0x7f
    while offset < 256 and start <= ptr + offset < end:
        value = mem[ptr + offset]
        offset += 1
        if value == terminator:
            return SequenceInfo(ptr, offset)
        if not modern and value in (marker, marker - 1):
            continue
        if modern and 0xef <= value <= 0xfd and value not in (0xf4, 0xf5):
            offset += 3 if value == 0xfb else 2 if value == 0xfa else 1
        elif not modern and 0xc0 <= value < (0xf0 if marker == 0x7e else 0x100):
            offset += 1 if value & 0x10 else 2
    raise _Invalid('Pattern does not terminate')


def _wave_effects(hints, calls, kind):
    """Execute the confirmed wave path; never select a row from SID output.

    A missing expected read makes the wave state unknown until the next note.
    The 95 body holds each row for the instrument's high-nibble wave speed.
    """
    table = hints.tables.get('wave')
    if not table:
        return
    left, right = table['left'], table['right']
    modern = kind != 'classic'
    horizon = max(c.index for c in calls) + 1
    reads = {c.index: c.reads for c in calls}
    for vh in hints.voices:
        source = {n.call: n for n in vh.notes}
        instrument, note, pointer, gate, mask = 0, 0, None, False, True
        result = []
        speed = counter = 0
        waveform = 0
        first_read = False
        for i in range(horizon):
            event = source.get(i)
            onset = False
            if event:
                if event.instrument is not None:
                    instrument = event.instrument
                if event.kind == 'note':
                    note = event.note
                    if not event.tie:
                        raw = hints.instruments.get(instrument, {}).get('raw', ())
                        pointer = raw[2 if modern else 9] if raw else None
                        speed = raw[6] >> 4 if raw and kind == '95' else 0
                        counter = speed
                        first_read = modern
                        mask = True
                        onset = True
                        if modern:
                            gate = True  # source note writes gate+test for one call
                elif event.command and event.command[0] in (0xf4, 0x7d, 0xfd):
                    mask = not mask
                    if pointer is None:
                        # Unknown waveform cannot establish a gate attack.
                        event = NoteHint(i, note, event.instrument, True,
                                         event.command, 'effect')
                    else:
                        new_gate = mask and bool(waveform & 1)
                        attack = new_gate and not gate
                        event = NoteHint(i, note, event.instrument, not attack,
                                         event.command, 'effect' if mask else 'gate_off')
                    gate = bool(waveform & 1) and mask
                result.append(event)
            if pointer is None or modern and onset:
                continue
            # Modern note-init reads its first wave on the following call.
            seen = set()
            while 0 <= pointer < len(left) and pointer not in seen:
                seen.add(pointer)
                value = left[pointer]
                if modern and not first_read and value == 0x90:
                    pointer = right[pointer]
                elif not modern and value >= 0x90:
                    pointer = (pointer - (value - 0x90)) & 255
                else:
                    break
            else:
                pointer = None
                continue
            if not any(lo <= table['address'] + pointer <= hi
                       for lo, hi in reads.get(i, ())):
                pointer = None
                continue
            value = left[pointer]
            waveform = value
            first_read = False
            new_gate = bool(value & 1) and mask
            if new_gate != gate and not onset and not event:
                result.append(NoteHint(i, note, instrument, not new_gate,
                    ('wave', pointer, value, right[pointer]),
                    'effect' if new_gate else 'gate_off'))
            gate = new_gate
            if kind == '95' and counter:
                counter -= 1
            else:
                pointer = (pointer + 1) & 255
                counter = speed
        vh.notes = sorted(result, key=lambda n: n.call)


def extract(sid_bytes, subtune, frames, memtrace, *, validate=True) -> StructureHints | None:
    """Recover rows, notes, order lists and raw instruments, or decline safely.

    Requires parsed ``memtrace.Call`` objects. Reads confirm each row, so init
    wrappers and startup delays need no emulation. Unknown or modified formats
    return None instead of guessing. The memory-read calls bound the timeline;
    source notes are retained; table effects require source program reads.
    ``validate=False`` skips the final SID gate-agreement acceptance check.
    """
    try:
        if not any('DMC' in name for name in identify(sid_bytes)):
            return None
        mem, start, end = _image(sid_bytes, subtune)
        layout = _locate(mem, start, end)
        if layout is None or not memtrace:
            return None
        if any(c.index != i for i, c in enumerate(memtrace)):
            return None
        hints = _extract(mem, start, end, layout, subtune, memtrace)
        if validate and hints is not None and (len(memtrace) != len(frames)
                or gate_rise_agreement(hints, frames) < 0.98):
            return None
        return hints
    except (ValueError, IndexError, struct.error):
        return None


def _extract(mem, start, end, layout, subtune, calls):
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
                           tempo_calls=[period], tables=_tables(mem, start, end, layout))
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
        for _, pat, _ in entries:
            ptr = byte(layout.low + pat) | byte(layout.high + pat) << 8
            vh.sequences[pat] = _sequence(mem, ptr, modern, layout.marker, start, end)
        states.append(dict(entries=entries, entry=0, offset=0, instrument=0, tie=False,
                           last_note=0, duration=1, seen=set(), loop_call=None, stopped=not entries))
    for call in calls:
        if not 0 <= call.index < len(calls):
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
            toggle = False
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
                        toggle = value == 0xf4
                        if toggle:
                            command = (value,)
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
                    elif value == 0xfd:
                        state['duration'] = params[0] or 256
                    else:
                        command = (value, *params)
                else:
                    if layout.marker == 0x7e and value == 0x7c:
                        state['tie'] = not state['tie']
                        continue
                    if value in (layout.marker, layout.marker - 1):
                        toggle = value == layout.marker - 1
                        if toggle:
                            command = (value,)
                        break
                    if value < 0x60:
                        note = value
                        break
                    if value < 0x80:
                        state['instrument'] = instrument = value & 31
                    elif value < 0xc0:
                        state['duration'] = (value & 63) or 256
                    elif layout.marker == 0x7e and value >= 0xf0:
                        command = (value,)
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
            vh.row_durations.append(state['duration'] * period)
            if note is not None:
                state['last_note'] = (note + trans) & 255
                sounding = call.index + (0 if modern else 1)
                if sounding < len(calls):
                    vh.notes.append(NoteHint(sounding, state['last_note'], instrument,
                                             state['tie'], command))
                inst = state['instrument']
                addr = layout.instruments + ((inst * layout.stride) & 255)
                hints.instruments[inst] = {'raw': tuple(byte(addr + n) for n in range(layout.stride))}
            else:
                sounding = call.index + (0 if modern else 1)
                if sounding < len(calls):
                    vh.notes.append(NoteHint(sounding, state['last_note'], instrument,
                                             True, command, 'effect' if command else 'rest'))
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
    _wave_effects(hints, calls, layout.kind)
    first_row = min((v.row_calls[0] for v in hints.voices if v.row_calls), default=0)
    hints.speed_commands = [(first_row, period)]
    return hints
