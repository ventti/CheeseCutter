import argparse
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from sid2ct.optimize import select_validated, parameter_search, suggest_options
from sid2ct.search import add_arguments, run_command


def diagnostic(score=.8):
    def windows():
        return [dict(start_seconds=0, end_seconds=5, audio={'similarity': score})]
    def voice():
        return dict(fixed_alignment={'similarity': score}, windows=windows())
    return dict(mix={'similarity': score}, mix_windows=windows(),
                voices={str(i): voice() for i in (1, 2, 3)},
                coupled_pairs={'12': voice()})


class RegressionSelection(unittest.TestCase):
    def setUp(self):
        self.records = [dict(name='before'), dict(name='trial')]
        self.report = {'candidates': {'before': diagnostic(), 'trial': diagnostic(.9)}}

    def test_better_mix_cannot_hide_voice_pair_or_window_loss(self):
        for category, key in [('voices', '2'), ('coupled_pairs', '12')]:
            for metric in ('fixed_alignment', 'windows'):
                with self.subTest(category=category, metric=metric):
                    report = json.loads(json.dumps(self.report))
                    data = report['candidates']['trial'][category][key]
                    target = data[metric] if metric == 'fixed_alignment' else data[metric][0]['audio']
                    target['similarity'] = .7
                    selected, rejected = select_validated(self.records, report)
                    self.assertEqual(selected['name'], 'before')
                    self.assertIn('trial', rejected)

    def test_improvement_and_explicit_tolerance(self):
        self.assertEqual(select_validated(self.records, self.report)[0]['name'], 'trial')
        self.report['candidates']['trial']['mix_windows'][0]['audio']['similarity'] = .799
        self.assertEqual(select_validated(self.records, self.report)[0]['name'], 'before')
        self.assertEqual(select_validated(self.records, self.report, .002)[0]['name'], 'trial')

    def test_missing_or_inconclusive_diagnostics_retain_before(self):
        self.assertEqual(select_validated(self.records, {})[0]['name'], 'before')
        self.report['candidates']['trial']['voices']['1']['fixed_alignment']['similarity'] = None
        self.assertEqual(select_validated(self.records, self.report)[0]['name'], 'before')
        del self.report['candidates']['trial']['mix_windows'][0]
        self.assertEqual(select_validated(self.records, self.report)[0]['name'], 'before')

    def test_mix_tie_keeps_before(self):
        self.report['candidates']['trial']['mix']['similarity'] = .8
        self.assertEqual(select_validated(self.records, self.report)[0]['name'], 'before')

    def test_joint_settings_and_unavailable_tuning(self):
        class Trial:
            def suggest_categorical(self, name, choices):
                return choices[0]
        options = suggest_options(Trial(), 6, False)
        self.assertFalse(options['joint_modeling'])
        self.assertEqual(options['tuning'], 'default')
        self.assertEqual(options['coupled_programs'], 'preserve')

    def test_missing_dependency_does_not_create_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)/'results'
            parser = argparse.ArgumentParser(); add_arguments(parser)
            args = parser.parse_args(['source.sid', '-o', str(output), '--optimizer', 'optuna'])
            with patch('sid2ct.optimize.load_optuna', side_effect=ValueError('Install Optuna')):
                self.assertEqual(run_command(args), 1)
            self.assertFalse(output.exists())


@unittest.skipUnless(importlib.util.find_spec('optuna'), 'Optional Optuna not installed')
class ParameterSearch(unittest.TestCase):
    def test_real_samplers_save_trials_failures_and_duplicate_results(self):
        for optimizer in ('optuna', 'random'):
            with self.subTest(optimizer=optimizer), tempfile.TemporaryDirectory() as directory:
                calls = []
                def build(name, options):
                    calls.append(name)
                    if len(calls) == 2:
                        raise ValueError('table capacity')
                    return b'identical', {'mix': {'similarity': .8}}
                result = parameter_search(build, output=Path(directory), optimizer=optimizer, cap=3)
                self.assertEqual(len(result['candidates']), 4)
                self.assertIn('error', result['candidates'][1])
                self.assertEqual(result['candidates'][2]['duplicate_of'], 'before')
                import optuna
                study = optuna.load_study(study_name=result['study_name'],
                                         storage='sqlite:///'+result['study_storage'])
                self.assertEqual(len(study.trials), 3)
                self.assertEqual(study.trials[0].state, optuna.trial.TrialState.FAIL)

    def test_repeated_settings_reuse_build_and_time_budget_stops_trials(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def build(name, options):
                calls.append(name)
                return b'ct', {'mix': {'similarity': .8}}
            with patch('sid2ct.optimize.suggest_options', return_value={'row_frames': 3}):
                result = parameter_search(build, output=Path(directory), optimizer='optuna', cap=3)
            self.assertEqual(len(calls), 2)
            self.assertEqual(result['candidates'][-1]['duplicate_of'], 'trial-0000')
            ticks = iter([0, 0, 2, 2, 2])
            result = parameter_search(build, output=Path(directory), optimizer='random', cap=3,
                                      seconds=1, clock=lambda: next(ticks))
            self.assertEqual(len(result['candidates']), 1)
            self.assertTrue(result['truncated'])

    def test_native_recovery_skips_parameter_trials(self):
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            def build(name, options):
                calls.append(name)
                return b'ct', {'mix': {'similarity': 1}, 'mode': 'recognized-cheesecutter'}
            result = parameter_search(build, output=Path(directory), optimizer='optuna')
            self.assertEqual(calls, ['before'])
            self.assertEqual(len(result['candidates']), 1)

    def test_search_checks_full_capture_and_keeps_baseline_on_regression(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sid = root/'source.sid'; sid.write_bytes(b'source')
            parser = argparse.ArgumentParser(); add_arguments(parser)
            args = parser.parse_args([str(sid), '-o', str(root/'results'), '--optimizer', 'optuna',
                                      '--candidate-cap', '1', '--audio-seconds', '1'])
            caches = []
            def convert(args):
                caches.append(args._input_cache)
                args.output.write_bytes(args.output.stem.encode())
                args.output.with_suffix('.json').write_text(json.dumps(dict(
                    audio_validation={'similarity': .8 if args.output.stem == 'before' else .9,
                                      'tested_seconds': 1}, captured_seconds=10)))
                return 0
            def compare(args):
                self.assertEqual(args.seconds, 10)
                entries = {item.split('=')[0]: diagnostic(.8 if item.startswith('before=') else .9)
                           for item in args.candidate}
                entries['trial-0000']['voices']['2']['windows'][0]['audio']['similarity'] = .7
                args.output.mkdir()
                (args.output/'report.json').write_text(json.dumps({'candidates': entries}))
                return 0
            with patch('sid2ct.search.convert.run_command', side_effect=convert), \
                 patch('sid2ct.search.compare.run_command', side_effect=compare):
                self.assertEqual(run_command(args), 0)
            self.assertIs(caches[0], caches[1])
            self.assertEqual((args.output/'selected.ct').read_bytes(), b'before')
            report = json.loads((args.output/'search.json').read_text())
            self.assertIn('trial-0000', report['rejected'])
