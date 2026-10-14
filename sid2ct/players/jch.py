"""Trace-checked extraction of packed JCH NewPlayer 20 sequences.

Format reference: SID Factory II's converter_jch.cpp and NP20 driver:
https://github.com/Chordian/sidfactory2
The editor's unpacked, fixed-address layout is deliberately not used here.
Relocatable instruction operands locate every table in the loaded PSID data.
Other NP generations, funk tempo and speed-changing commands are unsupported.
"""
import re
import struct
from dataclasses import dataclass

from .hints import NoteHint, StructureHints, VoiceHints
from .sidid import identify, sid_payload


# Order pointer -> optional transpose -> sequence index -> split sequence vectors.
_POINTERS = re.compile(
    rb'\xbd(..)\x85(.)\xbd(..)\x85(.)\xa0\x00\x98\x9d..'
    rb'\xb1.\x10\x0f\x0a\x9d..\xfe..\xd0\x03\xfe..\xc8\xb1.'
    rb'\xa8\xb9(..)\x85.\xb9(..)\x85.', re.DOTALL)
_INIT = re.compile(
    rb'\x0a\x0a\x0a\xa8\xa2\x00\xb9(..)\x9d(..)\x9d(..)'
    rb'\xb9(..)\x9d(..)\x9d(..)\xc8\xc8\xe8\xe0\x03\xd0.', re.DOTALL)
_LOOP_INIT = re.compile(
    rb'\xa2\x00\xb9(..)\x9d(..)\xb9(..)\x9d(..)'
    rb'\xc8\xc8\xe8\xe0\x03\xd0.', re.DOTALL)
_INSTRUMENT = re.compile(
    rb'\x68\x0a\x0a\x0a\x9d..\xa8\xb9(..)\x9d..\xfe..\x4c', re.DOTALL)
_COMMAND = re.compile(
    rb'\x68\x29\x3f\x0a\xa8\xb9(..)\x48\x29\x0f', re.DOTALL)
_TIMING = re.compile(
    rb'\xad(..)\xf0.\xc9\x02\xd0.\xbd..\xf0.\x4c..\xde..\x30.', re.DOTALL)


class _Unsupported(ValueError):
    pass


class _Image:
    def __init__(self, raw):
        self.data = sid_payload(raw)
        offset, self.base = struct.unpack_from('>HH', raw, 6)
        if not self.base:
            self.base = int.from_bytes(raw[offset:offset + 2], 'little')
        if self.base + len(self.data) > 65536:
            raise _Unsupported('Payload exceeds memory')

    def byte(self, address):
        offset = address - self.base
        if not 0 <= offset < len(self.data):
            raise _Unsupported('Pointer outside loaded data')
        return self.data[offset]

    def word(self, address):
        return self.byte(address) | self.byte(address + 1) << 8


def _operands(pattern, data):
    hits = list(pattern.finditer(data))
    if len(hits) != 1:
        raise _Unsupported('Missing or ambiguous code signature')
    return tuple(int.from_bytes(g, 'little') for g in hits[0].groups())


@dataclass
class _Row:
    start: int
    note_address: int
    note: int
    instrument: int | None
    duration: int | None
    tie: bool
    commands: tuple


def _sequence(image, address, command_table):
    rows = []
    pos = address
    # Y is an 8-bit sequence offset; packed sequences must fit one page's length.
    while pos - address < 256:
        start, instrument, commands = pos, None, []
        duration, tie = None, False
        while image.byte(pos) >= 0x80:
            value = image.byte(pos)
            pos += 1
            if pos - address >= 256:
                raise _Unsupported('Unterminated sequence')
            if value < 0xa0:
                duration, tie = value & 15, bool(value & 16)
            elif value < 0xc0:
                instrument = value & 31
            else:
                index = value & 63
                opcode = image.byte(command_table + 2 * index)
                param = image.byte(command_table + 2 * index + 1)
                if opcode & 0xf0 == 0xe0:
                    raise _Unsupported('Tempo command')
                commands.append((value, opcode, param))
        note = image.byte(pos)
        if note == 0x7f:
            if pos != start:
                raise _Unsupported('Prefixes before sequence terminator')
            return rows
        rows.append(_Row(start, pos, note, instrument, duration,
                         tie or note == 0x7e, tuple(commands)))
        pos += 1
    raise _Unsupported('Unterminated sequence')


def _order(image, start, loop_address):
    entries, positions, pos, transpose = [], {}, start, 0
    for _ in range(256):
        value = image.byte(pos)
        if value in (0xfe, 0xff):
            if value == 0xfe:
                return entries, None
            if loop_address not in positions:
                raise _Unsupported('Loop outside order list')
            return entries, positions[loop_address]
        positions[pos] = len(entries)
        if value & 0x80:
            transpose = value & 0x7f
            if transpose >= 64:
                transpose -= 128
            pos += 1
            value = image.byte(pos)
            if value >= 0x80:
                raise _Unsupported('Invalid order entry')
        entries.append((value, transpose))
        pos += 1
    raise _Unsupported('Unterminated order list')


