"""native_song(effect_programs='on'): effects recovered as command rows, checked by a real ct2util re-trace."""
import hashlib
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

try:
    import numpy as np
except ImportError:  # numpy is optional for plain conversion
    raise unittest.SkipTest('numpy is required for the effect programme tests')

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ct_synth  # noqa: E402
from sid2ct.convert import parse_trace  # noqa: E402
from sid2ct.ctplayer import CTPlayer  # noqa: E402
from sid2ct.filterfit import fit_filter  # noqa: E402
from sid2ct.ir import FilterTimeline  # noqa: E402
from sid2ct.native import native_song  # noqa: E402
from sid2ct.regdist import filter_distance, trace_distance  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
ROW_FRAMES = 5  # ct_synth speed 4

# sha256 prefixes of native_song output at the commit before effect_programs existed.
GOLDEN = {
    ('slide', ''): '713377256a9fd104', ('slide', 'full'): '5148d2e9f1276435',
    ('slide', 'compact'): '713377256a9fd104',
    ('vib', ''): '095fd9ff9de8a92a', ('vib', 'full'): 'f7844b2405a498e0', ('vib', 'compact'): '095fd9ff9de8a92a',
    ('random', ''): '0ee664ef2c5f067e', ('random', 'full'): '246d4088f6b42682',
    ('random', 'compact'): '673d044d980fb523',
}


def random_trace():
    r = random.Random(7)
    frames, cur = [], bytearray(25)
    cur[24] = 15
    for i in range(300):
        for v in range(3):
            b = v * 7
            if i % 12 == 0 and r.random() < .7:
                f = r.randrange(2000, 9000)
                cur[b], cur[b + 1], cur[b + 4] = f & 255, f >> 8, 0x41
                cur[b + 5], cur[b + 6] = r.choice((0x09, 0x39)), r.choice((0xF0, 0xA5))
            elif i % 12 == 8:
                cur[b + 4] &= 0xFE
            elif r.random() < .2:
                f = max(1, (cur[b] | cur[b + 1] << 8) + r.randrange(-30, 30))
                cur[b], cur[b + 1] = f & 255, f >> 8
        if 40 < i < 200:
            cur[22], cur[23], cur[24] = (i * 3) & 255, 0xF1, 0x1F
        frames.append(bytes(cur))
    return frames


def pointer(image, index):
    return struct.unpack_from('<H', image, 0xFA0 + index * 2)[0]


def command_rows(image):
    base = pointer(image, 24)
    return [(image[base + i], image[base + 64 + i], image[base + 128 + i]) for i in range(1, 64)]


