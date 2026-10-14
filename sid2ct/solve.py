"""CP-SAT instrument allocation for the native mapper (--instrument-allocation solve).

Chooses at most 47 CT instruments from observed sound variants plus merged
medoid candidates, assigns every variant to one chosen candidate and minimises
audibility-weighted register distortion under the CT table limits (wave rows
with exact-suffix sharing, pulse, filter and command rows).

Two layers. `solve_model` is a pure integer model over a `Problem` (options
with costs, table components, hint groups) and knows nothing about SID.
`build_problem` fills that model from observed variants: it renders each
variant and its nearest candidates through the exact CT player model
(`ctplayer.simulate_voice`), scores them with `regdist.trace_distance` and
prices the ADSR row commands that can repair a pair. The solver is optional:
a missing ortools, an infeasible model or a timeout without any solution
returns None and the caller falls back to the greedy `budget` allocation.
"""
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from types import SimpleNamespace
import time

from . import budget
from .allocation import _state, _wave, waveform_off

SCALE = 100000            # cost units are rounded to this fraction for the integer model
TICK_CAP = 4000         # longest note counted per event, in sound ticks
WINDOWS = (12, 24, 48, 96, 192, 384, 768, 1536)   # rendered window sizes (a cache-friendly grid)
TAIL = 8                # ticks that stand for the held remainder of a note after the window
NEAREST = 12            # candidates priced per variant besides its own and same-shape ones
MAX_VARIANTS = 800      # heavier variants are modelled; the rest follow their nearest choice
ENVELOPE_WEIGHT = 1.5   # per frame cost of a full-scale envelope difference (regdist does not see ADSR)
LOUDNESS_WEIGHT = 0.6   # per frame cost of one octave of envelope level ratio (loudness is heard on a log scale)
QUIET = 0.05            # level floor for that ratio
UNMATCHED_FACTOR = 1.1  # a variant left to the nearest chosen sound costs this times its worst priced option
EXACT_BIAS = 0.05       # per tick: tie-break toward an instrument that is exactly the variant's sound
SILENT = (0, 0, ((0, 0xE0), (0x7E, 0)), (), ())   # an instrument that plays nothing
ARP_PENALTY = 2.0       # distortion per tick for an arpeggio variant leaving its exact instrument
REPAIR_COST = 0.0       # distortion per tick charged for repairing a variant's AD/SR with a row command
DEFAULTS = dict(envelope_weight=ENVELOPE_WEIGHT, loudness_weight=LOUDNESS_WEIGHT, repair_cost=REPAIR_COST)


def tuned(params=None):
    """The solver's distortion weights: DEFAULTS overridden by a (possibly partial) dict."""
    merged = dict(DEFAULTS)
    merged.update({k: v for k, v in (params or {}).items() if k in DEFAULTS})
    return merged


@dataclass
class Option:
    candidate: int                  # -1: not modelled, the nearest chosen instrument takes the notes
    cost: float
    command: tuple | None = None    # row command (op, hi, lo) this repair needs, None when free
    repaired: bool = False          # an AD/SR row super turns the candidate into the variant's pair


@dataclass
class Problem:
    candidates: list                # signatures (ad, sr, wave, pulse, filter)
    options: list                   # per variant: list[Option]
    weights: list                   # per variant weight (hint penalty scale)
    instrument_limit: int = 47
    wave_limit: int = 254
    pulse_limit: int = 63
    filter_limit: int = 63
    command_limit: int = 0          # new command rows available to repairs
    free_commands: frozenset = frozenset()   # repair commands that already have a row
    protected: tuple = ()           # candidate indexes that must be chosen
    hints: dict = field(default_factory=dict)  # group -> {variant: weight}
    hint_penalty: float = 0.0       # cost per unit weight for a group member off its group's instrument
    warm: dict | None = None        # {'chosen': {ci}, 'pick': {vi: option index}}


@dataclass
class Solution:
    status: str
    objective: float
    chosen: list
    pick: dict
    seconds: float
    bound: float = 0.0
    hint_cost: float = 0.0
    commands: int = 0
    deterministic: float = 0.0   # CP-SAT deterministic time used
    wall: float = 0.0            # CP-SAT wall time used


