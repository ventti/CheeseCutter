#!/usr/bin/env python3
"""Diagnose arbitrary SID -> SID/CC reconstructions by SID voice and interval.

Mute other audio contributions rather than patching tune code or SID registers.
Shared filter behavior, sync/ring interactions and volume-driven samples limit
the interpretation: these renders are diagnostic solo views, not additive stems.
"""
from array import array
from concurrent.futures import ThreadPoolExecutor
import json
import os
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import wave

from .coupling import analyze as analyze_coupling, register_comparison
from .audio import analysis_workers, compare_wavs, load_wav
from .convert import ROOT, read_sid


def run(command, timeout=60):
    result = subprocess.run([str(x) for x in command], cwd=ROOT, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise ValueError(f'Command failed ({result.returncode}): {command[0]} '+result.stdout+result.stderr)
    return result.stdout.strip()


def source_multiplier(renderer_info, trace_info=None):
    trace = re.search(r'Trace CIA1 timerA: (\d+); variable: (yes|no)',trace_info or '')
    if trace and trace[2]=='yes':
        raise ValueError('Source changes its CIA timer; pass --multiplier explicitly.')
    timing = re.search(r'play speed (CIA|VBI); CIA1 timerA (\d+)',renderer_info)
    if not timing:
        raise ValueError('Renderer has no timing metadata; rebuild it or pass --multiplier.')
    timer = int(trace[1]) if trace and int(trace[1]) else None
    if timer is None and timing[1]=='VBI':
        return 1
    rate = 985248/((timer if timer is not None else int(timing[2]))+1)
    multiplier = round(rate/50)
    if not 1 <= multiplier <= 16 or abs(rate/(50*multiplier)-1) > .03:
        raise ValueError('CIA rate is outside supported 50*N timing; pass --multiplier explicitly.')
    return multiplier


def window_comparisons(a,b,temp,seconds,window_seconds,alignment):
    windows = []
    start = 0.0
    while start < seconds-.000001:
        stop = min(seconds,start+window_seconds)
        x,y = temp/'excerpt-source.wav',temp/'excerpt-candidate.wav'
        excerpt(a,x,start,stop);excerpt(b,y,start,stop)
        if (stop-start)*1000 > abs(alignment)+64:
            audio = compare_wavs(x,y,fixed_alignment_ms=alignment)
        else:
            audio = dict(verdict='inconclusive',similarity=None,
                         reason='Window too short for fixed alignment and spectral analysis.')
        windows.append(dict(start_seconds=start,end_seconds=stop,audio=audio))
        start = stop
    return windows


def published_paths(value, temporary, output):
    if isinstance(value,dict):
        return {k:published_paths(v,temporary,output) for k,v in value.items()}
    if isinstance(value,list):
        return [published_paths(v,temporary,output) for v in value]
    if isinstance(value,str) and value.startswith(str(temporary)+'/'):
        return str(output.resolve()/Path(value).relative_to(temporary))
    return value


def excerpt(source, destination, start, stop):
    with wave.open(str(source), 'rb') as wav:
        params = wav.getparams()
        wav.setpos(round(start*params.framerate))
        pcm = wav.readframes(round((stop-start)*params.framerate))
    with wave.open(str(destination), 'wb') as wav:
        wav.setparams(params)
        wav.writeframes(pcm)


def subtract_background(solo, muted, destination):
    rate, samples = load_wav(solo)
    other_rate, background = load_wav(muted)
    if rate != other_rate or len(samples) != len(background):
        raise ValueError('Background render must match solo duration and rate.')
    differences = [a-b for a,b in zip(samples,background)]
    clipped = sum(not -32768 <= v <= 32767 for v in differences)
    pcm = array('h',(max(-32768,min(32767,v)) for v in differences))
    if sys.byteorder != 'little':
        pcm.byteswap()
    with wave.open(str(destination),'wb') as wav:
        wav.setnchannels(1);wav.setsampwidth(2);wav.setframerate(rate)
        wav.writeframes(pcm.tobytes())
    return clipped


def print_metrics(label, audio):
    if audio['similarity'] is None:
        print(f'  {label}: inconclusive ({audio.get("reason","no signal")})',flush=True)
        return
    print(f'  {label}: score={audio["similarity"]:.6f} '
          f'envelope={audio["envelope_similarity"]:.6f} spectral={audio["spectral_similarity"]:.6f} '
          f'PCM error={audio["normalized_pcm_error"]:.6f} alignment={audio["alignment_ms"]:g}ms '
          f'RMS={audio["source_rms"]:g}→{audio["reconstruction_rms"]:g}',flush=True)


def add_arguments(parser):
    parser.add_argument("--workers", type=int, default=None, help="CPU cores to use for audio analysis (default: all available).")
    parser.add_argument('source', type=Path, help='Original SID file.')
    parser.add_argument('reconstruction', type=Path, nargs='?', help='Converted .ct or .sid file to compare; omit to convert the original first.')
    parser.add_argument('--candidate', action='append', default=[], metavar='LABEL=FILE',
                        help='Version to compare, e.g. before=old.ct; repeat to compare several versions.')
    parser.add_argument('-o', '--output', type=Path, required=True, help='New folder for the comparison report and WAV files.')
    parser.add_argument('--seconds', type=float, help='Seconds to compare; default: first player-state loop or 600-second search limit.')
    parser.add_argument('--window-seconds', type=float, default=5, help='Length of each comparison section in seconds (default: 5).')
    parser.add_argument('--subtune', type=int, default=1, help='Song number in the original SID file (default: 1).')
    parser.add_argument('--candidate-subtune', type=int, default=1, help='Song number in the converted files (default: 1).')
    parser.add_argument('--sid', '--sid-model', dest='sid_model', choices=('6581','8580'), help='SID chip model for both recordings; default: read the original file.')
    parser.add_argument('--multiplier',type=int,help='Set the original playback update rate to 50 times this number; default: detect it.')
    parser.add_argument('--row-frames',type=int,default=6, help='Pattern row length in PAL frames when converting (default: 6).')
    parser.add_argument('--auto-row-frames',action='store_true', help='Try several pattern row lengths when converting; keep the best audio match.')
    parser.add_argument('--selection-seconds',type=float,help='Seconds of audio used to choose a conversion; default: the entire comparison.')
    parser.add_argument('--renderer', type=Path, default=ROOT/'tools/sid_render', help='Path to the SID audio renderer.')
    parser.add_argument('--tool', type=Path, default=ROOT/'ct2util', help='Path to the ct2util program.')


def run_command(args, *, print_report=True):
    started = time.monotonic()
    workers = getattr(args, "workers", None)
    if workers is not None:
        if workers < 1:
            print("Analysis workers must be positive.")
            return 1
        os.environ["SID2CT_WORKERS"] = str(workers)
    try:
        if args.seconds is not None and (not math.isfinite(args.seconds) or not 0 < args.seconds <= 600):
            raise ValueError('Duration must be in (0,600] seconds.')
        if not math.isfinite(args.window_seconds) or not .1 <= args.window_seconds <= 600:
            raise ValueError('Window duration must be in [0.1,600] seconds.')
        candidates = {}
        if args.reconstruction and args.candidate:
            raise ValueError('Use the optional reconstruction or --candidate, not both.')
        items = ['reconstruction='+str(args.reconstruction)] if args.reconstruction else args.candidate
        for item in items:
            label, sep, filename = item.partition('=')
            if not sep or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*',label) or label=='source':
                raise ValueError('Use LABEL=FILE with an alphanumeric label (not source).')
            if label in candidates:
                raise ValueError('Duplicate candidate label: '+label)
            path = Path(filename).resolve()
            if path.suffix.lower() not in ('.ct','.sid') or not path.is_file():
                raise ValueError('Candidate must be an existing .ct or .sid: '+filename)
            candidates[label] = path
        raw = args.source.read_bytes()
        read_sid(raw,args.subtune)
        model = args.sid_model or ('8580' if raw[119]&0x30==0x20 else '6581')
        model_selection = 'override' if args.sid_model else ('source header' if raw[119]&0x30 in (0x10,0x20) else 'default (unspecified/either in header)')
        if args.output.exists():
            raise ValueError('Output directory already exists; use a new directory to preserve results.')
        if not 1 <= args.candidate_subtune <= 32:
            raise ValueError('Candidate subtune must be in 1..32.')
        if args.multiplier is not None and not 1 <= args.multiplier <= 16:
            raise ValueError('Source multiplier must be in 1..16.')
        if not 3 <= args.row_frames <= 127 or (args.selection_seconds is not None and (not math.isfinite(args.selection_seconds) or not 0 < args.selection_seconds <= 600)):
            raise ValueError('Row frames must be in 3..127 and selection seconds in (0,600].')
        args.output.parent.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='sid-voices-',dir=args.output.parent) as temp:
            temp = Path(temp).resolve()
            loop = None
            coupling = None
            source_trace_rate = None
            if args.seconds is None:
                from .loops import capture
                frames, loop = capture(args.tool.resolve(), args.source.resolve(), args.subtune, temp,
                                  multiplier=args.multiplier)
                args.seconds = loop['duration_seconds']
                source_trace_rate = loop['destination_calls_per_second']
                coupling = analyze_coupling(frames,source_trace_rate)
            else:
                # Supplied audio candidates previously needed no CPU tracing.
                # Keep that path usable when dependency analysis is unsupported.
                try:
                    from .loops import capture
                    frames, timing = capture(args.tool.resolve(),args.source.resolve(),
                                             args.subtune,temp,seconds=args.seconds,
                                             multiplier=args.multiplier)
                    source_trace_rate = timing['destination_calls_per_second']
                    coupling = analyze_coupling(frames,source_trace_rate)
                except (OSError,ValueError,subprocess.TimeoutExpired) as error:
                    coupling = dict(edges=[],unavailable_reason=str(error))
            pairs = sorted({''.join(str(v) for v in sorted((edge['source_voice'],edge['destination_voice'])))
                            for edge in coupling['edges']})
            infos = {}
            source_mix = temp/'source.mix.wav'
            infos['source.mix'] = run([args.renderer.resolve(),args.source.resolve(),source_mix,
                                       args.seconds,args.subtune,16000,model,'all'])
            automatic = not candidates
            multiplier = args.multiplier
            export_subtune = args.candidate_subtune
            timing_probe = None
            if automatic:
                ct = temp/'reconstruction.ct'
                command = [sys.executable,'-m','sid2ct','convert',args.source.resolve(),'-o',ct,
                           '--seconds',args.seconds,'--audio-seconds',min(args.seconds,args.selection_seconds or args.seconds),
                           '--row-frames',args.row_frames,'--subtune',args.subtune,
                           '--sid-model',model,'--skip-diagnostics','--renderer',args.renderer.resolve(),'--tool',args.tool.resolve()]
                if multiplier is not None:
                    command.extend(['--multiplier',multiplier])
                if args.auto_row_frames:
                    command.append('--auto-row-frames')
                # Conversion/grid search may legitimately exceed a single renderer's timeout.
                run(command,timeout=600)
                candidates['reconstruction'] = ct
                converted = json.loads(ct.with_suffix('.json').read_text())
                export_subtune = converted['audio_validation']['output_subtune']
                multiplier = converted.get('source_multiplier',multiplier)
            sources = {'source':(args.source.resolve(),args.subtune)}
            for label,path in candidates.items():
                if path.suffix.lower()=='.ct':
                    sid = temp/(label+'.sid')
                    run([args.tool.resolve(),'sid',path,'-s',export_subtune,'-o',sid])
                    sources[label] = (sid,1)
                else:
                    sources[label] = (path,args.candidate_subtune)
            modes = [('mix','all'),('voice1','1'),('voice2','2'),('voice3','3'),('muted','none')] + [(f'pair{pair}',pair) for pair in pairs]
            clipped = {}
            # Render independent SID/voice jobs concurrently. Each helper has
            # its own player instance and writes a distinct WAV.
            with ThreadPoolExecutor(max_workers=analysis_workers()) as executor:
                jobs = []
                for label,(sid,subtune) in sources.items():
                    for mode,mask in modes:
                        if label=='source' and mode=='mix':
                            continue
                        future = executor.submit(run, [args.renderer.resolve(),sid,
                            temp/f'{label}.{mode}.wav',args.seconds,subtune,16000,model,mask])
                        jobs.append((f'{label}.{mode}', future))
                for key,future in jobs:
                    infos[key] = future.result()
            for label in sources:
                for voice in (1,2,3):
                    clipped[f'{label}.voice{voice}'] = subtract_background(
                        temp/f'{label}.voice{voice}.wav',temp/f'{label}.muted.wav',
                        temp/f'{label}.voice{voice}.contribution.wav')
            for label in sources:
                for pair in pairs:
                    clipped[f'{label}.pair{pair}'] = subtract_background(
                        temp/f'{label}.pair{pair}.wav',temp/f'{label}.muted.wav',
                        temp/f'{label}.pair{pair}.contribution.wav')
            report = dict(source=str(args.source.resolve()),source_subtune=args.subtune,
                          seconds=args.seconds,window_seconds=args.window_seconds,sid_model=model,
                          sid_model_selection=model_selection,
                          loop_detection=loop, cross_channel_effects=coupling,
                          conversion='automatic' if automatic else 'supplied candidates',
                          source_multiplier=multiplier,
                          timing_probe=timing_probe.replace(str(temp),str(args.output.resolve())) if timing_probe else None,
                          renderer=infos,
                          limitations=[
                              'Scores rank candidates; they are not fidelity percentages.',
                              'Solo renders retain shared filter and oscillator interactions; they are not additive stems.',
                              'Sample muting is backend-dependent; volume/DC artifacts may remain.',
                              'Primary voice scores subtract a separate all-muted render to remove common background; nonlinear filter responses still prevent additive stems.',
                              'Voice numbers are physical SID channels; they do not infer musical roles.',
                              'Fixed alignment uses each candidate full-mix offset on every voice/window; independent alignment is diagnostic only.',
                              'Conversion integrates per-call CIA timer latches for CIA-timed PSIDs, then resamples to a supported PAL multiplier. Intra-call timer control and SID writes remain approximate.',
                          ],candidates={})
            for label,path in candidates.items():
                source_mix, candidate_mix = temp/'source.mix.wav',temp/f'{label}.mix.wav'
                mixed = compare_wavs(source_mix,candidate_mix)
                alignment = mixed['alignment_ms']
                entry = dict(input=str((args.output/path.name).resolve()) if automatic else str(path),mix=mixed,voices={})
                entry['mix_windows'] = window_comparisons(source_mix,candidate_mix,temp,args.seconds,args.window_seconds,alignment)
                mix_valid = [w for w in entry['mix_windows'] if w['audio']['similarity'] is not None]
                entry['worst_mix_window'] = min(mix_valid,key=lambda w:w['audio']['similarity']) if mix_valid else None
                for mode,mask in modes[1:4]:
                    a,b = temp/f'source.{mode}.contribution.wav',temp/f'{label}.{mode}.contribution.wav'
                    independent = compare_wavs(a,b)
                    fixed = compare_wavs(a,b,fixed_alignment_ms=alignment)
                    windows = window_comparisons(a,b,temp,args.seconds,args.window_seconds,alignment)
                    valid = [w for w in windows if w['audio']['similarity'] is not None]
                    entry['voices'][mask] = dict(fixed_alignment=fixed,independent_alignment=independent,
                        raw_solo=compare_wavs(temp/f'source.{mode}.wav',temp/f'{label}.{mode}.wav',
                                             fixed_alignment_ms=alignment),
                        clipped_samples={'source':clipped[f'source.{mode}'],'candidate':clipped[f'{label}.{mode}']},
                        source_wav=str((args.output/a.name).resolve()),
                        candidate_wav=str((args.output/b.name).resolve()),windows=windows,
                        worst_window=min(valid,key=lambda w:w['audio']['similarity']) if valid else None)
                if coupling['edges']:
                    try:
                        from .loops import capture
                        trace_dir = temp/(label+'.registers')
                        trace_dir.mkdir()
                        sid, subtune = sources[label]
                        candidate_frames, candidate_timing = capture(args.tool.resolve(),sid,
                            subtune,trace_dir,seconds=args.seconds)
                        entry['coupled_registers'] = register_comparison(frames,source_trace_rate,
                            candidate_frames,candidate_timing['destination_calls_per_second'],coupling,alignment)
                    except (OSError,ValueError,subprocess.TimeoutExpired) as error:
                        entry['coupled_registers'] = dict(unavailable_reason=str(error))
                entry['coupled_pairs'] = {}
                for pair in pairs:
                    a,b = temp/f'source.pair{pair}.contribution.wav',temp/f'{label}.pair{pair}.contribution.wav'
                    windows = window_comparisons(a,b,temp,args.seconds,args.window_seconds,alignment)
                    edges = [edge for edge in coupling['edges']
                             if set(pair)=={str(edge['source_voice']),str(edge['destination_voice'])}]
                    for window in windows:
                        overlaps = []
                        for edge in edges:
                            for interval in edge['intervals']:
                                start=max(window['start_seconds'],interval['start_seconds'])
                                end=min(window['end_seconds'],interval['end_seconds'])
                                if end > start:
                                    overlaps.append(dict(source_voice=edge['source_voice'],
                                        destination_voice=edge['destination_voice'],
                                        start_seconds=start,end_seconds=end,
                                        sync=interval['sync'],ring=interval['ring']))
                        window['coupling_intervals'] = overlaps
                    active = [w for w in windows if w['coupling_intervals']]
                    valid = [w for w in active if w['audio']['similarity'] is not None]
                    entry['coupled_pairs'][pair] = dict(
                        voices=[int(v) for v in pair],dependencies=edges,
                        fixed_alignment=compare_wavs(a,b,fixed_alignment_ms=alignment),
                        windows=windows,active_windows=active,
                        worst_active_window=min(valid,key=lambda w:w['audio']['similarity']) if valid else None,
                        source_wav=str((args.output/a.name).resolve()),
                        candidate_wav=str((args.output/b.name).resolve()),
                        clipped_samples={'source':clipped[f'source.pair{pair}'],
                                         'candidate':clipped[f'{label}.pair{pair}']},
                        limitations='Pair audio retains all chip oscillator activity; muting is not oscillator isolation. Active windows can contain uncoupled audio; shared filtering and sync chains can involve the third voice.')
                report['candidates'][label] = entry
                print(f'{label}:',flush=True)
                print_metrics('Mix',mixed)
                for voice in (1,2,3):
                    print_metrics(f'Voice {voice}',entry['voices'][str(voice)]['fixed_alignment'])
                for pair,data in entry['coupled_pairs'].items():
                    print_metrics('Coupled pair '+pair,data['fixed_alignment'])
                print('  Window (s)       Mix      V1      V2      V3',flush=True)
                for index,window in enumerate(entry['mix_windows']):
                    metrics = [window['audio']]+[entry['voices'][str(v)]['windows'][index]['audio'] for v in (1,2,3)]
                    values = ' '.join(f'{m["similarity"]:7.4f}' if m['similarity'] is not None else '    n/a' for m in metrics)
                    print(f'  {window["start_seconds"]:6.2f}–{window["end_seconds"]:<6.2f} {values}',flush=True)
            report['analysis_workers'] = analysis_workers()
            report['elapsed_seconds'] = round(time.monotonic()-started,3)
            if automatic:
                conversion_report = temp/'reconstruction.json'
                converted = published_paths(json.loads(conversion_report.read_text()),temp,args.output)
                conversion_report.write_text(json.dumps(converted,indent=2)+'\n')
                report['conversion_report'] = str((args.output/'reconstruction.json').resolve())
            (temp/'report.json').write_text(json.dumps(report,indent=2)+'\n')
            # Publish only the completed report, solo WAVs and any temporary SID exports.
            (temp/'excerpt-source.wav').unlink(missing_ok=True)
            (temp/'excerpt-candidate.wav').unlink(missing_ok=True)
            temp.rename(args.output)
            if print_report:
                print(f'{args.output}/report.json ({report["elapsed_seconds"]:.3f}s)')
        return 0
    except (OSError,ValueError,subprocess.TimeoutExpired) as error:
        print('sid2ct compare: '+str(error))
        return 1
