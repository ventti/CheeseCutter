"""Optuna search over the global conversion knobs, inside the default conversion's time budget.

Trials run in batches of BATCH (a constant, so the sampled sequence depends on
the seed only, not on how many cores there are); a batch is built and scored
concurrently by the portfolio's worker pool and told to the study in trial
order. Before any audio is rendered, each trial's register distance (regdist,
through the exact CT player model) is compared with the best seen: a trial that
is more than PRUNE_MARGIN worse is pruned without audio. Optuna is optional;
without it (or numpy) the caller falls back to one-change-at-a-time neighbours.
"""
import json
import math

from . import portfolio
from .audio import score_value

BATCH = 8
STARTUP_TRIALS = 6
GUARD_PENALTY = 0.25              # a trial that fails the v1 guard counts this much worse than its v2
TOLERANCE_RANGE = (6.0, 24.0)     # effect fit tolerance, cents
SOLVE_RANGES = dict(envelope_weight=(0.5, 3.0), loudness_weight=(0.15, 2.5), repair_cost=(0.0, 1.0))
LOG_SCALED = ('envelope_weight', 'loudness_weight')
MIN_TRIAL_SHARE = 0.8             # stop when less than this share of the last batch's time is left
RATE_NAMES = ('source', 'base')


def available():
    try:
        import numpy  # noqa: F401
        import optuna  # noqa: F401
    except ImportError:
        return False
    return True


def rate_name(rate, multiplier):
    return 'source' if rate == multiplier else 'base'


def params_from_options(opts, multiplier):
    """The search-space point of a dynamic candidate: only the knobs that apply to it."""
    params = dict(row_frames=opts['grid'], sound_rate=rate_name(opts['rate'], multiplier), tuning=opts['tuning'],
                  pitch_programs=opts['pitch'], modulation_programs=opts['modulation'],
                  coupled_programs=opts['couple'], effect_programs=opts['effect'],
                  instrument_allocation=opts['allocation'])
    if opts['effect'] == 'on':
        params['effect_tolerance'] = opts['effect_tolerance']
    if opts['allocation'] == 'solve':
        merged = dict(solve_defaults(), **(opts.get('solve_params') or {}))
        params.update({k: merged[k] for k in SOLVE_RANGES})
    return params


def solve_defaults():
    from .solve import DEFAULTS
    return {k: DEFAULTS[k] for k in SOLVE_RANGES}


def options_from_params(params, base, axes, multiplier):
    """Candidate options for a (possibly foreign or partial) parameter dict; values outside the axes are ignored."""
    opts = dict(base)
    for key, name in (('grid', 'row_frames'), ('tuning', 'tuning'), ('pitch', 'pitch_programs'),
                      ('modulation', 'modulation_programs'), ('couple', 'coupled_programs'),
                      ('effect', 'effect_programs'), ('allocation', 'instrument_allocation')):
        if name in params and params[name] in axes[key]:
            opts[key] = params[name]
    if params.get('sound_rate') in RATE_NAMES:
        wanted = multiplier if params['sound_rate'] == 'source' else 1
        if wanted in axes['rate']:
            opts['rate'] = wanted
    low, high = TOLERANCE_RANGE
    if opts['effect'] == 'on' and isinstance(params.get('effect_tolerance'), (int, float)):
        opts['effect_tolerance'] = min(high, max(low, float(params['effect_tolerance'])))
    if opts['allocation'] == 'solve':
        values = {k: min(SOLVE_RANGES[k][1], max(SOLVE_RANGES[k][0], float(params[k])))
                  for k in SOLVE_RANGES if isinstance(params.get(k), (int, float))}
        opts['solve_params'] = values or None
    return opts


def key_of(opts):
    return json.dumps({k: opts[k] for k in portfolio.OPTION_NAMES}, sort_keys=True, default=str)


