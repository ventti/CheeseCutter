"""Player-agnostic structure discovery from `ct2util sidtrace --mem-reads`.

The trace lists, per play call, which data addresses the player read. Song
data is read in a recognisable way: a pointer walks forward through a stream
(orderlist, sequence) and each walk step happens when a new row is due. This
module recovers streams, row events, row timing and stream start addresses
from those reads alone. It knows no player-specific addresses.

Limits: a stream shorter than MIN_CELLS cells is not reported; two streams
stored back to back and played in order look like one; voice tracks are
assigned by time overlap only, so equal-time switches can swap voices.
"""
from collections import Counter
from dataclasses import dataclass, field
from math import gcd
import re

MIN_CELLS = 3          # fewest consecutive reads that make a stream
MIN_GAP = 2            # median calls between steps of a row-rate stream
MAX_CELL = 16          # wider reads are tables or copies, not a row
DRIVER_WINDOW = 2      # calls between a driver step and the stream it selects
DENSE_FRACTION = 0.4   # address read in more calls than this is state, not data


@dataclass
class Call:
    index: int
    reads: list          # (start, end) inclusive ranges, outside zero page
    zp: list             # (start, end) inclusive zero-page ranges
    writes: list         # (reg, value, cycle)


def _ranges(text):
    out = []
    for part in text.split(','):
        if part:
            a, _, b = part.partition('-')
            out.append((int(a, 16), int(b or a, 16)))
    return out


def parse(text):
    """Parse the --mem-reads file into a list of Call."""
    calls = []
    for line in text.splitlines():
        f = line.split('\t')
        if len(f) != 4 or not f[1].startswith('R:'):
            raise ValueError(f'Not a --mem-reads line: {line[:60]!r}')
        writes = []
        for w in f[3][2:].split():
            m = re.fullmatch(r'([0-9a-f]{2}):([0-9a-f]{2})@(\d+)', w)
            if not m:
                raise ValueError(f'Bad write {w!r}')
            writes.append((int(m[1], 16), int(m[2], 16), int(m[3])))
        calls.append(Call(int(f[0]), _ranges(f[1][2:]), _ranges(f[2][2:]), writes))
    return calls


@dataclass
class Stream:
    """One run of a pointer walking forward: cells are (call, start, end)."""
    cells: list = field(default_factory=list)

    @property
    def start(self):
        return self.cells[0][1]

    @property
    def end(self):
        return self.cells[-1][2]

    @property
    def calls(self):
        return [c for c, _, _ in self.cells]


def _sparse_cells(calls):
    """Per call, the read ranges whose addresses are not read every call."""
    total = max(1, len(calls))
    count = Counter()
    for c in calls:
        for a, b in c.reads:
            count.update(range(a, b + 1))
    dense = {a for a, n in count.items() if n > DENSE_FRACTION * total}
    result = []
    for c in calls:
        cells = []
        for a, b in c.reads:
            lo = None
            for x in range(a, b + 2):
                keep = x <= b and x not in dense
                if keep and lo is None:
                    lo = x
                elif not keep and lo is not None:
                    cells.append((lo, x - 1))
                    lo = None
        result.append(cells)
    return result


def _median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2]


def _slow(stream):
    """True unless the pointer steps on (nearly) every call.

    Wave, pulse and filter table programs walk forward each tick; song data
    walks once per row. Row-rate-1 songs are therefore not recoverable.
    """
    gaps = [b - a for a, b in zip(stream.calls, stream.calls[1:])]
    return _median(gaps) >= MIN_GAP


def find_streams(calls):
    """Chain sparse cells where a pointer moves forward through data.

    A cell continues a chain when it starts after the previous cell's start
    and no later than one past its end. Players often re-read the byte under
    the pointer, so overlapping cells are normal. Returns all chains with at
    least MIN_CELLS cells, in start-call order.
    """
    open_at = {}        # address -> chain that a cell starting there continues
    chains = []
    for c, cells in zip(calls, _sparse_cells(calls)):
        claimed = set()
        updates = []
        for a, b in cells:
            if b - a >= MAX_CELL:
                continue
            chain = open_at.get(a)
            if chain is not None and id(chain) not in claimed:
                for x in range(chain.cells[-1][1] + 1, chain.cells[-1][2] + 2):
                    if open_at.get(x) is chain:
                        del open_at[x]
                chain.cells.append((c.index, a, b))
            else:
                chain = Stream([(c.index, a, b)])
                chains.append(chain)
            claimed.add(id(chain))
            updates.append((chain, a, b))
        for chain, a, b in updates:
            for x in range(a + 1, b + 2):
                open_at[x] = chain
    return [s for s in chains if len(s.cells) >= MIN_CELLS and _slow(s)]


