"""Bounded opt-in helper experiments; retain before and after artifacts for review."""
import argparse
import hashlib
import json
import math
import shutil
from pathlib import Path
import time
from . import budget as budgets, convert, compare
from .audio import score_value

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


def select_by_mix(records, score='v2', v1_tolerance=.01):
    """Select finished scored alternatives; before wins ties and unavailable scores."""
    scored = [record for record in records if 'error' not in record and
              record.get('mix', {}).get('similarity') is not None]
    before = next((r for r in scored if r['name']=='before'), None)
    if before:
        scored = [r for r in scored if score_value(r['mix'],'v1') >= score_value(before['mix'],'v1')-v1_tolerance]
    return max(scored, key=lambda record:score_value(record['mix'],score)) if scored else next(
        (record for record in records if record['name']=='before' and 'error' not in record), None)


def add_arguments(parser):
    convert.add_arguments(parser)
    search_help = {
        'output': 'Folder for all versions, WAV files and comparison reports.',
        'force': 'Replace search outputs in an existing folder.',
        'skip_audio': 'Not supported by search; audio is needed to choose a version.',
        'auto_row_frames': 'Not supported by search; use --row-frames to fix the row length.',
        'sound_programs': 'Search requires dynamic sounds (default: dynamic).',
        'sound_rate': 'Sound update rate: source uses the original rate; base uses 50 Hz (default: source; auto is not supported).',
        'tuning': 'Use CheeseCutter tuning or recovered original tuning (default: default; auto is not supported).',
        'coupled_programs': 'Search requires preserve to keep voices that affect each other (default: preserve).',
        'modulation_programs': 'Pulse-width method: compact or legacy (default: compact; auto is not supported).',
        'effect_programs': 'Map effects to command rows: on or off (default: off; auto is not supported).',
        'pitch_programs': 'Pitch changes to keep: attack, compact or full (default: full; auto is not supported).',
        'instrument_allocation': 'Leave at legacy; search tries the other instrument selection methods itself.',
        'change_points': 'Leave off; search tries change-point reporting itself.',
        'pattern_mining': 'Leave off; search tries repeated-pattern reuse itself.',
        'joint_modeling': 'Leave off; search tries prioritizing linked voices itself.',
    }
    for action in parser._actions:
        if action.dest in search_help:
            action.help = search_help[action.dest]
    parser.epilog = ('Keeps before.ct and every tried version. Optuna/random vary pinned settings and '
                     'accept improvements only after voice, pair and section checks; helpers use provisional mix ranking. '
                     'Auto choices are supported by convert instead.')
    parser.set_defaults(sound_programs="dynamic", sound_rate="source", tuning="default",
                        pitch_programs="full", modulation_programs="compact", coupled_programs="preserve",
                        effect_programs="off", instrument_allocation="legacy", row_frames=6)
    parser.add_argument('--candidate-cap', type=int, default=None, help='Maximum new versions besides before (default: 12 for helpers, 40 for optuna/random).')
    parser.add_argument('--search-seconds', type=float, default=None, help='Time limit in seconds (default: 600, or 3600 with --high-effort); a running conversion or comparison finishes before stopping.')
    parser.add_argument('--optimizer', choices=('helpers', 'optuna', 'random'), default='helpers',
                        help='helpers: five fixed experiments; optuna: learn promising settings; random: comparison using the same settings.')
    parser.add_argument('--regression-tolerance', type=float, default=0,
                        help='Allowed score loss in each voice, pair or section for parameter search (default: 0).')
    # Helpers retain their existing default; parameter search defaults to 40 trials.


