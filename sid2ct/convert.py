#!/usr/bin/env python3
"""Prototype unknown-player PSID -> editable CheeseCutter reconstruction.

Uses ct2util's CPU tracer and GTS5 importer, with no vendored dependencies.
"""
from __future__ import annotations
from collections import Counter
import json
import os
from argparse import Namespace
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from .coupling import analyze as analyze_coupling
from .audio import analysis_workers
from .budget import Budget, effort_seconds, diagnostics_reserve, DIAGNOSTICS_MARGIN
from . import portfolio
from .memory import Memory, capture_key, player_family, song_key
from .native import dmc_tuning, indexed_tuning

ROOT = Path(__file__).resolve().parents[1]
REST = (0xBD, 0, 0, 0)


def read_sid(raw, subtune):
    if len(raw) < 124 or raw[:4] != b'PSID':
        raise ValueError('Prototype requires a PSID v2-v4 file with a callable play routine.')
    version, offset, load, init, play, songs, start = struct.unpack_from('>7H', raw, 4)
    if version not in (2, 3, 4) or not 124 <= offset < len(raw):
        raise ValueError('Invalid or unsupported PSID header.')
    if not 1 <= subtune <= songs <= 32 or not 1 <= start <= songs:
        raise ValueError('Invalid subtune selection/header.')
    if not play or (version >= 3 and raw[122]) or (version >= 4 and raw[123]):
        raise ValueError('IRQ-only and multiple-SID players are not supported.')
    flags = int.from_bytes(raw[118:120], 'big')
    if flags & 3 or (flags >> 2) & 3 == 2:
        raise ValueError('BASIC/PlaySID-specific and NTSC-only songs are not supported.')
    payload = raw[offset:]
    if not load:
        if len(payload) < 3:
            raise ValueError('Missing embedded load address.')
        load, payload = int.from_bytes(payload[:2], 'little'), payload[2:]
    if not payload or load + len(payload) > 65536:
        raise ValueError('Payload exceeds C64 memory.')
    if not load <= (init or load) < load + len(payload) or not load <= play < load + len(payload):
        raise ValueError('Entry points outside payload.')
    return [raw[i:i+32].split(b'\0')[0].decode('latin1') for i in (22, 54, 86)]


def parse_trace(text):
    frames = []
    for line in text.splitlines():
        if len(line) != 50:
            raise ValueError('Expected 25 raw SID registers per trace line.')
        try:
            frame = bytes.fromhex(line)
        except ValueError as e:
            raise ValueError('Invalid SID trace hex.') from e
        if len(frame) != 25:
            raise ValueError('Invalid SID trace width.')
        frames.append(frame)
    if not frames:
        raise ValueError('Empty SID trace.')
    return frames


def pitch(freq):
    # PAL SID oscillator: f = register * 985248 / 2**24.
    if freq <= 0:
        return None
    note = 57 + 12 * math.log2(freq * 985248 / 2**24 / 440)
    return max(3, min(94, round(note))), abs(note - round(note)) * 100


