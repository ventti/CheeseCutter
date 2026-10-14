"""Build and score conversion candidates concurrently, under one time budget.

A candidate is one set of options for the native mapper (row grid, sound rate,
tuning, pitch/modulation/coupled programmes, effects, instrument allocation,
layout, solver weights). `run_task` builds it, replays it through the exact CT
player model for a cheap register distance (`regdist`, no audio), and renders
and scores its audio. `Runner` runs tasks in a process pool (or in this
process for one worker), returns results in task order whatever the completion
order, and gives every worker `workers // concurrency` cores for the solver, so
the total stays near the core count. Selection (`select`) uses one rule for
every candidate: the best v2 among those within the v1 tolerance of the best v1.
"""
from concurrent.futures import ProcessPoolExecutor, wait, FIRST_COMPLETED
from concurrent.futures.process import BrokenProcessPool
from contextlib import nullcontext
import hashlib
import json
import math
import multiprocessing
import os
from pathlib import Path
import subprocess
import time
import zlib

from . import budget as budgets
from .audio import compare_wavs, score_value

ROOT = Path(__file__).resolve().parents[1]
MAX_CONCURRENCY = 8            # candidates in flight at once
SOLVER_WORKERS = 2             # CP-SAT threads per candidate; fixed so results do not depend on --workers
GRACE_SECONDS = 20.0           # how long past the deadline a worker may take to notice it
PRUNE_MARGIN = 0.50            # a trial whose register distance exceeds the best candidate's by this share skips audio
REGDIST_LAG = 4                # frames of shift the register pre-score tries each way

OPTION_NAMES = ('grid', 'profile', 'rate', 'tuning', 'pitch', 'modulation', 'couple', 'effect',
                'allocation', 'layout', 'effect_tolerance', 'solve_params')


class Context:
    """Everything a worker needs besides the options; one picklable object shared by all tasks."""

    def __init__(self, **values):
        self.cache = None            # assessment cache of `search` (in-process runs only)
        self.converted_wav = None
        self.__dict__.update(values)

    def __getstate__(self):
        state = dict(self.__dict__)
        state['cache'] = None
        return state


_CTX = None


def set_context(ctx):
    global _CTX
    _CTX = ctx


def label(opts):
    """A short stable name for the candidate's options."""
    if opts['profile'] == 'static':
        return f'static-g{opts["grid"]}'
    tolerance = f'-t{opts["effect_tolerance"]:g}' if opts['effect'] == 'on' and opts['effect_tolerance'] != 12.0 else ''
    return (f'g{opts["grid"]}-r{opts["rate"]}-{opts["tuning"]}-{opts["pitch"]}-{opts["modulation"]}-'
            f'{opts["couple"]}-fx{opts["effect"]}{tolerance}-{opts["allocation"]}')


def _run(tool, *args):
    return subprocess.run([str(tool), *map(str, args)], cwd=ROOT, capture_output=True, text=True, timeout=60)


def assess_file(ctx, candidate, out_subtune, directory):
    """Export, render and score one CT. Returns (assessment, wav path)."""
    from .rendercache import render as cached_render
    candidate = Path(candidate)
    directory = Path(directory)
    key = (hashlib.sha256(candidate.read_bytes()).hexdigest(), ctx.raw_sha, ctx.audio_duration,
           ctx.model, ctx.subtune, out_subtune, ctx.renderer, ctx.renderer_sha, ctx.tool_sha)
    wav = directory/'result.wav'
    if ctx.cache is not None and key in ctx.cache and ctx.cache[key][1].is_file():
        prior, cached = ctx.cache[key]
        wav.write_bytes(cached.read_bytes())
        return dict(prior, cache_hit=True), wav
    exported = directory/'candidate.sid'
    result = _run(ctx.tool, 'sid', candidate, '-s', out_subtune, '-o', exported)
    if result.returncode:
        raise ValueError('Validation SID export failed: ' + result.stdout + result.stderr)
    info = cached_render([ctx.renderer, exported, wav, ctx.audio_duration, 1, 16000, ctx.model, 'all'], cwd=ROOT)
    assessment = compare_wavs(ctx.source_wav, wav)
    assessment.update(renderer=info, tested_seconds=ctx.audio_duration,
                      source_subtune=ctx.subtune, output_subtune=out_subtune)
    if ctx.cache is not None and ctx.converted_wav is not None:
        ctx.cache[key] = (dict(assessment), ctx.converted_wav)
    return assessment, wav


