"""Surrogate model that predicts a candidate's audio score from cheap features, so clearly worse trials skip audio.

Features are known before any audio is rendered: the register distance and its
components (`regdist`), the search options, the player family and song-level
numbers (length, voice activity, filter use). Targets are the v2 and v1 scores
relative to the song's median over the trials seen so far, so song difficulty
does not have to be learnt. The model (scikit-learn gradient boosting) is fitted on the trials recorded in
the memory database, saved next to it under a version key, and refitted when
enough new rows exist. The prune margin is calibrated from cross-validated
residuals grouped by song. Without scikit-learn, without a memory database, with too few
rows or with a poor cross-validated fit, `load` returns None and the caller keeps
the fixed register-distance rule.
"""
import hashlib
import json
import math
import pickle
import statistics

VERSION = 1
MIN_ROWS = 150              # fewer usable trials: no surrogate
RETRAIN_EXTRA = 100         # refit when this many new usable rows exist
MIN_SONGS = 5
MIN_R2 = 0.10               # cross-validated R2 of the v2 delta below this: not trusted
MARGIN_QUANTILE = 0.95      # share of true under-predictions the margin covers
MIN_MARGIN = 0.02
CV_FOLDS = 5

PARTS = ('pitch', 'gate', 'wave', 'pulse', 'cutoff', 'resonance', 'mode', 'route', 'volume')
SONG_FIELDS = ('frames', 'activity0', 'activity1', 'activity2', 'filter_use')
ORDINALS = dict(tuning=('default', 'source'), pitch_programs=('attack', 'compact', 'full'),
                modulation_programs=('legacy', 'compact'), coupled_programs=('legacy', 'preserve'),
                effect_programs=('off', 'on'), instrument_allocation=('legacy', 'trajectory', 'budget', 'solve'),
                sound_rate=('base', 'source'))
NUMERIC = ('row_frames', 'effect_tolerance', 'envelope_weight', 'loudness_weight', 'repair_cost')
NAN = float('nan')


def sklearn_available():
    try:
        import numpy  # noqa: F401
        import sklearn  # noqa: F401
    except ImportError:
        return False
    return True


def feature_key():
    """Changes whenever the feature layout or the library changes, so a stale model is never reused."""
    try:
        import sklearn
        library = sklearn.__version__
    except ImportError:
        library = 'none'
    layout = json.dumps([VERSION, PARTS, SONG_FIELDS, ORDINALS, NUMERIC, library], sort_keys=True)
    return hashlib.sha256(layout.encode()).hexdigest()[:16]


def song_features(frames):
    """Song-level numbers from the source register frames (25 bytes each); {} when unavailable."""
    try:
        from .regdist import _frames
        a = _frames(frames)
        if not len(a):
            return {}
        out = dict(frames=float(len(a)))
        for v in range(3):
            out[f'activity{v}'] = float(((a[:, v * 7 + 4] & 1) != 0).mean())
        routed = (a[:, 23] & 7) != 0
        out['filter_use'] = float((routed & ((a[:, 24] >> 4 & 7) != 0)).mean())
        return out
    except Exception:
        return {}


def family_code(vocab, family):
    return float(vocab.get(family, NAN)) if vocab else NAN


def build_vector(params, regdist, parts, song, family, vocab, ref_regdist):
    """One feature row (list of floats; NaN where unknown). `params` is the memory/Optuna parameter dict."""
    parts = parts or {}
    song = song or {}
    rel = regdist / ref_regdist if regdist is not None and ref_regdist else NAN
    row = [NAN if regdist is None else float(regdist), rel,
           math.log1p(regdist) if regdist is not None else NAN]
    row += [float(parts[k]) if parts.get(k) is not None else NAN for k in PARTS]
    for name, values in ORDINALS.items():
        value = params.get(name)
        row.append(float(values.index(value)) if value in values else NAN)
    for name in NUMERIC:
        value = params.get(name)
        row.append(float(value) if isinstance(value, (int, float)) else NAN)
    row += [float(song[k]) if song.get(k) is not None else NAN for k in SONG_FIELDS]
    row.append(family_code(vocab, family))
    return row


