"""WP8b: surrogate pruning model and the local polish stage (with fake scorers, no audio rendering)."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import random
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import zlib

from sid2ct import budget as budgets, memory, polish, portfolio, surrogate

try:
    import numpy  # noqa: F401
    import sklearn  # noqa: F401
    HAVE_SKLEARN = True
except ImportError:
    HAVE_SKLEARN = False


def synthetic_rows(songs=10, per_song=30, seed=5):
    """Trials whose v2 falls linearly with the register distance above the song's best, plus noise."""
    rng = random.Random(seed)
    rows = []
    for song in range(songs):
        base_v2 = 0.4 + 0.05 * song
        base_rd = 1.0 + 0.3 * song
        for _ in range(per_song):
            excess = rng.uniform(0.0, 1.5)
            rows.append(dict(song=f's{song}', family='fam', score_v1=0.9 - 0.1 * excess + rng.gauss(0, 0.004),
                             score_v2=base_v2 - 0.12 * excess + rng.gauss(0, 0.004), regdist=base_rd * (1 + excess),
                             state='done', features=None,
                             params=dict(row_frames=rng.choice([3, 4, 6]), sound_rate='source', tuning='default',
                                         pitch_programs='full', modulation_programs='compact',
                                         coupled_programs='legacy', effect_programs='off',
                                         instrument_allocation='legacy')))
    return rows


def rule_for(model, best_value):
    return surrogate.PruneRule(model, family='fam', song={}, ref_regdist=1.0, ref_v2=0.5, ref_v1=0.85,
                               best_value=best_value, reference_v1=0.9, tolerance=0.01)


@unittest.skipUnless(HAVE_SKLEARN, 'needs numpy and scikit-learn')
class SurrogateTests(unittest.TestCase):
    def test_trains_on_synthetic_rows_and_predicts_the_trend(self):
        model = surrogate.fit(synthetic_rows())
        self.assertIsNotNone(model)
        self.assertTrue(model.usable, model.reason)
        self.assertGreater(model.cv['r2_v2'], surrogate.MIN_R2)
        self.assertGreaterEqual(model.cv['margin_v2'], surrogate.MIN_MARGIN)
        params = synthetic_rows(1, 1)[0]['params']
        near = model.predict(surrogate.build_vector(params, 1.0, None, None, 'fam', model.vocab, 1.0))[0]
        far = model.predict(surrogate.build_vector(params, 2.5, None, None, 'fam', model.vocab, 1.0))[0]
        self.assertGreater(near, far + 0.05)
        summary = model.summary()
        self.assertTrue(summary['used'])
        self.assertIn('rmse_v2', summary)

    def test_rule_prunes_clearly_worse_trials_only(self):
        model = surrogate.fit(synthetic_rows())
        params = synthetic_rows(1, 1)[0]['params']
        rule = rule_for(model, best_value=0.5)
        self.assertTrue(rule.decide(params, 3.0, None)[0])      # far worse than the best
        self.assertFalse(rule.decide(params, 1.0, None)[0])     # as close as the best

    def test_too_little_data_or_noise_gives_no_usable_model(self):
        self.assertIsNone(surrogate.fit(synthetic_rows(songs=3, per_song=10)))
        rng = random.Random(1)
        noisy = synthetic_rows()
        for row in noisy:
            row['score_v2'] = 0.5 + rng.gauss(0, 0.05)
        model = surrogate.fit(noisy)
        self.assertTrue(model is None or not model.usable)
        if model is not None:
            self.assertIn('R2', model.reason)
            self.assertIn('rmse_v2', model.summary())     # the error is reported even for a rejected fit

    def test_model_is_saved_next_to_the_database_and_reloaded_until_enough_new_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = memory.Memory(Path(tmp)/'memory.sqlite3')
            for row in synthetic_rows():
                db.record_trial(row['song'], row['family'], 'x', row['params'], row['score_v1'], row['score_v2'],
                                row['regdist'], 'done', 0, 'default', 1.0)
            first = surrogate.load(db)
            self.assertIsNotNone(first)
            self.assertTrue((Path(tmp)/'surrogate.pkl').is_file())
            again = surrogate.load(db)
            self.assertEqual(again.rows, first.rows)
            self.assertEqual(again.cv, first.cv)
            for row in synthetic_rows(seed=9)[:surrogate.RETRAIN_EXTRA + 5]:
                db.record_trial(row['song'], row['family'], 'x', row['params'], row['score_v1'], row['score_v2'],
                                row['regdist'], 'done', 0, 'default', 1.0)
            self.assertGreater(surrogate.load(db).rows, first.rows)        # refitted
            db.close()

    def test_stale_version_key_is_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = memory.Memory(Path(tmp)/'memory.sqlite3')
            for row in synthetic_rows():
                db.record_trial(row['song'], row['family'], 'x', row['params'], row['score_v1'], row['score_v2'],
                                row['regdist'], 'done', 0, 'default', 1.0)
            surrogate.load(db)
            with mock.patch.object(surrogate, 'feature_key', return_value='other'):
                refit = surrogate.load(db)
            self.assertEqual(refit.version, 'other')
            db.close()


