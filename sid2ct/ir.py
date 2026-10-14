"""Whole-chip intermediate representation: three voices, global filter and volume, coupling graph.

Frames are 25-byte SID register snapshots on the trace clock (play calls).
Each voice is cut into Notes at gate rises, TEST retriggers and held-gate
(legato) pitch steps. A short gate gap before a gate rise is a hard-restart
lead that belongs to the new note, not a release tail of the old one. The
filter and master volume are single global timelines with per-voice routing.
Segmentation is advisory: nothing is dropped, only labelled.
"""
from dataclasses import dataclass, field
import math

import numpy as np

from .coupling import analyze, dependency_masks
from .joint_voice import temporal_dependency_groups

NOTE_MIN, NOTE_MAX = 3, 94  # rows use notes 0..2 as tie/gate controls
GATE, TEST = 0x01, 0x08
STABLE_CENTS = 8.0  # a window this flat is a held pitch, not a slide, vibrato or arpeggio


def equal_tuning(a4=440.0, clock=985248):
    """96-note equal-tempered PAL table, close to the stock CT 4.x table."""
    return [round(a4 * 2 ** ((n - 57) / 12) * 2 ** 24 / clock) for n in range(96)]


def tuning_from_image(image):
    """Read the 96-note frequency table from a decompressed CC2 payload."""
    import struct
    pointers = struct.unpack_from('<39H', image, 0xFA0)
    base = pointers[12] + (1 if pointers[12] == pointers[13] else 0)
    return [image[base + i] | image[base + 96 + i] << 8 for i in range(96)]


def estimate_tuning(frames, tuning=None, *, min_concentration=0.3):
    """Shift a tuning table by the global cents offset the trace's tonal pitches agree on.

    Returns (table, offset_cents). The offset is the circular mean, over a
    100-cent period, of the residuals of pitches held three frames (gated,
    waveform on) to their nearest table note; the table is returned unchanged (offset 0.0) when
    the residuals do not concentrate (min_concentration, 0..1), i.e. the song
    has no single detuned scale. Only a uniform offset is estimated.
    """
    tuning = list(tuning or equal_tuning())
    counts = {}
    for b in (0, 7, 14):
        run, last = 0, None
        for frame in frames:
            f = frame[b] | frame[b + 1] << 8
            tonal = frame[b + 4] & 1 and frame[b + 4] & 0xF0 and not frame[b + 4] & 8
            run = run + 1 if tonal and f and f == last else 1
            last = f if tonal else None
            if run == 3:  # held at least three frames: a played pitch, not a sweep
                counts[f] = counts.get(f, 0) + 1
    if not counts:
        return tuning, 0.0
    f = np.array(list(counts))
    w = np.minimum(np.array(list(counts.values())), 8).astype(float)
    nearest = np.array([tuning[nearest_note(int(x), tuning)[0]] for x in f], float)
    residual = 1200 * np.log2(f / nearest)
    z = (w * np.exp(2j * np.pi * residual / 100)).sum() / w.sum()
    if abs(z) < min_concentration:
        return tuning, 0.0
    offset = float(np.angle(z) * 100 / (2 * np.pi))
    return [round(t * 2 ** (offset / 1200)) for t in tuning], offset


def cents(freq, reference):
    """Signed cents of freq above reference; None when either is zero."""
    if freq <= 0 or reference <= 0:
        return None
    return 1200 * math.log2(freq / reference)


def nearest_note(freq, tuning, low=NOTE_MIN, high=NOTE_MAX):
    """Tuning note closest to freq in cents, and the signed residual cents."""
    if freq <= 0:
        return None, None
    best = min(range(low, high + 1), key=lambda n: abs(math.log2(freq / tuning[n])) if tuning[n] else 99)
    return best, cents(freq, tuning[best])


@dataclass(eq=False)
class Note:
    """One voice segment from a start edge to the next start edge."""
    voice: int
    kind: str                # initial, gate, test or legato (held gate, tie candidate)
    start: int               # first frame (gate rise / retrigger / pitch step)
    stop: int                # exclusive; includes the release tail unless trimmed by a lead
    lead: int                # frames of gate-off lead before start (0 = none)
    hard_restart: bool       # lead frames rewrote AD/SR
    lead_ad: int
    lead_sr: int
    gate_off: int            # tick of the first gate-off after start (None while held)
    freq: np.ndarray
    pulse: np.ndarray
    control: np.ndarray
    ad: np.ndarray
    sr: np.ndarray
    prev_freq: int           # voice frequency register on the frame before start
    base_note: int           # nearest tuning note of the stable onset
    base_cents: float
    base_freq: int
    coupled: bool = False    # oscillator is a SYNC/RING source or target during the span
    hidden: bool = False     # coupled but waveform-off (silent oscillator that still drives another)

    @property
    def length(self):
        return self.stop - self.start

    @property
    def test_mask(self):
        """True on ticks where TEST holds the oscillator (pitch is not observable)."""
        return (self.control & TEST) != 0


