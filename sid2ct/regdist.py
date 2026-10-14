"""Perceptually weighted distance between two SID register traces (25-byte frames).

Each frame pair is scored per voice and for the global filter and volume.
Pitch counts in cents and only while a voice is audible; every voice term is
weighted by an envelope estimate of the louder side, so a quiet release tail
costs less than a held note. Gate timing, waveform bits (including SYNC and
RING), pulse width, cutoff, resonance, mode, routing and master volume add
their own terms. The result is a mean per-frame cost: 0 is identical and 1 is
roughly one semitone of pitch error on a full-volume voice for every frame.
Used to compare a source trace with a CTPlayer trace without rendering audio.
"""
import math

import numpy as np

from . import budget

# SID attack and decay/release times (ms, full scale) indexed by nibble.
ATTACK_MS = (2, 8, 16, 24, 38, 56, 68, 80, 100, 250, 500, 800, 1000, 3000, 5000, 8000)
DECAY_MS = tuple(3 * t for t in ATTACK_MS)

PITCH_CAP_CENTS = 600.0
NOISE_PITCH_SCALE = 0.25          # a noise waveform's pitch is only a timbre colour
WEIGHTS = dict(pitch=1 / 100, gate=2.0, wave=0.5, pulse=1.5, cutoff=3.0, resonance=0.5, mode=0.5,
               route=0.5, volume=2.0)
CATEGORIES = tuple(WEIGHTS)


def _frames(trace):
    if isinstance(trace, np.ndarray):
        return trace.astype(np.int64)
    if not len(trace):
        return np.zeros((0, 25), np.int64)
    return np.frombuffer(b''.join(bytes(f) for f in trace), np.uint8).reshape(-1, 25).astype(np.int64)


def envelope_estimate(trace, voice, multiplier=1):
    """Approximate envelope level 0..1 per frame from the voice's gate and ADSR registers."""
    a = _frames(trace)
    base = voice * 7
    dt = 20.0 / multiplier
    level, state, last_gate = 0.0, 'release', 0
    out = np.zeros(len(a))
    for i, f in enumerate(a):
        gate = f[base + 4] & 1
        ad, sr = f[base + 5], f[base + 6]
        if gate and not last_gate:
            state = 'attack'
        elif not gate and last_gate:
            state = 'release'
        last_gate = gate
        sustain = (sr >> 4) / 15
        if state == 'attack':
            level += dt / ATTACK_MS[ad >> 4]
            if level >= 1:
                level, state = 1.0, 'decay'
        elif state == 'decay':
            tau = DECAY_MS[ad & 15] / 3.0
            level = sustain + (level - sustain) * math.exp(-dt / tau)
        else:
            tau = DECAY_MS[sr & 15] / 3.0
            level *= math.exp(-dt / tau)
        out[i] = level
    return out


def _popcount(x):
    x = np.asarray(x, np.int64)
    count = np.zeros_like(x)
    for bit in range(8):
        count += (x >> bit) & 1
    return count


def _cents(a, b):
    both = (a > 0) & (b > 0)
    ratio = np.where(both, a, 1) / np.where(both, b, 1)
    return np.where(both, np.abs(1200 * np.log2(ratio)), PITCH_CAP_CENTS)


