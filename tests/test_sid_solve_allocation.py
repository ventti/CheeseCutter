"""CP-SAT instrument allocation (sid2ct.solve): small problems with known optima, capacity, fallback, hints."""
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock
import zlib

try:
    import numpy  # noqa: F401
    from ortools.sat.python import cp_model  # noqa: F401
except ImportError:
    raise unittest.SkipTest('numpy and ortools are required for the solver tests')

from sid2ct import solve
from sid2ct.ctplayer import CTPlayer
from sid2ct.native import native_song
from sid2ct.solve import Option, Problem, solve_model

ROOT = Path(__file__).resolve().parents[1]


def sig(tag, wave_len=2, pulse_len=0, filter_len=0, ad=0, sr=0xF0):
    """A signature whose programs are unique per tag and have the given row counts."""
    wave = tuple((tag + i, 0x41) for i in range(wave_len - 1)) + ((0x7E, 0),)
    pulse = tuple((tag, i, 255, 0) for i in range(pulse_len))
    filt = tuple((tag, i, 255, 0) for i in range(filter_len))
    return (ad, sr, wave, pulse, filt)


def problem(candidates, costs, **limits):
    """costs: per variant {candidate index: cost}; every variant also may stay unmatched at a high cost."""
    options = [[Option(ci, c) for ci, c in row.items()] + [Option(-1, 1000.0)] for row in costs]
    return Problem(candidates, options, [1.0] * len(costs), **limits)


class SolveModel(unittest.TestCase):
    def test_finds_known_optimum(self):
        # Two instruments for four variants: {0,1} are close, {2,3} are close, so choose one of each pair.
        candidates = [sig(10), sig(20), sig(30), sig(40)]
        costs = [{0: 0, 1: 1, 2: 50}, {0: 1, 1: 0, 2: 50}, {2: 0, 3: 1}, {2: 1, 3: 0}]
        solution = solve_model(problem(candidates, costs, instrument_limit=2), 5, workers=1)
        self.assertEqual(solution.status, 'OPTIMAL')
        self.assertAlmostEqual(solution.objective, 2.0)
        self.assertEqual(len(solution.chosen), 2)
        self.assertTrue({0, 1} & set(solution.chosen) and {2, 3} & set(solution.chosen))

    def test_a_single_slot_goes_to_the_heaviest_use(self):
        candidates = [sig(10), sig(20)]
        costs = [{0: 0, 1: 9}, {0: 9, 1: 0}]
        p = problem(candidates, costs, instrument_limit=1)
        p.weights = [1, 1]
        p.options[0] = [Option(0, 0.0), Option(1, 9.0), Option(-1, 5.0)]
        p.options[1] = [Option(0, 9.0), Option(1, 0.0), Option(-1, 30.0)]
        solution = solve_model(p, 5, workers=1)
        self.assertEqual(solution.chosen, [1])        # variant 1 would cost 30 unmatched, variant 0 only 5

    def test_wave_capacity_and_suffix_sharing(self):
        long = sig(10, wave_len=6)
        # The short program is an exact suffix of the long one, so it is stored for free.
        short = (0, 0xF0, long[2][-3:], (), ())
        other = sig(50, wave_len=6)
        candidates = [long, short, other]
        costs = [{0: 0}, {1: 0}, {2: 0}]
        solution = solve_model(problem(candidates, costs, wave_limit=6), 5, workers=1)
        self.assertEqual(set(solution.chosen), {0, 1})  # other (6 more rows) does not fit
        self.assertEqual(solution.pick[2], len(costs[2]))       # -> its unmatched option
        used = solve.table_usage([candidates[i] for i in solution.chosen])
        self.assertLessEqual(used[1], 6)

    def test_pulse_and_filter_capacity(self):
        candidates = [sig(10, pulse_len=3, filter_len=2), sig(20, pulse_len=3, filter_len=2), sig(30)]
        costs = [{0: 0}, {1: 0}, {2: 0}]
        solution = solve_model(problem(candidates, costs, pulse_limit=3, filter_limit=4), 5, workers=1)
        used = solve.table_usage([candidates[i] for i in solution.chosen])
        self.assertLessEqual(used[2], 3)
        self.assertLessEqual(used[3], 4)
        self.assertIn(2, solution.chosen)
        self.assertEqual(len(solution.chosen), 2)

    def test_command_rows_are_limited_and_shared(self):
        candidates = [sig(10)]
        # Repairs 1 and 2 each need a command row; 3 reuses repair 1's row.
        costs = [{}, {}, {}]
        p = Problem(candidates, [[Option(0, 10.0), Option(0, 0.0, (4, 1, 1), True)],
                                 [Option(0, 10.0), Option(0, 0.0, (4, 2, 2), True)],
                                 [Option(0, 10.0), Option(0, 0.0, (4, 1, 1), True)]], [1, 1, 1],
                    command_limit=1)
        solution = solve_model(p, 5, workers=1)
        self.assertEqual(solution.objective, 10.0)       # one command row repairs variants 0 and 2
        self.assertEqual(solution.commands, 1)
        p.free_commands = frozenset({(4, 2, 2)})
        self.assertEqual(solve_model(p, 5, workers=1).objective, 0.0)

    def test_infeasible_returns_none(self):
        candidates = [sig(10, wave_len=8)]
        p = problem(candidates, [{0: 0}], wave_limit=4)
        p.protected = (0,)
        self.assertIsNone(solve_model(p, 5, workers=1))

    def test_hint_penalty_prefers_one_instrument_per_source_instrument(self):
        # Variants 0 and 1 are the same source instrument; their cheapest candidates differ by a hair.
        candidates = [sig(10), sig(20), sig(30)]
        def build(penalty):
            p = Problem(candidates, [[Option(0, 0.0), Option(2, 0.4)], [Option(1, 0.0), Option(2, 0.4)]], [10, 10],
                        instrument_limit=3, hints={7: {0: 10, 1: 10}}, hint_penalty=penalty)
            return solve_model(p, 5, workers=1)
        free = build(0.0)
        tied = build(1.0)
        self.assertEqual({0, 1}, set(free.chosen))
        self.assertEqual(tied.chosen, [2])               # both share candidate 2 despite costing more
        self.assertAlmostEqual(tied.objective, 0.8)
        # A hint is soft: a hugely better separate choice still wins.
        p = Problem(candidates, [[Option(0, 0.0), Option(2, 500.0)], [Option(1, 0.0), Option(2, 500.0)]], [10, 10],
                    instrument_limit=3, hints={7: {0: 10, 1: 10}}, hint_penalty=1.0)
        self.assertEqual(set(solve_model(p, 5, workers=1).chosen), {0, 1})