class SurrogateFallback(unittest.TestCase):
    def test_without_sklearn_there_is_no_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = memory.Memory(Path(tmp)/'memory.sqlite3')
            for row in synthetic_rows():
                db.record_trial(row['song'], row['family'], 'x', row['params'], row['score_v1'], row['score_v2'],
                                row['regdist'], 'done', 0, 'default', 1.0)
            with mock.patch.dict(sys.modules, {'sklearn': None}):
                self.assertFalse(surrogate.sklearn_available())
                self.assertIsNone(surrogate.load(db))
                self.assertIsNone(surrogate.fit(synthetic_rows()))
            db.close()

    def test_disabled_memory_gives_no_model(self):
        self.assertIsNone(surrogate.load(memory.Memory(enabled=False)))

    def test_old_trial_rows_without_features_and_old_databases_still_load(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)/'memory.sqlite3'
            import sqlite3
            old = sqlite3.connect(path)
            old.executescript('create table trials (id integer primary key autoincrement, song text, family text, '
                              'name text, params text, score_v1 real, score_v2 real, regdist real, state text, '
                              'seed integer, effort text, wall_seconds real, created text);')
            old.execute("insert into trials (song, family, params, score_v2, regdist, state) "
                        "values ('a', 'f', '{}', 0.5, 1.0, 'done')")
            old.commit()
            old.close()
            db = memory.Memory(path)
            self.assertEqual(db.usable_trials(), 1)
            self.assertIsNone(db.trial_rows()[0]['features'])
            db.record_trial('a', 'f', 'n', {}, 0.9, 0.5, 1.0, 'done', 0, 'default', 1.0, features=dict(parts=dict(pitch=1.0)))
            self.assertEqual(db.trial_rows()[1]['features']['parts']['pitch'], 1.0)
            db.close()


class AlwaysPrune:
    def decide(self, params, regdist, parts):
        return True, 0.1


class PruningDecisions(unittest.TestCase):
    def evaluate(self, task):
        ctx = SimpleNamespace(work_dir=tempfile.mkdtemp(), skip_audio=False, subtune=1)
        opts = dict(profile='dynamic', rate=1)
        task = dict(task, opts=opts, index=0, solve_limit=1)
        assessed = []
        with mock.patch.object(portfolio, 'build', return_value=(b'CC2data', {})), \
                mock.patch.object(portfolio, 'register_parts', return_value=dict(total=9.0, pitch=1.0)), \
                mock.patch.object(portfolio, 'assess_file',
                                  side_effect=lambda *a: (assessed.append(1) or dict(score_v1=.9, score_v2=.5), Path('x.wav'))):
            out = portfolio._evaluate(ctx, task, {})
        return out, assessed

    def test_shielded_and_base_candidates_are_never_pruned(self):
        out, assessed = self.evaluate(dict(shield=True, prune_rule=AlwaysPrune(), prune_above=0.001))
        self.assertNotIn('pruned', out)
        self.assertEqual(len(assessed), 1)
        out, assessed = self.evaluate(dict(shield=False, prune_rule=AlwaysPrune()))
        self.assertTrue(out['pruned'])
        self.assertEqual(out['pruned_by'], 'surrogate')
        self.assertEqual(assessed, [])

    def test_fixed_rule_applies_without_a_surrogate_and_a_broken_model_falls_back_to_it(self):
        out, _ = self.evaluate(dict(shield=False, prune_above=5.0))
        self.assertEqual((out['pruned'], out['pruned_by']), (True, 'regdist'))
        out, assessed = self.evaluate(dict(shield=False, prune_above=50.0))
        self.assertNotIn('pruned', out)
        self.assertEqual(len(assessed), 1)

        class Broken:
            def decide(self, *args):
                raise RuntimeError('model gone')
        out, _ = self.evaluate(dict(shield=False, prune_rule=Broken(), prune_above=5.0))
        self.assertEqual(out['pruned_by'], 'regdist')

    @unittest.skipUnless(HAVE_SKLEARN, 'needs scikit-learn')
    def test_tuner_builds_a_rule_only_from_a_usable_model_with_references(self):
        try:
            from sid2ct import tuner
        except ImportError:
            self.skipTest('needs optuna')
        try:
            import optuna  # noqa: F401
        except ImportError:
            self.skipTest('needs optuna')
        axes = dict(grid=[6], rate=[1], tuning=['default'], pitch=['full'], modulation=['compact'],
                    couple=['legacy'], effect=['off'], allocation=['legacy'])
        model = surrogate.fit(synthetic_rows())
        study = tuner.Tuner(None, axes, portfolio.base_options(axes), multiplier=1, surrogate=model)
        self.assertIsNone(study.prune_rule())                       # nothing observed yet
        for rd, v2 in ((1.0, .5), (1.2, .45)):
            study.observe(dict(options=dict(profile='dynamic'), regdist=rd, audio=dict(score_v1=.9, score_v2=v2)))
        self.assertIsNotNone(study.prune_rule())
        rejected = surrogate.Surrogate(None, None, {}, 10, 2, dict(rmse_v2=.05, r2_v2=0.0, margin_v2=.1), reason='poor')
        study = tuner.Tuner(None, axes, portfolio.base_options(axes), multiplier=1, surrogate=rejected)
        study.observe(dict(options=dict(profile='dynamic'), regdist=1.0, audio=dict(score_v1=.9, score_v2=.5)))
        self.assertIsNone(study.prune_rule())
        self.assertFalse(study.prune_summary([])['surrogate']['used'])


