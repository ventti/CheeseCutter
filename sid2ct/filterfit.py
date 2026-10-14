"""Fit the global SID filter timeline to a small set of CT 4.x filter-program starts.

The player's filter table has four-byte rows (duration or $80|mode, add or
route, preset cutoff or $ff, next row). A set row loads mode/route and an
optional 8-bit preset in one tick; a sweep row loads an optional preset and
then adds 2 * add 11-bit cutoff units per tick for `duration` ticks. A program
start ($60+n super on any voice row) loads row n on that tick. Row 0 must be a
stop row. Starts can only address rows 1..31, so each program's first row sits
in that head area and its remaining rows follow, reached by the next-row byte.
"""
from dataclasses import dataclass, field
import math

import numpy as np

STOP_ROW = (0, 0, 255, 127)
MAX_ROWS = 64          # table rows 0..63, row 0 is the stop row
MAX_STARTS = 31        # start supers address rows 1..31
INITIAL_ROUTE = 240    # cold-start value the player leaves in reg 23


@dataclass(frozen=True)
class FilterStart:
    frame: int
    program: int
    row: int


@dataclass
class FilterPlan:
    table: list
    starts: list
    programs: list = field(default_factory=list)  # logical rows per unique program
    error: float = 0.0           # mean absolute 11-bit cutoff error over all frames
    max_error: float = 0.0
    route_mismatch: int = 0      # frames whose route/res or mode bits differ
    tolerance_used: float = 0.0
    ok: bool = True              # fits the 63-row / 31-start capacity

    @property
    def rows_used(self):
        return len(self.table) - 1

    def table_bytes(self):
        return bytes(b for row in self.table for b in row)


def _dec(value):
    return (value - 1) & 255


def simulate_filter(table, starts, frames, route=INITIAL_ROUTE):
    """Replay filter-table rows as the player does; returns (cutoff11, reg23, mode) arrays.

    table is a list of four-byte rows, starts maps frame -> start row index.
    """
    t = bytes(b for row in table for b in row).ljust(256, b'\0')
    count = current = nxt = cutoff = low = add = fraction = band = 0
    cut, regs, modes = [], [], []
    for frame in range(frames):
        if frame in starts:
            nxt, count = (starts[frame] & 31) << 2, 0
        count = _dec(count)
        if count & 128:
            current = nxt
            duration, amount = t[current], t[current + 1]
            if duration >= 128:
                band, route, duration = duration & 112, amount, 0
            count = duration
            fraction = (amount & 3) << 1
            add = ((amount - 256 if amount & 128 else amount) >> 2) & 255
            follow = t[current + 3]
            nxt = (nxt + 4) & 255 if not follow else 0 if follow == 127 else (follow << 2) & 255
            if t[current + 2] != 255:
                cutoff, low = t[current + 2], 0
        else:
            total = low + fraction
            low = total & 7
            cutoff = (cutoff + add + (total >= 8)) & 255
        cut.append(cutoff << 3 | low)
        regs.append(route)
        modes.append(band >> 4)
    return np.array(cut), np.array(regs), np.array(modes)


