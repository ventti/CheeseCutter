import unittest
import argparse
import json
from pathlib import Path
import tempfile
from unittest.mock import patch
from sid2ct.search import add_arguments, run_command
from sid2ct.search import bounded_search, select_by_mix

class HelperSearch(unittest.TestCase):
    def test_force_reuses_existing_outputs_and_diagnostics(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            sid = root/'source.sid'; sid.write_bytes(b'source')
            output = root/'results'; output.mkdir()
            (output/'before.ct').write_bytes(b'old')
            (output/'keep.txt').write_text('keep')
            diagnostics = output/'diagnostics'; diagnostics.mkdir()
            (diagnostics/'old.json').write_text('{}')
            parser = argparse.ArgumentParser(); add_arguments(parser)
            args = parser.parse_args([str(sid), '-o', str(output), '--candidate-cap', '0'])
            def convert(args):
                self.assertTrue(args.force)
                args.output.write_bytes(b'new')
                args.output.with_suffix('.json').write_text(json.dumps({
                    'audio_validation': {'similarity': .8, 'tested_seconds': 1}}))
                return 0
            def compare(args):
                self.assertFalse(args.output.exists())
                args.output.mkdir()
                (args.output/'report.json').write_text('{}')
                return 0
            with patch('sid2ct.search.convert.run_command', side_effect=convert) as conversion, \
                 patch('sid2ct.search.compare.run_command', side_effect=compare):
                self.assertEqual(run_command(args), 1)
                conversion.assert_not_called()
                args.force = True
                self.assertEqual(run_command(args), 0)
            self.assertEqual((output/'before.ct').read_bytes(), b'new')
            self.assertEqual((output/'selected.ct').read_bytes(), b'new')
            self.assertEqual((output/'keep.txt').read_text(), 'keep')
            self.assertFalse((diagnostics/'old.json').exists())

    def test_cap_retains_before_and_errors(self):
        calls=[]
        def build(name,options):
            calls.append(name)
            if name=='trajectory': raise ValueError('capacity')
            return b'ct',dict(mix={'similarity':.8})
        result=bounded_search(build,cap=2)
        self.assertEqual(calls,['before','change-points','trajectory'])
        self.assertEqual(result['candidates'][1]['duplicate_of'],'before')
        self.assertEqual(result['candidates'][2]['error'],'capacity')
        self.assertTrue(result['truncated'])

    def test_elapsed_budget_prevents_next_build(self):
        ticks=iter([0,0,2,2,2])
        calls=[]
        def build(name,options):
            calls.append(name)
            return b'ct',{}
        result=bounded_search(build,seconds=1,clock=lambda:next(ticks))
        self.assertEqual(calls,['before'])
        self.assertTrue(result['truncated'])

    def test_failed_before_stops_experiments(self):
        def build(name,options): raise ValueError('unavailable')
        self.assertEqual(len(bounded_search(build)['candidates']),1)

    def test_selection_retains_before_on_ties_and_ignores_failed(self):
        before=dict(name='before',mix={'similarity':.8})
        after=dict(name='trajectory',mix={'similarity':.8})
        self.assertIs(select_by_mix([before,after]),before)
        after['mix']['similarity']=.9
        self.assertIs(select_by_mix([before,after]),after)
        after['error']='export failed'
        self.assertIs(select_by_mix([before,after]),before)
