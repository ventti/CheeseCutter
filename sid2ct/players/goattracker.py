"""GoatTracker 2 packed player structure recovery.

Layout follows gplay.c, greloc.c and player.s from
https://github.com/leafo/goattracker2/tree/master/src . Addresses are operands
of the sequencer and note-fetch code, never song-specific constants. Subtunes
are one-based, as in ct2util. Memory reads must come from the same subtune.
"""
from __future__ import annotations

from dataclasses import dataclass
import re
import struct

from .hints import NoteHint, StructureHints, VoiceHints
from .sidid import identify


@dataclass(frozen=True)
class Row:
    address: int
    note: int
    instrument: int | None
    command: tuple[int, int]


@dataclass
class Layout:
    memory: bytes
    orders: list[bytes]
    patterns: list[list[Row]]
    pattern_lo: int
    pattern_hi: int
    gate_timer: int | tuple[int, int]
    tempo: int
    instruments: dict[int, dict]
    tables: dict[str, dict]


def _word(data, offset):
    return int.from_bytes(data[offset:offset + 2], 'little')


def _pattern(memory, address):
    rows = []
    command = (0, 0)
    start = address
    while address - start < 256 and len(rows) <= 255:
        row_address = address
        value = memory[address]
        if value == 0:
            if not rows:
                raise ValueError('Empty packed pattern')
            return rows
        instrument = None
        if value < 0x40:
            instrument = value
            address += 1
            value = memory[address]
        if 0x40 <= value < 0x60:
            opcode = value & 15
            rest = value >= 0x50
            address += 1
            param = memory[address] if opcode else 0
            address += bool(opcode)
            command = (opcode, param)
            if rest:
                rows.append(Row(row_address, 0xBD, instrument, command))
                continue
            value = memory[address]
        if value < 0x60:
            raise ValueError('Invalid packed note')
        count = 256 - value if value >= 0xC0 else 1
        note = 0xBD if value >= 0xC0 else value
        rows.extend(Row(row_address, note, instrument if i == 0 else None, command)
                    for i in range(count))
        address += 1
    # Exactly 256 bytes can omit the end marker (8-bit pointer wraps).
    if address - start == 256 and rows:
        return rows
    raise ValueError('Packed pattern exceeds GT2 limits')


