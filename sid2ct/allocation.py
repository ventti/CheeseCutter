"""Deterministic native SID trajectory allocation (stdlib only).

Limits: 1024 observed signatures, 256 candidate medoids, 96 sampled ticks,
4096 wave rows per signature. At most 1024*256 cached distances and 47
(or caller limit) greedy passes. Excess input is rejected rather than silently
truncated. Ties use the immutable signature's tuple order. Returned medoids
are existing signatures; allocation does not allocate native table rows.
"""
from bisect import bisect_right
from functools import lru_cache
import math

MAX_SIGNATURES = 1024
MAX_CANDIDATES = 256
SAMPLES = 96


@lru_cache(maxsize=2048)
def _wave(program):
    if len(program) > 4096:
        raise ValueError('Wave program exceeds 4096 rows')
    ends, states = [], []
    total = 0
    i = 0
    while i < len(program):
        pitch, control = program[i]
        if pitch == 0x7E:
            break
        duration = 1
        if i + 1 < len(program) and 1 <= program[i + 1][1] < 16:
            duration = program[i + 1][1] + 2
            i += 1
        if control >= 0xE0:
            control &= 15
        total += duration
        ends.append(total)
        states.append((pitch, control))
        i += 1
    # Normalize only relative pitches. Absolute pitches encode fixed oscillator
    # frequencies and cannot safely be transposed (including absolute zero).
    origin = next((p for p, _ in states if p < 128), 0)
    states = tuple((p - origin if p < 128 else p, c) for p, c in states)
    return tuple(ends), states, total


def waveform_off(signature):
    return not any(c & 0xF0 for _, c in _wave(signature[2])[1])


def _state(decoded, tick):
    ends, states, _ = decoded
    return states[min(bisect_right(ends, tick), len(states) - 1)] if states else (0, 0)


def _modulation(left, right):
    # Preserve reset, slope, duration, routing and stop distinctions. Native
    # modulation tables are short; compare their ordered rows without inventing
    # tracker semantics for rows whose interpretation depends on player state.
    if left == right:
        return 0.0
    n = max(len(left), len(right))
    if not left or not right:
        return 32.0 + n
    error = 0.0
    for i in range(n):
        a, b = left[min(i, len(left)-1)], right[min(i, len(right)-1)]
        error += sum(abs(x-y) / 16 for x, y in zip(a, b))
    return error / n + abs(len(left)-len(right)) * 2


def trajectory_distance(left, right, *, coupled=False):
    """Compare signatures in tick time, invariant to relative pitch offset.

    Held tails are compared at equal ticks; duration and control transitions
    remain visible. SYNC/RING/TEST differences receive a large coupled penalty.
    Waveform-off/audible pairs have a large penalty; selection additionally
    reserves representatives for both classes so they need never be merged.
    """
    if left == right:
        return 0.0
    a, b = _wave(left[2]), _wave(right[2])
    horizon = max(a[2], b[2], 1)
    count = min(SAMPLES, horizon)
    error = 0.0
    for i in range(count):
        tick = (i * (horizon-1)) // max(count-1, 1)
        p, c = _state(a, tick)
        q, d = _state(b, tick)
        error += ((c ^ d) & 0xF0).bit_count() * 20
        error += ((c ^ d) & 14).bit_count() * (1000 if coupled else 80)
        error += (c ^ d) & 1
        error += abs(p-q) * 4 if (p >= 128) == (q >= 128) else 384
    error /= count
    error += abs(a[2]-b[2]) * 0.5
    error += sum(abs((left[j] >> shift & 15)-(right[j] >> shift & 15))
                 for j in (0, 1) for shift in (0, 4)) * 3
    error += _modulation(left[3], right[3]) + _modulation(left[4], right[4])
    if waveform_off(left) != waveform_off(right):
        error += 1000000
    return float(error)


def _class(signature, coupled):
    # Distinct critical-control transition sequences cannot lose their last
    # medoid. Gate is compared by distance, rather than fragmenting classes.
    controls = []
    if signature in coupled:
        for _, c in _wave(signature[2])[1]:
            critical = c & 14
            if not controls or controls[-1] != critical:
                controls.append(critical)
    return waveform_off(signature), tuple(controls)