def split_drivers(streams):
    """Separate orderlist-like driver streams from row streams.

    A driver is read only just before other streams begin (a new sequence is
    chosen), so each of its steps is within DRIVER_WINDOW calls before some
    other stream's first call.
    """
    firsts = sorted(s.calls[0] for s in streams)
    drivers, rows = [], []
    for s in streams:
        hits = 0
        for c in s.calls:
            if any(c <= f <= c + DRIVER_WINDOW and f != s.calls[0] for f in firsts):
                hits += 1
        (drivers if hits >= 0.8 * len(s.cells) else rows).append(s)
    return drivers, rows


def split_at_switches(rows, drivers):
    """Cut row streams where a driver step selects what is read next.

    Streams stored back to back and played in order chain into one run. When
    the next cell does not overlap the previous one and a driver was read
    just before, the pointer moved to a new sequence; cut there so the cell
    start becomes a sequence start. The driver is not matched to a voice, so
    an unrelated voice could be cut when switches are not simultaneous.
    """
    steps = sorted({c for d in drivers for c in d.calls})
    result = []
    for s in rows:
        piece = [s.cells[0]]
        for prev, cell in zip(s.cells, s.cells[1:]):
            switch = cell[1] > prev[2] and any(
                d <= cell[0] <= d + DRIVER_WINDOW for d in steps)
            if switch:
                result.append(Stream(piece))
                piece = []
            piece.append(cell)
        result.append(Stream(piece))
    return [r for r in result if len(r.cells) >= MIN_CELLS]


def event_calls(streams):
    return sorted({c for s in streams for c in s.calls})


def gap_histogram(streams):
    """Calls between consecutive steps of the same stream, counted.

    Within one stream only, so voices whose rows happen on different calls
    do not blur each other's timing.
    """
    hist = Counter()
    for s in streams:
        hist.update(b - a for a, b in zip(s.calls, s.calls[1:]))
    return hist


def estimate_grid(streams, events):
    """Row period and phase: the commonest step interval inside one stream.

    Sequences with held notes step at multiples of the row length, so a
    song made mostly of held notes reports a multiple of the true row length.
    Returns (period, phase, share of gaps equal to the period), or Nones.
    """
    hist = gap_histogram(streams)
    if not hist:
        return None, None, None
    period, count = hist.most_common(1)[0]
    phase = Counter(e % period for e in events).most_common(1)[0][0]
    return period, phase, count / sum(hist.values())


def assign_tracks(streams):
    """Greedy time-overlap colouring: chains that never overlap share a track."""
    tracks = []
    for s in sorted(streams, key=lambda s: s.calls[0]):
        free = [t for t in tracks if t[-1].calls[-1] < s.calls[0]]
        if free:
            max(free, key=lambda t: t[-1].calls[-1]).append(s)
        else:
            tracks.append([s])
    return tracks


def onset_calls(calls):
    """Calls where a voice gate rises or a frequency register changes.

    Needs only the SID writes in the trace, so it holds for any player. The
    first call never counts: there is no earlier value to compare with.
    """
    last = {}
    gate_on, freq_changed = [], []
    for c in calls:
        rising = moved = False
        for reg, val, _ in c.writes:
            v, r = divmod(reg, 7)
            if v > 2:
                continue
            old = last.get(reg)
            if old is not None:
                if r == 4 and val & 1 and not old & 1:
                    rising = True
                elif r in (0, 1) and val != old:
                    moved = True
            last[reg] = val
        if rising:
            gate_on.append(c.index)
        if moved:
            freq_changed.append(c.index)
    return gate_on, freq_changed


@dataclass
class Structure:
    streams: list
    events: list           # call indexes at which any stream advanced
    row_period: int        # calls per row (None if undetermined)
    row_phase: int
    period_share: float    # fraction of stream steps whose gap equals row_period
    row_boundaries: list   # first call of every row in [first event, last event]
    tracks: list           # list of lists of streams
    read_lag: int          # calls from a row's SID onset to the stream reads (mod period)
    sequence_starts: list  # (address, times a stream started there), commonest first
    orderlist_candidates: list  # start addresses of slow streams driving switches


def analyze(calls):
    streams = find_streams(calls)
    drivers, rows = split_drivers(streams)
    rows = split_at_switches(rows, drivers)
    events = event_calls(rows)
    period, phase, share = estimate_grid(rows, events)
    lag = 0
    if period:
        # Players read ahead of the row they sound. Anchor boundaries on when
        # the SID actually changes, and report the read lead separately.
        gate_on, freq = onset_calls(calls)
        onsets = gate_on if len(gate_on) >= 3 else freq
        if onsets:
            onset_phase = Counter(o % period for o in onsets).most_common(1)[0][0]
            lag = (phase - onset_phase) % period
            phase = onset_phase
    bounds = []
    if period and events:
        start = min(events[0], min(onsets) if period and onsets else events[0])
        first = start - (start - phase) % period
        bounds = list(range(first, events[-1] + 1, period))
    starts = Counter(s.start for s in rows)
    return Structure(rows, events, period, phase, share, bounds, assign_tracks(rows), lag,
                     starts.most_common(), sorted({s.start for s in drivers}))


def load(path):
    with open(path) as fh:
        return parse(fh.read())
