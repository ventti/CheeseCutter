"""Code-relative, trace-checked packed JCH/Laxity NewPlayer extraction.

Known layouts: NP14, NP15, NP20 and Laxity NP21. Pointer
operands locate source tables; memory reads establish row timing. Unknown
layouts or inconsistent timelines are rejected rather than guessed.
"""
import re
import struct
from dataclasses import dataclass

from .hints import NoteHint, SequenceInfo, StructureHints, VoiceHints, gate_rise_agreement
from .sidid import identify, sid_payload


# Order pointer -> optional transpose -> sequence index -> split sequence vectors.
_POINTERS = re.compile(
    rb'\xbd(..)\x85(.)\xbd(..)\x85(.)\xa0\x00\x98\x9d..'
    rb'\xb1.\x10\x0f\x0a\x9d..\xfe..\xd0\x03\xfe..\xc8\xb1.'
    rb'\xa8\xb9(..)\x85.\xb9(..)\x85.', re.DOTALL)
_INIT = re.compile(
    rb'\x0a\x0a\x0a\xa8\xa2\x00(?:\x8e..)?\xb9(..)\x9d(..)\x9d(..)'
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
    values = {tuple(int.from_bytes(g, 'little') for g in hit.groups()) for hit in hits}
    if len(values) != 1:
        raise _Unsupported('Missing or ambiguous code signature')
    return values.pop()


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
    """Extract packed NewPlayer data, checking rows against memory reads.

    ``subtune`` is 1-based; ``frames`` comes from convert.parse_trace and
    ``memtrace`` is a sequence of memtrace.Call objects starting at play call 0.
    Note indexes remain source values; transposition is in the order list.
    No table addresses, voice assignments or notes are inferred from SID gates.
    """
    try:
        return _extract(sid_bytes, subtune, frames, memtrace)
    except (ValueError, IndexError, struct.error, TypeError):
        return None


# Earlier generations use a precomputed duration table rather than a global
# countdown. Both operands are recovered from the duration-prefix handler.
_OLD_DURATION = re.compile(
    rb'\x68\x29\x0f\xa8\xb9(..)\x9d..\x9d..\xfe', re.DOTALL)
_OLD_INSTRUMENT = re.compile(
    rb'\xbc(..)\xb9(..)\xbc..\x99\x05\xd4', re.DOTALL)
_OLD_COMMAND = re.compile(rb'\x68\x29\x3f\x0a\xa8\xb9(..)\x48\x29\xc0', re.DOTALL)


def _extract(raw, subtune, frames, calls):
    matches = identify(raw)
    versions = [int(m.group(1)) for label in matches
                if (m := re.fullmatch(r'\(JCH_NewPlayer_V(\d+)\)', label))]
    if 'Laxity_NewPlayer_V21' in matches:
        versions = [21]
    if not versions or max(versions) not in (14, 15, 20, 21):
        return None
    version = max(versions)
    if not frames or not calls or len(frames) != len(calls):
        return None
    if any(c.index != i for i, c in enumerate(calls)):
        return None
    if not 1 <= subtune <= int.from_bytes(raw[14:16], 'big'):
        return None
    image = _Image(raw)
    if version == 21:
        table, order_low, loop_low, table_high, order_high, loop_high = _operands(
            re.compile(rb'\x0a\x0a\x0a\xa8\xa2\x00(?:\x8e..)?\xb9(..)\x9d(..)\x9d(..)'
                       rb'\xc8\xb9(..)\x9d(..)\x9d(..)\xc8\xe8\xe0\x03\xd0.', re.DOTALL), image.data)
        if table_high != table:
            raise _Unsupported('Inconsistent song table')
        seq_low, seq_high = _operands(re.compile(
            rb'\xbc..\xb9(..)\x85.\xb9(..)\x85.\xa9\x02\x9d..\xbc..\xb1.', re.DOTALL), image.data)
        instrument_table, = _operands(re.compile(
            rb'\xbd..\x9d..\xa8\xb9(..)\x9d..\xb9..\x9d..\xa9\x00\x9d', re.DOTALL), image.data)
        command_table, = _operands(re.compile(
            rb'\xbc..\xb9(..)\x10.\x29\xf0\xc9\x80', re.DOTALL), image.data)
    else:
        order_low, zp_low, order_high, zp_high, seq_low, seq_high = _operands(_POINTERS, image.data)
        table, init_low, loop_low, table_high, init_high, loop_high = _operands(_INIT, image.data)
        if (init_low, init_high) != (order_low, order_high) or table_high != table + 1 or zp_high != zp_low + 1:
            return None
        if version == 20:
            instrument_table, = _operands(_INSTRUMENT, image.data)
            command_table, = _operands(_COMMAND, image.data)
        else:
            instrument_index, instrument_table = _operands(_OLD_INSTRUMENT, image.data)
            if version == 14:
                param_table, command_table = _operands(re.compile(
                    rb'\x68\x29\x3f\x0a\xa8\xb9(..)\x9d..\xb9(..)\x48\x29\x1f', re.DOTALL), image.data)
                if param_table != command_table + 1:
                    raise _Unsupported('Inconsistent command table')
            else:
                command_table, = _operands(_OLD_COMMAND, image.data)
    duration_table = None
    if version < 20:
        duration_table, = _operands(_OLD_DURATION, image.data)
    elif version == 20:
        counter_address, = _operands(_TIMING, image.data)
        init_values = {m.group(1)[0] for m in re.finditer(
            rb'\xa9(.)\x8d' + re.escape(counter_address.to_bytes(2, 'little')), image.data, re.DOTALL)}
        if len(init_values) > 1:
            raise _Unsupported('Ambiguous initial clock')
        initial_counter = init_values.pop() if init_values else image.byte(counter_address)
    song = table + (subtune - 1) * 8
    period = image.byte(song + 6) + 1
    flags = image.byte(song + 7)
    if version == 20 and re.search(
            rb'\xb9' + re.escape(table.to_bytes(2, 'little')) + rb'\x8d'
            + re.escape(counter_address.to_bytes(2, 'little')) + rb'\x8d..', image.data, re.DOTALL):
        # Some builds copy the song's tempo into both countdown and reload
        # state at init. The saved runtime counter in the file is then stale.
        initial_counter = period - 1
    if flags & 0x80 and version != 21:
        if _operands(_LOOP_INIT, image.data) != (table + 2, loop_low, table + 3, loop_high):
            return None
    funk = funk_values = None
    if version >= 20:
        pattern = (re.compile(rb'\xac..\xb9(..)\x8d..\xce', re.DOTALL)
                   if version == 20 else
                   re.compile(rb'\xa8\xb9(..)\xc9\x02\x10.', re.DOTALL))
        funk_address, = _operands(pattern, image.data)
        funk_values = [image.byte(funk_address + i) + 1 for i in range(2 if version == 20 else 4)]
        if period < 3:
            funk = funk_values
    reads = [c.reads for c in calls]

    def read(call, lo, hi):
        return all(any(a <= address <= b for a, b in reads[call])
                   for address in range(lo, hi + 1))

    hints = StructureHints('JCH NewPlayer', str(version), tuple(VoiceHints() for _ in range(3)),
                           tempo_calls=[period])
    hints.tables['instruments'] = {'address': instrument_table, 'entries': hints.instruments}
    hints.tables['commands'] = {'address': command_table, 'entries': {}}
    if duration_table is not None:
        hints.tables['durations'] = {'address': duration_table,
                                    'raw': bytes(image.byte(duration_table + i) for i in range(16))}
    hints.warnings.append('Instrument bytes are from the loaded file, before runtime table edits.')
    if funk_values:
        hints.tables['funk'] = {'address': funk_address, 'raw': bytes(x - 1 for x in funk_values)}
    if funk:
        hints.tempo_calls = list(dict.fromkeys(funk))
    gate_modes = None
    if version == 15:
        gate_address, = _operands(re.compile(
            rb'\xbd..\xf0.\xbd(..)\xf0.\xc9\x01', re.DOTALL), image.data)
        gate_modes = [image.byte(gate_address + v) for v in range(3)]
        if any(m not in (0, 1, 2) for m in gate_modes):
            raise _Unsupported('Unknown gate mode')
        hints.tables['gate_modes'] = {'address': gate_address, 'raw': bytes(gate_modes)}
    # NP20 wave programs use split control/note columns. Store only entries
    # actually read during this trace; their bounds are verified in the image.
    if version == 20:
        wave_patterns = list(re.finditer(
            rb'\xbc..\xb9(..)\xc9\x7e\xd0.\xde..\x88\x4c..'
            rb'\xc9\x7f\xd0.\xb9(..)\x9d', image.data, re.DOTALL))
        wave_bases = {tuple(int.from_bytes(g, 'little') for g in m.groups()) for m in wave_patterns}
        if len(wave_bases) == 1:
            wave, wave_notes = wave_bases.pop()
            if wave_notes > wave:
                for name, base in [('wave', wave), ('wave_notes', wave_notes)]:
                    entries = {i: image.byte(base + i) for i in range(wave_notes - wave)
                               if any(any(lo <= base + i <= hi for lo, hi in c.reads) for c in calls)}
                    hints.tables[name] = {'address': base, 'entries': entries}
    sequences = {}
    initial_period = period
    durations_by_voice = [[], [], []]
    read_calls_by_voice = [[], [], []]
    loop_calls = []
    lag = 2 if version >= 20 else 0
    for voice, vh in enumerate(hints.voices):
        if not flags & (1 << voice):
            loop_calls.append(None)
            continue
        start = image.word(song + 2 * voice)
        loop = image.word(song + 8 + 2 * voice) if flags & 0x80 else start
        vh.orderlist, vh.loop_index = _order(image, start, loop)
        if not vh.orderlist:
            loop_calls.append(None)
            continue
        for pattern, _ in vh.orderlist:
            address = image.byte(seq_low + pattern) | image.byte(seq_high + pattern) << 8
            if pattern not in sequences:
                sequences[pattern] = _sequence(image, address, command_table)
            rows = sequences[pattern]
            if not rows:
                raise _Unsupported('Empty sequence')
            vh.sequences[pattern] = SequenceInfo(address, rows[-1].note_address + 2 - address)
        period = initial_period
        call, order_index, first_loop, duration = 0, 0, None, 0
        pending = None
        active = False
        current_instrument = image.byte(instrument_index + voice) // 8 if version == 14 else 0
        looping = False
        while call < len(calls):
            pattern, transpose = vh.orderlist[order_index]
            rows = sequences[pattern]
            for index, row in enumerate(rows):
                if call >= len(calls):
                    break
                # Find the actual packed-row read, requiring the lookahead byte
                # as well. This distinguishes it from the previous lookahead.
                observed = next((i for i in range(call, len(calls))
                                 if read(i, row.start, row.note_address + 1)), None)
                if observed is None:
                    if pending is None or pending - lag + max(vh.row_durations[-1], max(funk_values if period < 3 and funk_values else [period]) * (duration + 1)) < len(calls):
                        raise _Unsupported('Missing row read')
                    call = len(calls)
                    break
                row_lag = (image.byte(instrument_table + 8 * current_instrument + 3) & 15) + 1 if version == 14 else lag
                if row.instrument is not None:
                    current_instrument = row.instrument
                sounded = observed + row_lag
                if pending is not None:
                    vh.row_durations[-1] = sounded - pending
                if row.duration is not None:
                    duration = row.duration
                row_length = (image.byte(duration_table + duration) + 1
                              if duration_table is not None else period * (duration + 1))
                if sounded < len(frames):
                    if index == 0:
                        vh.pattern_calls.append(sounded)
                        if looping and first_loop is None:
                            first_loop = sounded
                    vh.row_calls.append(sounded)
                    vh.row_durations.append(row_length)
                    durations_by_voice[voice].append(duration + 1)
                    read_calls_by_voice[voice].append(observed)
                    # Zero releases the current gate; $7e holds the note.
                    kind = ('effect' if row.note == 0 and row.commands else
                            ('gate_off' if active else 'rest') if row.note == 0 else
                            'rest' if row.note == 0x7e else 'note')
                    # Non-note rows remain explicit but cannot be counted as
                    # attacks by the shared gate-agreement helper.
                    vh.notes.append(NoteHint(sounded, row.note, row.instrument,
                                             row.tie or kind != 'note' or (gate_modes is not None and gate_modes[voice] == 0 and active),
                                             row.commands or None, kind))
                    active = row.note != 0
                    pending = sounded
                    if row.instrument is not None:
                        addr = instrument_table + 8 * row.instrument
                        hints.instruments[row.instrument] = {
                            'raw': bytes(image.byte(addr + i) for i in range(8))}
                    for value, opcode, param in row.commands:
                        hints.tables['commands']['entries'][value & 63] = bytes((opcode, param))
                        if version in (20, 21) and opcode & 0xf0 == 0xe0:
                            hints.speed_commands.append((sounded, param + 1))
                            period = param + 1
                            if period not in hints.tempo_calls:
                                hints.tempo_calls.append(period)
                call = len(calls) if sounded >= len(frames) else observed + 1
            order_index += 1
            if order_index == len(vh.orderlist):
                if vh.loop_index is None:
                    break
                order_index = vh.loop_index
                looping = True
        loop_calls.append(first_loop)
    commands = sorted(set(hints.speed_commands))
    if len({call for call, _ in commands}) != len(commands):
        raise _Unsupported('Conflicting speed commands')
    if version >= 20:
        # Reproduce the global countdown, including commands from all voices.
        # This also gives a full duration for the final, truncated trace row.
        changes = {call - lag: speed for call, speed in commands}
        period = initial_period
        counter = initial_counter if version == 20 else 2
        phase = 1 if version == 20 else 0
        sentinel_funk = version == 21 and re.search(
            rb'\xc8\xb9' + re.escape(funk_address.to_bytes(2, 'little'))
            + rb'\xd0\x05\x8d..', image.data, re.DOTALL)
        deferred = re.search(
            rb'\xa9\x80\x8d(..)\x60\x2c(..)\x70.\x10.\xa9\x02\x8d..', image.data, re.DOTALL)
        if deferred and deferred.group(1) != deferred.group(2):
            raise _Unsupported('Inconsistent deferred init flag')
        ticks, funk_reloads = [], []
        for call in range(len(calls) + 4096):
            # A deferred NP21 init consumes its first play call before running
            # the countdown. Recover this path from the flag test in code.
            if version == 21 and deferred and call == 0:
                continue
            if call in changes:
                period = changes[call]
            counter -= 1
            if counter < 0:
                if period < 3:
                    if funk_values is None:
                        raise _Unsupported('Missing funk table')
                    counter = funk_values[phase] - 1
                    if version == 21:
                        counter = max(2, counter)
                        next_phase = (phase + 1) % (2 if period == 1 and not sentinel_funk else 4)
                        phase = 0 if sentinel_funk and funk_values[next_phase] == 1 else next_phase
                    else:
                        phase = 1 - phase
                    funk_reloads.append((call, counter + 1))
                else:
                    counter = period - 1
            if counter == 0:
                ticks.append(call + (lag if version == 21 else 0))
        tick_indices = {call: index for index, call in enumerate(ticks)}
        for voice, vh in enumerate(hints.voices):
            for index, (call, duration) in enumerate(zip(vh.row_calls, durations_by_voice[voice])):
                if call not in tick_indices:
                    raise _Unsupported('Row outside source clock')
                next_call = ticks[tick_indices[call] + duration]
                if index + 1 < len(vh.row_calls) and vh.row_calls[index + 1] != next_call:
                    raise _Unsupported('Skipped or inconsistent row')
                vh.row_durations[index] = next_call - call
        hints.speed_commands.extend((call, speed) for call, speed in funk_reloads if call < len(calls))
    elif version < 20:
        for voice, vh in enumerate(hints.voices):
            for index, (a, b) in enumerate(zip(read_calls_by_voice[voice], read_calls_by_voice[voice][1:])):
                expected = image.byte(duration_table + durations_by_voice[voice][index] - 1) + 1
                # NP14 fetches the next row early by the previous instrument's
                # gate delay; changing instruments moves that fetch boundary.
                if version != 14 and b - a != expected:
                    raise _Unsupported('Skipped or inconsistent row')
    hints.speed_commands = sorted(set(hints.speed_commands))
    if all(c is not None for c in loop_calls) and len(set(loop_calls)) == 1:
        hints.loop_call = loop_calls[0]
    if gate_rise_agreement(hints, frames) < 0.98 and any(not n.tie for v in hints.voices for n in v.notes):
        raise _Unsupported('Gate timing disagrees with decoded rows')
    # A source note may be deliberately tied, but an unexplained audible gate
    # rise means the decoded stream is incomplete. Reject the whole result.
    matched = total = 0
    for voice, vh in enumerate(hints.voices):
        control = voice * 7 + 4
        notes = {n.call for n in vh.notes if n.kind == 'note'}
        for i in range(1, len(frames)):
            if (frames[i][control] & 1 and not frames[i - 1][control] & 1
                    and any(frames[j][control] & 0xf0 for j in range(i, min(i + 4, len(frames))))):
                total += 1
                matched += any(i + delta in notes for delta in (-1, 0, 1))
    if total and matched / total < 0.95:
        raise _Unsupported('Audible gate rises missing from decoded rows')
    return hints