def table_usage(signatures):
    """(instruments, wave, pulse, filter rows) with exact-suffix wave sharing, as the mapper stores them."""
    from .allocation import program_cost
    return program_cost(signatures)


def _wave_suffix_holders(waves):
    """For every wave program the longer programs that contain it as an exact suffix."""
    by_last = defaultdict(list)
    for w in waves:
        by_last[w[-1]].append(w)
    return {w: [o for o in by_last[w[-1]] if len(o) > len(w) and o[-len(w):] == w] for w in waves}


def solve_model(problem, time_limit=20.0, *, workers=8, seed=0, gap=0.0, fix=None):
    """Solve the allocation; returns a Solution, or None when there is no usable result."""
    try:
        from ortools.sat.python import cp_model
    except ImportError:
        return None
    started = time.monotonic()
    p = problem
    m = cp_model.CpModel()
    chosen = [m.NewBoolVar(f'c{i}') for i in range(len(p.candidates))]
    m.Add(sum(chosen) <= p.instrument_limit)
    for ci in p.protected:
        m.Add(chosen[ci] == 1)
    if fix is not None:     # evaluate a given selection (used to compare with the greedy one)
        for i, var in enumerate(chosen):
            m.Add(var == int(i in fix))
    commands = {}
    xs = []
    objective = []
    for vi, options in enumerate(p.options):
        row = []
        for oi, o in enumerate(options):
            x = m.NewBoolVar(f'x{vi}_{oi}')
            if o.candidate >= 0:
                m.AddImplication(x, chosen[o.candidate])
            if o.command is not None and o.command not in p.free_commands:
                if o.command not in commands:
                    commands[o.command] = m.NewBoolVar(f'k{len(commands)}')
                m.AddImplication(x, commands[o.command])
            objective.append(round(o.cost * SCALE) * x)
            row.append(x)
        if not row:
            return None
        m.AddExactlyOne(row)
        xs.append(row)
    if commands:
        m.Add(sum(commands.values()) <= max(0, p.command_limit))
    # Tables: a chosen candidate needs its programs stored (a wave program also by a longer suffix holder).
    used = sorted({o.candidate for row in p.options for o in row if o.candidate >= 0} | set(p.protected))
    waves = {p.candidates[i][2] for i in used if p.candidates[i][2]}
    holders = _wave_suffix_holders(waves)
    stored_wave = {w: m.NewBoolVar('w') for w in waves}
    for i in used:
        w = p.candidates[i][2]
        if w:
            m.AddBoolOr([chosen[i].Not(), stored_wave[w], *(stored_wave[o] for o in holders[w])])
    m.Add(sum(len(w) * v for w, v in stored_wave.items()) <= p.wave_limit)
    for slot, limit in ((3, p.pulse_limit), (4, p.filter_limit)):
        stored = {}
        for i in used:
            t = p.candidates[i][slot]
            if t:
                if t not in stored:
                    stored[t] = m.NewBoolVar('t')
                m.AddImplication(chosen[i], stored[t])
        if stored:
            m.Add(sum(len(t) * v for t, v in stored.items()) <= limit)
    # Source-instrument hints: a soft preference, never a requirement.
    hint_terms = []
    if p.hint_penalty > 0:
        for g, members in p.hints.items():
            if len(members) < 2:
                continue
            reach = Counter(ci for vi in members for ci in {o.candidate for o in p.options[vi]} if ci >= 0)
            pool = [ci for ci, n in reach.most_common(8) if n >= 2]
            if not pool:
                continue
            z = {ci: m.NewBoolVar('z') for ci in pool}
            m.AddExactlyOne(list(z.values()))
            for vi, weight in members.items():
                miss = m.NewBoolVar('h')
                for ci in pool:
                    assigned = [xs[vi][oi] for oi, o in enumerate(p.options[vi]) if o.candidate == ci]
                    m.Add(miss >= z[ci] - sum(assigned))
                term = round(p.hint_penalty * weight * SCALE)
                if term:
                    hint_terms.append(term * miss)
    # Equal-cost optima are separated by a tiny index-based cost so every worker count finds the same one.
    ties = [(ci + 1) * var for ci, var in enumerate(chosen)] + \
           [(oi + 1) * x for row in xs for oi, x in enumerate(row)]
    m.Minimize(sum(objective) + sum(hint_terms) + sum(ties))
    if p.warm:
        warm = p.warm
        for i, var in enumerate(chosen):
            m.AddHint(var, int(i in warm['chosen']))
        for vi, oi in warm.get('pick', {}).items():
            for k, x in enumerate(xs[vi]):
                m.AddHint(x, int(k == oi))
    solver = cp_model.CpSolver()
    budget.check()
    # Stop on deterministic time only, so the result does not depend on machine load or on how long the model took
    # to build. Wall time is a safety backstop tied to the conversion budget, never a normal stopping rule.
    solver.parameters.max_deterministic_time = max(0.5, time_limit)
    left = budget.remaining()
    solver.parameters.max_time_in_seconds = max(0.5, left if left != float('inf') else 20 * time_limit)
    solver.parameters.num_search_workers = workers
    if workers > 1:
        solver.parameters.interleave_search = True    # reproducible multi-worker search
    solver.parameters.random_seed = seed
    solver.parameters.relative_gap_limit = gap
    status = solver.Solve(m)
    name = solver.StatusName(status)
    seconds = time.monotonic() - started
    if status not in (cp_model.OPTIMAL, cp_model.FEASIBLE):
        return None
    pick = {vi: next(oi for oi, x in enumerate(row) if solver.Value(x)) for vi, row in enumerate(xs)}
    picked = sorted({p.options[vi][oi].candidate for vi, oi in pick.items()} - {-1})
    chosen_set = sorted(i for i in range(len(chosen)) if solver.Value(chosen[i]))
    # Candidates no variant uses cost an instrument for nothing; drop them.
    chosen_set = [i for i in chosen_set if i in set(picked) or i in p.protected]
    cost = sum(p.options[vi][oi].cost for vi, oi in pick.items())
    used_commands = {p.options[vi][oi].command for vi, oi in pick.items()
                     if p.options[vi][oi].command is not None and p.options[vi][oi].command not in p.free_commands}
    return Solution(name, cost, chosen_set, pick, seconds, solver.BestObjectiveBound() / SCALE,
                    solver.ObjectiveValue() / SCALE - cost, len(used_commands),
                    solver.deterministic_time, solver.wall_time)


