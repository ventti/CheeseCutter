"""Generic regression tests for SID trajectory allocation; no song fixtures."""
import math
import random
import unittest

from sid2ct.allocation import (program_cost, select_representatives,
                        select_with_budgets, trajectory_distance)


def signature(wave=((0, 0x21), (0x7E, 0)), *, ad=0x12, sr=0xA4,
              pulse=(), filt=()):
    return (ad, sr, tuple(wave), tuple(pulse), tuple(filt))


class TrajectoryTests(unittest.TestCase):
    def test_identity_symmetry_and_nonnegative(self):
        examples = [signature(), signature(ad=0x14),
                    signature(((0, 0x41), (4, 0x41), (0x7E, 0))),
                    signature(((0, 0xE1), (0x7E, 0)))]
        for left in examples:
            self.assertEqual(trajectory_distance(left, left), 0)
            for right in examples:
                forward = trajectory_distance(left, right)
                self.assertFalse(math.isnan(forward))
                self.assertGreaterEqual(forward, 0)
                self.assertEqual(forward, trajectory_distance(right, left))

    def test_pitch_transposition_preserves_contour(self):
        low = signature(((0, 0x21), (4, 0x21),
                         (7, 0x20), (0x7E, 0)))
        high = signature(((12, 0x21), (16, 0x21),
                          (19, 0x20), (0x7E, 0)))
        bent = signature(((12, 0x21), (18, 0x21),
                          (19, 0x20), (0x7E, 0)))
        self.assertEqual(trajectory_distance(low, high), 0)
        self.assertGreater(trajectory_distance(high, bent), 0)

    def test_absolute_oscillator_pitch_is_preserved(self):
        low = signature(((0x80 + 24, 0x21), (0x7E, 0)))
        high = signature(((0x80 + 36, 0x21), (0x7E, 0)))
        self.assertGreater(trajectory_distance(low, high), 0)

    def test_late_waveform_and_pitch_changes_are_not_lost(self):
        prefix = ((0, 0x21),) * 24
        base = signature(prefix + ((0, 0x21), (0x7E, 0)))
        waveform_tail = signature(prefix + ((0, 0x41), (0x7E, 0)))
        pitch_tail = signature(prefix + ((7, 0x21), (0x7E, 0)))
        self.assertGreater(trajectory_distance(base, waveform_tail), 0)
        self.assertGreater(trajectory_distance(base, pitch_tail), 0)

    def test_timing_gate_and_coupled_control_have_effect(self):
        short = signature(((0, 0x21), (0, 0x20), (0x7E, 0)))
        long = signature(((0, 0x21), (0, 12), (0, 0x20), (0x7E, 0)))
        sync = signature(((0, 0x23), (0, 0x20), (0x7E, 0)))
        self.assertGreater(trajectory_distance(short, long), 0)
        self.assertGreater(trajectory_distance(short, sync, coupled=True), 0)

    def test_pulse_and_filter_tail_changes_have_effect(self):
        pulse = ((0, 0, 0x88, 0), (20, 4, 255, 127))
        filt = ((0x90, 0x01, 100, 0), (20, 4, 255, 127))
        base = signature(pulse=pulse, filt=filt)
        changed_pulse = signature(pulse=(pulse[0], (20, 8, 255, 127)), filt=filt)
        changed_filter = signature(pulse=pulse, filt=(filt[0], (20, 8, 255, 127)))
        self.assertGreater(trajectory_distance(base, changed_pulse), 0)
        self.assertGreater(trajectory_distance(base, changed_filter), 0)

    def test_hidden_source_is_separated_from_audible(self):
        hidden = signature(((0, 0xE1), (4, 0xE1), (0x7E, 0)))
        audible = signature(((0, 0x21), (4, 0x21), (0x7E, 0)))
        self.assertGreater(trajectory_distance(hidden, audible, coupled=True), 0)
        selected = select_representatives({hidden: 1, audible: 1000}, limit=2,
                                          coupled=(hidden,))
        self.assertEqual(set(selected), {hidden, audible})
        self.assertIn(hidden, select_representatives({hidden: 1, audible: 1000},
                      limit=2, protected=(hidden,), coupled=(hidden,)))