def _walk(cutoff, reg23, mode, tol, gap):
    """Greedy rows; returns programs as [(start_frame, [row, ...])] with next bytes unset."""
    n = len(cutoff)
    programs, rows, start = [], None, 0
    cur_cut, cur_route, cur_mode = 0, INITIAL_ROUTE, 0  # cold-start player state

    def close():
        nonlocal rows
        if rows:
            programs.append((start, rows))
        rows = None

    t = 0
    while t < n:
        if reg23[t] != cur_route or mode[t] != cur_mode:
            preset = 255
            if cur_cut is None or abs(cur_cut - int(cutoff[t])) > tol:
                preset = min(254, max(0, round(int(cutoff[t]) / 8)))
                cur_cut = preset * 8
            if rows is None:
                rows, start = [], t
            rows.append((0x80 | int(mode[t]) << 4, int(reg23[t]), preset, 0))
            cur_route, cur_mode = int(reg23[t]), int(mode[t])
            t += 1
            continue
        preset = 255
        if cur_cut is None or abs(cur_cut - int(cutoff[t])) > tol:
            preset = min(254, max(0, round(int(cutoff[t]) / 8)))
        base = preset * 8 if preset != 255 else cur_cut
        lo, hi, d = -math.inf, math.inf, 0
        a_lo, a_hi = 0, 0
        while d < 127 and t + d + 1 < n and reg23[t + d + 1] == cur_route and mode[t + d + 1] == cur_mode:
            k = d + 1
            new_lo = max(lo, (int(cutoff[t + k]) - tol - base) / k)
            new_hi = min(hi, (int(cutoff[t + k]) + tol - base) / k)
            low_add, high_add = max(-128, math.ceil(new_lo / 2)), min(127, math.floor(new_hi / 2))
            if low_add > high_add:
                break
            lo, hi, d, a_lo, a_hi = new_lo, new_hi, k, low_add, high_add
        add = 0 if d == 0 else min(a_hi, max(a_lo, round((a_lo + a_hi) / 2)))
        if add == 0 and (d + 1 >= gap or rows is None):
            # A long hold, or any idle hold between programs, needs no row: row 0 holds.
            if preset != 255:
                if rows is None:
                    rows, start = [], t
                rows.append((0, 0, preset, 0))
                cur_cut = base
            close()
            t += d + 1
            continue
        if rows is None:
            rows, start = [], t
        rows.append((d, add & 255, preset, 0))
        cur_cut = base + 2 * add * d
        t += d + 1
    close()
    return programs


def _layout(programs):
    """Head rows 1..J carry program starts; tails follow. Returns (table, starts, unique)."""
    unique, index = [], {}
    for _, rows in programs:
        key = tuple(rows)
        if key not in index:
            index[key] = len(unique)
            unique.append(rows)
    table = [STOP_ROW] + [None] * len(unique)
    for j, rows in enumerate(unique):
        head = rows[0]
        if len(rows) == 1:
            table[1 + j] = head[:3] + (127,)
            continue
        tail = len(table)
        table[1 + j] = head[:3] + (min(tail, 255),)
        for k, row in enumerate(rows[1:]):
            table.append(row[:3] + (0 if k < len(rows) - 2 else 127,))
    starts = [FilterStart(frame, index[tuple(rows)], 1 + index[tuple(rows)]) for frame, rows in programs]
    return table, starts, unique


def fit_filter(timeline, *, tolerance=16, gap=48, max_steps=10):
    """Fit a FilterTimeline to program starts, relaxing the cutoff tolerance until it fits the table.

    tolerance is in 11-bit cutoff units (at least 4: presets are multiples of 8).
    gap is the shortest constant stretch that ends a program instead of
    becoming a hold row. The plan reports the tolerance finally used.
    """
    cutoff, reg23 = np.asarray(timeline.cutoff), np.asarray(timeline.reg23)
    mode = np.asarray(timeline.mode)
    n = len(cutoff)
    tol = max(4.0, float(tolerance))
    for _ in range(max_steps):
        programs = _walk(cutoff, reg23, mode, tol, gap)
        table, starts, unique = _layout(programs)
        if len(table) <= MAX_ROWS and len(unique) <= MAX_STARTS:
            break
        tol *= 1.5
    ok = len(table) <= MAX_ROWS and len(unique) <= MAX_STARTS
    plan = FilterPlan(table, starts, unique, tolerance_used=tol, ok=ok)
    if ok and n:
        cut, regs, modes = simulate_filter(table, {s.frame: s.row for s in starts}, n)
        error = np.abs(cut - cutoff)
        plan.error, plan.max_error = float(error.mean()), float(error.max())
        plan.route_mismatch = int(((regs != reg23) | (modes != mode)).sum())
    return plan
