"""Local polish of a chosen CT: coordinate descent on single table entries, accepted only when the audio score improves.

Edits are small changes to one byte (or one nibble) of the sound tables the song really
uses: instrument ADSR nibbles, pulse and filter table rows, slide and vibrato command
parameters, and wave table rows. Each edit is first replayed through the CT player model
(`regdist`): an edit that leaves the register trace unchanged cannot change the audio and
one that makes the register distance clearly worse is dropped; only the rest is rendered
and scored. Edits are tried in batches of BATCH against the current best (a constant, so
the result does not depend on `--workers`); of each batch the best strict v2 gain that
keeps v1 within the guard is accepted, in a fixed order, and the other gains are tried
again against the new state in the next batch. Time is taken from the conversion's budget.
"""
from dataclasses import dataclass
from pathlib import Path
import hashlib
import shutil
import time
import zlib

from . import budget as budgets
from . import ctplayer
from .audio import score_value

BATCH = 8                  # edits evaluated together; constant so the outcome does not depend on the worker count
MIN_GAIN = 1e-6            # smallest v2 gain that counts as an improvement
FILTER_SLACK = 0.02        # an edit whose register distance is this share above the current one skips audio
EFFORT_LIMITS = {'default': dict(passes=2, edits=160), 'high': dict(passes=6, edits=2000)}
CHAIN_LIMIT = 64           # rows followed along a pulse or filter table chain
NAMES_KEPT = 40            # accepted edits listed in the report


@dataclass(frozen=True)
class Edit:
    name: str
    writes: tuple          # ((image address, new byte), ...)

    @property
    def addresses(self):
        return {a for a, _ in self.writes}


def available():
    try:
        import numpy  # noqa: F401
    except ImportError:
        return False
    return True


# Edit enumeration ------------------------------------------------------------


def _address(player, table, offset):
    return (player.pointers[table] + offset) & 65535


def _byte(image, addr):
    return image[addr & 65535]


def _bump(edits, name, image, addr, deltas, low=0, high=255):
    """Add one edit per delta that moves the byte at `addr` to a different value inside [low, high]."""
    old = image[addr]
    seen = set()
    for delta in deltas:
        value = old + delta
        if low <= value <= high and value != old and value not in seen:
            seen.add(value)
            edits.append(Edit(f'{name}{delta:+d}', ((addr, value),)))


def _nibble(edits, name, image, addr, high_half, deltas=(-1, 1)):
    old = image[addr]
    shift = 4 if high_half else 0
    current = old >> shift & 15
    for delta in deltas:
        value = current + delta
        if 0 <= value <= 15:
            new = (old & (0x0F if high_half else 0xF0)) | value << shift
            edits.append(Edit(f'{name}{delta:+d}', ((addr, new),)))


def _chain(image, player, table, start):
    """Row offsets of a pulse or filter table reachable from `start` (a row number), in walk order."""
    offset = (start << 2) & 255
    seen, rows = set(), []
    while offset not in seen and len(rows) < CHAIN_LIMIT:
        seen.add(offset)
        rows.append(offset)
        nxt = _byte(image, _address(player, table, offset + 3))
        offset = (offset + 4) & 255 if not nxt else 0 if nxt == 127 else (nxt << 2) & 255
    return rows


def _used_sequences(image):
    sequences = set()
    for track in range(32 * 3):
        start = ctplayer.TRACKS + track * 1024
        for pos in range(0, 1024, 2):
            if image[start + pos] >= 240:
                break
            sequences.add(image[start + pos + 1])
    return sorted(s for s in sequences if s < 128)


def _used_commands(image, player):
    commands = set()
    for sequence in _used_sequences(image):
        addr = player._read(ctplayer.SEQLO, sequence) | player._read(ctplayer.SEQHI, sequence) << 8
        for pos in range(0, 256, 4):
            row = image[addr + pos:addr + pos + 4]
            if len(row) < 4 or row[0] == 191:
                break
            if row[2] >= 96 and 0 < row[3] < 64:
                commands.add(row[3])
    return sorted(commands)


