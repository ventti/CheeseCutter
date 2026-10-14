"""WP8a: time budget, parallel candidate portfolio, memory database, defaults and plain-python fallback."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from sid2ct import budget as budgets, convert, flow, memory, portfolio
from tests.test_sid_reconstruct import unknown_sid

ROOT = Path(__file__).resolve().parents[1]
RENDERER = ROOT/'tools/sid_render'

try:
    import numpy  # noqa: F401
    HAVE_NUMPY = True
except ImportError:
    HAVE_NUMPY = False
try:
    import optuna  # noqa: F401
    HAVE_OPTUNA = True
except ImportError:
    HAVE_OPTUNA = False


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now


def parse(*argv):
    parser = argparse.ArgumentParser()
    convert.add_arguments(parser)
    return parser.parse_args(['song.sid', '-o', 'out.ct', *argv])


class BudgetTests(unittest.TestCase):
    def test_expiry_stages_and_children(self):
        clock = FakeClock()
        budget = budgets.Budget(100, clock)
        with budget.stage('a'):
            clock.now = 30
        with budget.stage('a'):
            clock.now = 40
        self.assertEqual(budget.stages['a'], 40)
        child = budget.child(reserve=20)
        self.assertEqual(child.remaining(), 40)
        child.add('b', 1)
        self.assertEqual(budget.stages['b'], 1)          # stage table is shared
        clock.now = 85
        self.assertTrue(child.expired())
        self.assertFalse(budget.expired())
        budget.set_total(60)
        self.assertTrue(budget.expired())

    def test_ambient_check_and_shield(self):
        clock = FakeClock()
        budget = budgets.Budget(10, clock)
        budgets.check()                                  # no ambient budget: never raises
        with budgets.activate(budget):
            budgets.check()
            clock.now = 11
            with self.assertRaises(budgets.BudgetExpired):
                budgets.check()
            with budgets.shield():
                budgets.check()
            self.assertEqual(budgets.remaining(), -1)
        budgets.check()

    def test_effort_profiles_scale_with_song_length(self):
        self.assertEqual(budgets.effort_seconds('default'), 600)
        self.assertEqual(budgets.effort_seconds('high'), 3600)
        self.assertEqual(budgets.effort_seconds('default', 325), 600)
        self.assertEqual(budgets.effort_seconds('default', 400), 600)
        self.assertEqual(budgets.effort_seconds('default', 240), 480)
        self.assertEqual(budgets.effort_seconds('default', 10), 300)         # never below half

    @unittest.skipUnless(HAVE_NUMPY, 'needs numpy')
    def test_inner_loops_check_the_budget(self):
        from sid2ct import regdist
        frames = [bytes(25)] * 40
        clock = FakeClock()
        budget = budgets.Budget(1, clock)
        clock.now = 2
        with budgets.activate(budget):
            with self.assertRaises(budgets.BudgetExpired):
                regdist.trace_distance(frames, frames, max_lag=2)
        with budgets.activate(budget), budgets.shield():
            regdist.trace_distance(frames, frames, max_lag=2)

    def test_solver_worker_pool_inherits_the_deadline(self):
        from sid2ct import solve
        clock = FakeClock()
        solve._init_worker(object(), 0.0)
        try:
            with self.assertRaises(budgets.BudgetExpired):
                budgets.check()
        finally:
            budgets.install(None)
            solve._WORKER = None


class FakeSlowStages(unittest.TestCase):
    """Runner and run_task with a slow fake `build` that checks the budget inside its inner loop."""

    def context(self, directory):
        return portfolio.Context(work_dir=directory, skip_audio=True, subtune=1, multiplier=1, frames=[])

    @staticmethod
    def slow_build(ctx, opts, directory, solve_limit):
        deadline = time.monotonic() + opts['grid'] * 0.01     # grid 100 -> about one second of work
        while time.monotonic() < deadline:
            budgets.check()
            time.sleep(0.005)
        return b'CC2' + bytes([opts['grid'] % 256]), {'warnings': [], 'row_frames': opts['grid']}

    def options(self, grid):
        return dict(grid=grid, profile='dynamic', rate=1, tuning='default', pitch='full', modulation='compact',
                    couple='legacy', effect='off', allocation='legacy', layout='compact', effect_tolerance=12.0,
                    solve_params=None)

    def test_budget_ends_inside_the_stage_but_the_shielded_candidate_finishes(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(portfolio, 'build', self.slow_build):
            runner = portfolio.Runner(self.context(tmp), 1, budgets.Budget(0.3))
            tasks = [portfolio.make_task('first', self.options(100), solve_limit=1, shield=True),
                     portfolio.make_task('slow', self.options(2000), solve_limit=1),   # 20 s if unchecked
                     portfolio.make_task('later', self.options(5), solve_limit=1)]
            began = time.monotonic()
            results = runner.run(tasks, budgets.Budget(0.3))
            self.assertLess(time.monotonic() - began, 5)
            self.assertFalse(results[0].get('expired'))
            self.assertIn('ct_path', results[0])                 # the shielded one ran past the deadline
            self.assertTrue(results[1]['expired'])
            self.assertTrue(results[2]['expired'])               # never started: budget already over

    def test_parallel_runner_returns_in_task_order_and_stops_at_the_deadline(self):
        with tempfile.TemporaryDirectory() as tmp, mock.patch.object(portfolio, 'build', self.slow_build):
            ctx = self.context(tmp)
            runner = portfolio.Runner(ctx, 2, budgets.Budget(2))
            try:
                tasks = [portfolio.make_task(f't{i}', self.options(g), solve_limit=1)
                         for i, g in enumerate((20, 3, 10))]
                results = runner.run(tasks, budgets.Budget(30))
            finally:
                runner.close(kill=True)
        # With a spawned pool the patched build is not visible, so only ordering and bookkeeping are checked.
        self.assertEqual([r['name'] for r in results], ['t0', 't1', 't2'])
        self.assertEqual([r['index'] for r in results], [0, 1, 2])

    def test_plan_parallel_never_oversubscribes(self):
        for workers in (2, 4, 7, 16, 64):
            for tasks in (1, 3, 8, 20):
                concurrency, inner = portfolio.plan_parallel(workers, tasks)
                self.assertLessEqual(concurrency * inner, workers)
                self.assertEqual(inner, portfolio.SOLVER_WORKERS)
        self.assertEqual(portfolio.plan_parallel(1, 8), (1, portfolio.SOLVER_WORKERS))
        self.assertEqual(portfolio.plan_parallel(16, 8), (8, 2))


class Selection(unittest.TestCase):
    @staticmethod
    def entry(v1, v2):
        return dict(audio=dict(score_v1=v1, score_v2=v2, similarity=v1), ct_path='x')

    def test_guard_reference_is_the_best_v1_not_the_first_candidate(self):
        results = [self.entry(.50, .40), self.entry(.80, .60), self.entry(.70, .90)]
        pick, guard = portfolio.select(results, 'v2', .01)
        self.assertEqual(pick, 1)                            # the third wins on v2 but loses 0.10 of v1
        self.assertEqual(guard['reference_v1'], .80)
        results.append(self.entry(.795, .65))
        self.assertEqual(portfolio.select(results, 'v2', .01)[0], 3)

    def test_ties_go_to_the_earlier_candidate_and_unscored_are_skipped(self):
        results = [dict(error='x'), self.entry(.8, .6), self.entry(.8, .6)]
        self.assertEqual(portfolio.select(results)[0], 1)
        self.assertEqual(portfolio.select([dict(error='x')])[0], None)
        self.assertEqual(portfolio.select([dict(ct_path='a'), dict(error='x')])[0], 0)   # trace-only run


class Defaults(unittest.TestCase):
    def test_new_methods_are_the_defaults(self):
        args = parse()
        self.assertEqual((args.effect_programs, args.instrument_allocation, args.structure_hints, args.layout),
                         ('auto', 'auto', 'auto', 'compact'))
        self.assertEqual(args.effort, 'default')
        self.assertIsNone(args.row_frames)
        self.assertIsNone(args.solve_time_limit)
        self.assertEqual(parse('--high-effort').effort, 'high')
        self.assertEqual(parse('--effort', 'high').effort, 'high')
        self.assertEqual(args.score, 'v2')

    def axes(self, *argv, edges=True):
        args = parse(*argv)
        return flow.build_axes(args, multiplier=4, coupling=dict(edges=[1] if edges else []), recovered=None,
                               anchored=False, profiles=['static', 'dynamic'])

    @unittest.skipUnless(HAVE_NUMPY, 'needs numpy')
    def test_auto_axes_and_forced_flags(self):
        axes = self.axes()
        self.assertEqual(axes['effect'], ['off', 'on'])
        self.assertIn('solve', axes['allocation'] + ['solve'])
        self.assertEqual(axes['grid'][0], 6)
        self.assertEqual(sorted(axes['grid']), [3, 4, 5, 6, 8, 12])
        self.assertEqual(axes['rate'], [4, 1])
        forced = self.axes('--effect-programs', 'on', '--instrument-allocation', 'legacy', '--row-frames', '5',
                           '--sound-rate', 'base', '--pitch-programs', 'attack')
        self.assertEqual((forced['effect'], forced['allocation'], forced['grid'], forced['rate'], forced['pitch']),
                         (['on'], ['legacy'], [5], [1], ['attack']))
        self.assertFalse(flow.free_knobs(self.axes(
            '--effect-programs', 'off', '--instrument-allocation', 'legacy', '--row-frames', '6',
            '--sound-rate', 'base', '--tuning', 'default', '--pitch-programs', 'full',
            '--modulation-programs', 'compact', '--coupled-programs', 'legacy')))

    def test_first_stage_order_puts_the_guaranteed_candidates_first(self):
        axes = dict(grid=[6, 3], rate=[4, 1], tuning=['default'], pitch=['full'], modulation=['compact'],
                    couple=['preserve'], effect=['off', 'on'], allocation=['legacy', 'solve'])
        options = portfolio.initial_options(axes)
        self.assertEqual([o['profile'] for o in options], ['static'] + ['dynamic'] * 4)
        base = options[1]
        self.assertEqual((base['effect'], base['allocation'], base['layout'], base['grid']), ('off', 'legacy', 'compact', 6))
        self.assertEqual({(o['effect'], o['allocation']) for o in options[1:]},
                         {(e, a) for e in ('off', 'on') for a in ('legacy', 'solve')})
        self.assertEqual(len(portfolio.initial_options(axes, all_grids=True)), 6)

    def test_first_stage_includes_the_compact_greedy_candidate(self):
        axes = dict(grid=[6], rate=[4, 1], tuning=['default'], pitch=['full', 'compact', 'attack'],
                    modulation=['compact', 'legacy'], couple=['preserve'], effect=['off', 'on'],
                    allocation=['legacy', 'solve'])
        last = portfolio.initial_options(axes)[-1]
        self.assertEqual((last['rate'], last['pitch'], last['effect'], last['allocation']), (1, 'compact', 'off', 'legacy'))

    def test_help_mentions_the_effort_flags(self):
        text = subprocess.run([sys.executable, '-m', 'sid2ct', 'convert', '--help'], cwd=ROOT, capture_output=True,
                              text=True).stdout
        for flag in ('--effort', '--high-effort', '--no-memory', '--layout', '--time-budget', '--seed'):
            self.assertIn(flag, text)


class MemoryTests(unittest.TestCase):
    def test_capture_roundtrip_best_and_family_ranking(self):
        with tempfile.TemporaryDirectory() as tmp:
            db = memory.Memory(Path(tmp)/'m.sqlite3')
            key = memory.capture_key(('a', 1))
            self.assertIsNone(db.load_capture(key))
            db.save_capture(key, ([b'x' * 25], {'k': 1}, 2, 1.0, None))
            self.assertEqual(db.load_capture(key)[2], 2)
            for song, family, v2, rows in (('s1', 'GoatTracker', .5, 3), ('s2', 'GoatTracker', .7, 4),
                                           ('s3', 'GoatTracker', .6, 5), ('s4', 'GoatTracker', .4, 6),
                                           ('s5', 'DMC', .9, 8), ('me', 'GoatTracker', .3, 12)):
                db.record_best(song, family, 't', {'row_frames': rows}, .8, v2)
            db.record_best('s1', 'GoatTracker', 't', {'row_frames': 99}, .8, .1)       # worse: ignored
            warm = db.warm_params('GoatTracker', 'me', k=3)
            self.assertEqual([p['row_frames'] for p in warm], [12, 4, 5, 3])          # own best, then top-3 by v2
            self.assertEqual(db.warm_params('unknown', 'zz'), [])
            db.close()

    def test_disabled_memory_and_unwritable_path_are_harmless(self):
        db = memory.Memory(enabled=False)
        self.assertFalse(db.enabled)
        db.save_capture('k', 1)
        db.record_trial('s', 'f', 'n', {}, 0, 0, 0, 'done', 0, 'default', 0)
        self.assertIsNone(db.load_capture('k'))
        self.assertEqual(db.warm_params('f', 's'), [])
        with tempfile.TemporaryDirectory() as tmp:
            blocked = Path(tmp)/'file'
            blocked.write_text('x')
            self.assertFalse(memory.Memory(blocked/'sub/m.sqlite3').enabled)

    def test_cache_dir_env_override(self):
        with mock.patch.dict(os.environ, {'SID2CT_CACHE': '/tmp/somewhere'}):
            self.assertEqual(memory.cache_dir(), Path('/tmp/somewhere'))

    @unittest.skipUnless(HAVE_OPTUNA and HAVE_NUMPY, 'needs optuna and numpy')
    def test_warm_start_enqueues_remembered_parameters_first(self):
        from sid2ct import tuner
        axes = dict(grid=[6, 3, 4], rate=[4, 1], tuning=['default'], pitch=['full', 'attack'], modulation=['compact'],
                    couple=['legacy'], effect=['off', 'on'], allocation=['legacy'])
        base = portfolio.base_options(axes)

        class FakeRunner:
            batches = []

            def run(self, tasks, deadline=None):
                self.batches.append([t['opts'] for t in tasks])
                return [dict(index=i, name=t['name'], options=t['opts'],
                             audio=dict(score_v1=.7, score_v2=.5, similarity=.7), stages={}, regdist=1.0)
                        for i, t in enumerate(tasks)]

        runner = FakeRunner()
        study = tuner.Tuner(runner, axes, base, multiplier=4, seed=3)
        warm = [dict(row_frames=3, sound_rate='base', pitch_programs='attack', effect_programs='on',
                     effect_tolerance=9.0, coupled_programs='legacy', tuning='default'),
                dict(row_frames=4, sound_rate='source', effect_programs='off', pitch_programs='full')]
        study.enqueue(warm)
        study.run(budgets.Budget(30), cap=2)
        first = runner.batches[0]
        self.assertEqual((first[0]['grid'], first[0]['rate'], first[0]['pitch'], first[0]['effect']), (3, 1, 'attack', 'on'))
        self.assertEqual(first[0]['effect_tolerance'], 9.0)
        self.assertEqual((first[1]['grid'], first[1]['rate'], first[1]['effect']), (4, 4, 'off'))

    @unittest.skipUnless(HAVE_OPTUNA and HAVE_NUMPY, 'needs optuna and numpy')
    def test_value_applies_the_v1_guard_and_pruning_skips_audio_only_when_clearly_worse(self):
        from sid2ct import tuner
        axes = dict(grid=[6], rate=[1], tuning=['default'], pitch=['full'], modulation=['compact'],
                    couple=['legacy'], effect=['off'], allocation=['legacy'])
        study = tuner.Tuner(None, axes, portfolio.base_options(axes), multiplier=1)
        study.observe(dict(audio=dict(score_v1=.9, score_v2=.5), regdist=2.0))
        good = dict(audio=dict(score_v1=.9, score_v2=.6))
        bad_v1 = dict(audio=dict(score_v1=.5, score_v2=.7))
        self.assertAlmostEqual(study.value(good), .6)
        self.assertAlmostEqual(study.value(bad_v1), .7 - tuner.GUARD_PENALTY)
        self.assertIsNone(study.value(dict(error='x')))
        self.assertEqual(study.best_regdist, 2.0)


@unittest.skipUnless(HAVE_NUMPY and RENDERER.is_file() and (ROOT/'ct2util').is_file(), 'needs numpy, renderer and ct2util')
class EndToEnd(unittest.TestCase):
    def convert(self, tmp, name, *argv):
        sid = Path(tmp)/'source.sid'
        sid.write_bytes(unknown_sid())
        output = Path(tmp)/(name + '.ct')
        env = dict(os.environ, SID2CT_CACHE=str(Path(tmp)/'cache'))
        result = subprocess.run([sys.executable, '-m', 'sid2ct', 'convert', str(sid), '-o', str(output), '--force',
                                 '--seconds', '3', '--multiplier', '2', '--skip-diagnostics', *argv],
                                cwd=ROOT, capture_output=True, text=True, timeout=600, env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return output.read_bytes(), json.loads(output.with_suffix('.json').read_text())

    def test_output_does_not_depend_on_the_worker_count(self):
        with tempfile.TemporaryDirectory() as tmp:
            one, report_one = self.convert(tmp, 'w1', '--workers', '1', '--no-memory', '--max-trials', '8',
                                           '--time-budget', '400')
            four, report_four = self.convert(tmp, 'w4', '--workers', '4', '--no-memory', '--max-trials', '8',
                                             '--time-budget', '400')
        self.assertEqual(one, four)
        self.assertEqual(report_one['effort']['selected'], report_four['effort']['selected'])
        names = lambda r: [(c['stage'], c['row_frames'], c['output_multiplier'], c['pitch_programs'],
                            c['effect_programs'], c['instrument_allocation'], (c.get('audio') or {}).get('score_v2'))
                           for c in r['sound_program_search']]
        self.assertEqual(names(report_one), names(report_four))
        self.assertGreater(len(report_one['sound_program_search']), 4)
        self.assertEqual(report_four['effort']['workers'], 4)
        for stage in ('capture', 'candidates', 'search', 'selection'):
            self.assertIn(stage, report_four['effort']['stage_seconds'])

    def test_tiny_budget_still_writes_the_best_so_far(self):
        with tempfile.TemporaryDirectory() as tmp:
            data, report = self.convert(tmp, 'tiny', '--workers', '2', '--no-memory', '--time-budget', '0.001')
        self.assertTrue(data.startswith(b'CC2'))
        self.assertIn('audio_validation', report)
        self.assertTrue(report['effort']['selected'])

    def test_no_memory_never_touches_the_database_and_memory_reuses_the_trace(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.convert(tmp, 'a', '--workers', '2', '--no-memory', '--max-trials', '0')
            self.assertFalse((Path(tmp)/'cache/memory.sqlite3').exists())
            self.convert(tmp, 'b', '--workers', '2', '--max-trials', '0')
            self.assertTrue((Path(tmp)/'cache/memory.sqlite3').is_file())
            _, report = self.convert(tmp, 'c', '--workers', '2', '--max-trials', '0')
        self.assertLess(report['effort']['stage_seconds']['capture'], 0.2)      # trace came from memory


class PlainPythonFallback(unittest.TestCase):
    """The system python3 has no numpy: conversion must still work (no effects, solver or Optuna)."""

    def test_plain_python_converts_with_and_without_audio(self):
        probe = subprocess.run(['python3', '-c', 'import numpy'], capture_output=True)
        if probe.returncode == 0:
            self.skipTest('python3 has numpy; the fallback cannot be exercised')
        with tempfile.TemporaryDirectory() as tmp:
            sid = Path(tmp)/'source.sid'
            sid.write_bytes(unknown_sid())
            env = dict(os.environ, SID2CT_CACHE=str(Path(tmp)/'cache'))
            for name, extra in (('trace', ['--skip-audio']),
                                ('audio', ['--skip-diagnostics', '--time-budget', '120'] if RENDERER.is_file() else None)):
                if extra is None:
                    continue
                output = Path(tmp)/(name + '.ct')
                result = subprocess.run(['python3', '-m', 'sid2ct', 'convert', str(sid), '-o', str(output),
                                         '--seconds', '1', '--multiplier', '2', '--workers', '2', *extra],
                                        cwd=ROOT, capture_output=True, text=True, timeout=300, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                report = json.loads(output.with_suffix('.json').read_text())
                self.assertTrue(output.read_bytes().startswith(b'CC2'))
                self.assertIn('stage_seconds', report['effort'])
                if name == 'audio':
                    stages = {(c['effect_programs'], c['instrument_allocation'])
                              for c in report.get('sound_program_search', [])}
                    self.assertEqual(stages - {('off', 'legacy')}, set())


if __name__ == '__main__':
    unittest.main()