def build(ctx, opts, directory, solve_limit):
    """The candidate's CC2 bytes and mapper report."""
    from . import convert
    if opts['profile'] == 'dynamic':
        from .native import native_song
        frequencies, tuning_name = ctx.tunings[opts['tuning']]
        data, report = native_song(
            ctx.template, ctx.frames, ctx.multiplier, opts['grid'], ctx.metadata, frequencies, opts['rate'],
            loop_start=ctx.loop_start, pitch_programs=opts['pitch'], modulation_programs=opts['modulation'],
            coupled_programs=opts['couple'], instrument_allocation=opts['allocation'],
            change_points=ctx.change_points, pattern_mining=ctx.pattern_mining, joint_modeling=ctx.joint_modeling,
            layout=opts['layout'], effect_programs=opts['effect'], solve_time_limit=solve_limit,
            structure_hints=ctx.hints, hint_scale=ctx.hint_scale, effect_tolerance=opts['effect_tolerance'],
            solve_params=opts['solve_params'])
        report['tuning'] = tuning_name
        report['instrument_allocation'] = opts['allocation']
        if tuning_name == 'dmc4':
            report['source_player'] = 'DMC4-compatible anchored tuning'
        return data, report
    bridge, report = convert.reconstruct(ctx.frames, ctx.multiplier, opts['grid'], ctx.metadata, loop_start=ctx.loop_start)
    sng = Path(directory)/'reconstructed.sng'
    sng.write_bytes(bridge)
    out = Path(directory)/'static.ct'
    result = _run(ctx.tool, 'sng2ct', sng, '-o', out)
    if result.returncode:
        raise ValueError('CC mapping failed: ' + result.stdout + result.stderr)
    report['conversion_details'] = result.stdout
    report['sound_programs'] = 'static'
    return out.read_bytes(), report


def register_parts(ctx, data, opts):
    """Register-level distance of a native CT to the source (no audio) with its components; None on failure."""
    try:
        from .regdist import CATEGORIES, image_distance
        image = zlib.decompress(data[3:])
        found = image_distance(ctx.frames, image, ctx.multiplier, opts['rate'], max_lag=REGDIST_LAG)
        return dict(total=float(found['total']), **{k: float(found[k]) for k in CATEGORIES})
    except Exception:
        return None


def register_distance(ctx, data, opts):
    """Total register distance (see `register_parts`); None when it cannot be computed."""
    parts = register_parts(ctx, data, opts)
    return None if parts is None else parts['total']


def _prune_decision(task, opts, regdist, parts):
    """(pruned?, predicted v2 or None, by which rule). Shielded tasks are never pruned."""
    if task.get('shield') or regdist is None:
        return False, None, None
    rule = task.get('prune_rule')
    if rule is not None:
        try:
            pruned, predicted = rule.decide(task.get('params') or {}, regdist, parts)
            return pruned, predicted, 'surrogate'
        except Exception:
            pass      # a broken model must not stop the trial: use the fixed rule below
    limit = task.get('prune_above')
    return (limit is not None and regdist > limit), None, 'regdist'


def _evaluate(ctx, task, stages):
    if task.get('polish'):
        from . import polish
        return polish.evaluate(ctx, task, stages)
    directory = Path(ctx.work_dir)/f'task{task.get("slot", task["index"])}'   # slots are unique per conversion
    directory.mkdir(parents=True, exist_ok=True)
    opts = task['opts']
    clock = time.monotonic
    began = clock()
    data, report = build(ctx, opts, directory, task['solve_limit'])
    stages['build'] = clock() - began
    candidate = directory/'candidate.ct'
    candidate.write_bytes(data)
    report['subtune'] = ctx.subtune
    out = dict(report=report, ct_path=str(candidate))
    if opts['profile'] == 'dynamic' and not ctx.skip_audio:
        began = clock()
        parts = register_parts(ctx, data, opts)
        out['regdist'] = None if parts is None else parts['total']
        out['regdist_parts'] = parts
        stages['regdist'] = clock() - began
        pruned, predicted, by = _prune_decision(task, opts, out['regdist'], parts)
        if pruned:
            out.update(pruned=True, pruned_by=by)
            if predicted is not None:
                out['predicted_v2'] = predicted
            return out
    if not ctx.skip_audio:
        began = clock()
        out['audio'], wav = assess_file(ctx, candidate, 1, directory)
        out['wav_path'] = str(wav)
        stages['audio'] = clock() - began
    return out


