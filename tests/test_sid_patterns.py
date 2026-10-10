import random
import unittest
from sid2ct.patterns import mine_patterns


def rows(*notes):
    return tuple((note, 1, 0, 0) for note in notes)


class PatternTests(unittest.TestCase):
    def test_motif_not_aligned_to_fixed_chunks(self):
        voice = rows(1, 2, 3, 4, 5) * 9
        plan = mine_patterns((voice,), max_pattern_length=8)
        self.assertEqual(plan.expand(), (voice,))
        self.assertEqual(len(plan.patterns), 1)
        self.assertEqual(len(plan.patterns[0]), 5)

    def test_intro_loop_and_physical_silent_voice(self):
        voices = (rows(9, 8, 1, 2, 1, 2), rows(0)*6, rows(1, 2)*3)
        plan = mine_patterns(voices, loop_start=2, max_pattern_length=4)
        self.assertEqual(plan.expand(), voices)
        for order, restart in zip(plan.orders, plan.restarts):
            self.assertEqual(sum(len(plan.patterns[i]) for i in order[:restart]), 2)
        self.assertEqual(len(plan.orders), 3)

    def test_cross_voice_dedup_preserves_order(self):
        voices = (rows(1, 2)*4, rows(3, 4)*4, rows(1, 2)*4)
        plan = mine_patterns(voices, max_pattern_length=2)
        self.assertEqual(plan.orders[0], plan.orders[2])
        self.assertNotEqual(plan.orders[0], plan.orders[1])
        self.assertEqual(plan.expand(), voices)

    def test_budget_fallback_and_determinism(self):
        voices = (rows(*range(100)),)
        plan = mine_patterns(voices, loop_start=17, search_row_budget=13)
        self.assertLessEqual(plan.search_rows, 13)
        self.assertTrue(plan.search_exhausted)
        self.assertEqual(plan, mine_patterns(voices, loop_start=17, search_row_budget=13))
        self.assertEqual(plan.expand(), voices)
        self.assertTrue(all(1 <= len(p) <= 64 for p in plan.patterns))

    def test_random_roundtrips(self):
        rng = random.Random(83)
        for _ in range(50):
            n = rng.randrange(1, 90)
            voices = tuple(rows(*(rng.randrange(4) for _ in range(n))) for _ in range(3))
            boundary = rng.randrange(n)
            plan = mine_patterns(voices, loop_start=boundary,
                                 max_pattern_length=7, search_row_budget=500)
            self.assertEqual(plan.expand(), voices)
            for order, restart in zip(plan.orders, plan.restarts):
                self.assertEqual(sum(len(plan.patterns[i]) for i in order[:restart]), boundary)

    def test_control_difference_is_exact(self):
        voices = (((1, 1, 0, 0), (1, 1, 0, 1))*4,)
        plan = mine_patterns(voices, max_pattern_length=2)
        self.assertEqual(plan.patterns, (voices[0][:2],))
        self.assertEqual(plan.expand(), voices)

    def test_limits_reject_instead_of_losing_rows(self):
        with self.assertRaises(ValueError):
            mine_patterns((rows(1, 2, 3),), max_pattern_length=1, max_patterns=2)
        for kwargs in ({'loop_start': 3}, {'loop_start': -1}, {'max_pattern_length': 65},
                       {'search_row_budget': -1}):
            with self.assertRaises(ValueError):
                mine_patterns((rows(1, 2, 3),), **kwargs)
        with self.assertRaises(ValueError):
            mine_patterns((rows(1), rows(1, 2)))
        with self.assertRaises(ValueError):
            mine_patterns((([1, 2],),))


if __name__ == '__main__':
    unittest.main()
