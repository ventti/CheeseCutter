import unittest
from sid2ct.search import bounded_search, select_by_mix

class HelperSearch(unittest.TestCase):
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
