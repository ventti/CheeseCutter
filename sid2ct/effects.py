"""Fit each IR note's pitch, ADSR and volume to CT 4.x player primitives with exact CT arithmetic.

Pitch models copy the per-tick formulas of ctplayer.py (and so player_v4.acme):
tick 0 is the gate-on tick (its frequency register is stale), a command super
acts on tick 0 and its effect first moves the pitch on tick 1. Candidate
primitives are flat, detune (cmd 3), slides (cmd 0/1), hi-fi and lo-fi vibrato
(cmd 2/5, optionally delayed by whole rows), portamento (cmd 7, from the
previous pitch), arpeggio (chord table) and absolute wave-table notes. The
cheapest primitive whose cents error is within tolerance wins. The global
filter lives in filterfit.py and is re-exported here.
"""
from collections import Counter
from dataclasses import dataclass, field
import math

import numpy as np

from .filterfit import FilterPlan, fit_filter, simulate_filter  # noqa: F401  (re-export)
from .ir import NOTE_MAX, NOTE_MIN, nearest_note

# Cost in table/sequence bytes. A command row is 3 bytes plus the inline super.
COST_COMMAND = 4
COST_WAVE_ROW = 2
NO_FIT_PENALTY_CENTS = 600.0


@dataclass(frozen=True)
class EffectFit:
    primitive: str           # flat, detune, slide, vibrato_hifi, vibrato_lofi, portamento, arpeggio, wave_abs
    params: dict
    error: float             # mean absolute cents over ticks 1..n-1 (TEST ticks excluded)
    max_error: float
    cost: float
    ok: bool                 # within the tolerance given to the fit
    dedup_key: tuple = ()    # equal keys may share one table entry
    delay: int = 0           # ticks before the effect starts (whole rows)
    command: tuple = None    # command table row (op, hi, lo)
    chord: tuple = None      # chord values (use chord_table_bytes for the delimited table bytes)
    waves: tuple = None      # ((absolute note, ticks), ...) for wave_abs


@dataclass(frozen=True)
class AdsrFit:
    kind: str                # none, inline or cmd4
    ad: int
    sr: int
    super_byte: int = None   # inline $a0..$df nibble super
    command: tuple = None    # (4, ad, sr)
    cost: float = 0
    changes: tuple = ()      # mid-note (tick, ad, sr) changes the CT cannot do at row start


@dataclass(frozen=True)
class NoteFit:
    note: object
    pitch: EffectFit
    adsr: AdsrFit
    needs_instrument: bool   # pitch and ADSR both need the row's single super


@dataclass(frozen=True)
class VolumeEvent:
    frame: int
    value: int
    super_byte: int          # $e0 | volume


@dataclass
class _Ctx:
    src: np.ndarray
    mask: np.ndarray
    tuning: list
    voice: int
    tol: float
    max_tol: float
    quantum: int
    prev_freq: int = 0
    _ref: int = None

    @property
    def n(self):
        return len(self.src)

    def F(self, note):
        return self.tuning[note]

    @property
    def ref(self):
        """Nearest tuning note to the median pitch, used to prefer canonical equivalent fits."""
        if self._ref is None:
            valid = self.src[1:][(self.src[1:] > 0) & ~self.mask[1:]]
            note = nearest_note(int(np.median(valid)), self.tuning)[0] if len(valid) else 36
            self._ref = 36 if note is None else note
        return self._ref

    def rank(self, fit):
        """Order equal-register fits by error, then closeness to the reference note, then delay."""
        note = fit.params.get('note', self.ref)
        return (round(fit.error, 3), abs(note - self.ref), fit.delay)


def _score(ctx, model):
    """(mean, max) absolute cents of model against src over ticks 1..n-1."""
    if model is None:
        return math.inf, math.inf
    s, m = ctx.src[1:].astype(float), np.asarray(model[1:], float)
    keep = ~ctx.mask[1:]
    if not keep.any():
        return 0.0, 0.0
    s, m = s[keep], m[keep]
    both = (s > 0) & (m > 0)
    err = np.where(both, np.abs(1200 * np.log2(np.where(both, s, 1) / np.where(both, m, 1))),
                   np.where((s == 0) & (m == 0), 0.0, NO_FIT_PENALTY_CENTS))
    return float(err.mean()), float(err.max())