def reconstruct(frames, multiplier=1, row_frames=6, metadata=None, loop_start=None):
    """Return a GTS5 bridge and explicit loss/estimation metrics.

    Output CC runs at PAL 1x. Source call times are divided by multiplier.
    Fixed-grid chunks deduplicate by content; they are not original patterns.
    """
    if not 1 <= multiplier <= 16 or not 3 <= row_frames <= 127:
        raise ValueError('Multiplier must be 1..16; row frames must be 3..127.')
    quantum = row_frames * multiplier
    row_count = (len(frames) + quantum - 1) // quantum
    if row_count > 64 * 510:
        raise ValueError('Capture exceeds CheeseCutter orderlist capacity; shorten it.')
    rows = [[list(REST) for _ in range(row_count)] for _ in range(3)]
    definitions = {}
    metrics = Counter()
    def place(v, call, note, instrument=0):
        row = min(row_count - 1, (call + quantum // 2) // quantum)
        if rows[v][row][0] != REST[0]:
            metrics['row_collisions'] += 1
        rows[v][row][:2] = [note, instrument]
        if call != row * quantum:
            metrics['quantized_events'] += 1
        metrics['events'] += 1
    for v in range(3):
        previous_gate = False
        last_note = None
        candidate = None
        candidate_start = 0
        for t, f in enumerate(frames):
            b = v * 7
            freq = f[b] | f[b+1] << 8
            control, ad, sr = f[b+4:b+7]
            gate = bool(control & 1 and control & 0xF0)
            estimate = pitch(freq)
            if not gate:
                if previous_gate:
                    place(v, t, 0xBE)
                candidate = None
                previous_gate = False
                continue
            # Hold pitch-only transitions for three PAL frames to avoid
            # interpreting short vibrato excursions as melody notes.
            n = estimate[0] if estimate else (last_note or 36)
            stable_pitch = estimate is not None and estimate[1] < 35
            if candidate != n:
                candidate, candidate_start = n, t
            attack = not previous_gate
            changed = stable_pitch and n != last_note and t - candidate_start >= 3 * multiplier
            if attack or changed:
                if attack:
                    # Skip short onset transients when choosing a static timbre.
                    end = min(len(frames), t + 3 * multiplier)
                    window = [x for x in frames[t:end] if x[b+4] & 1 and x[b+4] & 0xF0]
                    chosen = window[-1] if window else f
                    c, a, s = chosen[b+4:b+7]
                    pw = ((chosen[b+2] | chosen[b+3] << 8) & 4095) // 16 * 16
                    key = (c | 1, a, s, pw if c & 0x40 else 0)
                    if key not in definitions:
                        if len(definitions) >= 47:
                            # Fit the native instrument budget by reusing the
                            # nearest static timbre, preferring waveform matches.
                            def distance(other):
                                return ((key[0] ^ other[0]).bit_count() * 4096
                                        + abs(key[1] - other[1]) * 16
                                        + abs(key[2] - other[2]) * 16
                                        + abs(key[3] - other[3]))
                            key = min(definitions, key=distance)
                            metrics['approximated_instrument_attacks'] += 1
                        else:
                            definitions[key] = len(definitions) + 1
                    instrument = definitions[key]
                else:
                    instrument = 0
                    metrics['inferred_pitch_changes'] += 1
                place(v, t if attack else candidate_start, 0x60 + n, instrument)
                last_note = n
            previous_gate = True
    if not definitions:
        raise ValueError('No playable note attacks found in the capture.')
    # GTS global tempo parameter N produces N play calls per row.
    rows[0][0][2:] = [15, row_frames]
    from .loops import pattern_spans
    spans, restart = pattern_spans(row_count, quantum, loop_start)
    patterns, index, orders = [], {}, []
    for voice in rows:
        order = []
        for start, stop in spans:
            chunk = tuple(tuple(r) for r in voice[start:stop])
            if chunk not in index:
                if len(patterns) >= 126:
                    raise ValueError('More than 126 unique patterns; shorten the capture or increase --row-frames.')
                index[chunk] = len(patterns)
                patterns.append(chunk)
            order.append(index[chunk])
        if len(order) > 254:
            raise ValueError('GTS bridge orderlist exceeds 254 entries; shorten the capture.')
        orders.append(order)
    wave, pulse, instruments = [], [], []
    for (control, ad, sr, pw), number in definitions.items():
        wp = len(wave) + 1
        wave += [(control, 0), (255, 0)]
        pp = 0
        if control & 0x40:
            pp = len(pulse) + 1
            pulse += [(0x80 | (pw >> 8), pw & 255), (255, 0)]
        definition = bytes([ad, sr, wp, pp, 0, 0, 0, 0x82, control])
        instruments.append((definition, f'Guess {number:02X}'))
    out = bytearray(b'GTS5')
    for value in metadata or ['SID reconstruction', '', '']:
        out += value.encode('latin1', errors='replace')[:32].ljust(32, b'\0')
    out.append(1)
    for order in orders:
        out.append(len(order) + 1)
        out += bytes(order) + bytes([255, restart])
    out.append(len(instruments))
    for definition, name in instruments:
        out += definition + name.encode().ljust(16, b'\0')
    for table in (wave, pulse, [], []):
        out.append(len(table))
        out += bytes(a for a, _ in table) + bytes(b for _, b in table)
    out.append(len(patterns))
    for pattern in patterns:
        out.append(len(pattern) + 1)
        for row in pattern:
            out += bytes(row)
        out += bytes([255, 0, 0, 0])
    report = dict(mode='trace-reconstruction', source_calls=len(frames),
                  source_calls_per_second=50 * multiplier, source_multiplier=multiplier,
                  output_multiplier=1, row_frames=row_frames,
                  captured_seconds=len(frames)/(50*multiplier),
                  instruments=len(instruments), patterns=len(patterns), **metrics)
    for metric in ('events', 'row_collisions', 'quantized_events',
                   'inferred_pitch_changes', 'approximated_instrument_attacks'):
        report.setdefault(metric, 0)
    report['warnings'] = [
        'Instruments are static estimates; original programs and names are not recovered.',
        'Pitch changes may confuse melody, slides and arpeggios; effects are not reconstructed.',
        'Filter, volume automation, sync/ring modulation interactions and intra-call SID writes are not reproduced.',
        'Events are rounded to the PAL row grid; later events replace earlier events on the same voice/row.',
        'Capture is finite and the generated orderlists loop the complete capture; original loop boundaries are unknown.',
        'The CPU tracer supports a subset of C64 players; timers, ROM and illegal opcodes may prevent tracing.',
    ]
    if any(f[21:25] != frames[0][21:25] for f in frames[1:]):
        report['warnings'].append('Observed changing global SID registers that were omitted.')
    return bytes(out), report


def identify_extractor(raw):
    """The structure extractor module for a recognised GoatTracker, DMC or JCH NewPlayer SID, else None."""
    from .players import family, identify
    from .players import dmc, goattracker, jch
    try:
        families = {family(name) for name in identify(raw)}
    except (ValueError, OSError):
        return None
    for name, module in (('GoatTracker', goattracker), ('DMC', dmc), ('JCH NewPlayer', jch)):
        if name in families:
            return module
    return None


def source_structure(raw, subtune, extras, loop):
    """StructureHints from a --mem-reads capture, or None (hints only ever guide, never decide)."""
    module = identify_extractor(raw)
    if module is None or not extras.get('mem_reads'):
        return None
    from . import memtrace
    try:
        return module.extract(raw, subtune, extras['source_frames'], memtrace.parse(extras['mem_reads']))
    except Exception:  # an extractor failure costs the hint, not the conversion
        return None


def run(tool, *args):
    result = subprocess.run([str(tool), *map(str, args)], cwd=ROOT, capture_output=True,
                            text=True, timeout=60)
    return result


def add_arguments(parser):
    parser.add_argument('--score', choices=('v1','v2'), default='v2', help='Score used to choose candidates (default: v2).')
    parser.add_argument('--v1-tolerance', type=float, default=0.01, help='Maximum allowed v1 loss from the best v1 reached by any candidate (default: 0.01).')
    parser.add_argument("--workers", type=int, default=None, help="CPU cores to use: candidates are built and scored concurrently and the solver gets the rest (default: all available).")
    parser.add_argument('--effort', choices=('default', 'high'), default='default', help='Time budget for the whole conversion: default is about 10 minutes for a full detected-loop song (shorter captures get a proportional share), high about 60 minutes. The best result so far is always written when the budget ends.')
    parser.add_argument('--high-effort', dest='effort', action='store_const', const='high', help='Same as --effort high.')
    parser.add_argument('--time-budget', type=float, help='Total wall seconds for this conversion, overriding --effort.')
    parser.add_argument('--seed', type=int, default=0, help='Random seed of the parameter search (default: 0).')
    parser.add_argument('--max-trials', type=int, help='Most search candidates after the first stage (default: as many as the time budget allows; 0 skips the search).')
    parser.add_argument('--no-polish', dest='polish', action='store_false', help='Skip the local polish of the chosen CT (small edits to ADSR, pulse, filter, command and wave table entries, kept only when the audio score improves).')
    parser.add_argument('--no-memory', action='store_true', help='Do not read or write the memory database (~/.cache/sid2ct/memory.sqlite3, or $SID2CT_CACHE): no reused traces and no warm start.')
    parser.add_argument('sid', type=Path, help='Original SID file.')
    parser.add_argument('-o', '--output', type=Path, required=True, help='Output CheeseCutter .ct file.')
    parser.add_argument('--seconds', type=float, help='Seconds to convert; default: first player-state loop or the search limit.')
    parser.add_argument('--max-seconds', type=float, default=600, help='Maximum seconds to look for a repeating playback state (default: 600).')
    parser.add_argument('--multiplier', type=int, help='Set the original playback update rate to 50 times this number (1..16); default: detect it.')
    parser.add_argument('--row-frames', type=int, default=None, help='Length of each pattern row in PAL frames (3..127). Default: the search chooses among 3, 4, 5, 6, 8 and 12 (6 first).')
    parser.add_argument('--subtune', type=int, default=1, help='Song number in the SID file (default: 1).')
    parser.add_argument('--force-trace', action='store_true', help='Rebuild from observed sounds even if the original CheeseCutter song can be recovered.')
    parser.add_argument('--trace', type=Path, help='Read recorded SID register values from a ct2util sidtrace file.')
    parser.add_argument('--tool', type=Path, default=ROOT/'ct2util', help='Path to the ct2util program.')
    parser.add_argument('--force', action='store_true', help='Replace existing conversion outputs.')
    parser.add_argument('--skip-audio', action='store_true', help='Convert without rendering or comparing audio.')
    parser.add_argument('--renderer', type=Path, default=ROOT/'tools/sid_render', help='Path to the SID audio renderer.')
    parser.add_argument('--audio-seconds', type=float, help='Seconds of converted audio to compare; default: all converted audio.')
    parser.add_argument('--sid', '--sid-model', dest='sid_model', choices=('6581', '8580'), help='SID chip model for both recordings; default: the model specified by the original file.')
    parser.add_argument('--sound-programs', choices=('auto','static','dynamic'), default='auto',
                        help='static: fixed sounds; dynamic: follow sound changes; auto: try both.')
    parser.add_argument('--sound-rate', choices=('auto','base','source'), default='auto',
                        help='base: update sounds at 50 Hz; source: use the original rate; auto: try both.')
    parser.add_argument('--tuning', choices=('auto','default','source'), default='auto',
                        help='default: CheeseCutter tuning; source: recovered original tuning; auto: try available tunings.')
    parser.add_argument('--coupled-programs', choices=('auto','legacy','preserve'), default='auto',
                        help='preserve: keep oscillator changes that affect another voice through sync/ring; legacy: older method; auto: try both when needed.')
    parser.add_argument('--modulation-programs', choices=('auto','legacy','compact'), default='auto',
                        help='compact: follow pulse-width jumps and remove redundant holds; legacy: older method; auto: try both.')
    parser.add_argument('--pitch-programs', choices=('auto','attack','compact','full'), default='auto',
                        help='attack: keep early pitch changes; compact: remove redundant holds; full: keep later changes too; auto: compare all three (full without audio).')
    parser.add_argument('--effect-programs', choices=('auto','off','on'), default='auto',
                        help='on: map slides, vibrato, detune, arpeggios, AD/SR changes, volume and one global filter to command rows; off: older method; auto: try both.')
    parser.add_argument('--auto-row-frames', action='store_true', help='Try row lengths of 3, 4, 5, 6, 8 and 12 frames plus the requested length; keep the best audio match.')
    parser.add_argument('--instrument-allocation', choices=('auto','legacy','trajectory','budget','solve'), default='auto', help='auto: build legacy and solve and keep the better by audio; legacy: most-used sounds first; trajectory: group similar sound changes; budget: also fit all sound tables within their limits; solve: choose sounds with an integer solver (OR-Tools) that minimises register distortion within the table limits, falling back to budget.')
    parser.add_argument('--solve-time-limit', type=float, default=None, help='Seconds the integer solver may spend per sound allocation (default: 20, or 60 with --high-effort; never more than a share of the remaining budget).')
    parser.add_argument('--structure-hints', choices=('auto','off'), default='auto', help='When the solver is used, read the source player\'s own song data (GoatTracker, DMC, JCH NewPlayer) so notes that share a source instrument prefer one CC instrument. auto adds a slower memory trace; off skips it (default: auto).')
    parser.add_argument('--layout', choices=('compact','chunks'), default='compact', help='compact: reuse repeated and transposed sequence blocks (falls back to chunks if it cannot be verified); chunks: fixed 64-row blocks (default: compact).')
    parser.add_argument('--change-points', action='store_true', help='Report where pitch, gate or control values change; playback stays unchanged.')
    parser.add_argument('--pattern-mining', action='store_true', help='Reuse repeated pattern rows while keeping every row and the loop position.')
    parser.add_argument('--joint-modeling', action='store_true', help='Give extra priority to instruments in voices that affect each other; requires --coupled-programs preserve and trajectory or budget allocation.')
    parser.add_argument('--window-seconds', type=float, default=5, help='Length of each audio comparison section in seconds (default: 5).')
    parser.add_argument('--skip-diagnostics', action='store_true', help='Compare only the combined sound; skip individual voices and short sections.')


def remember_best(memory, song, family, chosen, multiplier):
    """Record the searched candidate in the memory database.

    A polished result is stored as its pre-polish candidate with the pre-polish scores: the parameters rebuild
    that CT, not the polished one, so a polished score next to them would promise more than they deliver.
    """
    from .tuner import params_from_options
    searched = chosen.get('pre_polish') or chosen
    if searched['options']['profile'] == 'dynamic' and searched.get('audio') and memory.enabled:
        audio = searched['audio']
        memory.record_best(song, family, searched['name'], params_from_options(searched['options'], multiplier),
                           audio.get('score_v1'), audio.get('score_v2'))


def convert_search(args, ctx, *, temp, raw_sid, frames, loop, hints, metadata, coupling, budget, memory,
                   song, family, workers, effort):
    """Build the candidate portfolio (sid2ct.flow) and return the chosen one: report, CT and WAV paths, audio."""
    from . import flow
    skip = args.skip_audio
    profiles = ['static', 'dynamic'] if args.sound_programs == 'auto' and not skip else [
        'dynamic' if args.sound_programs == 'auto' else args.sound_programs]
    recovered = anchored = None
    if 'dynamic' in profiles:
        fresh = temp/'fresh.ct'
        result = run(args.tool, 'init', ROOT/'src/c64/player.bin', '-o', fresh)
        if result.returncode:
            raise ValueError('Native template failed: '+result.stdout+result.stderr)
        ctx.template = fresh.read_bytes()
        anchored = dmc_tuning(raw_sid)
        recovered = anchored or indexed_tuning(raw_sid, frames)
        if args.tuning == 'source' and recovered is None:
            raise ValueError('No corroborated source frequency table found.')
        ctx.tunings = {'default': (None, 'default')}
        if recovered is not None:
            ctx.tunings['source'] = (recovered, 'dmc4' if anchored else 'indexed-source')
    axes = flow.build_axes(args, multiplier=args.multiplier, coupling=coupling, recovered=recovered,
                           anchored=bool(anchored), profiles=profiles)
    reserve = (0.03 * budget.total if skip or args.skip_diagnostics
               else diagnostics_reserve(budget.total, ctx.audio_duration))
    search_budget = budget.child(reserve=reserve)
    results, pick, guard, notes = flow.search(args, ctx, axes=axes, profiles=profiles, budget=budget,
                                              search_budget=search_budget, workers=workers or analysis_workers(),
                                              effort=effort, memory=memory, family=family, song=song)
    if pick is None:
        errors = [dict(name=r['name'], error=r.get('error', 'expired' if r.get('expired') else 'unknown')) for r in results]
        raise ValueError('Every candidate failed: '+json.dumps(errors))
    chosen = results[pick]
    report = chosen['report']
    summaries = [portfolio.summarise(r) for r in results]
    if args.auto_row_frames:
        report['row_grid_search'] = summaries
        report['warnings'].append('Row grid selected by a heuristic WAV score over the tested interval; it may differ elsewhere.')
    elif len(results) > 1:
        report['sound_program_search'] = summaries
    if any(r.get('expired') for r in results):
        report['warnings'].append('The time budget ended before every candidate was built; the best finished candidate was kept.')
    info = dict(selected=chosen['name'], selection=guard, candidates=len(results),
                worker_seconds=flow.aggregate_worker_seconds(results), **notes)
    remember_best(memory, song, family, chosen, args.multiplier)
    return dict(report=report, ct_path=chosen['ct_path'], audio=chosen.get('audio'), wav_path=chosen.get('wav_path'),
                recovered=recovered, info=info)


def run_command(args):
    started = time.monotonic()
    from .rendercache import render as cached_render
    requested_multiplier = args.multiplier
    workers = getattr(args, "workers", None)
    if workers is not None:
        if workers < 1:
            print("Analysis workers must be positive.")
            return 1
        os.environ["SID2CT_WORKERS"] = str(workers)
    effort = getattr(args, 'effort', None) or 'default'
    time_budget = getattr(args, 'time_budget', None)
    if time_budget is not None and not 0 < time_budget < math.inf:
        print('Time budget must be positive and finite.')
        return 1
    budget = Budget(time_budget if time_budget else effort_seconds(effort))
    report_path = args.output.with_suffix('.json')
    source_wav = args.output.with_suffix('.source.wav')
    converted_wav = args.output.with_suffix('.reconstructed.wav')
    diagnostics_path = args.output.with_suffix('.comparison')
    memory = None       # opened inside the conversion; closed in `finally` whatever happens
    try:
        if not math.isfinite(getattr(args,'v1_tolerance',.01)) or not 0 <= getattr(args,'v1_tolerance',.01) <= 1:
            raise ValueError('V1 tolerance must be in [0,1].')
        if args.output.resolve() == args.sid.resolve() or report_path.resolve() == args.sid.resolve():
            raise ValueError('Output must not replace the input SID.')
        if args.output.suffix.lower() != '.ct':
            raise ValueError('Output must have a .ct extension.')
        if (args.seconds is not None and (not math.isfinite(args.seconds) or not 0 < args.seconds <= 600)) or (args.multiplier is not None and not 1 <= args.multiplier <= 16) or (args.row_frames is not None and not 3 <= args.row_frames <= 127):
            raise ValueError('Use seconds in (0,600], multiplier 1..16 and row frames 3..127.')
        if args.auto_row_frames and args.skip_audio:
            raise ValueError('--auto-row-frames requires WAV validation.')
        if args.audio_seconds is not None and (not math.isfinite(args.audio_seconds) or not 0 < args.audio_seconds <= 600):
            raise ValueError('Audio seconds must be in (0,600].')
        if not args.skip_audio and not args.renderer.is_file():
            raise ValueError('Build the renderer with python3 tools/build_sid_renderer.py (libsidplayfp 3.x required), or use --skip-audio.')
        if getattr(args,'joint_modeling',False) and (args.coupled_programs != 'preserve' or getattr(args,'instrument_allocation','auto') == 'legacy'):
            raise ValueError('--joint-modeling requires --coupled-programs preserve and an allocation other than legacy.')
        outputs = [args.output, report_path] + ([] if args.skip_audio else [source_wav, converted_wav])
        if not args.skip_audio and not args.skip_diagnostics:
            if not math.isfinite(args.window_seconds) or not .1 <= args.window_seconds <= 600:
                raise ValueError('Window seconds must be in [0.1,600].')
            outputs.append(diagnostics_path)
            if args.force and diagnostics_path.exists():
                marker = diagnostics_path/'report.json'
                if diagnostics_path.is_symlink() or not marker.is_file():
                    raise ValueError('Existing comparison directory is not a generated report; choose another output.')
                previous = json.loads(marker.read_text())
                prior_input = previous.get('candidates',{}).get('reconstruction',{}).get('input')
                if previous.get('source') != str(args.sid.resolve()) or prior_input != str(args.output.resolve()):
                    raise ValueError('Existing comparison directory belongs to another conversion; choose another output.')

        if not args.force and any(p.exists() for p in outputs):
            raise ValueError('Output/report already exists; use --force to replace it.')
        raw_sid = args.sid.read_bytes()
        metadata = read_sid(raw_sid, args.subtune)
        model = args.sid_model or ('8580' if raw_sid[119] & 0x30 == 0x20 else '6581')
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='sid-reconstruct-') as temp:
            temp = Path(temp).resolve()
            ct = temp/'reconstructed.ct'
            report = None
            recovered = None
            chosen_info = None
            audio_source = temp/'source.wav'
            from .loops import capture, CC_BASE_RATE
            if not math.isfinite(args.max_seconds) or not 0 < args.max_seconds <= 600:
                raise ValueError('--max-seconds must be in (0,600].')
            loop = None
            input_cache = getattr(args, '_input_cache', None)
            memory = Memory(enabled=not getattr(args, 'no_memory', False))
            song, family = song_key(raw_sid, args.subtune), player_family(raw_sid)
            allocation_wanted = getattr(args, 'instrument_allocation', 'auto')
            wants_hints = ((allocation_wanted == 'solve' or (allocation_wanted == 'auto' and not args.skip_audio))
                           and getattr(args, 'structure_hints', 'auto') == 'auto'
                           and not args.trace and identify_extractor(raw_sid) is not None)
            import hashlib
            input_key = (hashlib.sha256(raw_sid).hexdigest(), args.subtune,
                         args.seconds, args.multiplier, args.max_seconds,
                         hashlib.sha256(args.tool.read_bytes()).hexdigest(),
                         hashlib.sha256(args.trace.read_bytes()).hexdigest() if args.trace else None)
            stored = None
            with budget.stage('capture'):
                if input_cache is not None and input_key in input_cache:
                    frames, loop, args.multiplier, duration, hints = input_cache[input_key]
                elif args.trace:
                    hints = None
                    args.multiplier = args.multiplier or 1
                    frames = parse_trace(args.trace.read_text())
                    duration = min(args.seconds or args.max_seconds, len(frames)/(50*args.multiplier))
                    frames = frames[:round(duration*50*args.multiplier)]
                else:
                    key = capture_key(input_key + (wants_hints,))
                    stored = memory.load_capture(key) if memory.enabled else None
                    if stored is not None:
                        frames, loop, args.multiplier, duration, hints = stored
                    else:
                        extras = {} if wants_hints else None
                        reads_limit = max(60.0, 0.25*budget.total)     # structure hints are optional: bound their trace
                        try:
                            frames, loop = capture(args.tool.resolve(), args.sid.resolve(), args.subtune,
                                temp, args.seconds, args.multiplier, args.max_seconds, extras, reads_limit)
                        except (subprocess.TimeoutExpired, ValueError) as error:
                            if not wants_hints:
                                raise
                            wants_hints, extras = False, None
                            frames, loop = capture(args.tool.resolve(), args.sid.resolve(), args.subtune,
                                temp, args.seconds, args.multiplier, args.max_seconds)
                            loop.setdefault('warnings', []).append(
                                'The memory trace for structure hints failed or timed out; converted without hints.')
                        args.multiplier = loop['source_multiplier']
                        duration = loop['duration_seconds']
                        hints = source_structure(raw_sid, args.subtune, extras, loop) if wants_hints else None
                        if memory.enabled:
                            memory.save_capture(key, (frames, loop, args.multiplier, duration, hints))
            if input_cache is not None:
                input_cache[input_key] = (frames, loop, args.multiplier, duration, hints)
            if not time_budget:
                budget.set_total(effort_seconds(effort, duration))
            coupling = analyze_coupling(frames, (50 if args.trace else CC_BASE_RATE)*args.multiplier)
            audio_duration = min(args.audio_seconds or duration, duration)
            renderer_info = None
            ctx = portfolio.Context(
                work_dir=str(temp), frames=frames, multiplier=args.multiplier, metadata=metadata,
                loop_start=loop['loop_start_frame'] if loop and loop['detected'] else None, hints=hints,
                hint_scale=(loop['destination_calls_per_second']/loop['source_calls_per_second']
                            if loop and hints is not None else 1.0),
                tool=str(args.tool), renderer=str(args.renderer.resolve()), model=model, subtune=args.subtune,
                audio_duration=audio_duration, source_wav=str(audio_source), skip_audio=args.skip_audio,
                raw_sha=hashlib.sha256(raw_sid).hexdigest(),
                renderer_sha=hashlib.sha256(args.renderer.read_bytes()).hexdigest() if not args.skip_audio else None,
                tool_sha=hashlib.sha256(args.tool.read_bytes()).hexdigest(),
                change_points=getattr(args, 'change_points', False), pattern_mining=getattr(args, 'pattern_mining', False),
                joint_modeling=getattr(args, 'joint_modeling', False), template=None, tunings={})
            ctx.cache = getattr(args, '_assessment_cache', None)
            ctx.converted_wav = converted_wav
            # Full libsidplayfp emulation honors the SID's actual timer setup.
            if not args.skip_audio:
                source_key = ('audio', hashlib.sha256(raw_sid).hexdigest(), args.subtune,
                              audio_duration, model, ctx.renderer_sha)
                with budget.stage('source_render'):
                    if input_cache is not None and source_key in input_cache:
                        wav_bytes, renderer_info = input_cache[source_key]
                        audio_source.write_bytes(wav_bytes)
                    else:
                        renderer_info = cached_render([args.renderer.resolve(), args.sid.resolve(), audio_source,
                                                       audio_duration, args.subtune, 16000, model, 'all'], cwd=ROOT)
                        if input_cache is not None:
                            input_cache[source_key] = (audio_source.read_bytes(), renderer_info)
            if not args.force_trace and not args.trace:
                exact = run(args.tool, 'sid2ct', args.sid.resolve(), '-o', ct)
                if exact.returncode == 0:
                    report = {'mode': 'recognized-cheesecutter', 'warnings': [],
                              'details': exact.stdout, 'subtunes': 'all (native recovery)'}
                elif 'not a CheeseCutter' not in exact.stdout:
                    raise ValueError(exact.stdout + exact.stderr)
            if report is None:
                chosen = convert_search(args, ctx, temp=temp, raw_sid=raw_sid, frames=frames, loop=loop, hints=hints,
                                        metadata=metadata, coupling=coupling, budget=budget, memory=memory,
                                        song=song, family=family, workers=workers, effort=effort)
                report = chosen['report']
                ct.write_bytes(Path(chosen['ct_path']).read_bytes())
                if chosen.get('audio') is not None:
                    report['audio_validation'] = chosen['audio']
                    (temp/'best.wav').write_bytes(Path(chosen['wav_path']).read_bytes())
                recovered = chosen['recovered']
                chosen_info = chosen['info']
            elif not args.skip_audio:
                report['audio_validation'], wav = portfolio.assess_file(ctx, ct, args.subtune, temp)
                (temp/'best.wav').write_bytes(wav.read_bytes())
            report['cross_channel_effects'] = coupling
            report['loop_detection'] = loop
            if loop:
                report['warnings'].extend(loop.get('warnings', []))
            report['captured_seconds'] = duration
            report['source_tuning_available'] = recovered is not None
            if loop:
                report['source_calls_per_second'] = loop['source_calls_per_second']
                report['source_calls'] = loop['trace_calls']
                report['resampled_calls'] = len(frames)
            if loop and loop['detected'] and report['mode'] != 'recognized-cheesecutter':
                report['warnings'] = [w for w in report['warnings'] if 'original loop boundaries are unknown' not in w]
                grid = report.get('row_frames', args.row_frames or 6)
                report['loop_start_row'] = round(loop['loop_start_frame']/(args.multiplier*grid))
                report['loop_timing'] = {
                    'implemented_start_seconds': report['loop_start_row']*grid/CC_BASE_RATE,
                    'implemented_end_seconds': math.ceil(len(frames)/(args.multiplier*grid))*grid/CC_BASE_RATE,
                    'start_error_seconds': report['loop_start_row']*grid/CC_BASE_RATE-loop['start_seconds'],
                    'end_error_seconds': math.ceil(len(frames)/(args.multiplier*grid))*grid/CC_BASE_RATE-duration,
                }
                report['warnings'].append('Detected loop restart is quantized to the output row grid; inference still loses SID write timing and effects.')
            if not args.skip_audio:
                report['source_renderer'] = renderer_info
                report['audio_validation']['source_wav'] = str(source_wav.resolve())
                report['audio_validation']['reconstructed_wav'] = str(converted_wav.resolve())
                report['audio_validation']['limitations'] = (
                    'Similarity is a ranking heuristic, not proof of equivalent playback. '
                    'An exact result applies only to this interval, subtune and renderer settings. '
                    'Alignment searches up to 250 ms on a 10 ms grid. '
                    'The source WAV honors actual SID timers; trace timing uses inferred CIA/VBI rate or the explicit --multiplier override.')
            diagnostics_done = not args.skip_audio and not args.skip_diagnostics
            if diagnostics_done and budget.remaining() <= 2 * DIAGNOSTICS_MARGIN * budget.total:
                diagnostics_done = False    # no time left: skip up front instead of starting and discarding them
                report['warnings'].append('The time budget ended before the voice and window diagnostics; they were skipped.')
                report['diagnostics_skipped'] = 'time budget'
            if diagnostics_done:
                from . import compare
                diagnostic_temp = temp/'diagnostics'
                diagnostic_args = Namespace(source=args.sid, reconstruction=ct, candidate=[],
                    output=diagnostic_temp, seconds=audio_duration, window_seconds=args.window_seconds,
                    subtune=args.subtune, candidate_subtune=report['audio_validation']['output_subtune'],
                    sid_model=model, multiplier=requested_multiplier, row_frames=report.get('row_frames', args.row_frames or 6),
                    auto_row_frames=False, selection_seconds=audio_duration,
                    score=getattr(args,"score","v2"), v1_tolerance=getattr(args,"v1_tolerance",.01),
                    renderer=args.renderer, tool=args.tool,
                    deadline=time.monotonic() + max(0.0, budget.remaining() - DIAGNOSTICS_MARGIN * budget.total))   # inside the budget
                try:
                    with budget.stage('diagnostics'):
                        failed = compare.run_command(diagnostic_args,print_report=False)
                except compare.DeadlineExceeded:
                    failed = False
                    diagnostics_done = False
                    report['warnings'].append('The time budget ended during the voice and window diagnostics; they were skipped.')
                    report['diagnostics_skipped'] = 'time budget'
                if failed:
                    raise ValueError('Voice/window validation failed.')
                if diagnostics_done:
                    diagnostic_report = json.loads((diagnostic_temp/'report.json').read_text())
                    diagnostic_report = compare.published_paths(diagnostic_report,diagnostic_temp,diagnostics_path)
                    diagnostic_report['candidates']['reconstruction']['input'] = str(args.output.resolve())
                    (diagnostic_temp/'report.json').write_text(json.dumps(diagnostic_report,indent=2)+'\n')
                    report['diagnostics'] = diagnostic_report
                    report['diagnostics_report'] = str((diagnostics_path/'report.json').resolve())
            report['score_selection'] = getattr(args,'score','v2')
            report['v1_tolerance'] = getattr(args,'v1_tolerance',.01)
            report['analysis_workers'] = analysis_workers()
            report['effort'] = dict(profile=effort, workers=workers or analysis_workers(),
                                    memory='off' if getattr(args, 'no_memory', False) else 'on',
                                    player_family=family, **budget.report())
            if chosen_info:
                report['effort'].update(chosen_info)
            report['elapsed_seconds'] = round(time.monotonic() - started, 3)
            report['source'] = str(args.sid.resolve())
            # Compute and validate before publishing either artifact.
            report_text = json.dumps(report, indent=2) + '\n'
            if not args.skip_audio and not args.skip_diagnostics:
                if diagnostics_path.exists():
                    import shutil
                    shutil.rmtree(diagnostics_path)      # a stale report of an earlier run must not outlive this one
                if diagnostics_done:
                    diagnostic_temp.rename(diagnostics_path)
            args.output.write_bytes(ct.read_bytes())
            report_path.write_text(report_text)
            if not args.skip_audio:
                source_wav.write_bytes(audio_source.read_bytes())
                converted_wav.write_bytes((temp/'best.wav').read_bytes())
        print(f'{args.output}: {report["mode"]} ({report["elapsed_seconds"]:.3f}s)')
        if loop and loop['detected']:
            print(f'Loop: {loop["start_seconds"]:.3f}s → {loop["end_seconds"]:.3f}s; full player-state recurrence')
        elif loop:
            print(f'Loop: none found within {loop["search_limit_seconds"]:g}s; saved finite capture')
        print(f'Report: {report_path}')
        if report.get('diagnostics_report'):
            print(f'Diagnostics: {report["diagnostics_report"]}')
        if not args.skip_audio:
            audio = report['audio_validation']
            print(f'Audio: {audio["verdict"]}; similarity={audio["similarity"]}; tested {audio["tested_seconds"]:.3f}s')
            if args.skip_diagnostics:
                from .compare import print_metrics
                print_metrics('Mix', audio)
        return 0
    except (ValueError, OSError, subprocess.TimeoutExpired) as error:
        print(f'error: {error}')
        return 1
    finally:
        if memory is not None:
            memory.close()