def extract(sid_bytes, subtune, frames, memtrace) -> StructureHints | None:
    """Extract NP20 packed data, checking every observed row against memory reads.

    ``subtune`` is 1-based; ``frames`` comes from convert.parse_trace and
    ``memtrace`` is a sequence of memtrace.Call objects starting at play call 0.
    Note indexes remain source values; transposition is in the order list.
    No table addresses, voice assignments or notes are inferred from SID gates.
    """
    try:
        return _extract(sid_bytes, subtune, frames, memtrace)
    except (ValueError, IndexError, struct.error, TypeError):
        return None


def _extract(raw, subtune, frames, calls):
    if '(JCH_NewPlayer_V20)' not in identify(raw):
        return None
    if not frames or not calls or len(frames) != len(calls):
        return None
    if any(c.index != i for i, c in enumerate(calls)):
        return None
    if not 1 <= subtune <= int.from_bytes(raw[14:16], 'big'):
        return None
    image = _Image(raw)
    order_low, zp_low, order_high, zp_high, seq_low, seq_high = _operands(_POINTERS, image.data)
    table, init_low, loop_low, table_high, init_high, loop_high = _operands(_INIT, image.data)
    if (init_low, init_high) != (order_low, order_high) or table_high != table + 1 or zp_high != zp_low + 1:
        return None
    instrument_table, = _operands(_INSTRUMENT, image.data)
    command_table, = _operands(_COMMAND, image.data)
    _operands(_TIMING, image.data)  # reads at counter 2; sounds at counter 0
    song = table + (subtune - 1) * 8
    period = image.byte(song + 6) + 1
    flags = image.byte(song + 7)
    if period < 3:
        return None  # alternating funk-tempo table
    if any(not flags & (1 << v) for v in range(3)):
        return None  # disabled voices need a different init path
    if flags & 0x80:
        if _operands(_LOOP_INIT, image.data) != (table + 2, loop_low, table + 3, loop_high):
            return None
    reads = [c.reads for c in calls]

    def read(call, lo, hi):
        return all(any(a <= address <= b for a, b in reads[call])
                   for address in range(lo, hi + 1))

    hints = StructureHints('JCH NewPlayer', '20', tuple(VoiceHints() for _ in range(3)),
                           tempo_calls=[period])
    hints.warnings.append('Instrument bytes are from the loaded file, before runtime table edits.')
    sequences = {}
    loop_calls = []
    for voice, vh in enumerate(hints.voices):
        start = image.word(song + 2 * voice)
        loop = image.word(song + 8 + 2 * voice) if flags & 0x80 else start
        vh.orderlist, vh.loop_index = _order(image, start, loop)
        if not vh.orderlist:
            return None
        # The first read is at init counter 3 -> counter 2, on play call 0.
        call, order_index, first_loop, duration = 0, 0, None, 0
        while call < len(calls):
            pattern, transpose = vh.orderlist[order_index]
            if pattern not in sequences:
                address = image.byte(seq_low + pattern) | image.byte(seq_high + pattern) << 8
                sequences[pattern] = _sequence(image, address, command_table)
            rows = sequences[pattern]
            if not rows:
                return None
            if call + 2 < len(frames):
                vh.pattern_calls.append(call + 2)
            for row in rows:
                if call >= len(calls):
                    break
                # The next byte is lookahead. Requiring it prevents mistaking
                # the preceding row's lookahead for this row's actual read.
                if not read(call, row.start, row.note_address + 1):
                    return None
                sounded = call + 2
                if sounded < len(frames):
                    vh.row_calls.append(sounded)
                    if row.note not in (0, 0x7e):
                        vh.notes.append(NoteHint(sounded, row.note, row.instrument, row.tie,
                                                 row.commands or None))
                    if row.instrument is not None:
                        address = instrument_table + 8 * row.instrument
                        hints.instruments[row.instrument] = {
                            'raw': bytes(image.byte(address + i) for i in range(8))}
                if row.duration is not None:
                    duration = row.duration
                call += period * (duration + 1)
            order_index += 1
            if order_index == len(vh.orderlist):
                if vh.loop_index is None:
                    break
                order_index = vh.loop_index
                if first_loop is None and call + 2 < len(frames):
                    first_loop = call + 2
        loop_calls.append(first_loop)
    if all(c is not None for c in loop_calls) and len(set(loop_calls)) == 1:
        hints.loop_call = loop_calls[0]
    return hints
