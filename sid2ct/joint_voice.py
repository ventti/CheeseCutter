"""Advisory joint oscillator features; no native allocation or song changes.

Standalone tests: put this directory and the existing import worktree on
PYTHONPATH, then run python3 -m unittest test_joint_voice. Production integration
should install this module in sid2ct and switch the import to .coupling.
Frames are 25-byte snapshots; voices are zero-based, intervals half-open.
Frequency features share one anchor across the group, preserving oscillator
ratios while removing common transposition. They do not estimate audible phase.
"""
from dataclasses import dataclass
import math

from .coupling import dependency_masks, effect_bits


@dataclass(frozen=True)
class DependencyGroup:
    start: int
    stop: int
    voices: tuple
    # Direct audible roots and their effective SYNC/RING bits.
    roots: tuple


@dataclass(frozen=True)
class GroupTrajectory:
    voices: tuple
    roots: tuple
    duration: int
    offsets: tuple
    # Each sample: per-voice (relative cents or None for zero, control,
    # pulse width, AD, SR), followed by the four shared filter registers.
    samples: tuple
    waveform_off_voices: tuple


def _frames(frames):
    result = tuple(bytes(frame) for frame in frames)
    if any(len(frame) != 25 for frame in result):
        raise ValueError('Expected 25-byte SID register frames.')
    return result


def _components(frame):
    roots = tuple((v, effect_bits(frame[v*7+4])) for v in range(3)
                  if frame[v*7+4] & 0xF0 and effect_bits(frame[v*7+4]))
    masks = []
    for root, _ in roots:
        # Delegate topology and upstream closure to the existing helper.
        # Clear other audible roots, retaining all oscillator SYNC/TEST bits.
        isolated = bytearray(frame)
        for v in range(3):
            if v != root:
                isolated[v*7+4] &= 0x0F
        masks.append(dependency_masks((isolated,))[0])
    merged = []
    for mask in masks:
        overlapping = [other for other in merged if other & mask]
        for other in overlapping:
            mask |= other
            merged.remove(other)
        merged.append(mask)
    return tuple(sorted((tuple(v for v in range(3) if mask & (1 << v)),
                         tuple((v, bits) for v, bits in roots if mask & (1 << v)))
                        for mask in merged))


def temporal_dependency_groups(frames):
    """Maximal local intervals with unchanged member/root topology.

    Uncoupled voices are omitted. Gate changes do not dissolve groups. A voice
    participating later does not retroactively couple its earlier trajectory.
    Root effect changes split intervals, frequency/envelope changes do not.
    Work and storage are linear in trace length (three physical oscillators).
    """
    frames = _frames(frames)
    active, result = {}, []
    for tick in range(len(frames)+1):
        current = set(_components(frames[tick])) if tick < len(frames) else set()
        for key in sorted(set(active)-current):
            result.append(DependencyGroup(active.pop(key), tick, *key))
        for key in sorted(current-set(active)):
            active[key] = tick
    return tuple(sorted(result, key=lambda g: (g.start, g.stop, g.voices, g.roots)))


def group_trajectory(frames, group, *, max_samples=96):
    """Bounded aligned samples, including endpoints and shared filter state.

    Full capture is available with max_samples=None. Bounded sampling can miss
    short internal transients; use full capture when matching exact transitions.
    Whole interval metadata protects permanently waveform-off source identity.
    """
    frames = _frames(frames)
    if not 0 <= group.start < group.stop <= len(frames):
        raise ValueError('Group interval must be nonempty and inside the trace.')
    if not group.voices or tuple(sorted(set(group.voices))) != group.voices or any(v not in (0, 1, 2) for v in group.voices):
        raise ValueError('Group voices must be sorted distinct SID indices.')
    if max_samples is not None and (not isinstance(max_samples, int) or max_samples < 2):
        raise ValueError('max_samples must be at least two or None.')
    segment = frames[group.start:group.stop]
    duration = len(segment)
    count = duration if max_samples is None else min(duration, max_samples)
    offsets = tuple(range(duration)) if count == duration else tuple(round(i*(duration-1)/(count-1)) for i in range(count))
    anchor = next((f[v*7] | f[v*7+1] << 8 for f in segment for v in group.voices
                   if f[v*7] | f[v*7+1] << 8), None)
    samples = []
    for i in offsets:
        f = segment[i]
        voices = []
        for v in group.voices:
            b = v*7
            frequency = f[b] | f[b+1] << 8
            pitch = round(1200*math.log2(frequency/anchor), 9) if frequency else None
            voices.append((pitch, f[b+4], (f[b+2] | f[b+3] << 8) & 4095, f[b+5], f[b+6]))
        samples.append((tuple(voices), tuple(f[21:25])))
    hidden = tuple(v for v in group.voices if all(not f[v*7+4] & 0xF0 for f in segment))
    return GroupTrajectory(group.voices, group.roots, duration, offsets, tuple(samples), hidden)