def enumerate_edits(image, limit=None):
    """Deterministic list of candidate edits for the song's used table entries (ADSR first, wave rows last)."""
    player = ctplayer.CTPlayer(bytes(image))
    instruments = sorted(player.used_instruments)
    edits = []
    for number in instruments:
        for column, label in ((0, 'ad'), (1, 'sr')):
            addr = _address(player, ctplayer.INST, column * 48 + number)
            for high_half, part in ((True, 'hi'), (False, 'lo')):
                _nibble(edits, f'i{number}.{label}.{part}', image, addr, high_half)
    pulse_rows = []
    filter_rows = []
    wave_rows = []
    for number in instruments:
        _, _, _, _, filt, pulse, _, wave = player._instrument(number)
        if 0 < pulse < 128:
            pulse_rows += [o for o in _chain(image, player, ctplayer.PULSE, pulse) if o not in pulse_rows]
        if filt and player.filter_used:
            filter_rows += [o for o in _chain(image, player, ctplayer.FILTER, filt) if o not in filter_rows]
        row = wave
        while row < 256:
            if row not in wave_rows:
                wave_rows.append(row)
            if _byte(image, _address(player, ctplayer.WAVE, row)) in (126, 127):
                break
            row += 1
    for offset in pulse_rows:
        base = lambda k: _address(player, ctplayer.PULSE, offset + k)
        dur = image[base(0)]
        edits += [Edit(f'pulse{offset}.dur{d:+d}', ((base(0), (dur & 128) | v),)) for d in (-1, 1)
                  for v in [(dur & 127) + d] if 0 <= v <= 127]
        _bump(edits, f'pulse{offset}.speed', image, base(1), (-1, 1, -4, 4))
        if image[base(2)] != 255:
            _bump(edits, f'pulse{offset}.start', image, base(2), (-16, 16, -1, 1), 0, 254)
    for offset in filter_rows:
        base = lambda k: _address(player, ctplayer.FILTER, offset + k)
        dur = image[base(0)]
        if dur >= 128:
            continue
        _bump(edits, f'filter{offset}.dur', image, base(0), (-1, 1), 0, 127)
        edits += [Edit(f'filter{offset}.add{d:+d}', ((base(1), (image[base(1)] + d) & 255),)) for d in (-1, 1, -4, 4)]
        if image[base(2)] != 255:
            _bump(edits, f'filter{offset}.cutoff', image, base(2), (-8, 8, -2, 2), 0, 254)
    for command in _used_commands(image, player):
        op = player._read(ctplayer.COMMAND, command)
        hi = _address(player, ctplayer.COMMAND, 64 + command)
        lo = _address(player, ctplayer.COMMAND, 128 + command)
        label = f'cmd{command}'
        if op in (0, 1, 3, 7):
            _bump(edits, f'{label}.lo', image, lo, (-1, 1, -4, 4))
            _bump(edits, f'{label}.hi', image, hi, (-1, 1))
        elif op == 2:
            _nibble(edits, f'{label}.feel', image, hi, False)
            _nibble(edits, f'{label}.amp', image, lo, False)
            _nibble(edits, f'{label}.freq', image, lo, True)
        elif op == 5:
            _bump(edits, f'{label}.hi', image, hi, (-1, 1))
            _bump(edits, f'{label}.lo', image, lo, (-1, 1))
        elif op == 4:
            for addr, part in ((hi, 'ad'), (lo, 'sr')):
                _nibble(edits, f'{label}.{part}.hi', image, addr, True)
                _nibble(edits, f'{label}.{part}.lo', image, addr, False)
    for row in wave_rows:
        transpose = _address(player, ctplayer.WAVE, row)
        control = _address(player, ctplayer.CONTROL, row)
        value = image[transpose]
        if value < 126:
            _bump(edits, f'wave{row}.note', image, transpose, (-1, 1, -12, 12), 0, 125)
        elif value >= 128:
            _bump(edits, f'wave{row}.abs', image, transpose, (-1, 1), 128, 255)
        ctl = image[control]
        if 16 <= ctl < 224:
            for bit in (0x10, 0x20, 0x40, 0x80):
                new = ctl ^ bit
                if 16 <= new < 224:
                    edits.append(Edit(f'wave{row}.form^{bit:02x}', ((control, new),)))
        elif 0 < ctl < 16:
            _bump(edits, f'wave{row}.delay', image, control, (-1, 1), 1, 15)
    return edits if limit is None else edits[:limit]


# Measuring ------------------------------------------------------------------

_BASE = {}          # per process: base image digest -> its played frames


def _rebuild(head, image):
    return head + zlib.compress(bytes(image), 6)