class Determinism(unittest.TestCase):
    def test_worker_count_does_not_change_the_allocation(self):
        candidates = [sig(10 * i, wave_len=3) for i in range(1, 9)]
        # Variant v prefers candidate v; distinct costs give a unique optimum for 4 slots.
        costs = [{ci: abs(vi - ci) * 3.0 + 0.01 * vi + 0.001 * ci for ci in range(8)} for vi in range(8)]
        results = [solve_model(problem(candidates, costs, instrument_limit=4), 20, workers=n, seed=3) for n in (1, 4)]
        self.assertEqual(results[0].chosen, results[1].chosen)
        self.assertEqual(results[0].pick, results[1].pick)
        self.assertAlmostEqual(results[0].objective, results[1].objective)

    def test_pricing_is_identical_serial_and_in_a_pool(self):
        import tempfile
        template = tempfile.mkdtemp()
        out = Path(template) / 't.ct'
        subprocess.run([str(ROOT / 'ct2util'), 'init', str(ROOT / 'src/c64/player.bin'), '-o', str(out)],
                       capture_output=True, check=True)
        data = zlib.decompress(out.read_bytes()[3:])
        from sid2ct.native import struct
        offsets = {i: struct.unpack_from('<H', data, 0xFA0 + i * 2)[0] for i in (14, 15, 16, 17)}
        maker = solve.ImageMaker(data, offsets, 1)
        import numpy as np
        source = np.zeros((40, 25), np.int64)
        source[:, 0], source[:, 1], source[:, 4], source[:, 5], source[:, 6] = 0x68, 0x11, 0x41, 0x09, 0xF0
        variants = [solve.Variant(sig(10 + i, wave_len=3, ad=i % 3), 40, 40, 40, 40.0, 0.0, source=source)
                    for i in range(80)]
        pairs = [(vi, variants[(vi * 7) % 80].signature) for vi in range(80)]
        serial = solve.Pricer(variants, maker, 1, True, workers=1).price_many(pairs)
        pooled = solve.Pricer(variants, maker, 1, True, workers=4).price_many(pairs)
        self.assertEqual(serial, pooled)