def _layout(raw, subtune):
    if not any(n.startswith('GoatTracker_V2') for n in identify(raw)):
        raise ValueError('Not a recognised GT2 player')
    offset, load = struct.unpack_from('>HH', raw, 6)
    songs = int.from_bytes(raw[14:16], 'big')
    if not 1 <= subtune <= songs:
        raise ValueError('Invalid subtune')
    payload = raw[offset:]
    if not load:
        load, payload = _word(payload, 0), payload[2:]
    if not payload or load + len(payload) > 65536:
        raise ValueError('Invalid load range')
    memory = bytes(load) + payload + bytes(65536 - load - len(payload))
    # LDA tablelo,Y / STA zp / LDA tablehi,Y / STA zp+1.
    pointers = []
    for match in re.finditer(rb'\xb9(..)\x85(.)\xb9(..)\x85(.)', payload, re.S):
        if match[4][0] != match[2][0] + 1:
            continue
        pos = load + match.start()
        lo, hi = _word(match[1], 0), _word(match[3], 0)
        if not load <= lo < hi < load + len(payload):
            continue
        following = memory[pos + 10:pos + 24]
        # The fetch compares with FX ($40); sequencer compares LOOP ($ff).
        if b'\xc9\x40' in following:
            pointers.append(('pattern', pos, lo, hi))
        elif b'\xc9\xff' in following:
            pointers.append(('song', pos, lo, hi))
    song = [p for p in pointers if p[0] == 'song']
    pattern = [p for p in pointers if p[0] == 'pattern']
    if len(song) != 1 or len(pattern) != 1:
        raise ValueError('Unsupported sequencer/fetch code')
    _, _, sl, sh = song[0]
    _, fetch, pl, ph = pattern[0]
    if sh - sl != songs * 3 or not 1 <= ph - pl <= 208:
        raise ValueError('Invalid pointer table sizes')
    orders = []
    for v in range(3):
        i = (subtune - 1) * 3 + v
        address = memory[sl + i] | memory[sh + i] << 8
        if not load <= address < load + len(payload):
            raise ValueError('Order outside payload')
        end = memory.index(255, address, min(address + 255, load + len(payload) - 1))
        order = memory[address:end + 2]
        if order[-1] >= len(order) - 2:
            raise ValueError('Invalid order restart')
        orders.append(order)
    pattern_addresses = [memory[pl + i] | memory[ph + i] << 8
                         for i in range(ph - pl)]
    if any(not load <= a < load + len(payload) for a in pattern_addresses):
        raise ValueError('Pattern outside payload')
    patterns = [_pattern(memory, address) for address in pattern_addresses]
    # Fixed-parameter players compare counter against an immediate timer.
    timers = []
    for m in re.finditer(rb'\xbd..\xc9(.)\xf0(.)', memory[load:fetch], re.S):
        branch = load + m.end() + int.from_bytes(m[2], 'little', signed=True)
        if branch == fetch - 3:  # LDY pattern number precedes the pointer loads
            timers.append(m[1][0])
    if len(timers) != 1:
        variable = []
        for m in re.finditer(rb'\xbd..\xdd(..)\xf0(.)', memory[load:fetch], re.S):
            branch = load + m.end() + int.from_bytes(m[2], 'little', signed=True)
            if branch == fetch - 3:
                target = m[1]
                refs = list(re.finditer(rb'\xb9(..)\x9d' + re.escape(target), payload, re.S))
                if len(refs) == 1:
                    variable.append((_word(refs[0][1], 0), ph + ph - pl))
        if len(variable) != 1:
            raise ValueError('Unsupported gate timer code')
        timer = variable[0]
    else:
        timer = timers[0]
    defaults = list(re.finditer(rb'\xa9(.)\x9d..\xa9\x01\x9d..\x9d..', payload, re.S))
    if len(defaults) != 1:
        raise ValueError('Unsupported tempo initialization')
    data_start = ph + ph - pl
    code = memory[load:min(sl, pl)]
    refs = sorted({_word(m[1], 0) + 1 for m in
                   re.finditer(rb'\xb9(..)', code, re.S)
                   if data_start - 1 <= _word(m[1], 0) < min(
                       memory[sl + i] | memory[sh + i] << 8 for i in range(sh - sl))})
    instruments = {}
    tables = {}
    if isinstance(timer, tuple) and len(refs) >= 2 and refs[0] == data_start:
        count = refs[1] - refs[0]
        if 1 <= count <= 63 and timer[0] + 1 == data_start + count * 7:
            fields = ('ad', 'sr', 'wave', 'pulse', 'filter', 'speed',
                      'vibrato_delay', 'gate_timer', 'first_wave')
            for i in range(count):
                instruments[i + 1] = {name: memory[data_start + j * count + i]
                                      for j, name in enumerate(fields)}
            instrument_end = data_start + 9 * count
            # Tables are identified by their execution code, not their contents.
            signatures = {
                'wave': rb'\xb9(..)\xc9\x10',
                'pulse': rb'\xb9(..)\x10.\x9d..\xb9(..)',
                'filter': rb'\xb9(..)\xf0.\x10.\x0a.*?\xb9(..)',
            }
            for name, signature in signatures.items():
                matches = [m for m in re.finditer(signature, code, re.S)
                           if _word(m[1], 0) + 1 >= instrument_end]
                if len(matches) != 1:
                    continue
                m = matches[0]
                left = _word(m[1], 0) + 1
                if name == 'wave':
                    # Right table is loaded in the wave loop/jump handler.
                    tail = code[m.end():m.end() + 100]
                    jumps = list(re.finditer(rb'\xb9(..)\x9d..\xa9\x00', tail, re.S))
                    if len(jumps) != 1:
                        continue
                    right = _word(jumps[0][1], 0) + 1
                else:
                    right = _word(m[2], 0) + 1
                size = right - left
                if 0 < size <= 255 and right + size <= min(
                        memory[sl + i] | memory[sh + i] << 8 for i in range(sh - sl)):
                    tables[name] = {'address': left, 'left': memory[left:right],
                                    'right': memory[right:right + size]}
            if 'filter' in tables:
                t = tables['filter']
                start = t['address'] + 2 * len(t['left'])
                end = min(memory[sl + i] | memory[sh + i] << 8 for i in range(sh - sl))
                # Speed table has an extra zero on both sides for pointer zero.
                size = (end - start) // 2 - 1
                if 0 <= size <= 255 and end - start == 2 * (size + 1):
                    tables['speed'] = {'address': start + 1,
                                      'left': memory[start + 1:start + 1 + size],
                                      'right': memory[start + size + 2:end]}
            for definition in instruments.values():
                definition['packed_tables'] = tables
    return Layout(memory, orders, patterns, pl, ph, timer,
                  defaults[0][1][0] + 1, instruments, tables)


def _orders(order, patterns):
    result, positions = [], {}
    transpose = 0
    for i, value in enumerate(order[:-2]):
        positions[i] = len(result)
        if value >= 0xE0:
            transpose = value - 0xF0
        elif value >= 0xD0:
            if not result:
                raise ValueError('Repeat before first pattern')
            result.extend([result[-1]] * (value - 0xD0))
        else:
            if value >= len(patterns):
                raise ValueError('Order references nonexistent pattern')
            result.append((value, transpose))
    loop = positions.get(order[-1])
    if not result or loop is None or loop >= len(result):
        raise ValueError('Invalid order loop')
    return result, loop