@dataclass(eq=False)
class VoiceTrack:
    voice: int
    freq: np.ndarray
    pulse: np.ndarray
    control: np.ndarray
    ad: np.ndarray
    sr: np.ndarray
    notes: list = field(default_factory=list)


@dataclass(eq=False)
class FilterTimeline:
    """Global filter registers per frame. cutoff is the 11-bit SID value."""
    cutoff: np.ndarray
    resonance: np.ndarray
    route: np.ndarray        # bits 0..2 voices, bit 3 external input
    mode: np.ndarray         # bits 0..2 = LP/BP/HP
    voice3_off: np.ndarray
    reg23: np.ndarray

    def routed(self, voice):
        """Boolean per frame: voice passes through the filter."""
        return (self.route >> voice & 1).astype(bool)

    def used(self):
        return bool(self.route.any() and self.mode.any())


@dataclass(eq=False)
class VolumeTimeline:
    volume: np.ndarray

    def changes(self):
        """(frame, value) at the first frame and wherever the volume changes."""
        v = self.volume
        if not len(v):
            return []
        index = np.flatnonzero(np.diff(v)) + 1
        return [(0, int(v[0]))] + [(int(i), int(v[i])) for i in index]


@dataclass(eq=False)
class CouplingGraph:
    edges: list              # coupling.analyze() edges (1-based voices)
    groups: tuple            # joint_voice dependency groups
    required: np.ndarray     # per frame bitmask of oscillators needed by SYNC/RING
    hidden_frames: list      # per voice: frames needed while waveform-off

    def partners(self, voice):
        """Voices (0-based) that ever exchange SYNC/RING with this voice."""
        result = set()
        for e in self.edges:
            s, d = e['source_voice'] - 1, e['destination_voice'] - 1
            if voice == s:
                result.add(d)
            elif voice == d:
                result.add(s)
        return result


@dataclass(eq=False)
class Chip:
    frames: int
    multiplier: int
    tuning: list
    voices: list
    filter: FilterTimeline
    volume: VolumeTimeline
    coupling: CouplingGraph

    def notes(self):
        return [n for v in self.voices for n in v.notes]


def _starts(gate, test):
    """Gate rises and TEST retriggers on a held gate: [(frame, kind)]."""
    result = []
    for i in range(len(gate)):
        previous = gate[i - 1] if i else False
        if gate[i] and not previous:
            result.append((i, 'initial' if i == 0 else 'gate'))
        elif gate[i] and test[i] and not (test[i - 1] if i else False):
            result.append((i, 'test'))
    return result


def _legato_splits(freq, test, start, end, hold, step_cents):
    """Held-gate pitch steps that stay put for `hold` frames (not vibrato/arps/slides).

    The step is measured against the median of the preceding 4*hold frames of
    the current segment, so a deep vibrato does not look like a step. A split
    frame is the last frame still at the old pitch, matching CT's tick 0.
    """
    splits = []
    settle = start + 1  # first frame of the current pitch's stable region
    j = start + 1 + hold
    while j + hold <= end:
        seg = splits[-1] if splits else start
        pre = freq[max(settle, j - 4 * hold):j]
        pre = pre[pre > 0]
        f = int(freq[j])
        if len(pre) >= hold and f > 0 and not test[j]:
            anchor = float(np.median(pre))
            w = freq[j:j + hold]
            if abs(1200 * math.log2(f / anchor)) >= step_cents and (w > 0).all() \
                    and not test[j:j + hold].any() \
                    and np.abs(1200 * np.log2(w / f)).max() <= STABLE_CENTS:
                # Backdate through a monotonic ramp to the last frame still at the old
                # pitch (CT tick 0 of a tie row): a portamento glide belongs to the
                # note it leads into, so the tie row can carry the speed.
                i, sign = j, 1 if f > anchor else -1
                floor = seg + 1
                while i - 1 > floor and freq[i - 1] > 0 and sign * (int(freq[i]) - int(freq[i - 1])) > 0 \
                        and abs(1200 * math.log2(freq[i] / freq[i - 1])) >= 2 and not test[i - 1]:
                    i -= 1
                # A glide or slide that begins with the note belongs to that note.
                if i - seg >= hold:
                    splits.append(i)
                settle = j
                j += hold
                continue
        j += 1
    return splits