class NativeSolve(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        template = Path(cls.temp.name)/'fresh.ct'
        result = subprocess.run([str(ROOT/'ct2util'), 'init', str(ROOT/'src/c64/player.bin'), '-o', str(template)],
                                capture_output=True, text=True)
        if result.returncode:
            raise unittest.SkipTest('Build ct2util with make -f Makefile.mac ct2util.')
        cls.template = template.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    @staticmethod
    def sounds(count, notes=1):
        """count distinct sounds (waveform x envelope), each played once, eight ticks on and four off."""
        frames = []
        for n in range(count * notes):
            k = n % count
            control = (0x11, 0x21, 0x41, 0x81)[k % 4]
            ad, sr = (k // 4 * 0x11) & 0xFF, 0xF0 - (k % 5)
            for tick in range(12):
                f = bytearray(25)
                freq = 4455 + 300 * (n % 7)
                gate = tick < 8
                f[:7] = bytes([freq & 255, freq >> 8, 0x00, 0x08, control if gate else control & 0xFE, ad, sr])
                f[24] = 15
                frames.append(bytes(f))
        return frames

    def build(self, count, **options):
        return native_song(self.template, self.sounds(count), 1, 4, ['', '', ''], instrument_allocation='solve',
                           solve_time_limit=4, **options)

    def test_pressure_run_respects_all_limits_and_validates(self):
        song, report = self.build(70)
        self.assertEqual(report['observed_instrument_variants'], 70)
        self.assertLessEqual(report['instruments'], 47)
        self.assertLessEqual(report['wave_rows'], 256)
        self.assertLessEqual(report['pulse_rows'], 64)
        self.assertLessEqual(report['filter_rows'], 64)
        allocation = report['helpers']['allocation']
        self.assertEqual(allocation['mode'], 'solve')
        self.assertIn(allocation['status'], ('OPTIMAL', 'FEASIBLE'))
        self.assertLessEqual(allocation['tables']['instruments'], 47)
        self.assertEqual(report['tuning_range_violations'], 0)
        # The exported song plays through the exact player model without a tuning-range fault.
        frames = CTPlayer(zlib.decompress(song[3:])).frames(600)
        self.assertEqual(len(frames), 600)

    def test_effect_programs_repair_envelopes_with_row_supers(self):
        song, report = self.build(70, effect_programs='on')
        allocation = report['helpers']['allocation']
        self.assertEqual(allocation['mode'], 'solve')
        self.assertLessEqual(report['instruments'], 47)
        self.assertGreaterEqual(allocation.get('repaired_variants', 0), 1)
        self.assertEqual(report['tuning_range_violations'], 0)

    def test_few_sounds_need_no_solver(self):
        _, report = self.build(12)
        self.assertEqual(report['helpers']['allocation']['status'], 'trivial')
        self.assertEqual(report['approximated_instrument_attacks'], 0)

    def test_falls_back_to_budget_without_a_solution(self):
        with mock.patch.object(solve, 'allocate', return_value=(None, None, {'status': 'no_solution'})):
            song, report = self.build(70)
        allocation = report['helpers']['allocation']
        self.assertEqual(allocation['fallback'], 'budget')
        self.assertEqual(allocation['status'], 'no_solution')
        self.assertLessEqual(report['instruments'], 47)
        self.assertEqual(report['tuning_range_violations'], 0)

    def test_solver_error_falls_back_to_budget(self):
        with mock.patch.object(solve, 'allocate', side_effect=RuntimeError('boom')):
            _, report = self.build(70)
        self.assertEqual(report['helpers']['allocation']['fallback'], 'budget')
        self.assertIn('boom', report['helpers']['allocation']['error'])

    def test_song_is_identical_for_one_and_four_workers(self):
        import os
        songs = []
        for workers in ('1', '4'):
            with mock.patch.dict(os.environ, {'SID2CT_WORKERS': workers}):
                songs.append(native_song(self.template, self.sounds(70), 1, 4, ['', '', ''], instrument_allocation='solve',
                                         solve_time_limit=30, effect_programs='on')[0])
        self.assertEqual(songs[0], songs[1])

    def test_other_modes_are_unchanged(self):
        a, _ = native_song(self.template, self.sounds(12), 1, 4, ['', '', ''], instrument_allocation='budget')
        b, _ = native_song(self.template, self.sounds(12), 1, 4, ['', '', ''], instrument_allocation='solve')
        self.assertEqual(a, b)       # a problem that fits needs no choice, so both modes build the same song


class Hints(unittest.TestCase):
    def test_groups_notes_by_source_instrument(self):
        from sid2ct.players.hints import NoteHint, StructureHints, VoiceHints
        voices = tuple(VoiceHints(notes=[NoteHint(call=c, note=48, instrument=i) for c, i in notes])
                       for notes in (((0, 1), (10, None), (20, 2)), (), ()))
        hints = StructureHints('GoatTracker', None, voices)
        # Events at frames 0, 10 and 20 on voice 0; the second keeps instrument 1.
        groups = solve.hint_groups([(0, 0, 0, 8), (0, 10, 1, 8), (0, 20, 2, 8), (0, 500, 3, 8)], hints, 1.0)
        self.assertEqual(groups, {1: {0: 8.0, 1: 8.0}, 2: {2: 8.0}})
        self.assertEqual(solve.hint_groups([(0, 0, 0, 8)], hints, 1.0, voices=3), {1: {0: 8.0}})


if __name__ == '__main__':
    unittest.main()
