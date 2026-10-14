"""Whole-chip IR: note segmentation, hard restart, legato, TEST, coupling, filter and volume timelines."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest

try:
    import numpy as np
except ImportError:  # numpy is optional for plain conversion
    raise unittest.SkipTest('numpy is required for the IR/effect fitting tests')

from sid2ct.ir import build_chip, equal_tuning, nearest_note

T = equal_tuning()


def trace(count, **voices):
    """Frames from per-voice callables f(i) -> (freq, pulse, control, ad, sr) plus optional filter/volume."""
    glob = voices.pop('glob', lambda i: (0, 0, 0xF0, 0x0F))  # cutoff lo, cutoff hi, res/route, mode/volume
    out = []
    for i in range(count):
        frame = bytearray(25)
        for v in range(3):
            fn = voices.get(f'v{v}')
            freq, pulse, control, ad, sr = fn(i) if fn else (0, 0, 0, 0, 0)
            frame[v * 7:v * 7 + 7] = bytes((freq & 255, freq >> 8, pulse & 255, pulse >> 8, control, ad, sr))
        frame[21:25] = bytes(glob(i))
        out.append(bytes(frame))
    return out


def note_gate(starts, freq=lambda i, s: T[48], ctrl=0x41, ad=0x09, sr=0xF0):
    """starts: [(rise, fall)] gate windows with constant pitch."""
    def fn(i):
        for rise, fall in starts:
            if rise <= i < fall:
                return freq(i, rise), 0x800, ctrl, ad, sr
        return T[48], 0x800, ctrl & 0xFE, ad, sr
    return fn


class Segmentation(unittest.TestCase):
    def test_gate_rises_make_notes(self):
        chip = build_chip(trace(60, v0=note_gate([(0, 20), (30, 50)])))
        notes = chip.voices[0].notes
        self.assertEqual([(n.kind, n.start, n.stop) for n in notes], [('initial', 0, 30), ('gate', 30, 60)])
        self.assertEqual(notes[0].gate_off, 20)
        self.assertEqual(notes[1].gate_off, 20)
        self.assertEqual(chip.voices[1].notes, [])
        self.assertEqual((notes[0].base_note, round(notes[0].base_cents, 6)), (48, 0.0))

    def test_base_pitch_is_nearest_tuning_note_with_cents(self):
        sharp = round(T[50] * 2 ** (30 / 1200))
        chip = build_chip(trace(30, v0=note_gate([(2, 30)], freq=lambda i, s: sharp)))
        n = chip.voices[0].notes[0]
        self.assertEqual(n.base_note, 50)
        self.assertAlmostEqual(n.base_cents, 30, delta=0.5)
        self.assertEqual(nearest_note(T[40], T), (40, 0.0))

    def test_hard_restart_lead_belongs_to_the_new_note(self):
        def v0(i):
            if i < 10:
                return T[48], 0x800, 0x41, 0x09, 0xF0
            if i < 12:   # gate off, ADSR zeroed for two frames
                return T[48], 0x800, 0x40, 0x00, 0x00
            return T[50], 0x800, 0x41, 0x09, 0xF0
        chip = build_chip(trace(30, v0=v0))
        first, second = chip.voices[0].notes
        self.assertEqual((first.stop, second.start, second.lead), (10, 12, 2))
        self.assertTrue(second.hard_restart)
        self.assertEqual((second.lead_ad, second.lead_sr), (0, 0))
        self.assertEqual(len(first.freq), 10)
        self.assertIsNone(first.gate_off)

    def test_gap_without_adsr_change_is_lead_but_not_hard_restart(self):
        chip = build_chip(trace(30, v0=note_gate([(0, 10), (11, 30)])))
        first, second = chip.voices[0].notes
        self.assertEqual((second.lead, second.hard_restart), (1, False))

    def test_long_release_stays_in_previous_note(self):
        chip = build_chip(trace(60, v0=note_gate([(0, 10), (40, 60)])))
        first, second = chip.voices[0].notes
        self.assertEqual((first.stop, second.lead), (40, 0))
        self.assertEqual(first.gate_off, 10)

    def test_legato_step_with_held_gate(self):
        def f(i, s):
            return T[48] if i < 20 else T[51]
        chip = build_chip(trace(40, v0=note_gate([(0, 40)], freq=f)))
        notes = chip.voices[0].notes
        self.assertEqual([n.kind for n in notes], ['initial', 'legato'])
        # Split on the last frame still at the old pitch (CT tie-row tick 0).
        self.assertEqual(notes[1].start, 19)
        self.assertEqual(int(notes[1].freq[0]), T[48])
        self.assertEqual(int(notes[1].freq[1]), T[51])
        self.assertEqual(notes[1].prev_freq, T[48])
        self.assertEqual(notes[1].base_note, 51)

    def test_glide_backdates_to_its_start(self):
        ramp = np.linspace(T[48], T[55], 10).astype(int)
        def f(i, s):
            return T[48] if i < 20 else int(ramp[min(9, i - 20)]) if i < 30 else T[55]
        chip = build_chip(trace(50, v0=note_gate([(0, 50)], freq=f)))
        notes = chip.voices[0].notes
        self.assertEqual([n.kind for n in notes], ['initial', 'legato'])
        self.assertEqual(notes[1].start, 20)  # ramp[0] still equals the old pitch

    def test_vibrato_slide_and_arpeggio_do_not_split(self):
        vib = lambda i, s: round(T[48] * 2 ** (np.sin(i / 2) * 60 / 1200))
        slide = lambda i, s: T[40] + 14 * (i - s)
        arp = lambda i, s: T[48 + (0, 4, 7)[(i // 2) % 3]]
        for name, fn in (('vibrato', vib), ('slide', slide), ('arpeggio', arp)):
            with self.subTest(name):
                chip = build_chip(trace(60, v0=note_gate([(2, 60)], freq=fn)))
                self.assertEqual(len(chip.voices[0].notes), 1, name)

    def test_slide_starting_with_the_note_is_one_note(self):
        chip = build_chip(trace(60, v0=note_gate([(2, 60)], freq=lambda i, s: T[40] + 30 * (i - s))))
        self.assertEqual([n.kind for n in chip.voices[0].notes], ['gate'])

    def test_test_bit_retrigger_inside_held_gate(self):
        def v0(i):
            control = 0x41 | (0x08 if i == 15 else 0)
            return T[48], 0x800, control, 0x09, 0xF0
        chip = build_chip(trace(30, v0=v0))
        notes = chip.voices[0].notes
        self.assertEqual([(n.kind, n.start) for n in notes], [('initial', 0), ('test', 15)])
        self.assertTrue(notes[1].test_mask[0])
        self.assertFalse(notes[1].test_mask[1])

    def test_multiplier_scales_thresholds(self):
        # Steps held for 4 frames: legato at 1x (hold 3) but an arpeggio-like pattern at 2x (hold 6).
        f = lambda i, s: T[48 + (0, 4)[(i // 4) % 2]]
        self.assertGreater(len(build_chip(trace(60, v0=note_gate([(0, 60)], freq=f)), multiplier=1).voices[0].notes), 1)
        self.assertEqual(len(build_chip(trace(60, v0=note_gate([(0, 60)], freq=f)), multiplier=2).voices[0].notes), 1)

    def test_rejects_bad_frames_and_accepts_empty(self):
        with self.assertRaises(ValueError):
            build_chip([bytes(24)])
        chip = build_chip([])
        self.assertEqual((chip.frames, chip.notes()), (0, []))


class Tuning(unittest.TestCase):
    def test_estimates_uniform_detune(self):
        from sid2ct.ir import estimate_tuning
        flat = [round(t * 2 ** (-35 / 1200)) for t in T]
        notes = [flat[n] for n in (36, 40, 43, 48, 52, 55, 60)]
        v0 = lambda i: (notes[(i // 6) % len(notes)], 0x800, 0x41, 9, 0xF0)
        table, offset = estimate_tuning(trace(80, v0=v0), T)
        self.assertAlmostEqual(offset, -35, delta=2)
        self.assertLessEqual(abs(table[48] - flat[48]), 2)

    def test_incoherent_pitches_keep_the_table(self):
        from sid2ct.ir import estimate_tuning
        rng = np.random.default_rng(3)
        seq = [int(x) for x in rng.integers(1500, 9000, 40)]
        v0 = lambda i: (seq[(i // 4) % 40], 0x800, 0x41, 9, 0xF0)
        self.assertEqual(estimate_tuning(trace(160, v0=v0), T), (T, 0.0))


class GlobalTimelines(unittest.TestCase):
    def test_filter_routing_cutoff_and_volume(self):
        def glob(i):
            cutoff = 100 + i * 8 + 5
            route = 0xF1 if i < 10 else 0xF6
            mode = 0x10 | (15 if i < 20 else 7)
            return cutoff & 7, cutoff >> 3, route, mode
        chip = build_chip(trace(30, glob=glob))
        f = chip.filter
        self.assertEqual(int(f.cutoff[3]), 100 + 24 + 5)
        self.assertEqual((int(f.resonance[0]), int(f.mode[0])), (15, 1))
        self.assertTrue(f.routed(0)[0] and not f.routed(1)[0])
        self.assertTrue(not f.routed(0)[12] and f.routed(1)[12] and f.routed(2)[12])
        self.assertTrue(f.used())
        self.assertEqual(chip.volume.changes(), [(0, 15), (20, 7)])

    def test_unused_filter(self):
        self.assertFalse(build_chip(trace(5)).filter.used())


class Coupling(unittest.TestCase):
    def test_sync_ring_edges_and_hidden_source(self):
        # Voice 0 is the hidden source (waveform off) syncing voice 1; voice 2 plain.
        v0 = lambda i: (T[40], 0, 0x00, 0, 0)
        v1 = lambda i: (T[44], 0x800, 0x43, 0x09, 0xF0)   # saw+sync+gate
        v2 = lambda i: (T[48], 0x800, 0x41, 0x09, 0xF0)
        chip = build_chip(trace(30, v0=v0, v1=v1, v2=v2))
        edges = [(e['source_voice'], e['destination_voice']) for e in chip.coupling.edges]
        self.assertEqual(edges, [(1, 2)])
        self.assertEqual(chip.coupling.partners(0), {1})
        self.assertEqual(chip.coupling.partners(2), set())
        self.assertEqual(len(chip.coupling.groups), 1)
        self.assertEqual(len(chip.coupling.hidden_frames[0]), 30)
        self.assertEqual(chip.coupling.hidden_frames[1].tolist(), [])
        self.assertTrue(chip.voices[1].notes[0].coupled)
        self.assertFalse(chip.voices[2].notes[0].coupled)

    def test_hidden_oscillator_note_is_flagged(self):
        v0 = lambda i: (T[40], 0, 0x01, 0, 0)            # gate on, waveform off
        v1 = lambda i: (T[44], 0x800, 0x43, 0x09, 0xF0)
        chip = build_chip(trace(30, v0=v0, v1=v1))
        n = chip.voices[0].notes[0]
        self.assertTrue(n.coupled and n.hidden)
        self.assertTrue(chip.voices[1].notes[0].coupled and not chip.voices[1].notes[0].hidden)


class CorpusSmoke(unittest.TestCase):
    def test_first_dev_song_builds_and_fits(self):
        root = Path(__file__).resolve().parents[1]
        from sid2ct import corpus
        hvsc = corpus.default_root()
        tool = root / 'ct2util'
        songs = [s for s in corpus.load() if s['split'] == 'dev'] if (root / 'tools/sid_corpus.toml').exists() else []
        if not songs or not (hvsc / songs[0]['path']).is_file() or not tool.is_file():
            self.skipTest('HVSC or ct2util missing.')
        from sid2ct.effects import fit_chip
        from sid2ct.loops import capture
        with tempfile.TemporaryDirectory() as d:
            frames, loop = capture(tool, hvsc / songs[0]['path'], songs[0]['subtune'], Path(d), seconds=6)
        chip = build_chip(frames, multiplier=loop['source_multiplier'])
        self.assertGreater(len(chip.notes()), 0)
        result = fit_chip(chip, tolerance=15.0)
        self.assertEqual(len(result.notes), len(chip.notes()))
        self.assertTrue(all(0 <= f.pitch.error for f in result.notes))


if __name__ == '__main__':
    unittest.main()