# Polish --------------------------------------------------------------------

HEAD = b'CC2'
TARGET = {3: 20, 5: 7, 9: 31, 12: 2, 20: 99}


def fake_image(value=10):
    return bytearray([value] * 32)


def fake_data(image):
    return HEAD + zlib.compress(bytes(image), 6)


def score_of(image):
    """v2 is best when every target byte is reached; v1 falls when byte 20 is raised (to exercise the guard)."""
    v2 = 0.5 - 0.002 * sum(abs(image[a] - t) for a, t in TARGET.items() if a != 20) \
        - 0.0005 * abs(image[20] - TARGET[20])
    v1 = 0.9 - (0.03 if image[20] > 50 else 0.0)
    return dict(score_v1=v1, score_v2=v2)


def fake_edits(image, limit=None):
    edits = []
    for address in sorted(TARGET):
        for delta in (-4, -1, 1, 4):
            value = image[address] + delta
            if 0 <= value <= 255:
                edits.append(polish.Edit(f'b{address}{delta:+d}', ((address, value),)))
    return edits if limit is None else edits[:limit]


class FakeRunner:
    """Evaluates polish tasks with the fake scorer on a thread pool, finishing in a shuffled order."""

    def __init__(self, workers, clock=None, seconds_per_batch=0.0):
        self.workers, self.clock, self.seconds = workers, clock, seconds_per_batch
        self.calls = 0
        self.random = random.Random(workers)

    def run(self, tasks, deadline=None):
        self.calls += 1
        if self.clock is not None:
            self.clock.now += self.seconds

        def one(task):
            time.sleep(self.random.random() * 0.002)
            image = bytearray(zlib.decompress(task['data'][3:]))
            for address, value in task['edit'].writes:
                image[address] = value
            return dict(index=task['index'] if 'index' in task else 0, name=task['name'], changed=True,
                        regdist=1.0, audio=score_of(image), ct_path=f'ct{task["slot"]}', wav_path=f'wav{task["slot"]}')
        with ThreadPoolExecutor(self.workers) as pool:
            return list(pool.map(one, tasks))