# ---------------------------------------------------------------------------
# Building the problem from observed sound variants


@dataclass
class Variant:
    signature: tuple
    base: int               # most used note
    max_base: int           # highest note any event plays
    ticks: int              # rendered window in sound ticks
    free: float             # event ticks that can take an AD/SR row super
    busy: float             # event ticks that cannot (command, chord, coupled, no effect planner)
    coupled: bool = False
    exact_required: bool = False   # an arpeggio chord needs this instrument's own wave program
    source: object = None          # observed register frames (voice moved to column 0) of a typical note

    @property
    def total(self):
        return self.free + self.busy


_FEATURE_TICKS = (0, 1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 47)


def _features(signature):
    import numpy as np
    ad, sr, wave, pulse, filt = signature
    decoded = _wave(wave)
    vec = [ad >> 4, ad & 15, sr >> 4, sr & 15]
    for tick in _FEATURE_TICKS:
        pitch, control = _state(decoded, tick)
        nib = control >> 4 & 15
        vec += [nib & 1, nib >> 1 & 1, nib >> 2 & 1, nib >> 3 & 1, control & 6, min(max(pitch, -24), 24) / 6
                if pitch < 128 else 8]
    vec += [len(pulse) > 0, (pulse[0][2] if pulse else 0) / 16, len(filt) > 0, min(decoded[2], 96) / 8]
    return np.array(vec, float)


