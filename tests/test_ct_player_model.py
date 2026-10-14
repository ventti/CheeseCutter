"""Differential fuzzing of the Python CT player against exported SID calls."""
import os
from pathlib import Path
import random
import struct
import subprocess
import tempfile
import unittest
import zlib

from sid2ct.ctplayer import CTPlayer, simulate_voice
from sid2ct.convert import parse_trace
from sid2ct.native import native_song

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / 'ct2util'


def patch(data, index, values):
    """Use the same pointer-table and column layout as native_song."""
    addr = struct.unpack_from('<H', data, 0xFA0 + index * 2)[0]
    data[addr:addr + len(values)] = bytes(values)


class CTPlayerModel(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not TOOL.is_file():
            raise unittest.SkipTest('Build ct2util with make -f Makefile.mac ct2util.')
        cls.temp = tempfile.TemporaryDirectory(prefix='ctplayer-')
        cls.directory = Path(cls.temp.name)
        cls.log_path = Path(os.environ.get('CTPLAYER_COMMAND_LOG',
                                           cls.directory / 'commands.log'))
        cls.log = open(cls.log_path, 'w')
        cls.run_tool('init', str(ROOT / 'src/c64/player.bin'), '-o',
                     str(cls.directory / 'template.ct'))
        cls.template = (cls.directory / 'template.ct').read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.log.close()
        cls.temp.cleanup()

    @classmethod
    def run_tool(cls, *args):
        cls.log.write('ct2util ' + ' '.join(args) + '\n')
        cls.log.flush()
        result = subprocess.run([str(TOOL), *args], cwd=ROOT,
                                stdout=cls.log, stderr=subprocess.STDOUT)
        cls.log.flush()
        if result.returncode:
            # Read the log after the command, never filter a live output pipe.
            raise AssertionError(cls.log_path.read_text())

    def make_song(self, rng, case):
        seed = bytearray(25)
        seed[0:2] = bytes((0x68, 0x11))
        seed[4:7] = bytes((0x41, 0x12, 0xA8))
        seed[24] = 15
        # Reuse native.py's template normalization, tuning, and track helpers.
        song, _ = native_song(self.template, [bytes(seed)] * 32, 1, 4,
                              ['Fuzz', '', ''])
        data = bytearray(zlib.decompress(song[3:]))
        wave, control = [0] * 256, [0] * 256
        instruments = [0] * 384
        pulse, filt = [0] * 256, [0] * 256
        pulse[:4] = [0, 0, 255, 127]
        filt[:4] = [0, 0, 255, 127]
        for instrument in range(1, 5):
            start = instrument * 8
            for i in range(5):
                wave[start + i] = rng.choice([0, 0, 4, 7, 12, 0x80 + rng.randrange(24, 70)])
                control[start + i] = rng.choice([0, rng.randrange(1, 16), 0x11,
                    0x21, 0x41, 0x81, 0x15, 0xE0, 0xE1, 0xE9])
            wave[start + 5] = rng.choice([126, 127])
            control[start + 5] = start + rng.randrange(5) if wave[start + 5] == 127 else 0
            definition = [rng.randrange(256), rng.randrange(256),
                rng.choice([0, 0x40, 0x80, 0xA0]) | rng.randrange(4),
                rng.choice([0, 8, 0x10, 0x20, 0x40]), instrument,
                rng.choice([instrument, 0x80 | rng.randrange(16)]),
                rng.randrange(256), start]
            for col, value in enumerate(definition):
                instruments[col * 48 + instrument] = value
            pulse[instrument * 4:instrument * 4 + 4] = [rng.randrange(256),
                rng.randrange(256), rng.choice([255, rng.randrange(255)]),
                rng.choice([127, instrument % 4 + 1])]
            filt[instrument * 4:instrument * 4 + 4] = [rng.choice([0x90, 0xA0, 0xC0]),
                rng.randrange(256), rng.randrange(255), instrument + 4]
            filt[(instrument + 4) * 4:(instrument + 4) * 4 + 4] = [rng.randrange(16),
                rng.randrange(256), 255, rng.choice([127, instrument])]
        commands = [0] * 256
        commands[64] = rng.randrange(256)
        for i in range(1, 10):
            commands[i] = i - 1
            commands[64 + i] = rng.randrange(16) if i in (3, 6, 8) else rng.randrange(256)
            commands[128 + i] = rng.randrange(256)
        chord = [3, 5, 4, 0x80, 0, 4, 7, 0x84, 0, 0x7C, 12, 0x88] + [0] * 116
        for index, values in [(14, wave), (15, control), (16, filt),
                              (17, pulse), (18, instruments), (24, commands), (30, chord)]:
            patch(data, index, values)
        supers = [i for i in range(1, 10) if i != 8] + [0x41, 0x62, 0x81, 0x82,
            *range(0xA0, 0xF0), 0xF0, 0xF1, 0xF3, 0xF7]
        if case % 4 == 0:
            # The player uses a signed CPY/BPL before the porta lookup.
            # Inline $c0..$ff in the same build would read past cmd1.
            supers = list(range(1, 10)) + [0x41, 0x62, 0x81, 0x82, 0xA3, 0xB7]
        for voice in range(3):
            for sequence in (voice * 2 + 1, voice * 2 + 2):
                raw = []
                for row in range(12):
                    raw.extend([0xC0 + rng.randrange(1, 5),
                                0x5F if row and rng.randrange(4) == 0 else 0xF0])
                    note = rng.choice([0, 1, 2, rng.randrange(24, 60)]) if row else rng.randrange(24, 60)
                    raw.extend([0x60 + note, rng.choice(supers)])
                raw.append(0xBF)
                lo = struct.unpack_from('<H', data, 0xFA0 + 22 * 2)[0]
                hi = struct.unpack_from('<H', data, 0xFA0 + 23 * 2)[0]
                addr = data[lo + sequence] | data[hi + sequence] << 8
                data[addr:addr + 256] = bytes(raw).ljust(256, b'\0')
            order = bytes([0xA0 + rng.randrange(4), voice * 2 + 1,
                           0xA0 + rng.randrange(4), voice * 2 + 2, 0xF0, 0])
            start = 65536 + 256 + 5 + 160 + 2048 + voice * 1024
            data[start:start + 1024] = order.ljust(1024, b'\0')
            patch(data, 19 + voice, order.ljust(1024, b'\0'))
        multiplier = (case % 3) + 1
        data[65538] = multiplier
        data[65541:65573] = bytes([rng.choice([0, 1, 3, 5, 7])]) * 32
        # Custom image tuning must survive model and optimized export alike.
        addr = struct.unpack_from('<H', data, 0xFA0 + 12 * 2)[0]
        for i in range(96):
            value = (data[addr + i] | data[addr + 96 + i] << 8) + rng.randrange(-2, 3)
            data[addr + i], data[addr + 96 + i] = value & 255, (value >> 8) & 255
        return data

    def test_differential_fuzz(self):
        rng = random.Random(0xCC407)
        cases = int(os.environ.get('CTPLAYER_FUZZ_CASES', '40'))
        calls = int(os.environ.get('CTPLAYER_FUZZ_FRAMES', '300'))
        compared = mismatches = 0
        for case in range(cases):
            with self.subTest(case=case):
                image = self.make_song(rng, case)
                ct, sid, trace = (self.directory / name for name in ('song.ct', 'song.sid', 'song.trace'))
                ct.write_bytes(b'CC2' + zlib.compress(image))
                self.run_tool('sid', str(ct), '-o', str(sid))
                self.run_tool('sidtrace', str(sid), '-f', str(calls), '-o', str(trace))
                expected = parse_trace(trace.read_text())
                player = CTPlayer(image)
                actual = player.frames(calls // 2) + player.frames(calls - calls // 2)
                for call, (left, right) in enumerate(zip(actual, expected)):
                    compared += 1
                    if left != right:
                        mismatches += 1
                        self.fail(f'case={case} call={call} multiplier={player.multiplier} '
                                  f'model={left.hex()} SID={right.hex()}')
                self.assertEqual(len(expected), calls)
        print(f'CTPlayer: {compared} frames compared, {mismatches} mismatches')

    def test_voice_matches_export(self):
        seed = bytearray(25)
        seed[0:2] = bytes((0x68, 0x11))
        seed[4:7] = bytes((0x41, 0x12, 0xA8))
        seed[24] = 15
        song, _ = native_song(self.template, [bytes(seed)] * 32, 1, 4,
                              ['One voice', '', ''])
        image = zlib.decompress(song[3:])
        ct, sid, trace = (self.directory / name for name in
                          ('voice.ct', 'voice.sid', 'voice.trace'))
        ct.write_bytes(song)
        self.run_tool('sid', str(ct), '-o', str(sid))
        self.run_tool('sidtrace', str(sid), '-f', '30', '-o', str(trace))
        expected = parse_trace(trace.read_text())
        self.assertEqual(CTPlayer(image).frames(30), expected)
        events = [(2, 48)] + [(call, 0) for call in range(6, 30, 4)]
        actual = simulate_voice(1, events, 30, image)
        # The fitter has no cold-start call; compare after the song's reset.
        self.assertEqual([f[:7] for f in actual[1:]],
                         [f[:7] for f in expected[1:]])

    def test_voice_entry_point(self):
        image = self.make_song(random.Random(7), 0)
        result = simulate_voice(1, [(0, 36), (12, 40, 3, True), (24, 1)], 80, image)
        self.assertEqual(len(result), 80)
        self.assertTrue(all(len(frame) == 25 for frame in result))
        self.assertTrue(any(frame[4] & 1 for frame in result))


if __name__ == '__main__':
    unittest.main()
