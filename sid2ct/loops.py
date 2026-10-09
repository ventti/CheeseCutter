"""Generic deterministic play-routine loop detection and timing."""
from bisect import bisect_right
import json
import math
import subprocess

# PAL CPU clock / (312 raster lines * 63 cycles), also CC base cadence.
CC_BASE_RATE = 985248 / (312 * 63)


def capture(tool, sid, subtune, directory, seconds=None, multiplier=None, max_seconds=600):
    """Require full emulated memory recurrence; musical motifs are insufficient."""
    trace = directory/'source.trace'
    info = directory/'loop.json'
    def run(calls):
        result = subprocess.run([str(tool), 'sidtrace', str(sid), '-s', str(subtune),
            '-f', str(calls), '--loop-info', str(info), '-o', str(trace)],
            capture_output=True, text=True, timeout=180)
        if result.returncode:
            raise ValueError('Tracing failed: '+result.stdout+result.stderr)
        return json.loads(info.read_text())
    probe = run(8)
    # Timer writes only determine playback for CIA-timed PSID subtunes.
    # VBI players may use the CIA registers as scratch/storage.
    raw = sid.read_bytes()
    cia = bool(int.from_bytes(raw[18:22], 'big') & (1 << min(subtune-1, 31)))
    def periods(info):
        if multiplier:
            return [1/(50*multiplier)] * info['trace_calls']
        if not cia:
            return [1/CC_BASE_RATE] * info['trace_calls']
        latches = info.get('timer_latches')
        if latches is None:
            if info['variable_timer']:
                raise ValueError('Variable CIA timing requires rebuilding ct2util.')
            latches = [info['cia_timer']] * info['trace_calls']
        # PSID CIA default is 60 Hz when no timer latch is supplied.
        return [(latch+1)/985248 if latch else 1/60 for latch in latches]
    initial = periods(probe)
    fastest = 1/min(initial)
    if fastest > CC_BASE_RATE*16*1.05:
        raise ValueError('Source rate exceeds supported multiplier range 1..16.')
    limit = seconds if seconds is not None else max_seconds
    data = run(math.ceil(limit*fastest))
    elapsed = periods(data)
    # A later tempo acceleration may need more calls than the short probe.
    if not data['detected'] and sum(elapsed) < limit:
        data = run(math.ceil(limit*CC_BASE_RATE*16))
        elapsed = periods(data)
    if seconds is None and not data['detected']:
        hint = 'increase --max-seconds or use an explicit --seconds capture' if max_seconds < 600 else 'use an explicit --seconds capture'
        raise ValueError(f'No full player-state loop found within {max_seconds:g}s; {hint}.')
    source = [bytes.fromhex(line) for line in trace.read_text().splitlines()]
    if seconds is not None and data['detected']:
        cycle = source[data['start_call']:data['end_call']]
        cycle_periods = elapsed[data['start_call']:data['end_call']]
        total = sum(elapsed)
        i = 0
        while total < seconds:
            source.append(cycle[i % len(cycle)])
            period = cycle_periods[i % len(cycle)]
            elapsed.append(period)
            total += period
            i += 1
    boundaries = [0.0]
    for period in elapsed:
        boundaries.append(boundaries[-1]+period)
    fastest = 1/min(elapsed)
    chosen = multiplier or max(1, round(fastest/CC_BASE_RATE))
    if not 1 <= chosen <= 16:
        raise ValueError('Source rate exceeds supported multiplier range 1..16.')
    target = CC_BASE_RATE*chosen
    duration = min(seconds, boundaries[-1]) if seconds is not None else boundaries[-1]
    frames = [source[min(len(source)-1, bisect_right(boundaries, i/target+1e-10)-1)]
              for i in range(round(duration*target))]
    start_time = boundaries[data['start_call']] if data['detected'] else None
    end_time = boundaries[data['end_call']] if data['detected'] else None
    data.pop('write_hashes', None)
    data.pop('timer_latches', None)
    data.update(source_calls_per_second=len(elapsed)/boundaries[-1], duration_seconds=duration,
        start_seconds=start_time, end_seconds=end_time,
        loop_start_frame=round(start_time*target) if start_time is not None else None,
        source_multiplier=chosen, timing_basis='override' if multiplier else 'cia' if cia else 'pal-vbi',
        resampled_calls=len(frames), destination_calls_per_second=target,
        search_limit_seconds=max_seconds)
    return frames, data


def pattern_spans(count, quantum, loop_start=None):
    """Split patterns at the intro/loop boundary and return its order index."""
    boundary = min(count-1, max(0, round(loop_start/quantum))) if loop_start is not None else 0
    starts = list(range(0, boundary, 64)) + list(range(boundary, count, 64))
    return [(start, min(start+64, boundary if start < boundary else count)) for start in starts], starts.index(boundary)
