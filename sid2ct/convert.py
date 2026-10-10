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
from .audio import analysis_workers, compare_wavs
from .native import dmc_tuning, indexed_tuning, native_song

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


def run(tool, *args):
    result = subprocess.run([str(tool), *map(str, args)], cwd=ROOT, capture_output=True,
                            text=True, timeout=60)
    return result


def add_arguments(parser):
    parser.add_argument("--workers", type=int, default=None, help="Parallel analysis workers (default: all available CPU cores).")
    parser.add_argument('sid', type=Path)
    parser.add_argument('-o', '--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, help='Explicit capture duration; default detect through the first full player-state loop.')
    parser.add_argument('--max-seconds', type=float, default=600, help='Loop search limit; fail if no loop is detected (default 600s).')
    parser.add_argument('--multiplier', type=int, help='Override source timing as 50*N calls/sec (1..16); default infer CIA/VBI timing.')
    parser.add_argument('--row-frames', type=int, default=6, help='PAL frames per output row (3..127).')
    parser.add_argument('--subtune', type=int, default=1)
    parser.add_argument('--force-trace', action='store_true', help='Use inference even for recognized CheeseCutter players.')
    parser.add_argument('--trace', type=Path, help='Use an existing ct2util sidtrace file instead of emulation.')
    parser.add_argument('--tool', type=Path, default=ROOT/'ct2util')
    parser.add_argument('--force', action='store_true')
    parser.add_argument('--skip-audio', action='store_true', help='Skip WAV validation (renderer not required).')
    parser.add_argument('--renderer', type=Path, default=ROOT/'tools/sid_render')
    parser.add_argument('--audio-seconds', type=float, help='Limit comparison duration; default compare the entire capture.')
    parser.add_argument('--sid', '--sid-model', dest='sid_model', choices=('6581', '8580'), help='Force the same model for both WAVs; default from source header.')
    parser.add_argument('--sound-programs', choices=('auto','static','dynamic'), default='auto',
                        help='Fit native wave/pulse/filter programs; auto compares with static sounds.')
    parser.add_argument('--sound-rate', choices=('auto','base','source'), default='auto',
                        help='Native sound ticks: auto compares 50 Hz and source rate; sequence rows stay at 50 Hz.')
    parser.add_argument('--tuning', choices=('auto','default','source'), default='auto',
                        help='auto compares default and corroborated source tuning; source requires a recovered table.')
    parser.add_argument('--coupled-programs', choices=('auto','legacy','preserve'), default='auto',
                        help='Analyze sync/ring dependencies; compare legacy with preserved source-oscillator trajectories when present.')
    parser.add_argument('--modulation-programs', choices=('auto','legacy','compact'), default='auto',
                        help='Compare legacy and compact pulse trajectories; compact preserves discontinuity resets and removes final holds.')
    parser.add_argument('--pitch-programs', choices=('auto','attack','compact','full'), default='auto',
                        help='Compare original, compact attack and full pitch trajectories; without audio use full.')
    parser.add_argument('--auto-row-frames', action='store_true', help='Choose the best WAV score among row grids 3,4,5,6,8,12.')
    parser.add_argument('--instrument-allocation', choices=('legacy','trajectory','budget'), default='legacy')
    parser.add_argument('--change-points', action='store_true', help='Report advisory change points without retriggering ADSR.')
    parser.add_argument('--pattern-mining', action='store_true', help='Factor exact rows with lossless expansion and loop checks.')
    parser.add_argument('--joint-modeling', action='store_true', help='Weight allocation by time-local physical dependencies; requires preserve and nonlegacy allocation.')
    parser.add_argument('--window-seconds', type=float, default=5, help='Seconds per diagnostic comparison window.')
    parser.add_argument('--skip-diagnostics', action='store_true', help='Skip voice/window diagnostics; retain mixed-WAV validation.')


def run_command(args):
    started = time.monotonic()
    requested_multiplier = args.multiplier
    workers = getattr(args, "workers", None)
    if workers is not None:
        if workers < 1:
            print("Analysis workers must be positive.")
            return 1
        os.environ["SID2CT_WORKERS"] = str(workers)
    report_path = args.output.with_suffix('.json')
    source_wav = args.output.with_suffix('.source.wav')
    converted_wav = args.output.with_suffix('.reconstructed.wav')
    diagnostics_path = args.output.with_suffix('.comparison')
    try:
        if args.output.resolve() == args.sid.resolve() or report_path.resolve() == args.sid.resolve():
            raise ValueError('Output must not replace the input SID.')
        if args.output.suffix.lower() != '.ct':
            raise ValueError('Output must have a .ct extension.')
        if (args.seconds is not None and (not math.isfinite(args.seconds) or not 0 < args.seconds <= 600)) or (args.multiplier is not None and not 1 <= args.multiplier <= 16) or not 3 <= args.row_frames <= 127:
            raise ValueError('Use seconds in (0,600], multiplier 1..16 and row frames 3..127.')
        if args.auto_row_frames and args.skip_audio:
            raise ValueError('--auto-row-frames requires WAV validation.')
        if args.audio_seconds is not None and (not math.isfinite(args.audio_seconds) or not 0 < args.audio_seconds <= 600):
            raise ValueError('Audio seconds must be in (0,600].')
        if not args.skip_audio and not args.renderer.is_file():
            raise ValueError('Build the renderer with python3 tools/build_sid_renderer.py (libsidplayfp 3.x required), or use --skip-audio.')
        if getattr(args,'joint_modeling',False) and (args.coupled_programs != 'preserve' or getattr(args,'instrument_allocation','legacy') == 'legacy'):
            raise ValueError('--joint-modeling requires --coupled-programs preserve and trajectory/budget allocation.')
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
            audio_source = temp/'source.wav'
            audio_result = temp/'result.wav'
            from .loops import capture, CC_BASE_RATE
            if not math.isfinite(args.max_seconds) or not 0 < args.max_seconds <= 600:
                raise ValueError('--max-seconds must be in (0,600].')
            loop = None
            if args.trace:
                if args.seconds is None:
                    raise ValueError('An external trace requires explicit --seconds; it has no player-state loop evidence.')
                args.multiplier = args.multiplier or 1
                frames = parse_trace(args.trace.read_text())
                duration = min(args.seconds, len(frames)/(50*args.multiplier))
            else:
                frames, loop = capture(args.tool.resolve(), args.sid.resolve(), args.subtune,
                    temp, args.seconds, args.multiplier, args.max_seconds)
                args.multiplier = loop['source_multiplier']
                duration = loop['duration_seconds']
            coupling = analyze_coupling(frames, (50 if args.trace else CC_BASE_RATE)*args.multiplier)
            audio_duration = min(args.audio_seconds or duration, duration)
            renderer_info = None
            def render(sid, output, subtune):
                result = run(args.renderer.resolve(), sid, output, audio_duration,
                             subtune, 16000, model)
                if result.returncode:
                    raise ValueError('Audio rendering failed: ' + result.stdout + result.stderr)
                return result.stdout.strip()
            def assess(candidate, subtune):
                import hashlib
                cache = getattr(args, '_assessment_cache', None)
                key = (hashlib.sha256(candidate.read_bytes()).hexdigest(),
                       hashlib.sha256(raw_sid).hexdigest(), audio_duration,
                       model, args.subtune, subtune, str(args.renderer.resolve()),
                       hashlib.sha256(args.renderer.read_bytes()).hexdigest(),
                       hashlib.sha256(args.tool.read_bytes()).hexdigest())
                if cache is not None and key in cache and cache[key][1].is_file():
                    prior, wav = cache[key]
                    audio_result.write_bytes(wav.read_bytes())
                    return dict(prior, cache_hit=True)
                exported = temp/'candidate.sid'
                result = run(args.tool, 'sid', candidate, '-s', subtune, '-o', exported)
                if result.returncode:
                    raise ValueError('Validation SID export failed: ' + result.stdout + result.stderr)
                info = render(exported, audio_result, 1)
                assessment = compare_wavs(audio_source, audio_result)
                assessment.update(renderer=info, tested_seconds=audio_duration,
                                  source_subtune=args.subtune, output_subtune=subtune)
                if cache is not None:
                    cache[key] = (dict(assessment), converted_wav)
                return assessment
            # Full libsidplayfp emulation honors the SID's actual timer setup.
            if not args.skip_audio:
                renderer_info = render(args.sid.resolve(), audio_source, args.subtune)
            if not args.force_trace and not args.trace:
                exact = run(args.tool, 'sid2ct', args.sid.resolve(), '-o', ct)
                if exact.returncode == 0:
                    report = {'mode': 'recognized-cheesecutter', 'warnings': [],
                              'details': exact.stdout, 'subtunes': 'all (native recovery)'}
                elif 'not a CheeseCutter' not in exact.stdout:
                    raise ValueError(exact.stdout + exact.stderr)
            if report is None:
                grids = sorted(set([3, 4, 5, 6, 8, 12, args.row_frames])) if args.auto_row_frames else [args.row_frames]
                profiles = ['static','dynamic'] if args.sound_programs=='auto' and not args.skip_audio else [
                    'dynamic' if args.sound_programs=='auto' else args.sound_programs]
                template = None
                native_variants = []
                if 'dynamic' in profiles:
                    fresh = temp/'fresh.ct'
                    result = run(args.tool,'init',ROOT/'src/c64/player.bin','-o',fresh)
                    if result.returncode:
                        raise ValueError('Native template failed: '+result.stdout+result.stderr)
                    template=fresh.read_bytes()
                    anchored = dmc_tuning(raw_sid)
                    recovered = anchored or indexed_tuning(raw_sid, frames)
                    if args.tuning == 'source' and recovered is None:
                        raise ValueError('No corroborated source frequency table found.')
                    tunings = [(None,'default')]
                    if recovered is not None and args.tuning != 'default':
                        source = (recovered,'dmc4' if anchored else 'indexed-source')
                        tunings = [source] if args.tuning == 'source' or anchored or args.skip_audio else tunings+[source]
                    rates = sorted(set([1,args.multiplier])) if args.sound_rate=='auto' else [
                        args.multiplier if args.sound_rate=='source' else 1]
                    if args.skip_audio and args.sound_rate=='auto':
                        rates = [args.multiplier]
                    pitches = ['attack','compact','full'] if args.pitch_programs == 'auto' and not args.skip_audio else [
                        'full' if args.pitch_programs == 'auto' else args.pitch_programs]
                    modulations = ['legacy','compact'] if args.modulation_programs == 'auto' and not args.skip_audio else [
                        'compact' if args.modulation_programs == 'auto' else args.modulation_programs]
                    coupled = ['legacy','preserve'] if args.coupled_programs == 'auto' and coupling['edges'] and not args.skip_audio else [
                        'preserve' if args.coupled_programs == 'auto' and coupling['edges'] else
                        'legacy' if args.coupled_programs == 'auto' else args.coupled_programs]
                    native_variants = [(rate,tuning,label,pitch,modulation,couple) for rate in rates for tuning,label in tunings for pitch in pitches for modulation in modulations for couple in coupled]
                variants = [(profile,rate,tuning,label,pitch,modulation,couple) for profile in profiles
                            for rate,tuning,label,pitch,modulation,couple in (native_variants if profile=='dynamic' else [(1,None,'default','attack','legacy','legacy')])]
                candidates, best_score = [], -1.0
                for grid, profile, rate, tuning, label, pitch, modulation, couple in [(g,*v) for g in grids for v in variants]:
                    try:
                        candidate = temp/'candidate.ct'
                        if profile=='dynamic':
                            native,candidate_report = native_song(template,frames,args.multiplier,grid,metadata,
                                                                  tuning,rate, loop_start=loop['loop_start_frame'] if loop and loop['detected'] else None,
                                                                  pitch_programs=pitch, modulation_programs=modulation, coupled_programs=couple,
                                                                  instrument_allocation=getattr(args,'instrument_allocation','legacy'),
                                                                  change_points=getattr(args,'change_points',False),
                                                                  pattern_mining=getattr(args,'pattern_mining',False),
                                                                  joint_modeling=getattr(args,'joint_modeling',False))
                            candidate.write_bytes(native)
                            candidate_report['tuning'] = label
                            if label=='dmc4':
                                candidate_report['source_player']='DMC4-compatible anchored tuning'
                        else:
                            bridge, candidate_report = reconstruct(frames, args.multiplier, grid, metadata, loop_start=loop['loop_start_frame'] if loop and loop['detected'] else None)
                            sng = temp/'reconstructed.sng'
                            sng.write_bytes(bridge)
                            result = run(args.tool, 'sng2ct', sng, '-o', candidate)
                            if result.returncode:
                                raise ValueError('CC mapping failed: ' + result.stdout + result.stderr)
                            candidate_report['conversion_details'] = result.stdout
                            candidate_report['sound_programs'] = 'static'
                        candidate_report['subtune'] = args.subtune
                        audio = assess(candidate, 1) if not args.skip_audio else None
                        score = audio['similarity'] if audio and audio['similarity'] is not None else -0.5
                        candidates.append({'row_frames': grid, 'sound_programs': profile,
                                           'output_multiplier': rate, 'tuning': label, 'pitch_programs': pitch, 'modulation_programs': modulation, 'coupled_programs': couple, 'audio': audio})
                        if score > best_score:
                            best_score, report = score, candidate_report
                            ct.write_bytes(candidate.read_bytes())
                            if audio is not None:
                                report['audio_validation'] = audio
                                (temp/'best.wav').write_bytes(audio_result.read_bytes())
                    except ValueError as error:
                        if len(grids)*len(variants)==1:
                            raise
                        candidates.append({'row_frames': grid, 'sound_programs': profile,
                                           'output_multiplier': rate, 'tuning': label, 'pitch_programs': pitch, 'modulation_programs': modulation, 'coupled_programs': couple, 'error': str(error)})
                if report is None:
                    raise ValueError('Every row-grid candidate failed: ' + json.dumps(candidates))
                if args.auto_row_frames:
                    report['row_grid_search'] = candidates
                    report['warnings'].append('Row grid selected by a heuristic WAV score over the tested interval; it may differ elsewhere.')
                elif len(variants)>1:
                    report['sound_program_search'] = candidates
            elif not args.skip_audio:
                report['audio_validation'] = assess(ct, args.subtune)
                (temp/'best.wav').write_bytes(audio_result.read_bytes())
            report['cross_channel_effects'] = coupling
            report['loop_detection'] = loop
            report['captured_seconds'] = duration
            if loop:
                report['source_calls_per_second'] = loop['source_calls_per_second']
                report['source_calls'] = loop['trace_calls']
                report['resampled_calls'] = len(frames)
            if loop and loop['detected'] and report['mode'] != 'recognized-cheesecutter':
                report['warnings'] = [w for w in report['warnings'] if 'original loop boundaries are unknown' not in w]
                grid = report.get('row_frames', args.row_frames)
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
            if not args.skip_audio and not args.skip_diagnostics:
                from . import compare
                diagnostic_temp = temp/'diagnostics'
                diagnostic_args = Namespace(source=args.sid, reconstruction=ct, candidate=[],
                    output=diagnostic_temp, seconds=audio_duration, window_seconds=args.window_seconds,
                    subtune=args.subtune, candidate_subtune=report['audio_validation']['output_subtune'],
                    sid_model=model, multiplier=requested_multiplier, row_frames=args.row_frames,
                    auto_row_frames=False, selection_seconds=audio_duration,
                    renderer=args.renderer, tool=args.tool)
                if compare.run_command(diagnostic_args,print_report=False):
                    raise ValueError('Voice/window validation failed.')
                diagnostic_report = json.loads((diagnostic_temp/'report.json').read_text())
                diagnostic_report = compare.published_paths(diagnostic_report,diagnostic_temp,diagnostics_path)
                diagnostic_report['candidates']['reconstruction']['input'] = str(args.output.resolve())
                (diagnostic_temp/'report.json').write_text(json.dumps(diagnostic_report,indent=2)+'\n')
                report['diagnostics'] = diagnostic_report
                report['diagnostics_report'] = str((diagnostics_path/'report.json').resolve())
            report['analysis_workers'] = analysis_workers()
            report['elapsed_seconds'] = round(time.monotonic() - started, 3)
            report['source'] = str(args.sid.resolve())
            # Compute and validate before publishing either artifact.
            report_text = json.dumps(report, indent=2) + '\n'
            if not args.skip_audio and not args.skip_diagnostics:
                if diagnostics_path.exists():
                    import shutil
                    shutil.rmtree(diagnostics_path)
                diagnostic_temp.rename(diagnostics_path)
            args.output.write_bytes(ct.read_bytes())
            report_path.write_text(report_text)
            if not args.skip_audio:
                source_wav.write_bytes(audio_source.read_bytes())
                converted_wav.write_bytes((temp/'best.wav').read_bytes())
        print(f'{args.output}: {report["mode"]} ({report["elapsed_seconds"]:.3f}s)')
        if loop and loop['detected']:
            print(f'Loop: {loop["start_seconds"]:.3f}s → {loop["end_seconds"]:.3f}s; full player-state recurrence')
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