class EffectPrograms(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.template = ct_synth.template()
        if cls.template is None:
            raise unittest.SkipTest('Build ct2util with make -f Makefile.mac ct2util.')
        cls.temp = tempfile.TemporaryDirectory()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def retrace(self, song, calls=110):
        """Frames the exported SID plays under the real ct2util player."""
        directory = Path(self.temp.name)
        ct, sid, trace = (directory / n for n in ('o.ct', 'o.sid', 'o.trace'))
        ct.write_bytes(song)
        for command in ([str(ROOT / 'ct2util'), 'sid', str(ct), '-o', str(sid)],
                        [str(ROOT / 'ct2util'), 'sidtrace', str(sid), '-f', str(calls), '-o', str(trace)]):
            result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return parse_trace(trace.read_text())

    def convert(self, source, effects, **kw):
        song, report = native_song(self.template, source, 1, ROW_FRAMES, ['Synth', '', ''],
                                   effect_programs=effects, pitch_programs='attack', **kw)
        return song, zlib.decompress(song[3:]), report

    def synth(self, calls=110, **kw):
        image = ct_synth.synth(self.template, length=12, speed=ROW_FRAMES - 1, **kw)
        return CTPlayer(image).frames(calls)

    def pitch_cost(self, source, song):
        return trace_distance(source, self.retrace(song, len(source)), 1, max_lag=8)['pitch']

    # off is the original mapper -------------------------------------------------

    def test_off_is_byte_identical_to_the_previous_mapper(self):
        slide = ct_synth.synth(self.template, [(40, 1, 0), (50, 0, 0)], commands=[(0, 0, 19)], speed=4, length=12)
        vibrato = ct_synth.synth(self.template, [(48, 1, 0), (50, 0, 0)], commands=[(5, 4, 6)], speed=4, length=12)
        sources = {'slide': CTPlayer(slide).frames(110), 'vib': CTPlayer(vibrato).frames(110),
                   'random': random_trace()}
        for (name, option), golden in GOLDEN.items():
            options = {'pitch_programs': 'full'} if option == 'full' else {'layout': option or 'chunks'}
            with self.subTest(song=name, option=option or 'default'):
                for extra in ({}, {'effect_programs': 'off'}):
                    song, _ = native_song(self.template, sources[name], 1, 4, ['a', 'b', 'c'], **options, **extra)
                    self.assertEqual(hashlib.sha256(song).hexdigest()[:16], golden)

    def test_invalid_option_is_rejected(self):
        with self.assertRaises(ValueError):
            native_song(self.template, random_trace(), 1, 4, ['a', 'b', 'c'], effect_programs='auto')

    # effects on -----------------------------------------------------------------

    def test_pitch_commands_are_recovered_and_replay_closer(self):
        cases = {
            'slide': (dict(commands=[(0, 0, 19)]), (0, 0, 19), 40),
            'detune': (dict(commands=[(3, 0, 0x50)]), (3, 0, 0x50), 40),
            'lofi vibrato': (dict(commands=[(5, 4, 40)]), (5, 4, 40), 48),
            'hifi vibrato': (dict(commands=[(2, 0, 0x30)]), (2, 0, 0x30), 48),
        }
        for name, (kw, command, note) in cases.items():
            with self.subTest(effect=name):
                source = self.synth(rows=[(note, 1, 0), (50, 0, 0)], **kw)
                song, image, report = self.convert(source, 'on')
                self.assertIn(command, command_rows(image))
                self.assertEqual(report['effects']['command_rows'], 1)
                _, _, off_report = self.convert(source, 'off')
                self.assertNotIn('effects', off_report)
                off_song = native_song(self.template, source, 1, ROW_FRAMES, ['Synth', '', ''],
                                       pitch_programs='attack')[0]
                self.assertLess(self.pitch_cost(source, song), self.pitch_cost(source, off_song))
                self.assertEqual(report['tuning_range_violations'], 0)

    def test_delayed_vibrato_starts_on_a_later_row(self):
        source = self.synth(rows=[(48, 0, 0), (50, 0, 0)], commands=[(5, 4, 40)], extra={2: 1})
        _, image, report = self.convert(source, 'on')
        self.assertIn((5, 4, 40), command_rows(image))
        self.assertEqual(report['effects']['delayed_command_rows'], 1)

    def test_arpeggio_becomes_a_chord_entry(self):
        for step in (1, 2):
            with self.subTest(step=step):
                source = self.synth(rows=[(40, 0x80, 0), (50, 0, 0)], chord=[0, 4, 7, 0x80],
                                    wave=('arp', {'step': step}))
                song, image, report = self.convert(source, 'on')
                chords = bytes(image[pointer(image, 30):pointer(image, 30) + 8])
                # Entry 0 is the neutral loop; the arpeggio starts at position 2 and loops to it.
                self.assertEqual(chords, bytes([0, 0x80, 0, 4, 7, 0x82, 0, 0]))
                self.assertEqual(report['effects']['chord_entries'], 1)
                instrument = pointer(image, 18)
                self.assertEqual(image[instrument + 2 * 48 + 1] & 15, step - 1)
                self.assertEqual(report['tuning_range_violations'], 0)
                off_song = native_song(self.template, source, 1, ROW_FRAMES, ['Synth', '', ''],
                                       pitch_programs='attack')[0]
                self.assertLess(self.pitch_cost(source, song), self.pitch_cost(source, off_song))

    def test_global_filter_is_hosted_on_a_free_row(self):
        # The filter starts mid-note, so no per-instrument filter programme can express it.
        filt = [0, 0, 255, 127, 0x90, 0xF1, 20, 2, 30, 8, 255, 127]
        source = self.synth(rows=[(40, 0, 0), (50, 0, 0)], extra={4: 0x61}, filt=filt)
        song, image, report = self.convert(source, 'on')
        self.assertEqual(report['effects']['filter'], 'global')
        self.assertEqual(report['effects']['filter_starts'], 1)
        measured = report['effects']['filter_distance']
        self.assertLess(measured['global_plan'], measured['instrument'])
        self.assertLess(filter_distance(source, self.retrace(song, len(source)), 1), 0.05)

    def test_instrument_filter_is_kept_when_it_plays_the_filter_better(self):
        filt = [0, 0, 255, 127, 0x90, 0xF1, 20, 2, 30, 8, 255, 127]
        source = self.synth(rows=[(40, 0x61, 0), (50, 0, 0)], filt=filt)
        _, _, report = self.convert(source, 'on')
        self.assertEqual(report['effects']['filter_distance']['chosen'], 'instrument')

    def test_adsr_variants_merge_under_capacity_pressure(self):
        # 64 attacks of one sound whose AD/SR differ: only 47 instruments exist.
        frames, cur = [], bytearray(25)
        cur[24] = 15
        for i in range(64):
            ad, sr = i % 16, 0xF0 | i // 16
            for tick in range(12):
                gate = tick < 8
                cur[0:2] = bytes((0x68, 0x11))
                cur[4:7] = bytes((0x41 if gate else 0x40, ad, sr))
                frames.append(bytes(cur))
        song, image, report = self.convert(frames, 'on')
        _, _, off = self.convert(frames, 'off')
        self.assertGreater(off['approximated_instrument_attacks'], 0)
        self.assertLess(report['approximated_instrument_attacks'], off['approximated_instrument_attacks'])
        self.assertGreater(report['effects']['adsr_supers'], 0)

    def test_filter_plan_is_ok_only_within_its_tolerance(self):
        n = 120
        cutoff = np.array([(i * 11) % 2000 for i in range(n)])
        timeline = FilterTimeline(cutoff, np.zeros(n, int), np.full(n, 1), np.full(n, 1),
                                  np.zeros(n, bool), np.full(n, 0xF1))
        plan = fit_filter(timeline, tolerance=8)
        self.assertEqual(plan.ok, len(plan.table) <= 64 and plan.max_error <= plan.tolerance_used + 4)


if __name__ == '__main__':
    unittest.main()