def select_representatives(usage, limit=47, *, coupled=(), protected=()):
    """Greedy weighted facility-location medoids over a bounded candidate pool.

    Protected entries and the most-used member of each hidden/critical-control
    class are mandatory. Reject impossible capacity. Other medoids maximize
    weighted reduction in nearest distance. Pool contains mandatory medoids,
    highest-use entries and a deterministic spread of remaining signatures.
    This is a bounded approximation, not a global clustering optimum.
    """
    if not isinstance(limit, int) or limit < 0:
        raise ValueError('limit must be a nonnegative integer')
    if len(usage) > MAX_SIGNATURES:
        raise ValueError('At most 1024 signatures are supported')
    for weight in usage.values():
        if not math.isfinite(weight) or weight <= 0:
            raise ValueError('Occurrence weights must be positive and finite')
    coupled, protected = set(coupled), set(protected)
    if not protected <= usage.keys() or not coupled <= usage.keys():
        raise ValueError('Protected and coupled entries must occur in usage')
    ranked = sorted(usage, key=lambda s: (-usage[s], s))
    if len(ranked) <= limit:
        return ranked
    if not limit:
        raise ValueError('No capacity for observed signatures')
    classes = {}
    for signature in ranked:
        classes.setdefault(_class(signature, coupled), signature)
    mandatory = protected | set(classes.values())
    if len(mandatory) > limit or len(mandatory) > MAX_CANDIDATES:
        raise ValueError('Capacity cannot preserve protected/critical source classes')
    pool = set(mandatory)
    pool.update(ranked[:min(MAX_CANDIDATES//2, MAX_CANDIDATES-len(pool))])
    remaining = sorted(set(ranked)-pool)
    slots = MAX_CANDIDATES-len(pool)
    if remaining and slots:
        pool.update(remaining[(i * len(remaining)) // slots]
                    for i in range(min(slots, len(remaining))))
    pool = sorted(pool)
    observations = sorted(usage)
    distances = {candidate: [trajectory_distance(observed, candidate,
                    coupled=observed in coupled or candidate in coupled)
                    for observed in observations] for candidate in pool}
    selected = sorted(mandatory)
    nearest = [min(distances[s][i] for s in selected)
               for i in range(len(observations))]
    weights = [usage[s] for s in observations]
    while len(selected) < min(limit, len(pool)):
        candidates = [s for s in pool if s not in selected]
        best = min(candidates, key=lambda s: (-sum(w * max(0, old-new)
                     for w, old, new in zip(weights, nearest, distances[s])),
                     -usage[s], s))
        selected.append(best)
        nearest = [min(old, new) for old, new in zip(nearest, distances[best])]
    return selected


def program_cost(signatures):
    """Return instrument/wave/pulse/filter row costs with exact sharing.

    Wave programs that are exact suffixes share storage, matching native wave
    suffix reuse. Pulse/filter programs share only when fully equal. Empty
    tables cost zero. Costs exclude caller-owned sentinel/reserved table rows;
    pass editable capacities after subtracting those rows.
    """
    signatures = set(signatures)
    waves = {s[2] for s in signatures if s[2]}
    stored = [w for w in waves if not any(len(other) > len(w) and
              other[-len(w):] == w for other in waves)]
    return (len(signatures), sum(map(len, stored)),
            sum(map(len, {s[3] for s in signatures if s[3]})),
            sum(map(len, {s[4] for s in signatures if s[4]})))


def select_with_budgets(usage, *, instrument_limit=47, wave_limit,
                        pulse_limit, filter_limit, coupled=(), protected=()):
    """Select feasible existing medoids under four explicit editable budgets.

    Greedy weighted medoid ordering is followed subject to row feasibility.
    Mandatory critical/source classes and protected entries are admitted first
    or rejected. This heuristic can leave capacity unused and can reject a
    feasible alternative mandatory medoid: it is not an exact integer solver.
    Programs are retained completely; no silent dropping of modulation rows.
    """
    budgets = (instrument_limit, wave_limit, pulse_limit, filter_limit)
    if any(not isinstance(b, int) or b < 0 for b in budgets):
        raise ValueError('All editable budgets must be nonnegative integers')
    coupled, protected = set(coupled), set(protected)
    # This also validates occurrence weights, membership and source capacity.
    order = select_representatives(usage, instrument_limit,
                                   coupled=coupled, protected=protected)
    ranked = sorted(usage, key=lambda s: (-usage[s], s))
    classes = {}
    for signature in ranked:
        classes.setdefault(_class(signature, coupled), signature)
    selected = sorted(protected | set(classes.values()))
    if any(c > b for c, b in zip(program_cost(selected), budgets)):
        raise ValueError('Mandatory medoids exceed editable table budgets')
    for signature in order:
        if signature in selected:
            continue
        trial = selected + [signature]
        if all(c <= b for c, b in zip(program_cost(trial), budgets)):
            selected = trial
    return selected