def extract(sid_bytes, subtune, frames, memtrace) -> StructureHints | None:
    """Recover rows from GT2 data and observed fetches; reject unknown layouts.

    `frames` are convert.parse_trace frames, `memtrace` is memtrace.parse output.
    Sounding rows follow the prefetch by the player's encoded gate timer.
    """
    try:
        layout = _layout(sid_bytes, subtune)
        if not frames or not memtrace:
            return None
        reads = [{a for lo, hi in c.reads for a in range(lo, hi + 1)} for c in memtrace]
        voices = []
        for order in layout.orders:
            entries, loop = _orders(order, layout.patterns)
            voice = VoiceHints(orderlist=entries, loop_index=loop)
            position = row = 0
            instrument = 1
            for call, addresses in zip(memtrace, reads):
                pattern, transpose = entries[position]
                source = layout.patterns[pattern][row]
                if (layout.pattern_lo + pattern not in addresses or
                        layout.pattern_hi + pattern not in addresses or
                        source.address not in addresses):
                    continue
                delay = (layout.memory[layout.gate_timer[0] + instrument]
                         if isinstance(layout.gate_timer, tuple) else layout.gate_timer)
                sounding = call.index + delay
                if sounding >= len(frames):
                    break
                voice.row_calls.append(sounding)
                if row == 0:
                    voice.pattern_calls.append(sounding)
                if source.instrument is not None:
                    instrument = source.instrument
                if 0x60 <= source.note < 0xBD:
                    voice.notes.append(NoteHint(sounding, source.note - 0x60 + transpose,
                                                source.instrument, source.command[0] == 3 or
                                                layout.instruments.get(instrument, {}).get(
                                                    'first_wave') == 0xFE,
                                                source.command))
                row += 1
                if row == len(layout.patterns[pattern]):
                    row = 0
                    position += 1
                    if position == len(entries):
                        position = loop
            voices.append(voice)
        if not all(v.row_calls for v in voices):
            return None
        warnings = ['The shared hints type has no table field; raw packed tables are in instrument packed_tables.',
                    'Loop call is not recovered from unordered memory reads.',
                    'Hard restart and legato instrument classes are not recovered.']
        if not layout.instruments:
            warnings.append('Optimized instrument layout: instrument and table fields were not recovered.')
        elif len(layout.tables) != 4:
            warnings.append('Some modulation tables were not recovered.')
        return StructureHints('GoatTracker', '2.x', tuple(voices),
                              instruments=layout.instruments,
                              tempo_calls=[b - a for a, b in zip(voices[0].row_calls,
                                                               voices[0].row_calls[1:])],
                              warnings=warnings)
    except (ValueError, IndexError, struct.error):
        return None


def to_sng(sid_bytes, subtune=1) -> bytes:
    """Rebuild an editable GTS5 song for fully recovered nine-field layouts.

    Unsupported optimizations raise ValueError. Packed instrument numbering is
    retained; editor names and unused data cannot be recovered. Instrument
    hard-restart class flags default to normal hard restart; this is an editable
    reconstruction, not a promise of register-exact audio.
    """
    layout = _layout(sid_bytes, subtune)
    if not layout.instruments or set(layout.tables) != {'wave', 'pulse', 'filter', 'speed'}:
        raise ValueError('SNG export needs all nine instrument fields and four tables')
    data = bytearray(b'GTS5')
    data += b'Recovered GT2'.ljust(32, b'\0') + bytes(64)
    data.append(1)
    for order in layout.orders:
        entries, loop = _orders(order, layout.patterns)
        converted = bytearray()
        positions = []
        transpose = 0
        for pattern, trans in entries:
            positions.append(len(converted))
            if trans != transpose:
                converted.append(0xF0 + trans)
                transpose = trans
            converted.append(pattern)
        if len(converted) > 253:
            raise ValueError('Expanded order exceeds GTS5 size')
        data.append(len(converted) + 1)
        data += converted + bytes([255, positions[loop]])
    # Instrument 63 carries the editor's default tempo in its AD byte.
    data.append(63)
    for i in range(1, 64):
        definition = layout.instruments.get(i)
        if definition:
            values = [definition[k] for k in ('ad', 'sr', 'wave', 'pulse', 'filter',
                      'speed', 'vibrato_delay', 'gate_timer', 'first_wave')]
            if values[5]:
                values[6] += 1
            data += bytes(values) + f'Packed {i}'.encode().ljust(16, b'\0')
        else:
            data += bytes([layout.tempo if i == 63 else 0]) + bytes(24)
    for name in ('wave', 'pulse', 'filter', 'speed'):
        table = layout.tables[name]
        left, right = bytearray(table['left']), bytearray(table['right'])
        for i, value in enumerate(left):
            if name == 'wave' and value < 0xF0:
                if value >= 0x20:
                    left[i] = value - 0x10
                elif value >= 0x10:
                    left[i] = 0xE0 | (value & 15)
                right[i] ^= 0x80
            elif name == 'filter' and 0x80 < value < 255:
                left[i] = 0x80 | ((value & 0x38) << 1)
        data.append(len(left))
        data += left + right
    data.append(len(layout.patterns))
    for pattern in layout.patterns:
        if len(pattern) > 254:
            raise ValueError('Pattern exceeds GTS5 size')
        data.append(len(pattern) + 1)
        for row in pattern:
            data += bytes((row.note, row.instrument or 0, *row.command))
        data += bytes((255, 0, 0, 0))
    return bytes(data)
