"""Find lossless, transposable sequence covers for one CheeseCutter subtune.

Rows describe events, not sounding notes: a rest leaves player state alone.
Instrument wave-table notes are outside this model and never transposed.
The bounded hash search and greedy dictionary cover are heuristic, not a
proof of global optimality. Costs count exported bytes, including wrap entries.
"""
from collections import Counter
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Row:
    note: int = None
    instrument: int = None
    command: int = 0
    tie: bool = False
    gate: int = None
    rest: bool = True

    def __post_init__(self):
        if self.note is not None and not 3 <= self.note <= 94:
            raise ValueError('note must be in 3..94')
        if self.instrument is not None and not 0 <= self.instrument < 48:
            raise ValueError('instrument must be in 0..47')
        if not 0 <= self.command <= 255 or self.gate not in (None, 1, 2):
            raise ValueError('invalid row control')
        if sum((self.note is not None, self.gate is not None, self.rest)) != 1:
            raise ValueError('row must be a note, gate event or rest')

    def native(self):
        value = self.note if self.note is not None else self.gate or 0
        return (0xF0 if self.instrument is None else 0xC0+self.instrument,
                0x5F if self.tie else 0xF0, 0x60+value, self.command)

    @classmethod
    def from_native(cls, raw):
        ins, tie, note, cmd = raw
        value = note % 0x60
        return cls(value if value >= 3 else None,
                   ins-0xC0 if 0xC0 <= ins < 0xF0 else None,
                   cmd, tie == 0x5F, value if value in (1, 2) else None,
                   value == 0)


def encode(rows):
    """Encode durations and local repeated instruments like Sequence.compact.

    First instruments are retained: an instrument event resets effect state,
    so matching shinst alone does not prove it removable at a boundary.
    """
    out = bytearray()
    oldins = olddelay = None
    i = 0
    while i < len(rows):
        row = rows[i]
        delay = 0
        while i+delay+1 < len(rows):
            following = rows[i+delay+1]
            # Sequence.compact ignores tie flags on following empty rests.
            if not following.rest or following.command or following.instrument is not None:
                break
            delay += 1
        if row.instrument is not None and row.instrument != oldins:
            out.append(0xC0+row.instrument)
            oldins = row.instrument
        delay &= 15  # Export stores the remainder before full 16-row holds.
        if delay != olddelay:
            out.append(0xF0+delay)
            olddelay = delay
        if row.tie:
            out.append(0x5F)
        note = row.note if row.note is not None else row.gate or 0
        out.append(note+0x60 if row.command else note)
        if row.command:
            out.append(row.command)
        i += delay+1
    out.append(0xBF)
    return bytes(out)


@dataclass(frozen=True)
class Layout:
    sequences: tuple
    orders: tuple
    restarts: tuple

    def expand(self):
        return expand(self)


def expand(layout):
    return tuple(tuple(replace(row, note=row.note+trans) if row.note is not None else row
                       for trans, seq in order for row in layout.sequences[seq-1])
                 for order in layout.orders)


def layout_cost(layout):
    return sum(len(encode(seq)) for seq in layout.sequences)+sum(2*len(o)+2 for o in layout.orders)


def _normal(block):
    # Ties defer pitch changes; commands can arm sticky portamento, chords,
    # or change timing. Without their incoming state, refuse transposition.
    if any(r.tie or r.command for r in block):
        return block, 0
    notes = [r.note for r in block if r.note is not None]
    if not notes:
        return block, 0
    # A legal representative with a bounded, explicit transpose ($80 is keep).
    shift = max(-31, min(31, notes[0]-36))
    shift = max(max(notes)-94, min(min(notes)-3, shift))
    return tuple(replace(r, note=r.note-shift) if r.note is not None else r for r in block), shift