def run_task(task):
    """Worker entry point. Always returns a dict: result fields, or `error`, or `expired`."""
    ctx = _CTX
    if task.get('inner'):
        os.environ['SID2CT_WORKERS'] = str(task['inner'])
    began = time.monotonic()
    result = dict(index=task['index'], name=task['name'], options=task['opts'], stages={})
    deadline = task.get('deadline_wall')
    own = budgets.Budget(math.inf if deadline is None else max(0.0, deadline - time.time()))
    try:
        with budgets.activate(own), (budgets.shield() if task.get('shield') else nullcontext()):
            result.update(_evaluate(ctx, task, result['stages']))
    except budgets.BudgetExpired:
        result['expired'] = True
    except Exception as error:   # one broken candidate must not stop the others
        if task.get('strict'):
            raise
        result['error'] = f'{type(error).__name__}: {error}' if not isinstance(error, ValueError) else str(error)
    result['wall_seconds'] = time.monotonic() - began
    return result


def plan_parallel(workers, tasks):
    """(concurrent candidates, solver workers each); the solver count is fixed for reproducibility."""
    concurrency = max(1, min(workers // SOLVER_WORKERS, tasks, MAX_CONCURRENCY))
    return concurrency, SOLVER_WORKERS


class Runner:
    """Runs batches of tasks for one conversion; results come back in task order."""

    def __init__(self, ctx, workers, budget):
        self.ctx, self.workers, self.budget = ctx, max(1, workers), budget
        self.pool = None
        self.concurrency = 1
        self.serial = 0              # next working directory number: every task gets its own
        set_context(ctx)

    def _pool(self, concurrency):
        if self.pool is not None and self.concurrency != concurrency:
            self.close()
        if self.pool is None:
            self.concurrency = concurrency
            self.pool = ProcessPoolExecutor(max_workers=concurrency, mp_context=multiprocessing.get_context('spawn'),
                                            initializer=set_context, initargs=(self.ctx,))
        return self.pool

    def run(self, tasks, deadline=None):
        """Run `tasks` (dicts without index/deadline); `deadline` is a Budget whose end stops unshielded work."""
        deadline = deadline or self.budget
        concurrency, inner = plan_parallel(self.workers, len(tasks))
        wall = time.time() + max(0.0, deadline.remaining())
        for index, task in enumerate(tasks):
            task.update(inner=inner, deadline_wall=wall)
            task.setdefault('index', index)
            if 'slot' not in task:
                task['slot'] = self.serial
                self.serial += 1
        results = {}
        if concurrency == 1:
            for task in tasks:
                if not task.get('shield') and deadline.expired():
                    results[task['index']] = dict(index=task['index'], name=task['name'],
                                                  options=task['opts'], expired=True, stages={})
                else:
                    results[task['index']] = run_task(task)
            return [results[task['index']] for task in tasks]
        pool = self._pool(concurrency)
        futures = {pool.submit(run_task, task): task for task in tasks}
        pending = set(futures)
        broken = False
        while pending:
            shielded = any(futures[f].get('shield') for f in pending)
            timeout = None if shielded else max(0.1, deadline.remaining() + GRACE_SECONDS)
            done, pending = wait(pending, timeout=timeout, return_when=FIRST_COMPLETED)
            if not done:
                broken = True
                break
            for future in done:
                task = futures[future]
                try:
                    results[task['index']] = future.result()
                except Exception as error:
                    results[task['index']] = dict(index=task['index'], name=task['name'], options=task['opts'],
                                                  error=f'{type(error).__name__}: {error}', stages={})
                    if isinstance(error, BrokenProcessPool):
                        broken = True     # a worker died: the pool cannot be reused
        for future in pending:
            task = futures[future]
            results[task['index']] = dict(index=task['index'], name=task['name'], options=task['opts'],
                                          expired=True, stages={})
        if broken:
            self.close(kill=True)
        return [results[task['index']] for task in tasks]

    def close(self, kill=False):
        pool, self.pool = self.pool, None
        if pool is None:
            return
        if kill:
            for process in list(getattr(pool, '_processes', {}).values()):
                process.terminate()
        pool.shutdown(wait=not kill, cancel_futures=True)


def make_task(name, opts, *, solve_limit, shield=False, prune_above=None, strict=False, prune_rule=None, params=None):
    """One candidate to build. `prune_rule` (surrogate) or `prune_above` (register distance) may skip its audio."""
    return dict(name=name, opts=opts, solve_limit=solve_limit, shield=shield, prune_above=prune_above, strict=strict,
                prune_rule=prune_rule, params=params)


# Option sets ---------------------------------------------------------------


def base_options(axes, layout='compact'):
    """The first value of every axis (convert lists its preferred value first)."""
    return dict(grid=axes['grid'][0], profile='dynamic', rate=axes['rate'][0], tuning=axes['tuning'][0],
                pitch=axes['pitch'][0], modulation=axes['modulation'][0], couple=axes['couple'][0],
                effect=axes['effect'][0], allocation=axes['allocation'][0], layout=layout,
                effect_tolerance=12.0, solve_params=None)


def initial_options(axes, layout='compact', static=True, all_grids=False):
    """Deterministic first stage: the static bridge, then effects x allocation at the base settings.

    The first dynamic entry is the base candidate (always built, even over budget).
    """
    base = base_options(axes, layout)
    dynamic = [dict(base, effect=effect, allocation=allocation)
               for effect in axes['effect'] for allocation in axes['allocation']]
    if all_grids:
        dynamic += [dict(base, grid=grid) for grid in axes['grid'][1:]]
    result = ([dict(base, profile='static', effect='off', allocation='legacy', pitch='attack',
                    modulation='legacy', couple='legacy', rate=1, tuning='default')] if static else []) + dynamic
    return result


def neighbour_options(best, axes):
    """Without Optuna: each alternative value of each axis, one change at a time, from the best options."""
    result = []
    for key, name in (('rate', 'rate'), ('tuning', 'tuning'), ('pitch', 'pitch'), ('modulation', 'modulation'),
                      ('couple', 'couple'), ('grid', 'grid')):
        for value in axes[name]:
            if value != best[key]:
                result.append(dict(best, **{key: value}))
    return result


# Selection -----------------------------------------------------------------


def select(results, score='v2', tolerance=0.01):
    """Index (into `results`) of the chosen candidate and the guard that was applied.

    Every candidate is scored by `score` (v2). The v1 guard compares each with
    the best v1 over all scored candidates, not with the first one built: a
    candidate wins only if its v1 is within `tolerance` of the best v1 any
    candidate reached, so a v2 gain can never cost more v1 than that. Ties go
    to the earlier candidate, so the choice does not depend on completion order.
    """
    scored = [(i, r) for i, r in enumerate(results)
              if r.get('audio') and score_value(r['audio'], score) is not None]
    if not scored:
        first = next((i for i, r in enumerate(results) if r.get('ct_path') and not r.get('error')), None)
        return first, dict(reference_v1=None, rule='no scored candidate')
    v1 = {i: r['audio'].get('score_v1') for i, r in scored}
    known = [v for v in v1.values() if v is not None]
    reference = max(known) if known else None
    admissible = [(i, r) for i, r in scored
                  if reference is None or (v1[i] is not None and v1[i] >= reference - tolerance)]
    pick = max(admissible, key=lambda item: (score_value(item[1]['audio'], score), -item[0]))[0]
    return pick, dict(reference_v1=reference, v1_tolerance=tolerance,
                      rule='best v2 among candidates within the tolerance of the best v1')


def summarise(result):
    """The report entry of one candidate (no paths to temporary files)."""
    options = result['options']
    entry = {'row_frames': options['grid'], 'sound_programs': options['profile'],
             'output_multiplier': options['rate'], 'tuning': options['tuning'], 'pitch_programs': options['pitch'],
             'modulation_programs': options['modulation'], 'coupled_programs': options['couple'],
             'effect_programs': options['effect'], 'instrument_allocation': options['allocation'],
             'layout': options['layout']}
    if options.get('effect') == 'on':
        entry['effect_tolerance'] = options['effect_tolerance']
    if options.get('solve_params'):
        entry['solve_params'] = options['solve_params']
    for key in ('regdist', 'pruned', 'pruned_by', 'predicted_v2', 'expired', 'error', 'audio', 'stage', 'trial'):
        if result.get(key) is not None:
            entry[key] = result[key]
    entry['wall_seconds'] = round(result.get('wall_seconds', 0.0), 2)
    return entry


def json_safe(value):
    return json.loads(json.dumps(value, default=str))
