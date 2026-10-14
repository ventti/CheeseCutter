"""Conversion flow bookkeeping: polish report, memory scores, diagnostics inside the budget, memory closed on error."""
import argparse
import copy
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from sid2ct import compare, convert, flow, portfolio
from tests.test_sid_reconstruct import unknown_sid

ROOT = Path(__file__).resolve().parents[1]


class FakeMemory:
    enabled = True

    def __init__(self, *args, **kwargs):
        self.recorded = []
        self.closed = False
        FakeMemory.last = self

    def record_best(self, *args):
        self.recorded.append(args)

    def close(self):
        self.closed = True

    def load_capture(self, key):
        return None

    def save_capture(self, key, value):
        pass


def options():
    return dict(grid=6, profile='dynamic', rate=1, tuning='default', pitch='full', modulation='compact',
                couple='legacy', effect='on', allocation='solve', layout='compact', effect_tolerance=12.0,
                solve_params=None)


class PolishBookkeeping(unittest.TestCase):
    def chosen(self):
        return dict(name='g6-x', options=options(), audio=dict(score_v1=.80, score_v2=.60),
                    report=dict(instruments=10, warnings=[], effects=dict(filter='global')))

    def stats(self):
        return dict(accepted=3, accepted_edits=['a', 'b', 'c'], passes=2, stopped='converged', seconds=12.5,
                    v1_after=.81, v2_after=.66, v2_gain=.06)

    def test_polished_report_marks_the_pre_polish_scores_and_leaves_the_original_alone(self):
        chosen = self.chosen()
        original = copy.deepcopy(chosen)
        report = flow.polished_report(chosen, self.stats())
        self.assertEqual(chosen, original)
        polish = report['polish']
        self.assertTrue(polish['applied'])
        self.assertEqual((polish['pre_polish_score_v2'], polish['v2_after'], polish['v2_gain']), (.60, .66, .06))
        self.assertEqual(report['instruments'], 10)

    def test_memory_gets_the_pre_polish_candidate_with_its_own_scores(self):
        chosen = self.chosen()
        polished = dict(chosen, name='g6-x+polish', audio=dict(score_v1=.81, score_v2=.66),
                        pre_polish=dict(name='g6-x', audio=chosen['audio'], options=chosen['options']))
        memory = FakeMemory()
        convert.remember_best(memory, 'song', 'family', polished, 1)
        (song, family, name, params, v1, v2), = memory.recorded
        self.assertEqual((song, family, name, v1, v2), ('song', 'family', 'g6-x', .80, .60))
        plain = FakeMemory()
        convert.remember_best(plain, 'song', 'family', chosen, 1)
        self.assertEqual(plain.recorded[0][2:3] + plain.recorded[0][4:], ('g6-x', .80, .60))

    def test_polish_reserve_is_small_with_a_floor_and_never_most_of_the_budget(self):
        self.assertAlmostEqual(flow.polish_reserve(528), 0.08 * 528)
        self.assertEqual(flow.polish_reserve(100), flow.POLISH_MIN_SECONDS)
        self.assertEqual(flow.polish_reserve(10), 5.0)


class AlternateFilter(unittest.TestCase):
    def run_prefer(self, mine, theirs):
        out = dict(report=dict(effects={}), ct_path='a.ct', audio=mine, wav_path='a.wav')
        other_report = dict(effects=dict(filter_distance=dict(chosen='global')))
        ctx = mock.Mock(subtune=1)
        with tempfile.TemporaryDirectory() as tmp, \
                mock.patch.object(portfolio, 'assess_file', return_value=(theirs, Path(tmp)/'b.wav')), \
                mock.patch.object(portfolio, 'register_parts', return_value=dict(total=1.5)):
            portfolio._prefer_by_audio(ctx, out, (b'CC2', other_report), tmp, options())
        return out

    def test_better_v2_wins_when_v1_holds(self):
        out = self.run_prefer(dict(score_v1=.7, score_v2=.5), dict(score_v1=.8, score_v2=.7))
        self.assertEqual(out['audio']['score_v2'], .7)
        self.assertEqual(out['regdist'], 1.5)
        self.assertEqual(out['report']['effects']['filter_selection'], 'audio')

    def test_a_v1_loss_beyond_the_tolerance_or_a_lower_v2_keeps_the_first(self):
        kept = self.run_prefer(dict(score_v1=.9, score_v2=.5), dict(score_v1=.5, score_v2=.7))
        self.assertEqual(kept['audio']['score_v2'], .5)
        kept = self.run_prefer(dict(score_v1=.7, score_v2=.6), dict(score_v1=.8, score_v2=.5))
        self.assertEqual(kept['audio']['score_v2'], .6)


class DiagnosticsDeadline(unittest.TestCase):
    def test_reserve_scales_with_the_audio_and_has_a_margin(self):
        from sid2ct import budget
        long_song = budget.diagnostics_reserve(600, 325)
        self.assertAlmostEqual(long_song, 0.12 * 600 + 0.02 * 600)       # capped by the share
        short = budget.diagnostics_reserve(300, 60)
        self.assertAlmostEqual(short, 10 + 0.24 * 60 + 0.02 * 300)
        self.assertLess(short, 0.12 * 300 + 0.02 * 300)

    def test_windows_stop_at_the_deadline(self):
        def late():
            raise compare.DeadlineExceeded('late')
        with self.assertRaises(compare.DeadlineExceeded):
            compare.window_comparisons(Path('a.wav'), Path('b.wav'), Path('.'), 10.0, 1.0, 0, late)


@unittest.skipUnless((ROOT/'ct2util').is_file(), 'needs ct2util')
class MemoryClosedOnError(unittest.TestCase):
    def test_memory_is_closed_when_the_conversion_fails(self):
        parser = argparse.ArgumentParser()
        convert.add_arguments(parser)
        with tempfile.TemporaryDirectory() as tmp:
            sid = Path(tmp)/'source.sid'
            sid.write_bytes(unknown_sid())
            args = parser.parse_args([str(sid), '-o', str(Path(tmp)/'out.ct'), '--force', '--seconds', '1',
                                      '--multiplier', '2', '--skip-audio'])
            with mock.patch.object(convert, 'Memory', FakeMemory), \
                    mock.patch.object(convert, 'convert_search', side_effect=ValueError('boom')):
                self.assertEqual(convert.run_command(args), 1)
        self.assertTrue(FakeMemory.last.closed)


if __name__ == '__main__':
    unittest.main()
