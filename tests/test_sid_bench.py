import tempfile
import unittest
from pathlib import Path

from sid2ct import bench


def report(mix=0.8, voices=(0.7, 0.75, None)):
    data = {'audio_validation': {'similarity': mix}, 'instruments': 47, 'approximated_instrument_attacks': 12,
            'observed_instrument_variants': 90,
            'diagnostics': {'candidates': {'reconstruction': {'voices': {}}}}}
    for number, value in enumerate(voices, 1):
        data['diagnostics']['candidates']['reconstruction']['voices'][str(number)] = {
            'fixed_alignment': {'similarity': value, 'verdict': 'inconclusive' if value is None else 'different'}}
    return data


class Bench(unittest.TestCase):
    def test_extract_scores(self):
        scores = bench.extract_scores(report())
        self.assertEqual((scores['mix'], scores['voice1'], scores['voice2'], scores['voice3']), (0.8, 0.7, 0.75, None))
        self.assertEqual((scores['instruments'], scores['approximated_attacks'], scores['observed_variants']), (47, 12, 90))
        empty = bench.extract_scores({})
        self.assertTrue(all(v is None for v in empty.values()))

    def test_v1_and_v2_scores_are_recorded_and_regressions_listed(self):
        def scored(v1, v2):
            data = report(v1)
            data['audio_validation'].update(score_v1=v1, score_v2=v2)
            return data
        self.assertEqual(bench.extract_scores(scored(.8, .6))['score_v2'], .6)
        # A report that predates score_v1 falls back to its similarity.
        self.assertEqual(bench.extract_scores(report(.7))['score_v1'], .7)
        self.assertIsNone(bench.extract_scores(report(.7))['score_v2'])
        with tempfile.TemporaryDirectory() as directory:
            db = bench.connect(Path(directory)/'b.sqlite3')
            entry = {'split': 'dev', 'composer': 'TBB'}
            base = bench.start_run(db, 'baseline', 'abc', {})
            new = bench.start_run(db, 'try', 'def', {})
            for name, before, after in (('TBB__A', (.80, .60), (.78, .62)), ('TBB__B', (.70, .50), (.71, .52))):
                bench.record(db, base, entry, name, 'ok', None, 1.0, bench.extract_scores(scored(*before)), 'r.json')
                bench.record(db, new, entry, name, 'ok', None, 1.0, bench.extract_scores(scored(*after)), 'r.json')
            table = bench.format_table(db, new, base)
            self.assertIn('mean score_v1 dev: 0.7450 (n=2)', table)
            self.assertIn('mean score_v2 dev: 0.5700 (n=2), mean delta +0.0200', table)
            self.assertIn('regression TBB__A: score_v1 -0.0200 score_v2 +0.0200', table)
            self.assertNotIn('regression TBB__B', table)

    def test_effect_programs_passthrough(self):
        command = bench.convert_command(Path('a.sid'), Path('o.ct'), {'subtune': 1}, 60, False, 'off')
        self.assertEqual(command[command.index('--effect-programs')+1], 'off')
        self.assertNotIn('--effect-programs', bench.convert_command(Path('a.sid'), Path('o.ct'), {'subtune': 1}, 60, False))

    def test_select_songs(self):
        songs = [{'path': 'MUSICIANS/T/TBB/Viidakko.sid', 'composer': 'TBB', 'split': 'dev'},
                 {'path': 'MUSICIANS/P/PRI/Foo.sid', 'composer': 'PRI', 'split': 'heldout'}]
        self.assertEqual(len(bench.select_songs(songs, 'all')), 2)
        self.assertEqual(bench.select_songs(songs, 'heldout')[0]['composer'], 'PRI')
        self.assertEqual(bench.select_songs(songs, 'all', '*viidakko*')[0]['composer'], 'TBB')
        self.assertEqual(bench.song_name(songs[0]), 'TBB__Viidakko')

    def test_convert_command(self):
        entry = {'subtune': 2}
        command = bench.convert_command(Path('a.sid'), Path('o.ct'), entry, 60, False)
        self.assertIn('--seconds', command)
        self.assertEqual(command[command.index('--subtune')+1], '2')
        self.assertNotIn('--seconds', bench.convert_command(Path('a.sid'), Path('o.ct'), entry, 60, True))

    def test_failure_reason(self):
        self.assertEqual(bench.failure_reason('x\nerror: bad header\n'), 'error: bad header')
        self.assertEqual(bench.failure_reason(''), 'no output')

    def test_db_record_and_delta(self):
        with tempfile.TemporaryDirectory() as directory:
            db = bench.connect(Path(directory)/'b.sqlite3')
            entry = {'split': 'dev', 'composer': 'TBB'}
            base = bench.start_run(db, 'baseline', 'abc', {})
            bench.record(db, base, entry, 'TBB__A', 'ok', None, 1.0, bench.extract_scores(report(0.70)), 'r.json')
            bench.record(db, base, entry, 'TBB__B', 'error', 'boom', 1.0, bench.extract_scores({}), 'r.json')
            new = bench.start_run(db, 'try', 'def', {})
            bench.record(db, new, entry, 'TBB__A', 'ok', None, 1.0, bench.extract_scores(report(0.75)), 'r.json')
            self.assertEqual(bench.previous_run(db, 'baseline', new), base)
            self.assertIsNone(bench.previous_run(db, 'baseline', base))
            rows = bench.deltas(db, new, base)
            self.assertAlmostEqual(rows[0][4], 0.05)
            table = bench.format_table(db, new, base)
            self.assertIn('+0.0500', table)
            self.assertIn('mean mix dev: 0.7500', table)
            self.assertIn('1 ok, 0 failed', table)
            self.assertIn('boom', bench.format_table(db, base, None))

    def test_run_song_records_failure_and_timeout(self):
        entry = {'path': 'x.sid', 'subtune': 1, 'composer': 'C', 'split': 'dev'}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            status, error, _, scores, _ = bench.run_song(entry, root, root/'song', 60, False, timeout=60)
            self.assertEqual(status, 'error')
            self.assertTrue(error)
            self.assertIsNone(scores['mix'])
            self.assertTrue((root/'song/convert.log').is_file())


if __name__ == '__main__':
    unittest.main()
