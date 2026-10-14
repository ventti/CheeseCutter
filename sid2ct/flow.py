"""The default conversion flow: deterministic candidates, then an Optuna search, then one selection.

1. Stage A builds and scores a fixed, ordered set of candidates in parallel:
   the static bridge, and the base settings crossed with effects x instrument allocation
   (effects auto = off and on, allocation auto = legacy and solve).
2. Stage B runs an Optuna study over the remaining knobs (row grid, sound rate, tuning, pitch,
   modulation and coupled programmes, effect tolerance, solver weights) in parallel batches, warm
   started from the memory database, until the time budget ends. Without Optuna or numpy it
   tries each alternative setting once instead.
3. One selection over every candidate (`portfolio.select`).
Everything runs under one `Budget`; the first dynamic candidate is shielded, so an output exists
whatever the budget says.
"""
from . import portfolio, tuner

DEFAULT_SOLVE_LIMIT = {'default': 20.0, 'high': 60.0}
SEARCH_SHARE = 0.15       # one candidate's solver may use this share of the remaining time
NEIGHBOURS = 6            # one-change neighbours of the best first-stage candidate that Optuna tries first
TRIAL_CAP = 400


def _numpy():
    try:
        import numpy  # noqa: F401
    except ImportError:
        return False
    return True


def _ortools():
    try:
        import ortools  # noqa: F401
    except ImportError:
        return False
    return True


def build_axes(args, *, multiplier, coupling, recovered, anchored, profiles):
    """Allowed values per knob, preferred value first. A flag that names a value pins its axis."""
    skip = args.skip_audio
    explicit_grid = args.row_frames is not None
    base_grid = args.row_frames or 6
    if explicit_grid or skip:
        grids = [base_grid]
    else:
        grids = [base_grid] + [g for g in (3, 4, 5, 6, 8, 12) if g != base_grid]
    tuning = ['default']
    if recovered is not None and args.tuning != 'default':
        tuning = ['source'] if args.tuning == 'source' or anchored or skip else ['default', 'source']
    rate_choice = args.sound_rate
    rates = ([multiplier, 1] if rate_choice == 'auto' and not skip else
             [multiplier] if rate_choice in ('auto', 'source') else [1])
    rates = list(dict.fromkeys(rates))
    pitch = ['full', 'compact', 'attack'] if args.pitch_programs == 'auto' and not skip else [
        'full' if args.pitch_programs == 'auto' else args.pitch_programs]
    modulation = ['compact', 'legacy'] if args.modulation_programs == 'auto' and not skip else [
        'compact' if args.modulation_programs == 'auto' else args.modulation_programs]
    edges = bool(coupling['edges'])
    if args.coupled_programs == 'auto':
        couple = (['preserve', 'legacy'] if edges and not skip else ['preserve'] if edges else ['legacy'])
    else:
        couple = [args.coupled_programs]
    requested = getattr(args, 'effect_programs', 'auto')
    effect = ['off', 'on'] if requested == 'auto' and not skip and _numpy() else ['off' if requested == 'auto' else requested]
    wanted = getattr(args, 'instrument_allocation', 'auto')
    if wanted == 'auto':
        allocation = ['legacy', 'solve'] if not skip and _ortools() else ['legacy']
    else:
        allocation = [wanted]
    return dict(grid=grids, rate=rates, tuning=tuning, pitch=pitch, modulation=modulation, couple=couple,
                effect=effect, allocation=allocation, explicit_grid=explicit_grid)


def free_knobs(axes):
    return (any(len(axes[k]) > 1 for k in ('grid', 'rate', 'tuning', 'pitch', 'modulation', 'couple', 'effect', 'allocation'))
            or 'on' in axes['effect'] or 'solve' in axes['allocation'])


def solve_limit_for(args, effort, search_budget):
    ceiling = getattr(args, 'solve_time_limit', None) or DEFAULT_SOLVE_LIMIT[effort]
    return min(ceiling, max(3.0, SEARCH_SHARE * max(0.0, search_budget.remaining())))


