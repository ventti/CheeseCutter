"""Native programs must never read beyond the 96-note tuning table."""
from pathlib import Path
import subprocess
import tempfile
import unittest
import zlib

from sid2ct.ctplayer import CTPlayer
from sid2ct.native import native_song
from tests.test_sid_reconstruct import frame

ROOT = Path(__file__).resolve().parents[1]


class NativeTuningRangeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        template = Path(cls.temp.name)/'fresh.ct'
        result = subprocess.run([str(ROOT/'ct2util'), 'init',
                                 str(ROOT/'src/c64/player.bin'), '-o', str(template)],
                                capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(result.stdout + result.stderr)
        cls.template = template.read_bytes()
        # A strictly increasing synthetic table makes all 96 notes distinct.
        cls.tuning = [100 + 500*n for n in range(96)]

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def checked_trace(self, song, calls=1800):
        player = CTPlayer(zlib.decompress(song[3:]))
        frequency = player._frequency
        indexes = []
        def checked(index):
            self.assertIn(index & 255, range(96))
            indexes.append(index & 255)
            return frequency(index)
        player._frequency = checked
        frames = player.frames(calls)
        return frames, indexes

    def test_note_95_and_low_absolute_notes_preserve_source_pitch(self):
        values = [self.tuning[n] for n in (36, 95, 1, 36) for _ in range(8)]
        song, report = native_song(self.template, [frame(freq=f) for f in values],
                                  1, 3, ['', '', ''], frequencies=self.tuning,
                                  pitch_programs='full')
        frames, indexes = self.checked_trace(song, 120)
        start = next(i for i, f in enumerate(frames) if f[4] == 0x11)
        self.assertEqual([f[0] | f[1] << 8 for f in frames[start:start+32]], values)
        self.assertIn(95, indexes)
        self.assertIn(1, indexes)
        self.assertEqual(report['tuning_clamped_source_samples'], 0)
        self.assertEqual(report['tuning_range_violations'], 0)

    def test_unrepresentable_source_pitch_clamps_to_note_95(self):
        song, report = native_song(self.template, [frame(freq=60000)]*24,
                                  1, 3, ['', '', ''], frequencies=self.tuning,
                                  pitch_programs='full')
        frames, indexes = self.checked_trace(song, 120)
        self.assertIn(95, indexes)
        self.assertIn(self.tuning[95], [f[0] | f[1] << 8 for f in frames])
        self.assertEqual(report['tuning_clamped_source_samples'], 24)
        self.assertEqual(report['tuning_range_violations'], 0)

    def test_exhausted_wave_table_fallback_cannot_overflow(self):
        # The first program fills the wave table and has offset 65. Reusing it
        # with base 60 formerly looked up note 125, beyond the frequency table.
        low = [frame(freq=self.tuning[30 if i % 2 == 0 else 95],
                     gate=True)
               for i in range(252)]
        low = [f[:4] + bytes((0x11 if i % 2 == 0 else 0x21,)) + f[5:]
               for i, f in enumerate(low)]
        low += [frame(freq=self.tuning[30], gate=False)]*3
        source = low*2 + [frame(freq=self.tuning[60], pulse=100)]*24
        for layout in ('chunks', 'compact'):
            with self.subTest(layout=layout):
                song, report = native_song(self.template, source, 1, 3,
                                          ['', '', ''], frequencies=self.tuning,
                                          pitch_programs='full', layout=layout)
                self.checked_trace(song)
                self.assertGreater(report['approximated_instrument_attacks'], 0)
                self.assertGreater(report['tuning_clamped_events'], 0)
                self.assertEqual(report['tuning_range_violations'], 0)
                self.assertGreater(report['tuning_range_verified_calls'], 0)