def run_command(args):
    started = time.monotonic()
    try:
        if args.search_seconds is None:
            args.search_seconds = budgets.EFFORTS[args.effort]
        parameter_mode = args.optimizer != 'helpers'
        if args.candidate_cap is None:
            args.candidate_cap = 40 if parameter_mode else 12
        if not math.isfinite(args.regression_tolerance) or not 0 <= args.regression_tolerance <= 1:
            raise ValueError('Regression tolerance must be in [0,1].')
        if parameter_mode:
            from .optimize import load_optuna
            load_optuna()  # Fail before creating output when the optional package is missing.
        if args.skip_audio:
            raise ValueError('Helper search requires audio; use convert for trace-only helpers.')
        if args.auto_row_frames or any(getattr(args, key)=='auto' for key in
            ('sound_programs','sound_rate','tuning','pitch_programs','modulation_programs','coupled_programs','effect_programs')):
            raise ValueError('Pin settings for helper search: dynamic, source/base rate, default/source tuning, attack/compact/full pitch, legacy/compact modulation, preserve coupling and on/off effects.')
        if args.sound_programs != 'dynamic' or args.coupled_programs != 'preserve':
            raise ValueError('Helper search requires dynamic sounds and preserve coupling.')
        if args.instrument_allocation != 'legacy' or args.change_points or args.pattern_mining or args.joint_modeling:
            raise ValueError('Search applies helpers itself; leave helper flags at their defaults.')
        if args.output.exists() and not args.force:
            raise ValueError('Search output already exists; use --force to replace search outputs.')
        if args.candidate_cap < 0 or not math.isfinite(args.search_seconds) or args.search_seconds <= 0:
            raise ValueError('Invalid candidate cap/time budget.')
        args.output.mkdir(parents=True, exist_ok=args.force)
        records_by_name = {}
        assessment_cache = {}
        input_cache = {}
        source_hash = hashlib.sha256(args.sid.read_bytes()).hexdigest()
        def build(name, options):
            if hashlib.sha256(args.sid.read_bytes()).hexdigest() != source_hash:
                raise ValueError('Source changed during search.')
            values = vars(args).copy()
            values.update(output=args.output/(name+'.ct'), skip_diagnostics=True, force=args.force,
                          _assessment_cache=assessment_cache, _input_cache=input_cache)
            values.update(options)
            began = time.monotonic()
            if convert.run_command(argparse.Namespace(**values)):
                raise ValueError('Conversion failed; see converter output.')
            path = values['output']
            report = json.loads(path.with_suffix('.json').read_text())
            details = dict(path=str(path.resolve()), options=options,
                mix=report['audio_validation'], captured_seconds=report.get('captured_seconds'),
                source_tuning_available=report.get('source_tuning_available', False),
                mode=report.get('mode'),
                conversion_wall_seconds=time.monotonic()-began)
            records_by_name[name] = details
            return path.read_bytes(), details
        if parameter_mode:
            from .optimize import parameter_search, select_validated
            report = parameter_search(build, output=args.output, optimizer=args.optimizer,
                cap=args.candidate_cap, seconds=args.search_seconds, seed=args.seed, row_frames=args.row_frames, score=args.score, v1_tolerance=args.v1_tolerance)
        else:
            report = bounded_search(build, cap=args.candidate_cap, seconds=args.search_seconds)
        if hashlib.sha256(args.sid.read_bytes()).hexdigest() != source_hash:
            raise ValueError('Source changed during search.')
        successes = [record for record in report['candidates'] if 'error' not in record]
        before = next((record for record in successes if record['name']=='before'), None)
        baseline_v1 = score_value(before['mix'],'v1') if before else None
        ranked = sorted((record for record in successes if record['name']!='before' and
                         'duplicate_of' not in record and score_value(record['mix'],args.score) is not None
                         and (baseline_v1 is None or (score_value(record['mix'],'v1') is not None
                              and score_value(record['mix'],'v1') >= baseline_v1-args.v1_tolerance))),
                        key=lambda record:-score_value(record['mix'],args.score))[:3]
        shortlist = ([before] if before else []) + ranked
        selected = select_by_mix(report['candidates'],args.score,args.v1_tolerance)
        if parameter_mode:
            selected = before  # Promote only after full-duration regression checks.
        report['selected'] = selected['name'] if selected else None
        report['selection_method'] = 'heuristic mix ranking; before wins ties; voice/window tradeoffs require review'
        report['diagnostics'] = 'unavailable' 
        if shortlist and (ranked or not parameter_mode) and not args.skip_diagnostics and time.monotonic()-started < args.search_seconds:
            diagnostics = args.output/'diagnostics'
            if args.force and diagnostics.exists():
                if diagnostics.is_dir() and not diagnostics.is_symlink():
                    shutil.rmtree(diagnostics)
                else:
                    diagnostics.unlink()
            values = dict(source=args.sid, reconstruction=None,
                candidate=[record['name']+'='+record['path'] for record in shortlist],
                output=args.output/'diagnostics', seconds=(before['captured_seconds'] if parameter_mode else before['mix']['tested_seconds']),
                window_seconds=args.window_seconds, subtune=args.subtune, candidate_subtune=1,
                sid_model=args.sid_model, multiplier=args.multiplier, row_frames=args.row_frames,
                auto_row_frames=False, selection_seconds=None, renderer=args.renderer,
                tool=args.tool, workers=args.workers, score=args.score, v1_tolerance=args.v1_tolerance)
            if compare.run_command(argparse.Namespace(**values)) == 0:
                report['diagnostics'] = str((args.output/'diagnostics/report.json').resolve())
                if parameter_mode:
                    try:
                        diagnostic_report = json.loads(Path(report['diagnostics']).read_text())
                        selected, rejected = select_validated(report['candidates'], diagnostic_report,
                                                             args.regression_tolerance, score=args.score, v1_tolerance=args.v1_tolerance)
                        report['rejected'] = rejected
                    except (KeyError, TypeError, ValueError) as error:
                        report['validation_error'] = str(error)
        if selected:
            (args.output/'selected.ct').write_bytes(Path(selected['path']).read_bytes())
        report['selected'] = selected['name'] if selected else None
        if parameter_mode:
            report['selection_method'] = 'Full-duration mix improvement with no voice/pair/window loss beyond regression tolerance; baseline retained without diagnostics.'
            report['regression_tolerance'] = args.regression_tolerance
            report['promotion'] = report['selection_method']
        report.update(source_sha256=source_hash, elapsed_seconds=time.monotonic()-started,
                      limitations=['Cap/time budget applies between operations; an in-flight conversion or comparison can exceed the ceiling.',
                                   'Identical CTs reuse mixed candidate renders only when source bytes, renderer bytes, duration, model and subtunes match.',
                                   ('Parameter combinations are experimental; only the three best unique mix candidates receive full diagnostics.' if parameter_mode else
                                    'No combinations; selected.ct follows provisional mix ranking and can have voice/pair/window regressions.'),
                                   'Change points are advisory; joint modeling adjusts allocation weights, not oscillator phase.'])
        (args.output/'search.json').write_text(json.dumps(report,indent=2)+'\n')
        print(f'Search: {report["selected"]} selected; {len(report["candidates"])} candidates; {report["elapsed_seconds"]:.3f}s')
        return 0 if before else 1
    except (OSError, ValueError) as error:
        print('sid2ct search: '+str(error))
        return 1