def _make(ctx, primitive, params, model, cost, **fields):
    error, worst = _score(ctx, model)
    ok = error <= ctx.tol and worst <= ctx.max_tol
    return EffectFit(primitive, params, error, worst, cost, ok, **fields)


# Exact per-tick models. Each returns n frequency registers; tick 0 is stale.

def _flat(ctx, note, offset=None):
    base = ctx.F(note) + (ctx.voice if offset is None else offset)
    return np.full(ctx.n, base & 0xFFFF)


def _slide(ctx, note, sign, speed, delay):
    out, offset = [], ctx.voice
    for i in range(ctx.n):
        if i > delay:
            offset = (offset + sign * speed) & 0xFFFF
        out.append((ctx.F(note) + offset) & 0xFFFF)
    return np.array(out)


def _hifi(ctx, note, feel, amp, frq, delay):
    out, offset = [], ctx.voice
    count, direction, phase = frq >> 1, 0, 0
    cor = frq & 1
    for i in range(ctx.n):
        if i > delay:
            delta = (ctx.F(note + 1) - ctx.F(note)) & 0xFFFF
            shifts = (amp + cor) & 255
            if shifts <= 128:
                delta >>= shifts
            cor = 0
            delta = (delta + phase) & 0xFFFF
            phase = (phase + feel) & 0xFFFF
            offset = (offset + (-delta if direction & 1 else delta)) & 0xFFFF
            count = (count + 1) & 255
            if count >= frq:
                direction, count = direction + 1, 0
        out.append((ctx.F(note) + offset) & 0xFFFF)
    return np.array(out)


def _lofi(ctx, note, frq, amp, delay):
    out, offset = [], ctx.voice
    count, direction = frq >> 1, 0
    for i in range(ctx.n):
        if i > delay:
            offset = (offset + (-(amp << 2) if direction & 1 else amp << 2)) & 0xFFFF
            count = (count + 1) & 255
            if count >= frq:
                direction, count = direction + 1, 0
        out.append((ctx.F(note) + offset) & 0xFFFF)
    return np.array(out)


def _porta(ctx, start, target, speed):
    out, pitch = [start], start
    goal = ctx.F(target)
    for _ in range(1, ctx.n):
        difference = (pitch - goal) & 0xFFFF
        adjusted = (difference + (speed if difference & 0x8000 else -speed)) & 0xFFFF
        crossed = bool((difference ^ adjusted) & 0x8000)
        pitch = goal if crossed else (goal + adjusted) & 0xFFFF
        out.append(pitch)
    return np.array(out)


def _chord_value(byte):
    return byte if byte < 64 else byte - 128


def _chord(ctx, note, values, loop, step):
    """values: chord bytes (>= 64 is negative); loop: index the cycle returns to."""
    out = [ctx.F(note) + ctx.voice]
    for i in range(1, ctx.n):
        k = (i - 1) // step
        k = k if k < len(values) else loop + (k - len(values)) % (len(values) - loop)
        n = note + _chord_value(values[k])
        if not 0 <= n < 96:
            return None
        out.append(ctx.F(n) + ctx.voice)
    return np.array(out)


def _waves(ctx, runs):
    out = [ctx.F(runs[0][0])]
    for note, ticks in runs:
        out += [ctx.F(note)] * ticks
    return np.array(out[:ctx.n] + [out[-1]] * max(0, ctx.n - len(out)))


# Parameter estimation helpers.

def _bases(ctx, *extra):
    """Candidate base notes near the first-tick, median and final pitch."""
    valid = ctx.src[1:][(ctx.src[1:] > 0) & ~ctx.mask[1:]]
    if not len(valid):
        return []
    seeds = [valid[0], int(np.median(valid)), valid[-1], *extra]
    found = set()
    for f in seeds:
        note, _ = nearest_note(int(f), ctx.tuning)
        if note is not None:
            found |= {max(NOTE_MIN, min(NOTE_MAX, n)) for n in (note - 1, note, note + 1)}
    return sorted(found)