def search(args, ctx, *, axes, profiles, budget, search_budget, workers, effort, memory, family, song, log=print):
    """Run the stages; returns (results, selection index, guard info, stage notes)."""
    dynamic = 'dynamic' in profiles
    static = 'static' in profiles
    layout = getattr(args, 'layout', 'compact')
    if dynamic:
        options = portfolio.initial_options(axes, layout, static=static, all_grids=args.auto_row_frames)
    else:
        options = [dict(portfolio.base_options(axes, layout), profile='static', effect='off', allocation='legacy',
                        pitch='attack', modulation='legacy', couple='legacy', rate=1, tuning='default')]
    first_dynamic = next((i for i, o in enumerate(options) if o['profile'] == 'dynamic'), None)
    strict = len(options) == 1
    limit = solve_limit_for(args, effort, search_budget)
    tasks = [portfolio.make_task(portfolio.label(o), o, solve_limit=limit,
                                 shield=(o['profile'] == 'static' or i == first_dynamic), strict=strict)
             for i, o in enumerate(options)]
    runner = portfolio.Runner(ctx, workers, budget)
    notes = {}
    try:
        with budget.stage('candidates'):
            first = runner.run(tasks, search_budget)
        for result in first:
            result['stage'] = 'initial'
        results = list(first)
        if dynamic and not any(r.get('ct_path') for r in first if r['options']['profile'] == 'dynamic'):
            # Every dynamic candidate failed (typically: too many rows for the native layout limits at this
            # grid on a long song): retry the base settings on coarser grids.
            coarser = [g for g in (8, 12, 16, 24) if g > axes['grid'][0]]
            retry = [portfolio.make_task(portfolio.label(dict(options[first_dynamic], grid=g)),
                                         dict(options[first_dynamic], grid=g, effect='off', allocation='legacy'),
                                         solve_limit=limit, shield=g == coarser[0] if coarser else False)
                     for g in coarser]
            if retry:
                for result in runner.run(retry, search_budget):
                    result['stage'] = 'retry'
                    results.append(result)
                    first.append(result)
        base_options = portfolio.base_options(axes, layout)
        trial_cap = TRIAL_CAP if getattr(args, 'max_trials', None) is None else max(0, args.max_trials)
        if not ctx.skip_audio and dynamic and free_knobs(axes) and trial_cap and not search_budget.expired():
            scored = [r for r in first if r.get('audio') and r['options']['profile'] == 'dynamic']
            best_index, _ = portfolio.select(scored, getattr(args, 'score', 'v2'), getattr(args, 'v1_tolerance', 0.01)) if scored else (None, None)
            best = scored[best_index]['options'] if best_index is not None else base_options
            if tuner.available():
                with budget.stage('search'):
                    study = tuner.Tuner(runner, axes, base_options, multiplier=ctx.multiplier, seed=getattr(args, 'seed', 0),
                                        memory=memory if memory.enabled else None, song=song, family=family,
                                        effort=effort, score=getattr(args, 'score', 'v2'), v1_tolerance=getattr(args, 'v1_tolerance', 0.01),
                                        solve_limit=getattr(args, 'solve_time_limit', None) or DEFAULT_SOLVE_LIMIT[effort])
                    study.seed_with(first)
                    warm = memory.warm_params(family, song) if memory.enabled else []
                    notes['warm_start_trials'] = len(warm)
                    study.enqueue(warm + [tuner.params_from_options(o, ctx.multiplier)
                                          for o in portfolio.neighbour_options(best, axes)[:NEIGHBOURS]])
                    trials = study.run(search_budget, cap=trial_cap)
                for result in trials:
                    result['stage'] = 'optuna'
                results += trials
                notes['optuna_trials'] = len(trials)
                notes['optuna_pruned'] = sum(1 for r in trials if r.get('pruned'))
            else:
                neighbours = portfolio.neighbour_options(best, axes)[:trial_cap]
                if neighbours:
                    extra_limit = solve_limit_for(args, effort, search_budget)
                    extra = [portfolio.make_task(portfolio.label(o), o, solve_limit=extra_limit) for o in neighbours]
                    with budget.stage('search'):
                        ran = runner.run(extra, search_budget)
                    for result in ran:
                        result['stage'] = 'neighbour'
                    results += ran
                    notes['neighbour_candidates'] = len(ran)
    finally:
        runner.close()
    with budget.stage('selection'):
        pick, guard = portfolio.select(results, getattr(args, 'score', 'v2'), getattr(args, 'v1_tolerance', 0.01))
    return results, pick, guard, notes


def aggregate_worker_seconds(results):
    totals = {}
    for result in results:
        for name, seconds in (result.get('stages') or {}).items():
            totals[name] = totals.get(name, 0.0) + seconds
    return {k: round(v, 2) for k, v in totals.items()}