class Tuner:
    def __init__(self, runner, axes, base, *, multiplier, seed=0, memory=None, song=None, family='unknown',
                 effort='default', score='v2', v1_tolerance=0.01, solve_limit=20.0):
        import optuna
        optuna.logging.set_verbosity(optuna.logging.WARNING)
        self.optuna = optuna
        self.runner, self.axes, self.base, self.multiplier = runner, axes, base, multiplier
        self.seed, self.memory, self.song, self.family, self.effort = seed, memory, song, family, effort
        self.score, self.tolerance, self.solve_limit = score, v1_tolerance, solve_limit
        sampler = optuna.samplers.TPESampler(seed=seed, n_startup_trials=STARTUP_TRIALS, constant_liar=True)
        self.study = optuna.create_study(direction='maximize', sampler=sampler)
        self.seen = {}               # options key -> result
        self.results = []            # trial results in trial order
        self.reference_v1 = None
        self.best_regdist = None     # register distance of the best candidate by guarded value (not the smallest)
        self.best_value = None
        self.last_batch_seconds = None
        self.infeasible_grid = 0     # a grid this fine (or finer) overflowed the native layout limits

    # Search space ------------------------------------------------------------

    def _choices(self, axis):
        values = list(self.axes[axis])
        return values

    def distributions(self, params):
        """Optuna distributions for exactly the parameters of one point (matches `suggest`)."""
        d = self.optuna.distributions
        result = {}
        for name, axis in (('row_frames', 'grid'), ('tuning', 'tuning'), ('pitch_programs', 'pitch'),
                           ('modulation_programs', 'modulation'), ('coupled_programs', 'couple'),
                           ('effect_programs', 'effect'), ('instrument_allocation', 'allocation')):
            if name in params and len(self.axes[axis]) > 1:
                result[name] = d.CategoricalDistribution(self._choices(axis))
        if 'sound_rate' in params and len(self.axes['rate']) > 1:
            result['sound_rate'] = d.CategoricalDistribution(list(RATE_NAMES))
        if 'effect_tolerance' in params:
            result['effect_tolerance'] = d.FloatDistribution(*TOLERANCE_RANGE)
        for name, (low, high) in SOLVE_RANGES.items():
            if name in params:
                result[name] = d.FloatDistribution(low, high, log=name in LOG_SCALED)
        return result

    def suggest(self, trial):
        """Define-by-run sampling; returns the full point (fixed axes included)."""
        base = params_from_options(self.base, self.multiplier)
        params = dict(base)
        for name, axis in (('row_frames', 'grid'), ('sound_rate', 'rate'), ('tuning', 'tuning'),
                           ('pitch_programs', 'pitch'), ('modulation_programs', 'modulation'),
                           ('coupled_programs', 'couple'), ('effect_programs', 'effect'),
                           ('instrument_allocation', 'allocation')):
            if len(self.axes[axis]) > 1:
                choices = list(RATE_NAMES) if name == 'sound_rate' else self._choices(axis)
                params[name] = trial.suggest_categorical(name, choices)
        params.pop('effect_tolerance', None)
        for name in SOLVE_RANGES:
            params.pop(name, None)
        if 'on' in self.axes['effect'] and params['effect_programs'] == 'on':
            params['effect_tolerance'] = trial.suggest_float('effect_tolerance', *TOLERANCE_RANGE)
        if 'solve' in self.axes['allocation'] and params['instrument_allocation'] == 'solve':
            for name, (low, high) in SOLVE_RANGES.items():
                params[name] = trial.suggest_float(name, low, high, log=name in LOG_SCALED)
        return params

    # Values ------------------------------------------------------------------

    def value(self, result):
        audio = result.get('audio')
        value = score_value(audio, self.score) if audio else None
        if value is None or not math.isfinite(value):
            return None
        v1 = audio.get('score_v1')
        if self.reference_v1 is not None and (v1 is None or v1 < self.reference_v1 - self.tolerance):
            value -= GUARD_PENALTY
        return value

    def observe(self, result):
        """Fold a finished candidate into the guard reference and the register-distance threshold."""
        audio = result.get('audio')
        if audio and audio.get('score_v1') is not None:
            self.reference_v1 = max(self.reference_v1 or 0.0, audio['score_v1'])
        value = self.value(result)
        if value is not None and result.get('regdist') is not None and (self.best_value is None or value > self.best_value):
            # The solver optimises its own distortion, so a good candidate need not have the smallest
            # register distance: prune relative to the best candidate by audio, not by distance.
            self.best_value, self.best_regdist = value, result['regdist']

    def seed_with(self, results):
        """Tell the study about the deterministic first-stage results so sampling learns from them."""
        for result in results:
            opts = result['options']
            self.observe(result)
            self.seen[key_of(opts)] = result
        walls = sorted(r['wall_seconds'] for r in results
                       if r['options']['profile'] == 'dynamic' and r.get('wall_seconds') and not r.get('expired'))
        if walls:
            self.last_batch_seconds = walls[len(walls) // 2]     # expected duration of a trial, until a batch is timed
        for result in results:
            opts = result['options']
            if opts['profile'] != 'dynamic':
                continue
            value = self.value(result)
            if value is None:
                continue
            params = params_from_options(opts, self.multiplier)
            distributions = self.distributions(params)
            params = {k: v for k, v in params.items() if k in distributions}
            try:
                self.study.add_trial(self.optuna.trial.create_trial(params=params, distributions=distributions,
                                                                    value=value))
            except Exception:
                pass    # a point the space cannot express only costs the prior

    def enqueue(self, params_list):
        for params in params_list:
            opts = options_from_params(params, self.base, self.axes, self.multiplier)
            if key_of(opts) in self.seen:
                continue
            point = params_from_options(opts, self.multiplier)
            distributions = self.distributions(point)
            self.study.enqueue_trial({k: v for k, v in point.items() if k in distributions}, skip_if_exists=True)

    # Loop --------------------------------------------------------------------

    def run(self, deadline, cap=200):
        """Run batches until the budget or `cap` trials end; returns the trial results in trial order."""
        trial_results = []
        while len(trial_results) < cap and not deadline.expired():
            if self.last_batch_seconds is not None and deadline.remaining() < MIN_TRIAL_SHARE * self.last_batch_seconds:
                break
            batch = []
            for _ in range(min(BATCH, cap - len(trial_results))):
                trial = self.study.ask()
                params = self.suggest(trial)
                opts = options_from_params(params, self.base, self.axes, self.multiplier)
                batch.append((trial, params, opts))
            threshold = None if self.best_regdist is None else self.best_regdist * (1 + portfolio.PRUNE_MARGIN)
            tasks, positions, fresh = [], {}, {}
            for number, (trial, params, opts) in enumerate(batch):
                key = key_of(opts)
                if key in self.seen or key in fresh:
                    continue
                if opts['grid'] <= self.infeasible_grid:
                    # More rows than a coarser grid that already overflowed: no need to build it.
                    self.seen[key] = dict(index=-1, name=f'trial-{trial.number:04d}', options=opts, stages={},
                                          error=f'skipped: layout capacity exceeded at row grid {self.infeasible_grid}')
                    continue
                fresh[key] = number
                limit = min(self.solve_limit, max(3.0, 0.2 * max(0.0, deadline.remaining())))
                task = portfolio.make_task(f'trial-{trial.number:04d}', opts, solve_limit=limit, prune_above=threshold)
                positions[number] = len(tasks)
                tasks.append(task)
            began = deadline.clock()
            ran = self.runner.run(tasks, deadline) if tasks else []
            self.last_batch_seconds = deadline.clock() - began
            by_key = {}
            for number, (trial, params, opts) in enumerate(batch):
                key = key_of(opts)
                if number in positions:
                    result = dict(ran[positions[number]])
                    by_key[key] = result
                    duplicate = False
                else:
                    original = self.seen.get(key) or by_key[key]
                    result = dict(original, duplicate_of=original.get('name'))
                    duplicate = True
                result['trial'] = trial.number
                self._tell(trial, params, result, duplicate)
                trial_results.append(result)
                if not duplicate:
                    self.seen[key] = result
            for result in ran:
                self.observe(result)
                if 'layout exceeds native capacity' in (result.get('error') or ''):
                    self.infeasible_grid = max(self.infeasible_grid, result['options']['grid'])
            if any(r.get('expired') for r in ran):
                break
        self.results = trial_results
        return trial_results

    def _tell(self, trial, params, result, duplicate):
        state = self.optuna.trial.TrialState
        value = self.value(result)
        if result.get('pruned'):
            self.study.tell(trial, state=state.PRUNED)
            outcome = 'pruned'
        elif value is None:
            self.study.tell(trial, state=state.FAIL)
            outcome = 'expired' if result.get('expired') else 'failed'
        else:
            self.study.tell(trial, value)
            outcome = 'done'
        if self.memory is not None and not duplicate:
            audio = result.get('audio') or {}
            self.memory.record_trial(self.song, self.family, result.get('name'), params, audio.get('score_v1'),
                                     audio.get('score_v2'), result.get('regdist'), outcome, self.seed, self.effort,
                                     result.get('wall_seconds'))
