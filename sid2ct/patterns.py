"""Bounded exact CT-row mining; no pitch/control approximation.

mine_patterns takes physical voices in their original order, each a tuple of
immutable, hashable row tuples. loop_start is a row offset shared by all voices
(None means restart at zero). Returned pattern IDs are zero-based; a native
writer must translate them to its slot IDs and enforce its order-byte capacity.
Each voice has its own restart order index. Patterns may be shared across voices
but voices are never merged, permuted or dropped (including silent voices).

Search visits at most search_row_budget row elements (default 1,000,000), with
length <= 64 and input <= 100,000 rows per voice / 16 voices. Once exhausted,
unindexed material uses exact fixed-size chunks. Memory is O(search_row_budget
+ input rows). Extraction costs O(voices * rows * max_pattern_length**2)
row-element work in the worst case; expansion is linear. The search budget
bounds candidate indexing, not the necessary full lossless extraction pass. Search is greedy, not globally
optimal; it never changes rows or infers a player loop from musical repetition.
"""
from dataclasses import dataclass


@dataclass(frozen=True)
class PatternPlan:
    patterns: tuple
    orders: tuple
    restarts: tuple
    loop_start: int
    row_count: int
    search_rows: int
    search_exhausted: bool

    def expand(self):
        """Return original physical voices as immutable row sequences."""
        return tuple(tuple(row for pid in order for row in self.patterns[pid])
                     for order in self.orders)


def mine_patterns(voices, *, loop_start=None, max_pattern_length=64,
                  max_patterns=127, search_row_budget=1_000_000):
    """Make a deterministic lossless plan with a hard intro/loop split.

    Exact repeated windows are ranked by estimated saved rows, then length.
    Occurrences used in the estimate cannot overlap within a voice/region.
    First-use order determines IDs, avoiding hash iteration dependence. A full
    pattern dictionary raises ValueError; no lossy capacity fallback is made.
    Empty captures, unequal voice lengths and mutable rows are rejected.
    """
    if not isinstance(voices, tuple) or not 1 <= len(voices) <= 16:
        raise ValueError('voices must be a tuple containing 1..16 physical voices')
    if not isinstance(max_pattern_length, int) or not 1 <= max_pattern_length <= 64:
        raise ValueError('max_pattern_length must be in 1..64')
    if not isinstance(max_patterns, int) or not 1 <= max_patterns <= 127:
        raise ValueError('max_patterns must be in 1..127')
    if not isinstance(search_row_budget, int) or search_row_budget < 0:
        raise ValueError('search_row_budget must be a nonnegative integer')
    count = len(voices[0])
    if not 1 <= count <= 100_000:
        raise ValueError('capture must contain 1..100000 rows')
    for voice in voices:
        if not isinstance(voice, tuple) or len(voice) != count:
            raise ValueError('voices must be immutable tuples of equal length')
        for row in voice:
            if not isinstance(row, tuple):
                raise ValueError('rows must be immutable tuples')
            try:
                hash(row)
            except TypeError as exc:
                raise ValueError('row fields must be immutable and hashable') from exc
    boundary = 0 if loop_start is None else loop_start
    if not isinstance(boundary, int) or not 0 <= boundary < count:
        raise ValueError('loop_start must be a row offset inside the capture')
    regions = ((0, boundary), (boundary, count)) if boundary else ((0, count),)
    # Each key records nonoverlapping occurrences; only exact tuples are keys.
    occurrences = {}
    used = 0
    exhausted = False
    for vid, voice in enumerate(voices):
        for rid, (start, stop) in enumerate(regions):
            for pos in range(start, stop):
                for length in range(2, min(max_pattern_length, stop-pos)+1):
                    if used + length > search_row_budget:
                        exhausted = True
                        break
                    used += length
                    key = voice[pos:pos+length]
                    record = occurrences.setdefault(key, [0, None, -1])
                    location = (vid, rid)
                    if record[1] != location or pos >= record[2]:
                        record[0] += 1
                        record[1], record[2] = location, pos+length
                if exhausted:
                    break
            if exhausted:
                break
        if exhausted:
            break
    patterns, ids, orders, restarts = [], {}, [], []
    for voice in voices:
        order = []
        restart = 0
        for start, stop in regions:
            if start == boundary:
                restart = len(order)
            pos = start
            while pos < stop:
                length = min(max_pattern_length, stop-pos)
                best = (0, 0)
                for candidate in range(2, length+1):
                    record = occurrences.get(voice[pos:pos+candidate])
                    repetitions = record[0] if record else 0
                    rank = ((candidate-1)*(repetitions-1), candidate)
                    if repetitions >= 2 and rank > best:
                        best = rank
                if best[0]:
                    length = best[1]
                key = voice[pos:pos+length]
                if key not in ids:
                    if len(patterns) >= max_patterns:
                        raise ValueError('pattern dictionary exceeds max_patterns')
                    ids[key] = len(patterns)
                    patterns.append(key)
                order.append(ids[key])
                pos += length
        orders.append(tuple(order))
        restarts.append(restart)
    return PatternPlan(tuple(patterns), tuple(orders), tuple(restarts), boundary,
                       count, used, exhausted)
