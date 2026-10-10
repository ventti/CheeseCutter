"""Bounded opt-in helper experiments; retain before and after artifacts for review."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import time
from . import convert, compare

VARIANTS = (
    ('change-points', {'change_points': True}),
    ('trajectory', {'instrument_allocation': 'trajectory'}),
    ('budget', {'instrument_allocation': 'budget'}),
    ('patterns', {'pattern_mining': True}),
    ('joint', {'instrument_allocation': 'trajectory', 'joint_modeling': True}),
)


def bounded_search(build, *, cap=12, seconds=600, clock=time.monotonic):
    """Deterministic single-change experiments; errors retain finished results.

    Budget is checked between builds. One in-flight build may exceed it. No
    combinations are attempted without independent diagnostic acceptance.
    """
    if not isinstance(cap, int) or cap < 0 or not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('Search cap must be nonnegative and seconds positive/finite.')
    start = clock()
    records, hashes = [], {}
    for index, (name, options) in enumerate((('before', {}), *VARIANTS)):
        if index and (index > cap or clock()-start >= seconds):
            break
        began = clock()
        try:
            data, details = build(name, options)
            digest = hashlib.sha256(data).hexdigest()
            record = dict(name=name, sha256=digest, **details)
            if digest in hashes:
                record['duplicate_of'] = hashes[digest]
            else:
                hashes[digest] = name
        except (ValueError, OSError) as error:
            record = dict(name=name, error=str(error))
        record['wall_seconds'] = clock()-began
        records.append(record)
        if index == 0 and 'error' in record:
            break
    return dict(candidates=records, wall_seconds=clock()-start, cap=cap,
                time_budget_seconds=seconds, truncated=len(records)<len(VARIANTS)+1,
                promotion='provisional mix selection; before retained for voice/pair/window review')


def select_by_mix(records):
    """Select finished scored alternatives; before wins ties and unavailable scores."""
    scored = [record for record in records if 'error' not in record and
              record.get('mix', {}).get('similarity') is not None]
    return max(scored, key=lambda record:record['mix']['similarity']) if scored else next(
        (record for record in records if record['name']=='before' and 'error' not in record), None)


def add_arguments(parser):
    convert.add_arguments(parser)
    parser.set_defaults(sound_programs="dynamic", sound_rate="source", tuning="default",
                        pitch_programs="full", modulation_programs="compact", coupled_programs="preserve")
    parser.add_argument('--candidate-cap', type=int, default=12)
    parser.add_argument('--search-seconds', type=float, default=600)


def run_command(args):
    started = time.monotonic()
    try:
        if args.skip_audio:
            raise ValueError('Helper search requires audio; use convert for trace-only helpers.')
        if args.auto_row_frames or any(getattr(args, key)=='auto' for key in
            ('sound_programs','sound_rate','tuning','pitch_programs','modulation_programs','coupled_programs')):
            raise ValueError('Pin settings for helper search: dynamic, source/base rate, default/source tuning, attack/compact/full pitch, legacy/compact modulation and preserve coupling.')
        if args.sound_programs != 'dynamic' or args.coupled_programs != 'preserve':
            raise ValueError('Helper search requires dynamic sounds and preserve coupling.')
        if args.instrument_allocation != 'legacy' or args.change_points or args.pattern_mining or args.joint_modeling:
            raise ValueError('Search applies helpers itself; leave helper flags at their defaults.')
        if args.output.exists():
            raise ValueError('Search output must be a new directory.')
        if args.candidate_cap < 0 or not math.isfinite(args.search_seconds) or args.search_seconds <= 0:
            raise ValueError('Invalid candidate cap/time budget.')
        args.output.mkdir(parents=True)
        records_by_name = {}
        assessment_cache = {}
        source_hash = hashlib.sha256(args.sid.read_bytes()).hexdigest()
        def build(name, options):
            if hashlib.sha256(args.sid.read_bytes()).hexdigest() != source_hash:
                raise ValueError('Source changed during search.')
            values = vars(args).copy()
            values.update(output=args.output/(name+'.ct'), skip_diagnostics=True, force=False, _assessment_cache=assessment_cache)
            values.update(options)
            began = time.monotonic()
            if convert.run_command(argparse.Namespace(**values)):
                raise ValueError('Conversion failed; see converter output.')
            path = values['output']
            report = json.loads(path.with_suffix('.json').read_text())
            details = dict(path=str(path.resolve()), options=options,
                mix=report['audio_validation'], conversion_wall_seconds=time.monotonic()-began)
            records_by_name[name] = details
            return path.read_bytes(), details
        report = bounded_search(build, cap=args.candidate_cap, seconds=args.search_seconds)
        successes = [record for record in report['candidates'] if 'error' not in record]
        before = next((record for record in successes if record['name']=='before'), None)
        ranked = sorted((record for record in successes if record['name']!='before' and
                         'duplicate_of' not in record and record['mix']['similarity'] is not None),
                        key=lambda record:-record['mix']['similarity'])[:3]
        shortlist = ([before] if before else []) + ranked
        selected = select_by_mix(report['candidates'])
        if selected:
            (args.output/'selected.ct').write_bytes(Path(selected['path']).read_bytes())
        report['selected'] = selected['name'] if selected else None
        report['selection_method'] = 'heuristic mix ranking; before wins ties; voice/window tradeoffs require review'
        report['diagnostics'] = 'unavailable' 
        if shortlist and not args.skip_diagnostics and time.monotonic()-started < args.search_seconds:
            values = dict(source=args.sid, reconstruction=None,
                candidate=[record['name']+'='+record['path'] for record in shortlist],
                output=args.output/'diagnostics', seconds=before['mix']['tested_seconds'],
                window_seconds=args.window_seconds, subtune=args.subtune, candidate_subtune=1,
                sid_model=args.sid_model, multiplier=args.multiplier, row_frames=args.row_frames,
                auto_row_frames=False, selection_seconds=None, renderer=args.renderer,
                tool=args.tool, workers=args.workers)
            if compare.run_command(argparse.Namespace(**values)) == 0:
                report['diagnostics'] = str((args.output/'diagnostics/report.json').resolve())
        report.update(source_sha256=source_hash, elapsed_seconds=time.monotonic()-started,
                      limitations=['Cap/time budget applies between operations; an in-flight conversion or comparison can exceed the ceiling.',
                                   'Identical CTs reuse mixed candidate renders only when source bytes, renderer bytes, duration, model and subtunes match.',
                                   'No combinations; selected.ct follows provisional mix ranking and can have voice/pair/window regressions.',
                                   'Change points are advisory; joint modeling adjusts allocation weights, not oscillator phase.'])
        (args.output/'search.json').write_text(json.dumps(report,indent=2)+'\n')
        return 0 if before else 1
    except (OSError, ValueError) as error:
        print('sid2ct search: '+str(error))
        return 1