def played_frames(ctx, image, rate):
    from .regdist import _frames, ct_trace
    step = max(1, ctx.multiplier // rate)
    source = _frames(ctx.frames)[::step]
    return source, ct_trace(bytes(image), len(source))


def distance_of(ctx, image, rate):
    """(register distance total, played frames) of a CC2 image against the source."""
    from .regdist import trace_distance
    from .portfolio import REGDIST_LAG
    source, played = played_frames(ctx, image, rate)
    return float(trace_distance(source, played, rate, max_lag=REGDIST_LAG)['total']), played


def evaluate(ctx, task, stages):
    """Worker side: apply one edit to the base image, filter by register distance, then render and score."""
    from .portfolio import assess_file
    clock = time.monotonic
    began = clock()
    data = task['data']
    head = data[:3]
    base = bytearray(zlib.decompress(data[3:]))
    digest = hashlib.sha256(bytes(base)).hexdigest()
    rate = task['opts']['rate']
    if digest not in _BASE:
        _BASE.clear()
        _BASE[digest] = played_frames(ctx, base, rate)[1]
    budgets.check()
    image = bytearray(base)
    for address, value in task['edit'].writes:
        image[address] = value
    total, played = distance_of(ctx, image, rate)
    out = dict(report={}, regdist=total, changed=played != _BASE[digest])
    stages['regdist'] = clock() - began
    if not out['changed']:
        return out
    if total > task['base_regdist'] * (1 + FILTER_SLACK):
        out['filtered'] = True
        return out
    directory = Path(ctx.work_dir)/f'task{task["slot"]}'
    directory.mkdir(parents=True, exist_ok=True)
    candidate = directory/'candidate.ct'
    candidate.write_bytes(_rebuild(head, image))
    budgets.check()
    began = clock()
    out['audio'], wav = assess_file(ctx, candidate, 1, directory)
    out['ct_path'], out['wav_path'] = str(candidate), str(wav)
    stages['audio'] = clock() - began
    return out


# The loop -------------------------------------------------------------------


def run(ctx, runner, budget, *, data, audio, opts, reference_v1, tolerance, score='v2', effort='default',
        workdir=None, log=None):
    """Polish CT bytes `data` (scored `audio`); returns (dict of results, stats).

    The result dict has `data`, `audio`, `ct_path`, `wav_path` when something was accepted, else it is empty.
    """
    limits = EFFORT_LIMITS.get(effort, EFFORT_LIMITS['default'])
    stats = dict(passes=0, edits=0, unchanged=0, filtered=0, audio_evals=0, accepted=0, accepted_edits=[],
                 v2_before=score_value(audio, score), v1_before=audio.get('score_v1'), stopped='converged')
    head = data[:3]
    image = bytearray(zlib.decompress(data[3:]))
    current = dict(audio=audio)
    current['regdist'], _ = distance_of(ctx, image, opts['rate'])
    best_v2 = score_value(audio, score)
    floor_v1 = None if reference_v1 is None else reference_v1 - tolerance
    began = time.monotonic()
    slot = 100000
    done = False
    for _ in range(limits['passes']):
        edits = enumerate_edits(image, limits['edits'])
        stats['passes'] += 1
        queue = list(edits)
        accepted_here = 0
        while queue:
            if budget.expired():
                stats['stopped'] = 'budget'
                done = True
                break
            batch, queue = queue[:BATCH], queue[BATCH:]
            current_data = _rebuild(head, image)
            tasks = []
            for edit in batch:
                slot += 1
                tasks.append(dict(name=edit.name, opts=opts, solve_limit=0, shield=False, strict=False, polish=True,
                                  edit=edit, data=current_data, base_regdist=current['regdist'], slot=slot))
            results = runner.run(tasks, budget)
            stats['edits'] += len(batch)
            if any(r.get('expired') for r in results):
                stats['stopped'] = 'budget'
                done = True
                _discard(ctx, [t['slot'] for t in tasks])
                break
            winners = []
            for edit, task, result in zip(batch, tasks, results):
                if result.get('error'):
                    continue
                if not result.get('changed'):
                    stats['unchanged'] += 1
                elif result.get('filtered'):
                    stats['filtered'] += 1
                elif result.get('audio'):
                    stats['audio_evals'] += 1
                    new_v2 = score_value(result['audio'], score)
                    new_v1 = result['audio'].get('score_v1')
                    ok = (new_v2 is not None and new_v2 > best_v2 + MIN_GAIN
                          and (floor_v1 is None or (new_v1 is not None and new_v1 >= floor_v1)))
                    if ok:
                        winners.append((new_v2, edit, task, result))
            keep = None
            if winners:
                # Best gain first; equal gains go to the earlier edit. The rest is tried again next batch.
                winners.sort(key=lambda w: (-w[0], batch.index(w[1])))
                best_v2, edit, task, result = winners[0]
                for address, value in edit.writes:
                    image[address] = value
                current = dict(audio=result['audio'], regdist=result['regdist'], ct_path=result['ct_path'],
                               wav_path=result['wav_path'])
                keep = task['slot']
                stats['accepted'] += 1
                accepted_here += 1
                if len(stats['accepted_edits']) < NAMES_KEPT:
                    stats['accepted_edits'].append(edit.name)
                taken = edit.addresses
                retry = [w[1] for w in winners[1:] if not (w[1].addresses & taken)]
                queue = retry + [e for e in queue if not (e.addresses & taken) and e not in retry]
            _discard(ctx, [t['slot'] for t in tasks if t['slot'] != keep])
        if done or not accepted_here:
            break
    else:
        stats['stopped'] = 'passes'
    stats['seconds'] = round(time.monotonic() - began, 2)
    final = score_value(current['audio'], score)
    stats.update(v2_after=final, v1_after=current['audio'].get('score_v1'),
                 v2_gain=None if final is None or stats['v2_before'] is None else round(final - stats['v2_before'], 6))
    if not stats['accepted']:
        return {}, stats
    return dict(data=_rebuild(head, image), audio=current['audio'], ct_path=current['ct_path'],
                wav_path=current['wav_path']), stats


def _discard(ctx, slots):
    for slot in slots:
        shutil.rmtree(Path(ctx.work_dir)/f'task{slot}', ignore_errors=True)