def _voice_notes(track, tuning, hold, max_lead, step_cents, required, voice):
    gate = (track.control & GATE).astype(bool)
    test = (track.control & TEST).astype(bool)
    n = len(gate)
    edges = _starts(gate, test)
    # (frame, kind) including legato steps inside each gated stretch.
    marks = []
    for k, (s, kind) in enumerate(edges):
        end = edges[k + 1][0] if k + 1 < len(edges) else n
        marks.append((s, kind))
        off = s
        while off < end and gate[off]:
            off += 1
        marks += [(j, 'legato') for j in _legato_splits(track.freq, test, s, off, hold, step_cents)]
    marks.sort()
    notes = []
    for k, (s, kind) in enumerate(marks):
        stop = marks[k + 1][0] if k + 1 < len(marks) else n
        lead, lead_ad, lead_sr, hard = 0, 0, 0, False
        if kind == 'gate' and s > 0:
            g = s
            while g > 0 and not gate[g - 1]:
                g -= 1
            gap = s - g
            if 0 < gap <= max_lead and g > 0:
                lead = gap
                lead_ad, lead_sr = int(track.ad[s - 1]), int(track.sr[s - 1])
                hard = (lead_ad, lead_sr) != (int(track.ad[g - 1]), int(track.sr[g - 1]))
                if notes:
                    # The gap is a restart, not a release: trim the previous note.
                    notes[-1].stop = g
        onset = track.freq[s + 1:s + 1 + hold] if s + 1 < n else track.freq[s:s + 1]
        onset = onset[onset > 0]
        base_freq = int(np.median(onset)) if len(onset) else int(track.freq[s])
        base, residual = nearest_note(base_freq, tuning)
        off = next((t for t in range(s, stop) if not gate[t]), None)
        note = Note(voice, kind, s, stop, lead, hard, lead_ad, lead_sr,
                    None if off is None else off - s,
                    track.freq[s:stop], track.pulse[s:stop], track.control[s:stop],
                    track.ad[s:stop], track.sr[s:stop],
                    int(track.freq[s - 1]) if s else 0,
                    base if base is not None else 36, residual or 0.0, base_freq)
        mask = (required[s:stop] >> voice & 1).astype(bool)
        note.coupled = bool(mask.any())
        note.hidden = bool(mask.any() and (mask & ((track.control[s:stop] & 0xF0) == 0)).sum() * 2 >= mask.sum())
        notes.append(note)
    # Trimmed predecessors changed length after their arrays were sliced.
    for note in notes:
        note.freq, note.pulse, note.control = (a[:note.stop - note.start] for a in (note.freq, note.pulse, note.control))
        note.ad, note.sr = note.ad[:note.stop - note.start], note.sr[:note.stop - note.start]
        if note.gate_off is not None and note.gate_off >= note.length:
            note.gate_off = None
    return notes


def build_chip(frames, *, multiplier=1, tuning=None, legato_cents=100.0,
               legato_hold=None, max_lead=None, rate=None):
    """Segment a register trace into the whole-chip IR.

    multiplier scales the default thresholds (legato_hold = 3 and max_lead = 3
    base ticks). tuning is a 96-entry frequency table (defaults to equal
    temperament). rate is the trace call rate used by the coupling analysis.
    """
    frames = [bytes(f) for f in frames]
    if any(len(f) != 25 for f in frames):
        raise ValueError('Expected 25-byte SID register frames.')
    tuning = list(tuning or equal_tuning())
    hold = legato_hold or 3 * multiplier
    max_lead = max_lead if max_lead is not None else 3 * multiplier
    a = np.frombuffer(b''.join(frames), np.uint8).reshape(-1, 25).astype(np.int32) if frames \
        else np.zeros((0, 25), np.int32)
    required = np.array(dependency_masks(frames), np.int32) if frames else np.zeros(0, np.int32)
    tracks = []
    for v in range(3):
        b = v * 7
        tracks.append(VoiceTrack(v, a[:, b] | a[:, b + 1] << 8, (a[:, b + 2] | a[:, b + 3] << 8) & 4095,
                                 a[:, b + 4], a[:, b + 5], a[:, b + 6]))
    for t in tracks:
        t.notes = _voice_notes(t, tuning, hold, max_lead, legato_cents, required, t.voice) if len(a) else []
    flt = FilterTimeline(a[:, 22] << 3 | (a[:, 21] & 7), a[:, 23] >> 4, a[:, 23] & 15,
                         a[:, 24] >> 4 & 7, (a[:, 24] >> 7).astype(bool), a[:, 23].copy())
    vol = VolumeTimeline(a[:, 24] & 15)
    hidden = [np.flatnonzero((required >> v & 1).astype(bool) & ((tracks[v].control & 0xF0) == 0))
              for v in range(3)]
    graph = CouplingGraph(analyze(frames, rate or 50.0 * multiplier)['edges'] if frames else [],
                          temporal_dependency_groups(frames) if frames else (), required, hidden)
    return Chip(len(frames), multiplier, tuning, tracks, flt, vol, graph)