def compress(voices, *, loop_start=0, preferred_cut_points=None,
             search_row_budget=1_000_000, max_sequences=127):
    """Mine normalized windows and greedily cover them by shared byte savings.

    The fixed cover is always a contender. Preferred cuts break cost ties;
    the loop boundary is mandatory. Search is bounded in row-element work.
    """
    voices = tuple(tuple(v) for v in voices)
    if not voices or not voices[0] or any(len(v) != len(voices[0]) for v in voices):
        raise ValueError('voices must have equal nonzero lengths')
    n = len(voices[0])
    if not 0 <= loop_start < n or not 1 <= max_sequences <= 127:
        raise ValueError('invalid layout limits or loop start')
    if any(not isinstance(r, Row) for v in voices for r in v):
        raise ValueError('streams must contain Row objects')
    regions = ((0, loop_start), (loop_start, n)) if loop_start else ((0, n),)
    preferred = preferred_cut_points or [() for _ in voices]
    if len(preferred) != len(voices):
        raise ValueError('preferred cuts must be supplied per voice')
    counts = Counter()
    # Spend the budget across every voice, rather than exhausting it on the
    # first voice. Every position is eligible, including off-grid repeats.
    lengths = tuple(range(2, 65))
    positions = sum(stop-start for start, stop in regions)*len(voices)
    if positions*sum(lengths) > search_row_budget:
        lengths = tuple(length for length in (4, 8, 12, 16, 24, 32, 48, 64)
                        if positions*sum(x for x in (4, 8, 12, 16, 24, 32, 48, 64)
                                         if x <= length) <= search_row_budget)
    for voice in voices:
        for start, stop in regions:
            for pos in range(start, stop):
                for length in lengths:
                    if pos+length <= stop:
                        counts[_normal(voice[pos:pos+length])[0]] += 1
    encoded_cost = {}
    def byte_cost(block):
        if block not in encoded_cost:
            encoded_cost[block] = len(encode(block))
        return encoded_cost[block]
    def cover(mining, grid=None):
        sequences, ids, orders, restarts = [], {}, [], []
        for vid, voice in enumerate(voices):
            order = []
            restart = 0
            for start, stop in regions:
                if start == loop_start:
                    restart = len(order)
                pos = start
                while pos < stop:
                    choices = []
                    block_lengths = ((min(grid,stop-pos),) if grid else
                                     range(1,min(64,stop-pos)+1))
                    for length in block_lengths:
                        block, trans = _normal(voice[pos:pos+length]) if mining else (voice[pos:pos+length], 0)
                        cost = byte_cost(block)
                        if cost > 256:
                            continue
                        repeats = counts[block] if mining else 1
                        # Re-Pair-style shared dictionary admission: amortize
                        # definition bytes over repeated uses, charge each order.
                        effective = (0 if block in ids else cost/max(1, repeats))+2
                        rank = (effective/length, pos+length not in preferred[vid], -length)
                        if (mining and grid is None) or length == min(grid or 64, stop-pos):
                            choices.append((rank, block, trans, length))
                    if not choices:
                        raise ValueError('sequence exceeds byte capacity')
                    _, block, trans, length = min(choices, key=lambda x: x[0])
                    if block not in ids:
                        if len(sequences) >= max_sequences:
                            raise ValueError('layout exceeds sequence capacity')
                        ids[block] = len(sequences)+1
                        sequences.append(block)
                    order.append((trans, ids[block]))
                    pos += length
            if len(order) > 511:
                raise ValueError('layout exceeds order capacity including wrap')
            orders.append(tuple(order))
            restarts.append(restart)
        return Layout(tuple(sequences), tuple(orders), tuple(restarts))
    def dynamic_cover():
        # Price shared definitions across all voices, then find the cheapest
        # path through each region. A local greedy choice misses later reuse.
        sequences, ids, orders, restarts = [], {}, [], []
        for voice in voices:
            order = []
            restart = 0
            for start, stop in regions:
                if start == loop_start:
                    restart = len(order)
                costs = {stop: 0.0}
                steps = {}
                for pos in range(stop-1, start-1, -1):
                    choices = []
                    for length in set(lengths) | {min(64, stop-pos)}:
                        if pos+length > stop:
                            continue
                        block, trans = _normal(voice[pos:pos+length])
                        cost = byte_cost(block)
                        if cost > 256:
                            continue
                        uses = max(1, counts[block])
                        price = (0 if block in ids else cost/uses)+2
                        choices.append((price+costs[pos+length], -length,
                                        block, trans, length))
                    if not choices:
                        raise ValueError('sequence exceeds byte capacity')
                    choice = min(choices,key=lambda c:c[:2])
                    costs[pos] = choice[0]
                    steps[pos] = choice[2:]
                pos = start
                while pos < stop:
                    block, trans, length = steps[pos]
                    if block not in ids:
                        ids[block] = len(sequences)+1
                        sequences.append(block)
                    order.append((trans,ids[block]))
                    pos += length
            orders.append(tuple(order))
            restarts.append(restart)
        if len(sequences)>max_sequences or any(len(o)>511 for o in orders):
            raise ValueError('layout exceeds native capacity')
        return Layout(tuple(sequences),tuple(orders),tuple(restarts))

    candidates = []
    for mining in ((False, True) if search_row_budget else (False,)):
        try:
            candidates.append(cover(mining))
        except ValueError:
            pass
    if search_row_budget:
        # Regular periods provide inexpensive contenders for the free-cut
        # cover. Sharing several repetitions together amortizes order bytes.
        for grid in range(2,65):
            try:
                candidates.append(cover(True,grid))
            except ValueError:
                pass
        try:
            candidates.append(dynamic_cover())
        except ValueError:
            pass
    if not candidates:
        raise ValueError('no layout fits native limits')
    result = min(candidates, key=layout_cost)
    if expand(result) != voices:
        raise ValueError('layout expansion changed rows')
    return result