class PolishTests(unittest.TestCase):
    def run_polish(self, workers, *, budget=None, reference_v1=0.9, effort='high'):
        image = fake_image()
        data = fake_data(image)
        ctx = SimpleNamespace(work_dir=tempfile.mkdtemp(), multiplier=1)
        with mock.patch.object(polish, 'enumerate_edits', fake_edits), \
                mock.patch.object(polish, 'distance_of', return_value=(1.0, [])):
            return polish.run(ctx, FakeRunner(workers), budget or budgets.Budget(1e9), data=data,
                              audio=score_of(image), opts=dict(rate=1), reference_v1=reference_v1, tolerance=0.01,
                              effort=effort), data

    def test_accepts_only_strict_improvements_and_keeps_the_guard(self):
        (found, stats), data = self.run_polish(2)
        self.assertTrue(found)
        image = zlib.decompress(found['data'][3:])
        self.assertGreater(stats['v2_after'], stats['v2_before'])
        self.assertAlmostEqual(stats['v2_after'], score_of(image)['score_v2'], places=6)
        self.assertEqual(found['audio'], score_of(image))
        self.assertGreaterEqual(stats['v1_after'], 0.9 - 0.01)       # the guard held
        for address, target in TARGET.items():
            if address != 20:
                self.assertEqual(image[address], target)             # every free byte reached its optimum
        self.assertLessEqual(image[20], 50)                          # raising byte 20 would break v1: refused
        self.assertEqual(stats['accepted'], len(stats['accepted_edits']))
        self.assertTrue(found['data'].startswith(HEAD))

    def test_nothing_accepted_returns_empty(self):
        with mock.patch.dict(TARGET, {a: 10 for a in TARGET}):
            (found, stats), _ = self.run_polish(2)
        self.assertEqual(found, {})
        self.assertEqual(stats['accepted'], 0)

    def test_result_does_not_depend_on_the_worker_count(self):
        outcomes = []
        for workers in (1, 3, 16):
            (found, stats), _ = self.run_polish(workers)
            outcomes.append((found['data'], stats['accepted_edits'], stats['v2_after'], stats['edits']))
        self.assertEqual(outcomes[0], outcomes[1])
        self.assertEqual(outcomes[0], outcomes[2])

    def test_budget_ends_the_polish_with_only_accepted_gains(self):
        class Tick:
            now = 0.0
        tick = Tick()
        budget = budgets.Budget(2.5, clock=lambda: tick.now)
        image = fake_image()
        ctx = SimpleNamespace(work_dir=tempfile.mkdtemp(), multiplier=1)
        runner = FakeRunner(2, clock=tick, seconds_per_batch=1.0)
        with mock.patch.object(polish, 'enumerate_edits', fake_edits), \
                mock.patch.object(polish, 'distance_of', return_value=(1.0, [])):
            found, stats = polish.run(ctx, runner, budget, data=fake_data(image), audio=score_of(image),
                                      opts=dict(rate=1), reference_v1=0.9, tolerance=0.01)
        self.assertEqual(stats['stopped'], 'budget')
        self.assertEqual(runner.calls, 3)                    # batches 1..3 ran, then the budget was gone
        self.assertLessEqual(stats['edits'], 3 * polish.BATCH)
        self.assertGreaterEqual(stats['v2_after'], stats['v2_before'])
        # An already expired budget evaluates nothing.
        tick.now = 100.0
        runner = FakeRunner(2, clock=tick)
        with mock.patch.object(polish, 'enumerate_edits', fake_edits), \
                mock.patch.object(polish, 'distance_of', return_value=(1.0, [])):
            found, stats = polish.run(ctx, runner, budget, data=fake_data(image), audio=score_of(image),
                                      opts=dict(rate=1), reference_v1=0.9, tolerance=0.01)
        self.assertEqual((found, runner.calls, stats['stopped']), ({}, 0, 'budget'))

    def test_high_effort_allows_more_passes_than_default(self):
        self.assertGreater(polish.EFFORT_LIMITS['high']['passes'], polish.EFFORT_LIMITS['default']['passes'])
        self.assertGreater(polish.EFFORT_LIMITS['high']['edits'], polish.EFFORT_LIMITS['default']['edits'])


class EditHelpers(unittest.TestCase):
    def test_bump_and_nibble_stay_in_range_and_skip_no_ops(self):
        image = bytearray([0, 15, 0xF3])
        edits = []
        polish._bump(edits, 'a', image, 0, (-1, 1, 4))
        self.assertEqual([e.writes[0][1] for e in edits], [1, 4])
        edits = []
        polish._nibble(edits, 'n', image, 2, True)
        self.assertEqual([e.writes[0][1] for e in edits], [0xE3])           # high nibble 15: only down
        edits = []
        polish._nibble(edits, 'n', image, 2, False)
        self.assertEqual(sorted(e.writes[0][1] for e in edits), [0xF2, 0xF4])

    def test_polish_flag_and_availability(self):
        import argparse
        from sid2ct import convert
        parser = argparse.ArgumentParser()
        convert.add_arguments(parser)
        self.assertTrue(parser.parse_args(['s.sid', '-o', 'o.ct']).polish)
        self.assertFalse(parser.parse_args(['s.sid', '-o', 'o.ct', '--no-polish']).polish)
        with mock.patch.dict(sys.modules, {'numpy': None}):
            self.assertFalse(polish.available())


if __name__ == '__main__':
    unittest.main()