def nearest_candidates(variants, candidates, k=NEAREST):
    """Per variant the indexes of its k nearest candidates by a cheap sampled-program distance.

    Same-shape candidates (same programs, other AD/SR) and the variant's own
    candidate are always kept: they are what AD/SR row supers repair.
    """
    import numpy as np
    fv = np.array([_features(v.signature) for v in variants])
    fc = np.array([_features(c) for c in candidates])
    d = np.abs(fv[:, None, :] - fc[None, :, :]).sum(axis=2)
    index = {c: i for i, c in enumerate(candidates)}
    shapes = defaultdict(list)
    for i, c in enumerate(candidates):
        shapes[c[2:]].append(i)
    result = []
    for vi, v in enumerate(variants):
        own = shapes.get(v.signature[2:], [])
        keep = set(own)
        if v.signature in index:
            keep.add(index[v.signature])
        off = waveform_off(v.signature)
        added = 0
        for ci in np.argsort(d[vi], kind='stable'):
            if added >= k:
                break
            ci = int(ci)
            if ci not in keep and waveform_off(candidates[ci]) == off:
                keep.add(ci)
                added += 1
        result.append(sorted(c for c in keep if waveform_off(candidates[c]) == off))
    return result


def adsr_repair(wanted, base, effects):
    """What turns an instrument's (ad, sr) into `wanted` on one row: (kind, command).

    kind is 'none', 'inline' (free row super), 'command' or None when the
    mapper has no effect planner (plain mode has no row supers).
    """
    if not effects:
        return None, None
    if wanted == base:
        return 'none', None
    from .effects import fit_adsr
    stand_in = SimpleNamespace(length=2, ad=[wanted[0]] * 2, sr=[wanted[1]] * 2)
    fit = fit_adsr(stand_in, *base)
    if fit.kind == 'inline':
        return 'inline', None
    return 'command', fit.command


def build_problem(variants, pricer, *, instrument_limit=47, wave_limit=254,
                  pulse_limit=63, filter_limit=63, command_limit=0, free_commands=frozenset(),
                  protected_signatures=(), hints=None, hint_penalty=0.0, k=NEAREST, merge=True):
    """Price every (variant, candidate) pair and return a Problem.

    pricer.price_many([(variant index, signature)]) -> one [(cost, command, repaired)] list per
    pair; see Pricer. Pairs are priced in batches so a process pool can share the work.
    """
    candidates = [v.signature for v in variants]
    for sig in (*protected_signatures, SILENT):
        if sig not in candidates:
            candidates.append(sig)
    index = {c: i for i, c in enumerate(candidates)}
    def priced(pairs):
        """{(vi, ci): option tuples}, pairs priced once, in the given (stable) order."""
        return dict(zip(pairs, pricer.price_many([(vi, candidates[ci]) for vi, ci in pairs])))

    def eligible(vi, ci):
        return ci == index.get(variants[vi].signature) or \
            variants[vi].max_base + _relative_limit(candidates[ci]) <= 95

    near = nearest_candidates(variants, candidates, k)
    quiet = index[SILENT]
    for vi, v in enumerate(variants):
        # Playing nothing beats a loud wrong sound; a coupled source's oscillator must keep sounding.
        if not v.coupled and quiet not in near[vi] and not waveform_off(v.signature):
            near[vi] = sorted(set(near[vi]) | {quiet})
    first = priced([(vi, ci) for vi in range(len(variants)) for ci in near[vi] if eligible(vi, ci)])
    options = [[Option(ci, *t) for ci in near[vi] if (vi, ci) in first for t in first[(vi, ci)]]
               for vi in range(len(variants))]
    if merge:
        new = []
        for sig, source in _merged_candidates(variants, candidates, options, instrument_limit):
            candidates.append(sig)
            index[sig] = len(candidates) - 1
            new.append((index[sig], source))
        pairs = [(vi, ci) for ci, source in new for vi, v in enumerate(variants)
                 if any(o.candidate == source for o in options[vi]) and waveform_off(candidates[ci]) == waveform_off(v.signature)
                 and eligible(vi, ci)]
        extra = priced(pairs)
        for (vi, ci), tuples in extra.items():
            options[vi].extend(Option(ci, *t) for t in tuples)
    for vi, v in enumerate(variants):
        own = index.get(v.signature)
        row = []
        for o in options[vi]:
            extra = 0.0
            if o.candidate != own and not o.repaired:
                extra += EXACT_BIAS * v.total
            if o.candidate != own and v.exact_required:
                extra += ARP_PENALTY * v.total
            row.append(Option(o.candidate, o.cost + extra, o.command, o.repaired))
        worst = max((o.cost for o in row), default=0.0)
        row.append(Option(-1, max(UNMATCHED_FACTOR * worst, 0.3 * v.total) + (ARP_PENALTY * v.total if v.exact_required else 0.0)))
        options[vi] = row
    protected = tuple(index[s] for s in protected_signatures)
    return Problem(candidates, options, [v.total for v in variants], instrument_limit, wave_limit,
                   pulse_limit, filter_limit, command_limit, frozenset(free_commands), protected,
                   hints or {}, hint_penalty)


