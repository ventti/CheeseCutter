"""Physical SID oscillator dependencies, independent of envelope gate state.

Topology and ring mask follow reSID's SID constructor and writeCONTROL_REG:
https://github.com/libsidplayfp/resid/blob/master/sid.cc
https://github.com/libsidplayfp/resid/blob/master/wave.cc
A gate-off or waveform-off source oscillator can still drive another voice.
"""
from functools import lru_cache


def effect_bits(control):
    # Ring changes triangle polarity. Saw selection disables that substitution.
    ring = control & 4 if control & 0x10 and not control & 0x20 else 0
    return (control & 2) | ring


def dependency_masks(frames):
    """Per-tick required oscillators, including upstream sync chains."""
    result = []
    for frame in frames:
        required = 0
        for destination in range(3):
            control = frame[destination*7+4]
            if not control & 0xF0 or not effect_bits(control):
                continue
            required |= 1 << destination
            source = (destination+2) % 3
            # A sync source can itself be reset by its preceding oscillator.
            for _ in range(3):
                required |= 1 << source
                if not frame[source*7+4] & 2:
                    break
                source = (source+2) % 3
        result.append(required)
    return result


def analyze(frames, rate):
    """Record dependency intervals on the trace timebase; no gate-only test."""
    edges = []
    for destination in range(3):
        source = (destination+2) % 3
        b, s = destination*7, source*7
        intervals = []
        start, previous = None, 0
        counts = dict(sync_ticks=0, ring_ticks=0, source_gate_off_ticks=0,
                      source_waveform_off_ticks=0, source_test_ticks=0,
                      source_frequency_changes=0)
        for i in range(len(frames)+1):
            bits = effect_bits(frames[i][b+4]) if i < len(frames) and frames[i][b+4]&0xF0 else 0
            if bits != previous:
                if previous:
                    intervals.append(dict(start_frame=start, end_frame=i,
                        start_seconds=start/rate, end_seconds=i/rate,
                        sync=bool(previous&2), ring=bool(previous&4)))
                start, previous = i, bits
            if bits:
                control = frames[i][s+4]
                counts['sync_ticks'] += bool(bits&2)
                counts['ring_ticks'] += bool(bits&4)
                counts['source_gate_off_ticks'] += not bool(control&1)
                counts['source_waveform_off_ticks'] += not bool(control&0xF0)
                counts['source_test_ticks'] += bool(control&8)
                counts['source_frequency_changes'] += bool(i and frames[i][s:s+2] != frames[i-1][s:s+2])
        if intervals:
            edges.append(dict(source_voice=source+1, destination_voice=destination+1,
                              intervals=intervals, **counts))
    return dict(trace_rate=rate, edges=edges,
                limitations='Register snapshots identify oscillator dependencies, not cycle-exact phase or envelope audibility. Gate-off intervals can contain release tails.')


@lru_cache(maxsize=4096)
def wave_trajectory(program):
    """Decode native delays to compare coupled pitch/control at sound ticks."""
    result = []
    i = 0
    while i < len(program) and program[i][0] != 0x7E:
        pitch, control = program[i]
        duration = 1
        if i+1 < len(program) and 1 <= program[i+1][1] < 16:
            duration = program[i+1][1]+2
            i += 1
        if control >= 0xE0:
            control &= 15
        result.extend([(pitch, control)]*duration)
        i += 1
    # Retain a bounded sample of start, middle and tail for long trajectories.
    if len(result) > 96:
        result = [result[round(i*(len(result)-1)/95)] for i in range(96)]
    return tuple(result)


def trajectory_distance(left, right):
    """Coupled pitch contours and SYNC/RING/TEST matter beyond loudness."""
    a, b = wave_trajectory(left), wave_trajectory(right)
    if not a or not b:
        return 0
    error = 0
    for i in range(max(len(a), len(b))):
        p, c = a[min(i,len(a)-1)]
        q, d = b[min(i,len(b)-1)]
        error += ((c^d)&14).bit_count()*1000
        # Relative offsets compare contour without encoding song-note identity.
        # Absolute rows cannot safely be compared as relative transpositions.
        error += abs(p-q)*4 if (p&128) == (q&128) else 96*4
    return error / max(len(a),len(b))

def register_comparison(source, source_rate, candidate, candidate_rate, coupling, alignment_ms):
    """Audit oscillator inputs at the mix alignment, not output pitch alone.

    Snapshot cadences and row quantization limit tick correspondence. Source
    gate/waveform differences are intentionally excluded from oscillator reset
    errors: frequency, TEST and upstream SYNC remain relevant while muted.
    """
    import math
    edges = []
    for edge in coupling['edges']:
        s, d = (edge['source_voice']-1)*7, (edge['destination_voice']-1)*7
        total = matched = source_error = destination_error = 0
        source_control_errors = destination_control_errors = zero_errors = 0
        ratio_errors = []
        for i, frame in enumerate(source):
            if not frame[d+4]&0xF0 or not effect_bits(frame[d+4]):
                continue
            total += 1
            j = round((i/source_rate+alignment_ms/1000)*candidate_rate)
            if not 0 <= j < len(candidate):
                continue
            other = candidate[j]
            matched += 1
            sf, df = frame[s]|frame[s+1]<<8, frame[d]|frame[d+1]<<8
            sc, dc = other[s]|other[s+1]<<8, other[d]|other[d+1]<<8
            source_error += abs(sf-sc)
            destination_error += abs(df-dc)
            source_control_errors += bool((frame[s+4]^other[s+4])&10)
            destination_control_errors += effect_bits(frame[d+4]) != effect_bits(other[d+4])
            if sf and df and sc and dc:
                ratio_errors.append(abs(1200*math.log2((df/sf)/(dc/sc))))
            else:
                zero_errors += (bool(sf),bool(df)) != (bool(sc),bool(dc))
        edges.append(dict(source_voice=edge['source_voice'],destination_voice=edge['destination_voice'],
            active_source_ticks=total,compared_ticks=matched,
            overlap_fraction=matched/total if total else 0,
            source_frequency_mean_absolute_error=source_error/matched if matched else None,
            destination_frequency_mean_absolute_error=destination_error/matched if matched else None,
            source_test_or_sync_mismatch_ticks=source_control_errors,
            destination_effect_mismatch_ticks=destination_control_errors,
            frequency_ratio_zero_mismatch_ticks=zero_errors,
            frequency_ratio_mean_absolute_error_cents=sum(ratio_errors)/len(ratio_errors) if ratio_errors else None,
            frequency_ratio_max_error_cents=max(ratio_errors) if ratio_errors else None))
    return dict(alignment_ms=alignment_ms,source_trace_rate=source_rate,
        candidate_trace_rate=candidate_rate,edges=edges,
        limitations='Global WAV alignment only approximates register tick correspondence. Row rounding and intra-call writes can shift comparisons. Ratios describe oscillator inputs, not audible pitch or cycle-exact oscillator phase.')