def _delays(ctx):
    return sorted({0, *(k * ctx.quantum for k in range(1, min(ctx.n // max(1, ctx.quantum), 12) + 1)
                        if k * ctx.quantum < ctx.n - 2)})


def _runs(x):
    """Lengths of consecutive runs with the same sign (zeros join the previous run)."""
    lengths, last = [], 0
    for v in x:
        s = 1 if v > 0 else -1 if v < 0 else last
        if s == last or not last:
            if lengths:
                lengths[-1] += 1
            else:
                lengths.append(1)
        else:
            lengths.append(1)
        last = s or last
    return lengths


def _clip(value, low, high):
    return max(low, min(high, int(value)))


def _fit_flat(ctx):
    fits = [_make(ctx, 'flat', {'note': b}, _flat(ctx, b), 0, dedup_key=('flat',)) for b in _bases(ctx)]
    return min(fits, key=ctx.rank) if fits else None


def _fit_detune(ctx):
    valid = ctx.src[1:][(ctx.src[1:] > 0) & ~ctx.mask[1:]]
    if not len(valid):
        return None
    target = int(np.median(valid))
    best = None
    for b in _bases(ctx):
        offset = (target - ctx.F(b)) & 0xFFFF
        fit = _make(ctx, 'detune', {'note': b, 'offset': offset}, _flat(ctx, b, offset), COST_COMMAND,
                    command=(3, offset >> 8, offset & 255), dedup_key=('cmd', 3, offset >> 8, offset & 255))
        best = _better(ctx, best, fit)
    return best


def _fit_slide(ctx):
    best = None
    for delay in _delays(ctx):
        s = ctx.src[delay + 1:]
        keep = (s[1:] > 0) & (s[:-1] > 0) & ~ctx.mask[delay + 2:]
        if keep.sum() < 2:
            continue
        diffs = np.diff(s.astype(np.int64))[keep]
        estimate = int(round(float(np.median(diffs))))
        if estimate == 0:
            continue
        sign = 1 if estimate > 0 else -1
        for speed in {abs(estimate) + d for d in (-1, 0, 1)}:
            if not 1 <= speed < 65536:
                continue
            for b in _bases(ctx, int(ctx.src[1]) - sign * speed * (delay == 0)):
                fit = _make(ctx, 'slide', {'note': b, 'direction': 'up' if sign > 0 else 'down', 'speed': speed},
                            _slide(ctx, b, sign, speed, delay), COST_COMMAND, delay=delay,
                            command=(0 if sign > 0 else 1, speed >> 8, speed & 255),
                            dedup_key=('cmd', 0 if sign > 0 else 1, speed >> 8, speed & 255))
                best = _better(ctx, best, fit)
    return best


def _vibrato_estimates(ctx, delay):
    s = ctx.src[delay + 1:].astype(float)
    s = s[~ctx.mask[delay + 1:]]
    if len(s) < 4 or not (s > 0).all():
        return None
    center = float(np.median(s))
    runs = _runs(s - center)
    pp = float(s.max() - s.min())
    if pp <= 0 or len(runs) < 2:
        return None
    interior = runs[1:-1]
    half = int(round(float(np.median(interior)))) if interior else max(runs)
    return center, pp, max(1, half)


def _fit_vibrato(ctx):
    best = {'vibrato_hifi': None, 'vibrato_lofi': None}
    for delay in _delays(ctx):
        est = _vibrato_estimates(ctx, delay)
        if est is None:
            continue
        center, pp, half = est
        for frq in sorted({max(1, half + d) for d in (-1, 0, 1)}):
            swing = pp / frq
            if frq <= 16:
                for b in _bases(ctx, int(center)):
                    semitone = (ctx.F(b + 1) - ctx.F(b)) & 0xFFFF
                    amp0 = _clip(round(math.log2(semitone / swing)) if swing > 0 and semitone else 0, 0, 15)
                    for amp in sorted({_clip(amp0 + d, 0, 15) for d in (-1, 0, 1)}):
                        for feel in (0,):
                            fit = _hifi_fit(ctx, b, feel, amp, frq, delay)
                            best['vibrato_hifi'] = _better(ctx, best['vibrato_hifi'], fit)
                if best['vibrato_hifi'] is not None and not best['vibrato_hifi'].ok and delay == 0:
                    # The swing estimate assumes a constant amplitude; feel grows it each tick.
                    note = best['vibrato_hifi'].params['note']
                    for amp in range(16):
                        for feel in range(1, 16):
                            fit = _hifi_fit(ctx, note, feel, amp, frq, delay)
                            best['vibrato_hifi'] = _better(ctx, best['vibrato_hifi'], fit)
            if frq <= 128:
                amp0 = swing / 4
                for amp in sorted({_clip(round(amp0) + d, 0, 255) for d in (-1, 0, 1)}):
                    for b in _bases(ctx, int(center)):
                        model = _lofi(ctx, b, frq, amp, delay)
                        fit = _make(ctx, 'vibrato_lofi', {'note': b, 'frq': frq, 'amp': amp}, model, COST_COMMAND,
                                    delay=delay, command=(5, frq, amp), dedup_key=('cmd', 5, frq, amp))
                        best['vibrato_lofi'] = _better(ctx, best['vibrato_lofi'], fit)
    return [f for f in best.values() if f]


def _hifi_fit(ctx, note, feel, amp, frq, delay):
    model = _hifi(ctx, note, feel, amp, frq, delay)
    hi, lo = feel & 15, (frq - 1) << 4 | amp & 15
    return _make(ctx, 'vibrato_hifi', {'note': note, 'feel': feel, 'amp': amp, 'frq': frq}, model, COST_COMMAND,
                 delay=delay, command=(2, hi, lo), dedup_key=('cmd', 2, hi, lo))


def _better(ctx, a, b):
    return b if a is None or ctx.rank(b) < ctx.rank(a) else a


def _fit_porta(ctx):
    if ctx.prev_freq <= 0 or ctx.n < 3:
        return None
    valid = ctx.src[1:][(ctx.src[1:] > 0) & ~ctx.mask[1:]]
    if len(valid) < 2:
        return None
    final = int(np.median(valid[-max(2, len(valid) // 4):]))
    target, _ = nearest_note(final, ctx.tuning)
    if target is None:
        return None
    chain = np.concatenate([[ctx.prev_freq], ctx.src[1:]]).astype(np.int64)
    steps = np.abs(np.diff(chain))
    steps = steps[steps > 0]
    if not len(steps):
        return None
    estimate = int(round(float(np.median(steps[:-1] if len(steps) > 1 else steps))))
    best = None
    for speed in sorted({_clip(estimate + d, 1, 4095) for d in (-2, -1, 0, 1, 2)}):
        fit = _make(ctx, 'portamento', {'note': target, 'speed': speed, 'start': ctx.prev_freq},
                    _porta(ctx, ctx.prev_freq, target, speed), COST_COMMAND,
                    command=(7, speed >> 8, speed & 255), dedup_key=('cmd', 7, speed >> 8, speed & 255))
        best = _better(ctx, best, fit)
    return best


def _note_runs(ctx):
    """Nearest-note runs over ticks 1..n-1 as [(note, ticks)], or None if any tick is unplayable."""
    runs = []
    for f in ctx.src[1:]:
        note, _ = nearest_note(int(f), ctx.tuning, 0, 95)
        if note is None:
            return None
        if runs and runs[-1][0] == note:
            runs[-1][1] += 1
        else:
            runs.append([note, 1])
    return runs


def _chord_for(runs):
    """Shortest chord entry (values, loop) that replays the run notes, or None.

    values are signed offsets from the first note (stored $00..$3f up, $40..$7f
    down); loop is the index the entry returns to after its last value.
    """
    notes = [r[0] for r in runs]
    for length in range(2, len(notes) + 1):
        for cycle in range(1, length + 1):
            pre = length - cycle
            replay = [notes[k] if k < length else notes[pre + (k - length) % cycle] for k in range(len(notes))]
            if replay == notes:
                values = [n - notes[0] for n in notes[:length]]
                if not all(-64 <= v <= 63 for v in values):
                    return None
                return tuple(v if v >= 0 else 128 + v for v in values), pre
    return None


def chord_table_bytes(fit, base=0):
    """Chord table bytes for an arpeggio fit placed at table position base (absolute loop target)."""
    return tuple(fit.chord) + (0x80 | (base + fit.params['loop']),)


def _fit_arpeggio(ctx, runs):
    if runs is None or len(runs) < 3:
        return None
    full = [t for _, t in runs[:-1]]
    step = full[0]
    if any(t != step for t in full) or runs[-1][1] > step or not 1 <= step <= 16:
        return None
    found = _chord_for(runs)
    if found is None:
        return None
    values, loop = found
    base = runs[0][0]
    model = _chord(ctx, base, values, loop, step)
    return _make(ctx, 'arpeggio', {'note': base, 'step': step, 'loop': loop}, model,
                 len(values) + 1 + 2 * COST_WAVE_ROW, chord=values, dedup_key=('chord', values, loop, step))


def _fit_wave(ctx, runs):
    if runs is None or len(runs) < 2 or len(runs) > 96:
        return None
    waves = tuple((n, t) for n, t in runs)
    return _make(ctx, 'wave_abs', {'runs': waves}, _waves(ctx, waves), COST_WAVE_ROW * len(waves) + 1,
                 waves=waves, dedup_key=('wave', waves))


def fit_pitch(note, tuning, *, tolerance=12.0, max_tolerance=None, quantum=6, voice=None, lag=0,
              noise_scale=4.0):
    """Return the cheapest EffectFit within tolerance (mean cents), else the lowest-error fit with ok=False.

    quantum is the row length in trace ticks (row_frames * multiplier); effect
    onsets are searched only at whole rows. note is an ir.Note. lag is the
    number of CT ticks that pass before the note's gate shows: 0 when the
    instrument's hard-restart type writes the gate on tick 0 (stale pitch,
    what native.py instruments do), 1 for restart type $40 (gate appears with
    the first wave tick, so the note's first frame already has the effect).
    Notes that are mostly noise waveform (bit $80) are fitted with the
    tolerances multiplied by noise_scale: their pitch is only a timbre colour.
    """
    if np.count_nonzero(np.asarray(note.control) & 0x80) * 2 >= max(1, len(note.control)):
        tolerance *= noise_scale
        max_tolerance = max_tolerance * noise_scale if max_tolerance is not None else None
    src, mask = np.asarray(note.freq, np.int64), np.asarray(note.test_mask)
    if lag:
        src, mask = np.concatenate([np.zeros(lag, np.int64), src]), np.concatenate([np.ones(lag, bool), mask])
    ctx = _Ctx(src, mask, list(tuning),
               note.voice if voice is None else voice, tolerance,
               max_tolerance if max_tolerance is not None else max(3 * tolerance, 40.0),
               max(1, quantum), note.prev_freq)
    return fit_trace(ctx)


def fit_trace(ctx):
    """Fit one frequency trajectory (ctx: _Ctx); exposed for tests and tools."""
    if ctx.n < 2 or not (~ctx.mask[1:] & (ctx.src[1:] > 0)).any():
        return EffectFit('flat', {'note': 36}, 0.0, 0.0, 0, True, dedup_key=('flat',))
    flat = _fit_flat(ctx)
    if flat is not None and flat.ok:
        return flat
    pool = [flat] if flat else []
    stages = (lambda: [_fit_detune(ctx), _fit_slide(ctx), _fit_porta(ctx), *_fit_vibrato(ctx)],
              lambda: _runs_fits(ctx))
    for stage in stages:
        fits = [f for f in stage() if f is not None]
        pool += fits
        good = [f for f in fits if f.ok]
        if good:
            return min(good, key=lambda f: (f.cost, *ctx.rank(f)))
    return min(pool, key=lambda f: (f.error, f.cost)) if pool else EffectFit('flat', {'note': 36}, math.inf, math.inf, 0, False)


def _runs_fits(ctx):
    runs = _note_runs(ctx)
    return [_fit_arpeggio(ctx, runs), _fit_wave(ctx, runs)]


def make_ctx(freqs, tuning, *, voice=0, tolerance=12.0, quantum=6, prev_freq=0, mask=None, max_tolerance=None):
    """Context for fit_trace from a raw per-tick frequency list (tests, tools)."""
    src = np.asarray(freqs, np.int64)
    return _Ctx(src, np.zeros(len(src), bool) if mask is None else np.asarray(mask), list(tuning), voice,
                tolerance, max_tolerance if max_tolerance is not None else max(3 * tolerance, 40.0),
                max(1, quantum), prev_freq)


def fit_adsr(note, base_ad, base_sr):
    """Express the note's AD/SR relative to its instrument's base ADSR.

    One changed nibble is an inline $a0..$df super (AD attack/decay,
    SR sustain/release); more is command 4. Later mid-note changes are only
    reported, because the CT can set ADSR only on a row start.
    """
    i = min(1, note.length - 1)
    ad, sr = int(note.ad[i]), int(note.sr[i])
    changes = tuple((t, int(note.ad[t]), int(note.sr[t])) for t in range(i + 1, note.length)
                    if (note.ad[t], note.sr[t]) != (note.ad[t - 1], note.sr[t - 1]))
    nibbles = [(160, ad >> 4, base_ad >> 4), (176, ad & 15, base_ad & 15),
               (192, sr >> 4, base_sr >> 4), (208, sr & 15, base_sr & 15)]
    diff = [(base, value) for base, value, old in nibbles if value != old]
    if not diff:
        return AdsrFit('none', ad, sr, changes=changes)
    if len(diff) == 1:
        base, value = diff[0]
        return AdsrFit('inline', ad, sr, super_byte=base + value, cost=1, changes=changes)
    return AdsrFit('cmd4', ad, sr, command=(4, ad, sr), cost=COST_COMMAND, changes=changes)


def fit_volume(volume, *, min_gap=1):
    """Master-volume changes as $e0|v supers, sampled every min_gap frames.

    Rapid fades collapse onto the sampling grid (one event per gap), since
    every event costs one row super on some voice.
    """
    v = np.asarray(volume.volume if hasattr(volume, 'volume') else volume)
    events, last = [], None
    for frame in range(0, len(v), max(1, min_gap)):
        value = int(v[min(len(v) - 1, frame + max(1, min_gap) - 1)]) if frame else int(v[0])
        if value != last:
            events.append(VolumeEvent(frame, value, 0xE0 | value))
            last = value
    return events


def _needs_super(fit):
    return fit.command is not None or fit.chord is not None


def fit_note(note, tuning, *, base_ad=None, base_sr=None, **kwargs):
    """Pitch plus ADSR fit for one note, flagging a clash over the row's single super."""
    pitch = fit_pitch(note, tuning, **kwargs)
    if base_ad is None:
        base_ad, base_sr = int(note.ad[min(1, note.length - 1)]), int(note.sr[min(1, note.length - 1)])
    adsr = fit_adsr(note, base_ad, base_sr)
    return NoteFit(note, pitch, adsr, _needs_super(pitch) and adsr.kind != 'none')


@dataclass
class ChipEffects:
    notes: list = field(default_factory=list)
    filter: FilterPlan = None
    volume: list = field(default_factory=list)


def fit_chip(chip, *, tolerance=12.0, quantum=None, filter_tolerance=16, volume_gap=None, **kwargs):
    """Fit every note, the global filter and the volume of an ir.Chip.

    quantum defaults to 6 base ticks * chip.multiplier. The modal AD/SR per
    voice is taken as the instrument base for the ADSR fit.
    """
    quantum = quantum or 6 * chip.multiplier
    result = ChipEffects()
    for track in chip.voices:
        modal = Counter((int(n.ad[min(1, n.length - 1)]), int(n.sr[min(1, n.length - 1)])) for n in track.notes)
        base = modal.most_common(1)[0][0] if modal else (0, 0)
        for note in track.notes:
            result.notes.append(fit_note(note, chip.tuning, base_ad=base[0], base_sr=base[1],
                                         tolerance=tolerance, quantum=quantum, **kwargs))
    if chip.filter.used():
        result.filter = fit_filter(chip.filter, tolerance=filter_tolerance)
    result.volume = fit_volume(chip.volume, min_gap=volume_gap or quantum)
    return result


@dataclass(frozen=True)
class HostedEvent:
    event: object
    voice: int
    row: int
    shift_rows: int


def assign_hosts(events, quantum, occupied, *, frame_of=None, max_shift=2, voices=(0, 1, 2), prefer=None):
    """Give each global event (filter start / volume change) a free (voice, row) host.

    Each voice row carries at most one super. occupied maps voice -> set of rows
    that already hold one and is updated in place. The ideal row is
    round(frame / quantum); shifts of 0, -1, +1, -2, +2 ... rows are tried, and
    within a row the voices in `prefer` order. Events without a free host
    within max_shift rows are returned with voice None.
    """
    frame_of = frame_of or (lambda e: e.frame)
    order = list(prefer) if prefer else list(voices)
    hosted = []
    for event in sorted(events, key=frame_of):
        ideal = round(frame_of(event) / quantum)
        placed = None
        for shift in sorted(range(-max_shift, max_shift + 1), key=lambda s: (abs(s), s)):
            row = ideal + shift
            if row < 0:
                continue
            voice = next((v for v in order if row not in occupied.setdefault(v, set())), None)
            if voice is not None:
                occupied[voice].add(row)
                placed = HostedEvent(event, voice, row, shift)
                break
        hosted.append(placed or HostedEvent(event, None, ideal, 0))
    return hosted