def chunk_layout(voices, *, loop_start=0):
    voices = tuple(tuple(v) for v in voices)
    if not voices or not voices[0] or any(len(v)!=len(voices[0]) for v in voices):
        raise ValueError('voices must have equal nonzero lengths')
    n = len(voices[0])
    if not 0 <= loop_start < n:
        raise ValueError('invalid loop start')
    regions = ((0, loop_start), (loop_start, n)) if loop_start else ((0,n),)
    sequences, ids, orders, restarts = [], {}, [], []
    for voice in voices:
        order = []
        restart = 0
        for start, stop in regions:
            if start == loop_start:
                restart = len(order)
            for pos in range(start, stop, 64):
                block = voice[pos:min(pos+64,stop)]
                if block not in ids:
                    ids[block] = len(sequences)+1
                    sequences.append(block)
                order.append((0,ids[block]))
        orders.append(tuple(order))
        restarts.append(restart)
    if len(sequences)>127 or any(len(o)>511 for o in orders):
        raise ValueError('layout exceeds native capacity')
    return Layout(tuple(sequences),tuple(orders),tuple(restarts))


def comparison(voices, layout, *, loop_start=0):
    fixed = layout_cost(chunk_layout(voices, loop_start=loop_start))
    compact = layout_cost(layout)
    chunks = chunk_layout(voices, loop_start=loop_start)
    return dict(chunks_bytes=fixed, compact_bytes=compact, saved_bytes=fixed-compact,
                chunks_sequence_bytes=sum(len(encode(s)) for s in chunks.sequences),
                compact_sequence_bytes=sum(len(encode(s)) for s in layout.sequences),
                chunks_order_bytes=sum(2*len(o)+2 for o in chunks.orders),
                compact_order_bytes=sum(2*len(o)+2 for o in layout.orders))


def without_repeated_instruments(voices):
    """Propose omissions; validate them with the player before accepting."""
    result = []
    for voice in voices:
        instrument = None
        rows = []
        for row in voice:
            if row.instrument is not None:
                if row.instrument == instrument:
                    row = replace(row, instrument=None)
                else:
                    instrument = row.instrument
            rows.append(row)
        result.append(tuple(rows))
    return tuple(result)


def player_for_layout(image, layout, *, packed=True):
    """Initialize export feature selection from editable rows, then pack them.

    CTPlayer expects editable four-byte rows when discovering instruments,
    but its sequencer accepts the exported duration/instrument byte stream.
    """
    import struct
    from .ctplayer import CTPlayer, TRACKS
    data = bytearray(image)
    pointers = struct.unpack_from('<39H', data, 0xFA0)
    packed_rows = []
    for seq in range(128):
        addr = data[pointers[22]+seq] | data[pointers[23]+seq] << 8
        rows = layout.sequences[seq-1] if 1 <= seq <= len(layout.sequences) else (Row(),)
        raw = bytes(x for row in rows for x in row.native())
        data[addr:addr+256] = (raw + (b'\xbf' if len(rows)<64 else b'')).ljust(256, b'\0')
        packed_rows.append((addr, encode(rows)))
    empty = (bytes((0xA0, 0, 0xF0, 0))).ljust(1024, b'\0')
    data[TRACKS:TRACKS+32*3*1024] = empty*(32*3)
    for vid, (order, restart) in enumerate(zip(layout.orders, layout.restarts)):
        raw = bytes(x for trans, seq in order for x in (0xA0+trans, seq))
        raw += bytes((0xF0 | ((restart*2)>>8), (restart*2)&255))
        data[TRACKS+vid*1024:TRACKS+(vid+1)*1024] = raw.ljust(1024,b'\0')
    player = CTPlayer(data)
    for addr, raw in (packed_rows if packed else ()):
        if len(raw)>256:
            raise ValueError('Packed sequence exceeds capacity')
        data[addr:addr+256] = raw.ljust(256,b'\0')
    player.image = bytes(data)
    return player