def _finite(*values):
    return all(v is not None and math.isfinite(v) for v in values)


def training_data(rows):
    """(X, y_v2, y_v1, groups, vocab) from memory trial rows; per-song references as at prediction time."""
    import numpy as np
    by_song = {}
    for row in rows:
        by_song.setdefault(row['song'], []).append(row)
    vocab = {name: i for i, name in enumerate(sorted({r['family'] or 'unknown' for r in rows}))}
    X, y2, y1, groups = [], [], [], []
    for song, group in sorted(by_song.items()):
        scored = [r for r in group if r['state'] == 'done' and _finite(r['score_v2'], r['regdist'])]
        if len(scored) < 3:
            continue
        ref_rd = min(r['regdist'] for r in group if _finite(r['regdist']))
        ref2 = statistics.median(r['score_v2'] for r in scored)
        v1s = [r['score_v1'] for r in scored if _finite(r['score_v1'])]
        ref1 = statistics.median(v1s) if v1s else None
        for r in scored:
            features = r.get('features') or {}
            X.append(build_vector(r['params'], r['regdist'], features.get('parts'), features.get('song'),
                                  r['family'] or 'unknown', vocab, ref_rd))
            y2.append(r['score_v2'] - ref2)
            y1.append(r['score_v1'] - ref1 if ref1 is not None and _finite(r['score_v1']) else NAN)
            groups.append(song)
    return np.array(X, float), np.array(y2, float), np.array(y1, float), groups, vocab


def _fit(X, y):
    """Fit one gradient boosting regressor; a column that is all NaN here (song numbers of old rows) becomes 0."""
    import numpy as np
    from sklearn.ensemble import HistGradientBoostingRegressor
    X = np.array(X, float)
    X[:, np.isnan(X).all(axis=0)] = 0.0
    return HistGradientBoostingRegressor(max_iter=150, learning_rate=0.08, max_depth=4, min_samples_leaf=10,
                                         early_stopping=False, random_state=0).fit(X, y)


def _cross_validate(X, y, groups):
    """Out-of-fold predictions grouped by song; returns (rmse, r2, margin)."""
    import numpy as np
    from sklearn.model_selection import GroupKFold
    mask = np.isfinite(y)
    X, y = X[mask], y[mask]
    groups = [g for g, keep in zip(groups, mask) if keep]
    folds = min(CV_FOLDS, len(set(groups)))
    if folds < 2 or len(y) < 10:
        return None
    out = np.full(len(y), np.nan)
    for train, test in GroupKFold(n_splits=folds).split(X, y, groups):
        out[test] = _fit(X[train], y[train]).predict(X[test])
    residual = y - out
    rmse = float(np.sqrt(np.mean(residual ** 2)))
    total = float(np.sum((y - y.mean()) ** 2))
    r2 = 1.0 - float(np.sum(residual ** 2)) / total if total > 0 else 0.0
    margin = max(MIN_MARGIN, float(np.quantile(residual, MARGIN_QUANTILE)))
    return rmse, r2, margin


def fit(rows):
    """A `Surrogate` from memory rows (`usable` False when the cross-validated fit is poor); None without enough data."""
    if not sklearn_available():
        return None
    X, y2, y1, groups, vocab = training_data(rows)
    if len(y2) < MIN_ROWS or len(set(groups)) < MIN_SONGS:
        return None
    songs = len(set(groups))
    cv2 = _cross_validate(X, y2, groups)
    if cv2 is None:
        return None
    if cv2[1] < MIN_R2:
        return Surrogate(None, None, vocab, len(y2), songs, dict(rmse_v2=cv2[0], r2_v2=cv2[1], margin_v2=cv2[2]),
                         reason=f'cross-validated R2 {cv2[1]:.2f} is below {MIN_R2}')
    cv1 = _cross_validate(X, y1, groups)
    import numpy as np
    keep = np.isfinite(y1)
    model1 = _fit(X[keep], y1[keep]) if keep.sum() >= MIN_ROWS and cv1 else None
    return Surrogate(_fit(X, y2), model1, vocab, len(y2), songs,
                     dict(rmse_v2=cv2[0], r2_v2=cv2[1], margin_v2=cv2[2], rmse_v1=cv1[0] if cv1 else None,
                          r2_v1=cv1[1] if cv1 else None, margin_v1=cv1[2] if cv1 else None))


