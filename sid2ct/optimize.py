"""Optional, bounded parameter experiments using Optuna or random sampling."""
import hashlib
import math
import time


def load_optuna():
    try:
        import optuna
    except ImportError as error:
        raise ValueError('Parameter search requires Optuna: python3 -m pip install -r tools/requirements-sid-search.txt') from error
    return optuna


def suggest_options(trial, row_frames, source_tuning_available=True):
    allocation = trial.suggest_categorical('instrument_allocation', ['legacy', 'trajectory', 'budget'])
    return dict(
        row_frames=trial.suggest_categorical('row_frames', sorted({3, 4, 5, 6, 8, 12, row_frames})),
        sound_programs='dynamic', coupled_programs='preserve',
        sound_rate=trial.suggest_categorical('sound_rate', ['base', 'source']),
        tuning=trial.suggest_categorical('tuning', ['default', 'source'] if source_tuning_available else ['default']),
        pitch_programs=trial.suggest_categorical('pitch_programs', ['attack', 'compact', 'full']),
        modulation_programs=trial.suggest_categorical('modulation_programs', ['legacy', 'compact']),
        instrument_allocation=allocation,
        joint_modeling=trial.suggest_categorical('joint_modeling', [False, True]) if allocation != 'legacy' else False)


def parameter_search(build, *, output, optimizer, cap=40, seconds=600, seed=0,
                     row_frames=6, clock=time.monotonic):
    optuna = load_optuna()
    if cap < 0 or not math.isfinite(seconds) or seconds <= 0:
        raise ValueError('Search cap must be nonnegative and seconds positive/finite.')
    sampler = (optuna.samplers.TPESampler(seed=seed) if optimizer == 'optuna'
               else optuna.samplers.RandomSampler(seed=seed))
    # New runs retain old study history; each invocation has an independent budget.
    study = optuna.create_study(direction='maximize', sampler=sampler,
                               storage='sqlite:///' + str((output/'trials.sqlite3').resolve()))
    start = clock()
    records, hashes, configurations = [], {}, {}

    def evaluate(name, options):
        began = clock()
        record = dict(name=name, options=options)
        try:
            key = tuple(sorted(options.items()))
            if key in configurations:
                previous = configurations[key]
                record.update({k: v for k, v in previous.items() if k not in ('name', 'wall_seconds')})
                record['duplicate_of'] = previous['name']
            else:
                data, details = build(name, options)
                digest = hashlib.sha256(data).hexdigest()
                record.update(details, sha256=digest)
                if digest in hashes:
                    record['duplicate_of'] = hashes[digest]
                else:
                    hashes[digest] = name
                configurations[key] = record
        except (ValueError, OSError) as error:
            record['error'] = str(error)
        record['wall_seconds'] = clock()-began
        records.append(record)
        return record

    before = evaluate('before', {})
    study.set_user_attr('before', before)
    study.set_user_attr('optimizer', optimizer)
    study.set_user_attr('seed', seed)
    if 'error' not in before and before.get('mode') != 'recognized-cheesecutter':
        for index in range(cap):
            if clock()-start >= seconds:
                break
            trial = study.ask()
            options = suggest_options(trial, row_frames, before.get('source_tuning_available', False))
            record = evaluate(f'trial-{trial.number:04d}', options)
            trial.set_user_attr('record', record)
            score = record.get('mix', {}).get('similarity')
            if 'error' in record or score is None or not math.isfinite(score):
                study.tell(trial, state=optuna.trial.TrialState.FAIL)
            else:
                study.tell(trial, score)
    return dict(candidates=records, wall_seconds=clock()-start, cap=cap,
                time_budget_seconds=seconds, truncated=len(records)<cap+1,
                optimizer=optimizer, seed=seed, optuna_version=optuna.__version__,
                study_name=study.study_name, study_storage=str((output/'trials.sqlite3').resolve()))


def diagnostic_scores(entry):
    """Use fixed mix alignment, including every voice/pair and section."""
    result = {'mix': entry['mix']['similarity']}

    def windows(prefix, values):
        for window in values:
            key = (prefix, window['start_seconds'], window['end_seconds'])
            result[str(key)] = window['audio']['similarity']

    windows('mix', entry['mix_windows'])
    if set(entry['voices']) != {'1', '2', '3'}:
        raise ValueError('Full diagnostics must include all three voices.')
    for category in ('voices', 'coupled_pairs'):
        for label, data in entry[category].items():
            prefix = category + label
            result[prefix] = data['fixed_alignment']['similarity']
            windows(prefix, data['windows'])
    return result


def select_validated(records, diagnostics, tolerance=0):
    before = next((r for r in records if r['name'] == 'before' and 'error' not in r), None)
    if before is None:
        return None, {}
    entries = diagnostics.get('candidates', {})
    if 'before' not in entries:
        return before, {'before': ['Full diagnostics unavailable.']}
    baseline = diagnostic_scores(entries['before'])
    rejected, accepted = {}, [before]
    for record in records:
        name = record['name']
        if name == 'before' or 'error' in record or 'duplicate_of' in record:
            continue
        reasons = []
        if name not in entries:
            reasons.append('Full diagnostics unavailable.')
        else:
            scores = diagnostic_scores(entries[name])
            if scores.keys() != baseline.keys():
                reasons.append('Diagnostic sections do not match the baseline.')
            for key, prior in baseline.items():
                if prior is None:
                    continue  # Silent/inconclusive baseline sections cannot be ranked.
                score = scores.get(key)
                if score is None or not math.isfinite(score) or score < prior-tolerance:
                    reasons.append('Regression or unavailable score: '+key)
            if baseline['mix'] is None or scores['mix'] is None or scores['mix'] <= baseline['mix']:
                reasons.append('Full-duration mix did not improve.')
        if reasons:
            rejected[name] = reasons
        else:
            accepted.append(record)
    return max(accepted, key=lambda r: entries.get(r['name'], {}).get('mix', {}).get('similarity') or -1), rejected
