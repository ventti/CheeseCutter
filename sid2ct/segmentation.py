"""Advisory change points for complete 25-byte SID register snapshots.

No snapshots are discarded or rewritten. Boundary indices use the input tick
clock (not PAL frames); defaults are sample counts, so callers must scale
``sustain`` to their capture rate. Gate edges are immediate, including short
releases and waveform-off attacks. Pitch/control changes need ``sustain`` ticks
and are backdated to their onset. No gate/audibility/dependency filtering is
applied: hidden oscillator frequency, SYNC, RING and TEST remain observable.

O(3*N) time, O(number of boundaries) output; max_frames rejects oversized input.
These are candidate boundaries, not inferred notes or instrument identities.
Splitting at every boundary can separate release tails from their attacks;
integration must retain original gate edges and associate tails with attacks.
"""
from dataclasses import dataclass
from math import isfinite, log2


@dataclass(frozen=True)
class Boundary:
    frame: int
    voice: int  # zero-based physical SID voice
    reasons: tuple[str, ...]
    gate_on: bool
    frequency: int
    control: int


def detect_boundaries(frames, *, sustain=3, pitch_cents=80.0,
                      max_frames=2_000_000):
    """Return immutable boundaries sorted by (frame, voice).

    ``frames`` is an indexable sequence of 25-byte snapshots. Initial states
    yield ``initial`` boundaries; an empty trace yields (). Reasons are ordered
    initial, gate_rise/gate_release, pitch, control. Control compares all bits
    except GATE. Sustained pitch deviations must stay on the same side of the
    last accepted frequency, resisting brief attacks/vibrato excursions. Zero
    frequency transitions are handled explicitly. Threshold is in cents, hence
    independent of absolute tuning; continuous slides can produce candidates.
    Unconfirmed changes at EOF produce no pitch/control boundary. Gate edges
    never wait for confirmation and reset pitch/control anchors, preventing
    attack transients from being mistaken for a new sustained note.
    """
    if not isinstance(sustain, int) or isinstance(sustain, bool) or sustain < 1:
        raise ValueError('sustain must be a positive integer')
    if not isfinite(pitch_cents) or pitch_cents <= 0:
        raise ValueError('pitch_cents must be finite and positive')
    if not isinstance(max_frames, int) or max_frames < 0:
        raise ValueError('max_frames must be a nonnegative integer')
    if len(frames) > max_frames:
        raise ValueError('trace exceeds max_frames')
    for frame in frames:
        if len(frame) != 25 or any(not isinstance(x, int) or not 0 <= x <= 255 for x in frame):
            raise ValueError('each snapshot must contain exactly 25 byte values')
    if not frames:
        return ()
    found = {}

    def add(i, voice, reason):
        found.setdefault((i, voice), []).append(reason)

    def direction(value, anchor):
        if value == anchor:
            return 0
        if not value or not anchor:
            return 1 if value > anchor else -1
        delta = 1200 * log2(value / anchor)
        return (1 if delta > 0 else -1) if abs(delta) >= pitch_cents else 0

    for voice in range(3):
        b = voice * 7
        first = frames[0]
        anchor = first[b] | first[b+1] << 8
        control = first[b+4] & 0xFE
        gate = bool(first[b+4] & 1)
        pitch_start = control_start = None
        pitch_side = 0
        candidate_control = None
        add(0, voice, 'initial')
        for i in range(1, len(frames)):
            frame = frames[i]
            value = frame[b] | frame[b+1] << 8
            current_control = frame[b+4] & 0xFE
            current_gate = bool(frame[b+4] & 1)
            if current_gate != gate:
                add(i, voice, 'gate_rise' if current_gate else 'gate_release')
                gate, anchor, control = current_gate, value, current_control
                pitch_start = control_start = None
                pitch_side = 0
                candidate_control = None
                continue
            side = direction(value, anchor)
            if not side:
                pitch_start, pitch_side = None, 0
            else:
                if pitch_start is None or side != pitch_side:
                    pitch_start, pitch_side = i, side
                if i - pitch_start + 1 >= sustain:
                    add(pitch_start, voice, 'pitch')
                    anchor = value
                    pitch_start, pitch_side = None, 0
            if current_control == control:
                control_start, candidate_control = None, None
            else:
                if control_start is None or candidate_control != current_control:
                    control_start, candidate_control = i, current_control
                if i - control_start + 1 >= sustain:
                    add(control_start, voice, 'control')
                    control = current_control
                    control_start, candidate_control = None, None
    order = {'initial': 0, 'gate_rise': 1, 'gate_release': 1, 'pitch': 2, 'control': 3}
    result = []
    for (i, voice), reasons in sorted(found.items()):
        b = voice * 7
        frame = frames[i]
        result.append(Boundary(i, voice, tuple(sorted(reasons, key=order.get)),
                               bool(frame[b+4] & 1), frame[b] | frame[b+1] << 8,
                               frame[b+4]))
    return tuple(result)
