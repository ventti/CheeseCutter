"""Round-trip: songs built from CT primitives, rendered by CTPlayer, must fit back to the same parameters."""
from pathlib import Path
import sys
import unittest

try:
    import numpy as np
except ImportError:  # numpy is optional for plain conversion
    raise unittest.SkipTest('numpy is required for the IR/effect fitting tests')

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_synth  # noqa: E402
from sid2ct.ctplayer import CTPlayer  # noqa: E402
from sid2ct.effects import (chord_table_bytes, fit_adsr, fit_chip, fit_filter, fit_note,  # noqa: E402
                            fit_pitch, fit_volume, assign_hosts, simulate_filter, VolumeEvent)
from sid2ct.ir import build_chip, tuning_from_image  # noqa: E402

SPEED = 4
ROW = SPEED + 1  # a row lasts speed + 1 base ticks


class Synth(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = ct_synth.template()
        if cls.template is None:
            raise unittest.SkipTest('Build ct2util with make -f Makefile.mac ct2util.')

    def render(self, rows, calls=110, **kw):
        image = ct_synth.synth(self.template, rows, length=kw.pop('length', 12), speed=SPEED, **kw)
        frames = CTPlayer(image).frames(calls)
        tuning = tuning_from_image(image)
        return image, frames, tuning, build_chip(frames, tuning=tuning)

    def first_note(self, rows, **kw):
        image, frames, tuning, chip = self.render(rows, **kw)
        note = chip.voices[0].notes[0]
        return note, tuning, chip

    def fit(self, rows, **kw):
        fit_kw = {'tolerance': 0.5, 'quantum': ROW}
        fit_kw.update(kw.pop('fit', {}))
        note, tuning, chip = self.first_note(rows, **kw)
        return fit_pitch(note, tuning, **fit_kw)

    def test_flat(self):
        fit = self.fit([(40, 0, 0), (50, 0, 0)])
        self.assertEqual((fit.primitive, fit.params['note'], fit.error), ('flat', 40, 0.0))

    def test_detune(self):
        fit = self.fit([(40, 1, 0), (50, 0, 0)], commands=[(3, 0x00, 0x50)])
        self.assertEqual((fit.primitive, fit.params['note'], fit.params['offset']), ('detune', 40, 0x50))
        self.assertEqual(fit.command, (3, 0, 0x50))
        self.assertTrue(fit.ok)
        self.assertLess(fit.error, 0.01)

    def test_slide_up_and_down(self):
        for op, name in ((0, 'up'), (1, 'down')):
            with self.subTest(direction=name):
                fit = self.fit([(40, 1, 0), (50, 0, 0)], commands=[(op, 0, 19)])
                self.assertEqual((fit.primitive, fit.params['direction'], fit.params['speed'],
                                  fit.params['note']), ('slide', name, 19, 40))
                self.assertEqual(fit.command, (op, 0, 19))
                self.assertLess(fit.error, 0.01)

    def test_gate_lag_for_restart_type_40(self):
        # Restart type $40 shows the gate on the first wave tick: the note's first frame already has the slide.
        note, tuning, chip = self.first_note([(40, 1, 0), (50, 0, 0)], commands=[(0, 0, 19)], restart=0x40)
        self.assertNotEqual(fit_pitch(note, tuning, tolerance=0.5, quantum=ROW).error, 0.0)
        fit = fit_pitch(note, tuning, tolerance=0.5, quantum=ROW, lag=1)
        self.assertEqual((fit.primitive, fit.params['speed'], fit.params['note']), ('slide', 19, 40))
        self.assertLess(fit.error, 0.01)

    def test_multiplier_two_runs_effects_per_call(self):
        image = ct_synth.synth(self.template, [(40, 1, 0), (50, 0, 0)], commands=[(5, 4, 6)], speed=SPEED,
                               length=12, multiplier=2)
        frames = CTPlayer(image).frames(220)
        tuning = tuning_from_image(image)
        note = build_chip(frames, multiplier=2, tuning=tuning).voices[0].notes[0]
        fit = fit_pitch(note, tuning, tolerance=0.5, quantum=ROW * 2)
        self.assertEqual((fit.primitive, fit.params['frq'], fit.params['amp']), ('vibrato_lofi', 4, 6))

    def test_slide_16_bit_speed(self):
        fit = self.fit([(30, 1, 0), (50, 0, 0)], commands=[(0, 1, 0x20)], length=3)
        self.assertEqual((fit.primitive, fit.params['speed']), ('slide', 0x120))

    def test_hifi_vibrato(self):
        for feel, amp, frq in ((0, 2, 4), (0, 2, 5), (2, 2, 6)):
            with self.subTest(feel=feel, amp=amp, frq=frq):
                lo = (frq - 1) << 4 | amp
                fit = self.fit([(48, 1, 0), (50, 0, 0)], commands=[(2, feel, lo)])
                self.assertEqual(fit.primitive, 'vibrato_hifi')
                self.assertEqual((fit.params['feel'], fit.params['amp'], fit.params['frq']), (feel, amp, frq))
                self.assertEqual(fit.command, (2, feel, lo))
                self.assertLess(fit.error, 0.01)

    def test_lofi_vibrato(self):
        fit = self.fit([(48, 1, 0), (50, 0, 0)], commands=[(5, 4, 6)])
        self.assertEqual((fit.primitive, fit.params['frq'], fit.params['amp']), ('vibrato_lofi', 4, 6))
        self.assertEqual(fit.command, (5, 4, 6))
        self.assertLess(fit.error, 0.01)

    def test_portamento_tie(self):
        image, frames, tuning, chip = self.render([(36, 0, 0), (43, 1, 1), (50, 0, 0)],
                                                  commands=[(7, 0, 100)], length=8)
        legato = [n for n in chip.voices[0].notes if n.kind == 'legato'][0]
        fit = fit_pitch(legato, tuning, tolerance=4.0, quantum=ROW)
        self.assertEqual((fit.primitive, fit.params['note'], fit.params['speed']), ('portamento', 43, 100))
        self.assertEqual(fit.command, (7, 0, 100))
        self.assertLess(fit.error, 0.01)

    def test_arpeggio_dedup_key_and_chord_bytes(self):
        for step in (1, 2):
            with self.subTest(step=step):
                fit = self.fit([(40, 0x80, 0), (50, 0, 0)], chord=[0, 4, 7, 0x80], wave=('arp', {'step': step}))
                self.assertEqual(fit.primitive, 'arpeggio')
                self.assertEqual((fit.params['note'], fit.params['step'], fit.chord, fit.params['loop']),
                                 (40, step, (0, 4, 7), 0))
                self.assertEqual(fit.dedup_key, ('chord', (0, 4, 7), 0, step))
                self.assertEqual(chord_table_bytes(fit, 0), (0, 4, 7, 0x80))
                self.assertLess(fit.error, 0.01)

    def test_arpeggio_negative_and_prefix(self):
        # Down a fourth then up a fifth, looping back to the second entry.
        chord = [0, 128 - 5, 7, 0x80 | 1]
        fit = self.fit([(40, 0x80, 0), (50, 0, 0)], chord=chord, wave=('arp', {'step': 2}))
        self.assertEqual((fit.primitive, fit.chord, fit.params['loop']), ('arpeggio', (0, 123, 7), 1))
        self.assertLess(fit.error, 0.01)

    def test_absolute_wave_notes(self):
        notes, delays = [60, 48, 36], [0, 2, 1]
        fit = self.fit([(40, 0, 0), (50, 0, 0)], wave=('abs', {'notes': notes, 'delays': delays}),
                       length=2)
        self.assertEqual(fit.primitive, 'wave_abs')
        self.assertEqual([n for n, _ in fit.waves], notes)
        self.assertEqual([t for _, t in fit.waves][:2], [3, 2])
        self.assertLess(fit.error, 0.01)

    def test_delayed_vibrato_onset(self):
        # Vibrato starts five rows (25 ticks) into the note via a tie row with the command.
        image, frames, tuning, chip = self.render([(48, 0, 0), (0, 1, 0), (50, 0, 0)],
                                                  commands=[(2, 0, 0x32)], length=5)
        note = chip.voices[0].notes[0]
        fit = fit_pitch(note, tuning, tolerance=0.5, quantum=ROW)
        self.assertEqual((fit.primitive, fit.delay), ('vibrato_hifi', ROW * 5))
        self.assertLess(fit.error, 0.01)

    def test_cheapest_primitive_wins_within_tolerance(self):
        # A 1-unit offset is flat within any sensible tolerance, never a command.
        note, tuning, chip = self.first_note([(40, 1, 0), (50, 0, 0)], commands=[(3, 0, 1)])
        self.assertEqual(fit_pitch(note, tuning, tolerance=12).primitive, 'flat')

    def test_unfittable_reports_not_ok(self):
        rng = np.random.default_rng(1)
        note, tuning, chip = self.first_note([(40, 0, 0), (50, 0, 0)])
        note.freq = (tuning[40] * 2 ** (rng.uniform(-1, 1, len(note.freq)))).astype(int)
        fit = fit_pitch(note, tuning, tolerance=4.0, quantum=ROW)
        self.assertFalse(fit.ok)

    def test_adsr_inline_nibble_and_command(self):
        note, tuning, chip = self.first_note([(40, 0xA3, 0), (50, 0, 0)])  # attack 3, instrument AD $09
        fit = fit_adsr(note, 0x09, 0xF0)
        self.assertEqual((fit.kind, fit.super_byte, fit.ad), ('inline', 0xA3, 0x39))
        note, tuning, chip = self.first_note([(40, 1, 0), (50, 0, 0)], commands=[(4, 0x25, 0x7B)])
        fit = fit_adsr(note, 0x09, 0xF0)
        self.assertEqual((fit.kind, fit.command), ('cmd4', (4, 0x25, 0x7B)))
        self.assertEqual(fit_adsr(note, 0x25, 0x7B).kind, 'none')
        for byte, nibble in ((0xB2, 'decay'), (0xC5, 'sustain'), (0xD9, 'release')):
            with self.subTest(nibble=nibble):
                note, tuning, chip = self.first_note([(40, byte, 0), (50, 0, 0)])
                self.assertEqual(fit_adsr(note, 0x09, 0xF0).super_byte, byte)

    def test_super_conflict_flagged(self):
        note, tuning, chip = self.first_note([(40, 1, 0), (50, 0, 0)], commands=[(0, 0, 9)], adsr=(0x09, 0xF0))
        base = fit_note(note, tuning, base_ad=0x09, base_sr=0xF0, tolerance=4.0, quantum=ROW)
        self.assertFalse(base.needs_instrument)
        clash = fit_note(note, tuning, base_ad=0x29, base_sr=0xF0, tolerance=4.0, quantum=ROW)
        self.assertTrue(clash.needs_instrument)

    def test_volume_super(self):
        image, frames, tuning, chip = self.render([(40, 0xE5, 0), (50, 0, 0)])
        events = fit_volume(chip.volume)
        self.assertEqual([e.value for e in events], [0, 15, 5])  # cold start writes 0 on call 0
        self.assertEqual(events[2].super_byte, 0xE5)
        # Sampling on a coarse grid collapses a fast fade into few events.
        fade = fit_volume(np.array([15] * 3 + [14, 13, 12, 11, 10, 9, 8]), min_gap=4)
        self.assertLessEqual(len(fade), 3)

    def test_filter_sweep_program_round_trip(self):
        # Set row (low-pass, res 15 on voice 1, cutoff 20), up-sweep 20 ticks, down-sweep 15 ticks, stop.
        filt = [0, 0, 255, 127,
                0x90, 0xF1, 20, 0,
                20, 6, 255, 0,
                15, 252, 255, 127]
        image, frames, tuning, chip = self.render([(40, 0x61, 0), (50, 0, 0)], filt=filt, calls=118)
        tl = chip.filter
        cut, regs, modes = simulate_filter([tuple(filt[i:i + 4]) for i in range(0, 16, 4)],
                                           {int(np.flatnonzero(tl.reg23 != 240)[0]): 1}, chip.frames)
        self.assertTrue((cut == tl.cutoff).all() and (regs == tl.reg23).all() and (modes == tl.mode).all())
        plan = fit_filter(tl, tolerance=4)
        self.assertTrue(plan.ok)
        self.assertEqual(len(plan.starts), 1)
        self.assertEqual(plan.starts[0].frame, int(np.flatnonzero(tl.reg23 != 240)[0]))
        self.assertEqual(plan.route_mismatch, 0)
        self.assertLessEqual(plan.max_error, 4)
        rows = plan.table[1:]
        self.assertEqual(rows[0][:3] + (0,), (0x90, 0xF1, 20, 0)) if len(rows) == 3 else None
        self.assertEqual([r[0] for r in plan.table[1:]], [0x90, 20, 15])
        self.assertEqual([r[1] for r in plan.table[1:]][1:], [6, 252])

    def test_filter_repeated_programs_share_rows(self):
        filt = [0, 0, 255, 127, 0x90, 0xF1, 20, 0, 20, 6, 255, 127]
        image, frames, tuning, chip = self.render([(40, 0x61, 0), (40, 0, 0), (40, 0x61, 0), (50, 0, 0)],
                                                  filt=filt, calls=200, length=12)
        plan = fit_filter(chip.filter, tolerance=4)
        self.assertGreaterEqual(len(plan.starts), 2)
        self.assertEqual(len({s.row for s in plan.starts}), len(plan.programs))
        self.assertLessEqual(plan.max_error, 4)

    def test_chip_fit_end_to_end(self):
        filt = [0, 0, 255, 127, 0x90, 0xF1, 20, 0, 20, 6, 255, 127]
        image, frames, tuning, chip = self.render([(40, 0x61, 0), (44, 1, 0), (50, 0, 0)],
                                                  filt=filt, commands=[(0, 0, 9)], calls=130)
        result = fit_chip(chip, tolerance=4.0, quantum=ROW)
        self.assertTrue(result.filter.ok)
        self.assertEqual(len(result.notes), len(chip.notes()))
        self.assertTrue(all(f.pitch.ok for f in result.notes))

    def test_host_assignment_respects_one_super_per_row(self):
        events = [VolumeEvent(8, 1, 0xE1), VolumeEvent(8, 2, 0xE2), VolumeEvent(9, 3, 0xE3)]
        occupied = {0: {2}}
        hosted = assign_hosts(events, ROW, occupied)
        slots = [(h.voice, h.row) for h in hosted]
        self.assertEqual(len(set(slots)), 3)
        self.assertNotIn((0, 2), slots)
        self.assertTrue(all(h.voice is not None for h in hosted))
        full = {v: set(range(0, 40)) for v in range(3)}
        self.assertIsNone(assign_hosts([VolumeEvent(8, 1, 0xE1)], ROW, full)[0].voice)


if __name__ == '__main__':
    unittest.main()