def frame_costs(source, trace, multiplier=1):
    """Per-frame cost arrays by category over the common length, plus the per-voice envelopes."""
    a, b = _frames(source), _frames(trace)
    n = min(len(a), len(b))
    a, b = a[:n], b[:n]
    costs = {k: np.zeros(n) for k in CATEGORIES}
    envelopes = []
    for v in range(3):
        o = v * 7
        env = np.maximum(envelope_estimate(a, v, multiplier), envelope_estimate(b, v, multiplier))
        envelopes.append(env)
        ca, cb = a[:, o + 4], b[:, o + 4]
        wa, wb = ca & 0xF0, cb & 0xF0
        audible_a = (wa != 0) & ((ca & 8) == 0)
        audible_b = (wb != 0) & ((cb & 8) == 0)
        both = audible_a & audible_b
        fa, fb = a[:, o] | a[:, o + 1] << 8, b[:, o] | b[:, o + 1] << 8
        noise = ((wa & 0x80) != 0) | ((wb & 0x80) != 0)
        cents = np.minimum(_cents(fa, fb), PITCH_CAP_CENTS)
        costs['pitch'] += np.where(both, cents * np.where(noise, NOISE_PITCH_SCALE, 1.0) * env, 0.0)
        costs['gate'] += np.where((ca & 1) != (cb & 1), env, 0.0)
        # A voice that sounds on one side only is a waveform miss, as are differing bits.
        diff = _popcount((wa ^ wb) >> 4) + _popcount((ca ^ cb) & 6)
        costs['wave'] += np.where(audible_a | audible_b, diff * env, 0.0)
        pulse_a = ((a[:, o + 2] | a[:, o + 3] << 8) & 4095)
        pulse_b = ((b[:, o + 2] | b[:, o + 3] << 8) & 4095)
        uses_pulse = (((wa | wb) & 0x40) != 0) & (audible_a | audible_b)
        costs['pulse'] += np.where(uses_pulse, np.abs(pulse_a - pulse_b) / 4095 * env, 0.0)
    # Filter terms only count on voices that pass through it.
    route_a, route_b = a[:, 23] & 7, b[:, 23] & 7
    routed_env = np.zeros(n)
    for v in range(3):
        routed_env = np.maximum(routed_env, np.where(((route_a | route_b) >> v) & 1, envelopes[v], 0.0))
    cutoff_a = a[:, 22] << 3 | (a[:, 21] & 7)
    cutoff_b = b[:, 22] << 3 | (b[:, 21] & 7)
    mode_a, mode_b = a[:, 24] >> 4 & 7, b[:, 24] >> 4 & 7
    active = ((route_a != 0) & (mode_a != 0)) | ((route_b != 0) & (mode_b != 0))
    costs['cutoff'] = np.where(active, np.abs(cutoff_a - cutoff_b) / 2047 * routed_env, 0.0)
    costs['resonance'] = np.where(active, np.abs((a[:, 23] >> 4) - (b[:, 23] >> 4)) / 15 * routed_env, 0.0)
    costs['mode'] = np.where(route_a | route_b, _popcount(mode_a ^ mode_b) * routed_env, 0.0)
    costs['route'] = _popcount(route_a ^ route_b) * np.maximum.reduce(envelopes) if n else np.zeros(0)
    costs['volume'] = np.abs((a[:, 24] & 15) - (b[:, 24] & 15)) / 15 * np.maximum.reduce(envelopes) if n else np.zeros(0)
    return costs, n


def trace_distance(source, trace, multiplier=1, *, max_lag=0):
    """Mean weighted cost per frame and its breakdown: dict(total, lag, frames, <category>=mean cost).

    max_lag > 0 also tries shifting the CT trace by up to that many frames
    each way and keeps the smallest total (the CT's first note starts a
    couple of ticks after its row, so a small constant lag is not an error).
    """
    a, b = _frames(source), _frames(trace)
    best = None
    for lag in range(-max_lag, max_lag + 1):
        budget.check()
        x = a[max(0, -lag):]
        y = b[max(0, lag):]
        costs, n = frame_costs(x, y, multiplier)
        if not n:
            continue
        parts = {k: float(WEIGHTS[k] * costs[k].mean()) for k in CATEGORIES}
        total = sum(parts.values())
        if best is None or total < best['total']:
            best = dict(total=total, lag=lag, frames=n, **parts)
    return best or dict(total=0.0, lag=0, frames=0, **{k: 0.0 for k in CATEGORIES})


def filter_distance(source, trace, multiplier=1, *, max_lag=8):
    """Cutoff, resonance, mode and routing part of the distance (best shift of the trace within max_lag)."""
    a, b = _frames(source), _frames(trace)
    best = None
    for lag in range(-max_lag, max_lag + 1):
        costs, n = frame_costs(a[max(0, -lag):], b[max(0, lag):], multiplier)
        if n:
            value = float(sum(WEIGHTS[k] * costs[k].mean() for k in ('cutoff', 'resonance', 'mode', 'route')))
            best = value if best is None else min(best, value)
    return best or 0.0


def ct_trace(image, calls):
    """SID register frames the exact CT 4.x model plays for a decompressed CC2 payload."""
    from .ctplayer import CTPlayer
    return CTPlayer(image).frames(calls)


def image_distance(frames, image, multiplier, output_multiplier=1, *, max_lag=8):
    """trace_distance between source frames (at `multiplier`) and what the CT image plays.

    The source is decimated to the image's sound rate first; the image is
    the decompressed CC2 payload native_song builds.
    """
    step = max(1, multiplier // output_multiplier)
    source = _frames(frames)[::step]
    played = ct_trace(image, len(source))
    return trace_distance(source, played, output_multiplier, max_lag=max_lag)