def verify_player(image, original, candidate, *, loop_start=0, calls=None):
    """Refuse undefined tuning reads and compare complete SID output.

    Out-of-range reads access export-dependent adjacent memory. Even equal
    editable-image traces cannot prove equality after relocation in that case.
    Cover the capture and two loop passes, including pending boundary state.
    """
    baseline = chunk_layout(original, loop_start=loop_start)
    left = player_for_layout(image, baseline)
    right = player_for_layout(image, candidate)
    frequency = left._frequency
    def checked_frequency(note):
        if not 0 <= (note & 255) < 96:
            raise ValueError(f'Player tuning index {note & 255} outside 0..95; export memory depends on layout')
        return frequency(note)
    left._frequency = checked_frequency
    other_frequency = right._frequency
    def checked_other(note):
        if not 0 <= (note & 255) < 96:
            raise ValueError('Candidate reads outside tuning table')
        return other_frequency(note)
    right._frequency = checked_other
    n = len(original[0])
    if calls is None:
        calls = (n+2*(n-loop_start)+64)*(max(3, left.speed+1))*left.multiplier+8
    for call in range(calls):
        if left.frames(1)[0] != right.frames(1)[0]:
            raise ValueError(f'Layout changed player registers at call {call}')
    return calls


def row_statistics(voices):
    """Distinct content shares at every start, across physical voices."""
    rows = [row for voice in voices for row in voice]
    active = [row for row in rows if row != Row()]
    result = dict(rows=len(rows), distinct_rows=len(set(rows)),
                  distinct_row_share=len(set(rows))/len(rows),
                  active_rows=len(active), distinct_active_rows=len(set(active)),
                  distinct_active_row_share=len(set(active))/max(1,len(active)))
    for length in (8,16,32,64):
        blocks = [voice[pos:pos+length] for voice in voices
                  for pos in range(len(voice)-length+1)]
        result[f'distinct_{length}_row_block_share'] = len(set(blocks))/max(1,len(blocks))
    return result


def verify_export(image, original, candidate, *, loop_start=0, calls=15000):
    """Check the assembled export too, including its order-list packing."""
    from pathlib import Path
    import subprocess
    import tempfile
    import zlib
    tool = Path(__file__).resolve().parents[1]/'ct2util'
    if not tool.is_file():
        raise ValueError('Cannot verify compact export: ct2util is missing')
    baseline = chunk_layout(original, loop_start=loop_start)
    traces = []
    with tempfile.TemporaryDirectory(prefix='sid2ct-layout-') as directory:
        for name, plan in (('chunks', baseline), ('compact', candidate)):
            stem = Path(directory)/name
            editable = player_for_layout(image, plan, packed=False).image
            stem.with_suffix('.ct').write_bytes(b'CC2'+zlib.compress(editable))
            for command in (
                [str(tool), 'sid', str(stem.with_suffix('.ct')), '-o', str(stem.with_suffix('.sid'))],
                [str(tool), 'sidtrace', str(stem.with_suffix('.sid')), '-f', str(calls), '-o', str(stem.with_suffix('.trace'))],
            ):
                result = subprocess.run(command, capture_output=True, text=True)
                if result.returncode:
                    raise ValueError('Compact export verification failed: '+result.stdout+result.stderr)
            traces.append(stem.with_suffix('.trace').read_bytes().splitlines())
    if traces[0] != traces[1]:
        first = next((i for i, pair in enumerate(zip(*traces)) if pair[0] != pair[1]),
                     min(map(len, traces)))
        raise ValueError(f'Compact export changed SID registers at call {first}')
    return calls