def _relative_limit(signature):
    return max((n for n, c in signature[2] if c >= 16 and n < 128), default=0)


def _settle_ticks(ad, output_multiplier):
    """Ticks an envelope needs to rise and decay to its sustain level (the part a short window would miss)."""
    from .regdist import ATTACK_MS, DECAY_MS
    return int((ATTACK_MS[ad >> 4] + DECAY_MS[ad & 15]) * output_multiplier / 20)


def _window(v, candidate, output_multiplier=1):
    """Ticks to render for a pair: both programs and envelopes settled plus a margin, on the WINDOWS grid."""
    need = max(_wave(v.signature[2])[2], _wave(candidate[2])[2],
               _settle_ticks(v.signature[0], output_multiplier), _settle_ticks(candidate[0], output_multiplier))
    need = min(need + 2 * TAIL, v.ticks)
    return next((w for w in WINDOWS if w >= need), WINDOWS[-1]) if need > 0 else WINDOWS[0]


def _blend(per_tick, window, ticks):
    """Mean per-tick distortion over the note: the window itself, then the last TAIL ticks stand for the rest."""
    d_all = float(per_tick.mean())
    if ticks <= window:
        return d_all
    tail = float(per_tick[-TAIL:].mean())
    return (d_all * window + tail * (ticks - window)) / ticks


def _price(v, candidate, compare, render, effects, output_multiplier=1, repair_cost=0.0):
    """Option list for one pair: [(cost, command, repaired)]."""
    window = _window(v, candidate, output_multiplier)
    try:
        plain = _blend(compare(v, window, render(candidate, v.base, window)), window, v.ticks)
    except (IndexError, ValueError, ZeroDivisionError):
        return []
    result = [(plain * v.total, None, False)]
    wanted, base = v.signature[:2], candidate[:2]
    kind, command = adsr_repair(wanted, base, effects)
    if kind is None or kind == 'none' or v.free <= 0:
        return result
    try:
        fixed = _blend(compare(v, window, render(wanted + candidate[2:], v.base, window)), window, v.ticks)
    except (IndexError, ValueError, ZeroDivisionError):
        return result
    cost = fixed * v.free + plain * v.busy + repair_cost * v.free
    if cost < result[0][0] - 1e-9:
        result.append((cost, command, True))
    return result


def _merged_candidates(variants, candidates, options, limit):
    """Merged medoid candidates: greedy facility location over the priced pairs, then each
    medoid's cluster contributes its most used AD/SR pair to the medoid's programs."""
    best = defaultdict(dict)       # candidate -> {variant: cheapest cost}
    for vi, row in enumerate(options):
        for o in row:
            if o.candidate >= 0 and o.cost < best[o.candidate].get(vi, float('inf')):
                best[o.candidate][vi] = o.cost
    miss = [max(1.0, v.total * 1.0) for v in variants]
    current = list(miss)
    picked = []
    for _ in range(min(limit, len(candidates))):
        gain, choice = 0.0, None
        for ci, covered in best.items():
            if ci in picked:
                continue
            g = sum(max(0.0, current[vi] - cost) for vi, cost in covered.items())
            if g > gain + 1e-12:
                gain, choice = g, ci
        if choice is None:
            break
        picked.append(choice)
        for vi, cost in best[choice].items():
            current[vi] = min(current[vi], cost)
    clusters = defaultdict(list)
    for vi in range(len(variants)):
        owner = min(((best[ci].get(vi, float('inf')), ci) for ci in picked), default=(None, None))[1]
        if owner is not None:
            clusters[owner].append(vi)
    known, merged = set(candidates), []
    for ci, members in sorted(clusters.items()):
        votes = Counter()
        for vi in members:
            votes[variants[vi].signature[:2]] += variants[vi].total
        adsr = max(votes.items(), key=lambda kv: (kv[1], kv[0]))[0]
        sig = adsr + candidates[ci][2:]
        if sig not in known:
            known.add(sig)
            merged.append((sig, ci))
    return merged