class AllocationTests(unittest.TestCase):
    def test_capacity_existing_members_and_no_duplicates(self):
        usage = {signature(ad=i): i + 1 for i in range(60)}
        for limit in (1, 2, 7, 47, 80):
            with self.subTest(limit=limit):
                selected = select_representatives(usage, limit=limit)
                self.assertLessEqual(len(selected), limit)
                self.assertEqual(len(selected), len(set(selected)))
                self.assertTrue(set(selected).issubset(usage))
        self.assertEqual(set(select_representatives(usage, limit=80)), set(usage))
        self.assertEqual(select_representatives({}, limit=47), [])
        self.assertEqual(select_representatives({}, limit=0), [])
        with self.assertRaises(ValueError):
            select_representatives(usage, limit=0)

    def test_protected_low_usage_representative_is_retained(self):
        protected = signature(ad=0xFF)
        usage = {signature(ad=i): 100 for i in range(8)}
        usage[protected] = 1
        selected = select_representatives(usage, limit=2, protected=(protected,))
        self.assertIn(protected, selected)
        self.assertEqual(len(selected), 2)

    def test_hidden_and_critical_classes_cannot_be_silently_dropped(self):
        audible = signature()
        hidden = signature(((0, 0xE1), (0x7E, 0)))
        with self.assertRaises(ValueError):
            select_representatives({audible: 1000, hidden: 1}, limit=1)
        sync = signature(((0, 0x23), (0x7E, 0)))
        with self.assertRaises(ValueError):
            select_representatives({audible: 1000, sync: 1}, limit=1,
                                   coupled=(audible, sync))

    def test_protected_over_capacity_is_rejected(self):
        a, b = signature(ad=1), signature(ad=2)
        with self.assertRaises(ValueError):
            select_representatives({a: 1, b: 1}, limit=1, protected=(a, b))

    def test_weights_change_single_representative_choice(self):
        a, b = signature(ad=0x01), signature(ad=0xE1)
        self.assertEqual(select_representatives({a: 1000, b: 1}, limit=1), [a])
        self.assertEqual(select_representatives({a: 1, b: 1000}, limit=1), [b])

    def test_distinct_trajectory_wins_over_redundant_frequent_variant(self):
        common = signature()
        near = signature(ad=0x13)
        distinct = signature(((0, 0x81), (0, 0x80), (0x7E, 0)))
        selected = select_representatives({common: 1000, near: 100, distinct: 100}, limit=2)
        self.assertIn(common, selected)
        self.assertIn(distinct, selected)

    def test_input_order_and_repeat_runs_are_deterministic(self):
        items = [(signature(ad=i), 1 + i % 5) for i in range(55)]
        expected = select_representatives(dict(items), limit=7)
        rng = random.Random(12345)
        for _ in range(5):
            rng.shuffle(items)
            self.assertEqual(select_representatives(dict(items), limit=7), expected)


class BudgetTests(unittest.TestCase):
    def test_exact_sharing_and_wave_suffix_sharing(self):
        tail = ((7, 0x21), (0x7E, 0))
        pulse = ((0, 0, 0x88, 127),)
        filt = ((0x90, 1, 100, 127),)
        a = signature(((0, 0x21),) + tail, pulse=pulse, filt=filt)
        b = signature(tail, ad=0x13, pulse=pulse, filt=filt)
        self.assertEqual(program_cost([a, b, a]), (2, 3, 1, 1))
        selected = select_with_budgets({a: 100, b: 10}, instrument_limit=2,
                        wave_limit=3, pulse_limit=1, filter_limit=1)
        self.assertEqual(set(selected), {a, b})

    def test_each_budget_is_enforced_without_truncation(self):
        a = signature()
        b = signature(((0, 0x41), (0x7E, 0)), ad=0x13,
                      pulse=((0, 0, 0x88, 127),),
                      filt=((0x90, 1, 100, 127),))
        usage = {a: 100, b: 10}
        for wave, pulse, filt in ((2, 5, 5), (10, 0, 5), (10, 5, 0)):
            with self.subTest(budgets=(wave, pulse, filt)):
                selected = select_with_budgets(usage, instrument_limit=2,
                    wave_limit=wave, pulse_limit=pulse, filter_limit=filt)
                self.assertEqual(selected, [a])
                self.assertTrue(all(c <= bound for c, bound in
                    zip(program_cost(selected), (2, wave, pulse, filt))))

    def test_protected_hidden_fallback_survives_feasible_budgets(self):
        audible = signature()
        hidden = signature(((0, 0xE1), (0x7E, 0)))
        selected = select_with_budgets({audible: 10000, hidden: 1},
            instrument_limit=2, wave_limit=4, pulse_limit=0, filter_limit=0,
            protected=(hidden,), coupled=(hidden,))
        self.assertEqual(set(selected), {audible, hidden})
        with self.assertRaises(ValueError):
            select_with_budgets({audible: 10000, hidden: 1},
                instrument_limit=2, wave_limit=3, pulse_limit=0, filter_limit=0,
                protected=(hidden,), coupled=(hidden,))

    def test_budget_selection_is_deterministic(self):
        items = [(signature(ad=i), i + 1) for i in range(12)]
        kwargs = dict(instrument_limit=4, wave_limit=2,
                      pulse_limit=0, filter_limit=0)
        self.assertEqual(select_with_budgets(dict(items), **kwargs),
                         select_with_budgets(dict(reversed(items)), **kwargs))


if __name__ == '__main__':
    unittest.main()