class Surrogate:
    """Fitted models plus the calibrated margins; picklable (it travels to pool workers inside a `PruneRule`)."""

    def __init__(self, model2, model1, vocab, rows, songs, cv, reason=None):
        self.version = feature_key()
        self.model2, self.model1, self.vocab, self.rows, self.songs, self.cv = model2, model1, vocab, rows, songs, cv
        self.reason = reason

    @property
    def usable(self):
        return self.model2 is not None

    def predict(self, vector):
        """(predicted v2 delta, predicted v1 delta or None) for one feature row."""
        import numpy as np
        x = np.array([vector], float)
        return float(self.model2.predict(x)[0]), (float(self.model1.predict(x)[0]) if self.model1 else None)

    def summary(self):
        out = dict(used=self.usable, rows=self.rows, songs=self.songs,
                   **{k: (round(v, 4) if v is not None else None) for k, v in self.cv.items()})
        if self.reason:
            out['reason'] = self.reason
        return out


def model_path(memory):
    return None if memory.path is None else memory.path.parent / 'surrogate.pkl'


def load(memory):
    """The cached surrogate when still current, a refitted one when enough new rows exist, else None (it may be unusable)."""
    if not sklearn_available() or not getattr(memory, 'enabled', False):
        return None
    path = model_path(memory)
    usable = memory.usable_trials()
    cached = None
    try:
        cached = pickle.loads(path.read_bytes()) if path and path.is_file() else None
    except Exception:
        cached = None
    if cached is not None and (getattr(cached, 'version', None) != feature_key()
                               or not isinstance(cached, Surrogate)):
        cached = None
    if cached is not None and usable < cached.rows + RETRAIN_EXTRA:
        return cached            # a rejected fit is kept too, so it is not recomputed for every conversion
    if usable < MIN_ROWS:
        return cached
    fresh = fit(memory.trial_rows())
    if fresh is None:
        return cached
    try:
        path.write_bytes(pickle.dumps(fresh, protocol=4))
    except Exception:
        pass
    return fresh


class PruneRule:
    """Decides, from a trial's register distance, whether its audio render can be skipped.

    Built by the tuner before each batch from the search state so far (the
    best value, the guard reference and the song's reference numbers) and
    sent to the workers with every task. Deterministic: same state, same decision.
    """

    def __init__(self, surrogate, *, family, song, ref_regdist, ref_v2, ref_v1, best_value, reference_v1,
                 tolerance):
        self.surrogate, self.family, self.song = surrogate, family, song
        self.ref_regdist, self.ref_v2, self.ref_v1 = ref_regdist, ref_v2, ref_v1
        self.best_value, self.reference_v1, self.tolerance = best_value, reference_v1, tolerance

    def decide(self, params, regdist, parts):
        """(prune?, predicted v2) for one trial."""
        vector = build_vector(params, regdist, parts, self.song, self.family, self.surrogate.vocab, self.ref_regdist)
        d2, d1 = self.surrogate.predict(vector)
        predicted = self.ref_v2 + d2
        if predicted + self.surrogate.cv['margin_v2'] < self.best_value:
            return True, predicted
        margin1 = self.surrogate.cv.get('margin_v1')
        if d1 is not None and margin1 is not None and self.reference_v1 is not None and self.ref_v1 is not None:
            if self.ref_v1 + d1 + margin1 < self.reference_v1 - self.tolerance:
                return True, predicted
        return False, predicted