# ---------------------------------------------------------------------------
# Structure hints


def hint_groups(events, hints, scale, voices=3):
    """Group event variants by source instrument number.

    events: [(voice, start frame, variant index, ticks)]. A hinted note
    belongs to an event when it starts within about two ticks of it.
    Returns {instrument: {variant: weight}}.
    """
    from bisect import bisect_left
    notes = []
    for voice in range(voices):
        current, rows = None, []
        for n in hints.voices[voice].notes:
            if n.kind != 'note':
                continue
            if n.instrument is not None:
                current = n.instrument
            if current is not None:
                rows.append((round(n.call * scale), current))
        notes.append(sorted(rows))
    tolerance = max(2.0, 2 * scale)
    groups = defaultdict(lambda: defaultdict(float))
    for voice, start, vi, ticks in events:
        rows = notes[voice]
        pos = bisect_left(rows, (start, -1))
        near = [r for r in rows[max(0, pos - 1):pos + 1] if abs(r[0] - start) <= tolerance]
        if near:
            instrument = min(near, key=lambda r: abs(r[0] - start))[1]
            groups[instrument][vi] += ticks
    return {g: dict(m) for g, m in groups.items()}


# ---------------------------------------------------------------------------
# Glue for native._native_song


class Pricer:
    """Prices (variant, candidate) pairs: renders the candidate through the CT player model and compares
    it with the variant's observed note. Picklable, so price_many can use a process pool."""

    def __init__(self, variants, image_maker, output_multiplier, effects, workers=1, params=None):
        self.variants, self.image_maker = variants, image_maker
        self.params = tuned(params)
        self.output_multiplier, self.effects, self.workers = output_multiplier, effects, workers
        self._render = None

    def _setup(self):
        if self._render is None:
            self._render = make_renderer(self.image_maker, self.output_multiplier)

    def compare(self, v, window, trace):
        """Per-tick distortion: regdist's weighted register costs plus envelope level and loudness terms."""
        import numpy as np
        from .regdist import WEIGHTS, envelope_estimate, frame_costs
        a, b = v.source[:window], trace[2 * self.output_multiplier:]   # a row's note opens on its tick 2
        n = min(len(a), len(b))
        a, b = a[:n], b[:n]
        costs, n = frame_costs(a, b, self.output_multiplier)
        total = sum(WEIGHTS[k] * costs[k] for k in costs)
        ea = envelope_estimate(a, 0, self.output_multiplier)[:n]
        eb = envelope_estimate(b, 0, self.output_multiplier)[:n]
        octaves = abs(np.log2((ea + QUIET) / (eb + QUIET)))
        return total + self.params['envelope_weight'] * abs(ea - eb) + self.params['loudness_weight'] * octaves

    def price(self, vi, candidate):
        budget.check()
        self._setup()
        return _price(self.variants[vi], candidate, self.compare, self._render, self.effects, self.output_multiplier,
                      self.params['repair_cost'])

    def price_many(self, pairs):
        """Results in the order of pairs, whatever the worker count (pricing is a pure function)."""
        if self.workers <= 1 or len(pairs) < 64:
            return [self.price(vi, sig) for vi, sig in pairs]
        from concurrent.futures import ProcessPoolExecutor
        chunk = max(8, -(-len(pairs) // (self.workers * 8)))
        chunks = [pairs[i:i + chunk] for i in range(0, len(pairs), chunk)]
        with ProcessPoolExecutor(self.workers, initializer=_init_worker, initargs=(self, budget.remaining())) as pool:
            return [r for part in pool.map(_price_chunk, chunks) for r in part]

    def __getstate__(self):
        state = dict(self.__dict__)
        state['_render'] = None
        return state


_WORKER = None


def _init_worker(pricer, seconds_left=float('inf')):
    global _WORKER
    _WORKER = pricer
    if seconds_left != float('inf'):
        budget.install(budget.Budget(max(0.0, seconds_left)))   # lives as long as the worker


def _price_chunk(pairs):
    return [_WORKER.price(vi, sig) for vi, sig in pairs]


class ImageMaker:
    """Picklable make_image: the template payload with the four programme tables installed."""

    def __init__(self, data, offsets, output_multiplier):
        self.data, self.offsets, self.output_multiplier = bytes(data), dict(offsets), output_multiplier

    def __call__(self, wave, control, pulses, filters):
        image = bytearray(self.data)
        for index, values in ((14, wave), (15, control), (17, [x for r in pulses for x in r]),
                              (16, [x for r in filters for x in r])):
            addr = self.offsets[index]
            image[addr:addr + 256] = bytes(values) + bytes(256 - len(values))
        image[65538] = self.output_multiplier
        return image


def _observed(frames, voice, start, stop, step):
    """The source's register frames for one note with that voice moved to column 0 (where the renders play)."""
    import numpy as np
    seg = np.frombuffer(b''.join(bytes(f) for f in frames[start:stop:step]), np.uint8).reshape(-1, 25).astype(np.int64)
    out = np.zeros_like(seg)
    out[:, :7] = seg[:, voice * 7:voice * 7 + 7]
    out[:, 21:25] = seg[:, 21:25]
    out[:, 23] = (seg[:, 23] & 0xF0) | (seg[:, 23] >> voice & 1)
    return out


def make_renderer(make_image, output_multiplier):
    """render(signature, base, ticks) -> numpy frames, through the exact CT player model.

    make_image(wave, control, pulses, filters) returns a CC2 payload with those
    tables installed (the native mapper's own layout: wave starts at row 2,
    pulse and filter programs at row 1).
    """
    import numpy as np
    from .ctplayer import simulate_voice
    cache = {}

    def table(program):
        rows = [[0, 0, 255, 127]]
        for i, r in enumerate(program):
            rr = list(r)
            rr[3] = 1 + i + 1 if i + 1 < len(program) else 127
            rows.append(rr)
        return rows

    def render(signature, base, ticks):
        key = (signature, base, ticks)
        if key not in cache:
            ad, sr, wave, pulse, filt = signature
            image = make_image([0, 0x7E] + [n for n, _ in wave], [0x11, 0] + [c for _, c in wave],
                               table(pulse) if pulse else [[0, 0, 255, 127]],
                               table(filt) if filt else [[0, 0, 255, 127]])
            definition = (ad, sr, wave[-1][1] if wave[-1][0] == 0x7E else 0, 0, 1 if filt else 0,
                          1 if pulse else 0, 0, 2)
            frames = simulate_voice(definition, [(0, base)], ticks, image)
            cache[key] = np.frombuffer(b''.join(frames), np.uint8).reshape(-1, 25).astype(np.int64)
        return cache[key]
    render.cache = cache
    return render


def allocate(events, stops, plans, *, frames, usage, step, effects, make_image, output_multiplier, limits,
             coupled_signatures, protected, warm_selection=None, hints=None, hint_scale=1.0,
             time_limit=20.0, free_commands=frozenset(), command_limit=0, workers=8, hint_penalty=0.05, compare_warm=False, evaluate=None,
             params=None):
    """Run the solver over a native mapper's events.

    frames: the source's register frames; step: source frames per sound tick.
    events: [(voice, start, base, signature, coupled)]; stops: {(voice, start): stop frame};
    plans: {(voice, start): NotePlan | None}; usage: Counter of signature -> events.
    Returns (selected signatures, {signature: (candidate signature, command, repaired)}, report)
    or (None, None, report) when the solver gave no usable answer.
    """
    started = time.monotonic()
    infos = {}
    for v, start, base, sig, coupled in events:
        ticks = max(2, min(TICK_CAP, -(-(stops[(v, start)] - start) // step)))
        plan = plans.get((v, start))
        busy = coupled or not effects or (plan is not None and (plan.command or plan.chord))
        weight = ticks * (2.0 if coupled else 1.0)
        entry = infos.setdefault(sig, dict(bases=Counter(), ticks=[], free=0.0, busy=0.0, coupled=False,
                                           arp=False, max_base=0))
        entry['bases'][base] += 1
        entry['ticks'].append(ticks)
        entry['free' if not busy else 'busy'] += weight
        entry['coupled'] |= bool(coupled)
        entry['arp'] |= plan is not None and plan.arpeggio()
        entry['max_base'] = max(entry['max_base'], base)
        entry.setdefault('events', []).append((ticks, base, v, start))
    ranked = sorted(infos, key=lambda s: (-(infos[s]['free'] + infos[s]['busy']), s))
    modelled = ranked[:MAX_VARIANTS]
    variants = []
    for sig in modelled:
        e = infos[sig]
        ticks, base, voice, start = sorted(e['events'])[len(e['events']) // 2]
        variants.append(Variant(sig, base, e['max_base'], ticks, e['free'], e['busy'], e['coupled'], e['arp'],
                                _observed(frames, voice, start, start + ticks * step, step)))
    pricer = Pricer(variants, make_image, output_multiplier, effects, workers, params)
    groups = {}
    if hints is not None:
        position = {sig: i for i, sig in enumerate(modelled)}
        groups = hint_groups([(v, s, position[sig], -(-(stops[(v, s)] - s) // step))
                              for v, s, b, sig, c in events if sig in position], hints, hint_scale)
    problem = build_problem(variants, pricer, instrument_limit=limits[0],
                            wave_limit=limits[1], pulse_limit=limits[2], filter_limit=limits[3],
                            command_limit=command_limit, free_commands=free_commands,
                            protected_signatures=protected, hints=groups,
                            hint_penalty=hint_penalty if groups else 0.0)
    built = time.monotonic() - started
    index = {c: i for i, c in enumerate(problem.candidates)}
    if warm_selection:
        keep = {index[s] for s in warm_selection if s in index}
        pick = {}
        for vi, row in enumerate(problem.options):
            choices = [(o.cost, oi) for oi, o in enumerate(row) if o.candidate in keep and o.command is None]
            if choices:
                pick[vi] = min(choices)[1]
        problem.warm = dict(chosen=keep, pick=pick)
    report = dict(variants=len(infos), modelled=len(variants), candidates=len(problem.candidates),
                  options=sum(map(len, problem.options)), hint_groups=len(groups), build_seconds=round(built, 2))
    if evaluate:
        report['compare'] = {}
        for label, selection in evaluate.items():
            keep = {index[s] for s in selection if s in index}
            alt = solve_model(problem, 10.0, workers=workers, fix=keep)
            report['compare'][label] = round(alt.objective, 3) if alt else None
    budget.check()
    solution = solve_model(problem, time_limit, workers=workers)
    if compare_warm and warm_selection:
        base = solve_model(problem, 10.0, workers=workers, fix=problem.warm['chosen'])
        report['warm_objective'] = round(base.objective, 3) if base else None
    if solution is None:
        report['status'] = 'no_solution'
        return None, None, report
    selected = [problem.candidates[i] for i in solution.chosen]
    assignment = {}
    for vi, oi in solution.pick.items():
        o = problem.options[vi][oi]
        assignment[modelled[vi]] = (problem.candidates[o.candidate], o.command, o.repaired)
    for sig in ranked[MAX_VARIANTS:]:
        from .allocation import trajectory_distance
        same = [s for s in selected if waveform_off(s) == waveform_off(sig)]
        if same:
            assignment[sig] = (min(same, key=lambda s: (trajectory_distance(sig, s, coupled=sig in coupled_signatures), s)),
                               None, False)
    report.update(status=solution.status, objective=round(solution.objective, 3), bound=round(solution.bound, 3),
                  solver_seconds=round(solution.seconds, 2), solver_wall=round(solution.wall, 2),
                  solver_deterministic=round(solution.deterministic, 2), selected=len(selected),
                  hint_cost=round(solution.hint_cost, 3), repair_commands=solution.commands,
                  seconds=round(time.monotonic() - started, 2))
    return selected, assignment, report
