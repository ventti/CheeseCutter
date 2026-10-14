"""Differential fuzzing of the Python CT player against exported SID calls."""
from collections import Counter
import time
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
        cls.started = time.perf_counter()
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
        print(f'CTPlayer suite run time: {time.perf_counter() - cls.started:.2f} s')

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
        count = 16 if case % 4 == 0 else rng.randrange(5, 17)
        for instrument in range(1, count + 1):
            start = (instrument - 1) * 16
            for i in range(14):
                wave[start + i] = rng.choice([0, 0, 4, 7, 12, 0x80 + rng.randrange(24, 70)])
                control[start + i] = rng.choice([0, rng.randrange(1, 16), 0x11,
                    0x21, 0x41, 0x81, 0x15, 0xE0, 0xE1, 0xE9])
            wave[start + 14] = rng.choice([126, 127])
            control[start + 14] = start + rng.randrange(14) if wave[start + 14] == 127 else 0
            definition = [rng.randrange(256), rng.randrange(256),
                rng.choice([0, 0x40, 0x80, 0xA0, 0xC0, 0xE0]) | rng.randrange(4),
                rng.randrange(256), 1 + (instrument - 1) % 15,
                rng.choice([1 + (instrument - 1) % 15, 0x80 | rng.randrange(16)]),
                rng.randrange(256), start]
            for col, value in enumerate(definition):
                instruments[col * 48 + instrument] = value
        # Four-row programs: advance, jump, loop or stop; $ff keeps the preset.
        for row in range(1, 64):
            pulse[row * 4:row * 4 + 4] = [rng.randrange(4) | rng.choice([0, 128]),
                rng.randrange(256), rng.choice([255, rng.randrange(256)]),
                rng.choice([0, 127, rng.randrange(1, 64)])]
            mode, route = (case // 16) % 8, case % 16
            filt[row * 4:row * 4 + 4] = [0x80 | mode << 4,
                rng.randrange(16) << 4 | route, rng.choice([255, rng.randrange(255)]),
                rng.choice([0, 127, rng.randrange(1, 64)])]
        for base in range(1, 61, 4):
            for table in (pulse, filt):
                table[(base + 1) * 4:(base + 1) * 4 + 4] = [rng.randrange(4), rng.randrange(256), 255, 0]
                table[(base + 2) * 4 + 3] = rng.choice([base, base + 3, 127])
                table[(base + 3) * 4 + 3] = 127
        pulse[255] = filt[255] = 127
        commands = [0] * 256
        commands[64] = rng.randrange(256)
        for i in range(1, 10):
            commands[i] = i - 1
            commands[64 + i] = rng.randrange(16) if i in (3, 6, 8) else rng.randrange(256)
            commands[128 + i] = rng.randrange(256)
        chord = [rng.randrange(2, 6), rng.randrange(2, 6), 0x80]
        for _ in range(15):
            start = len(chord)
            chord.extend([rng.randrange(13), rng.randrange(0x70, 0x80),
                          rng.randrange(13), 0x80 | start])
        chord += [0] * (128 - len(chord))
        for index, values in [(14, wave), (15, control), (16, filt),
                              (17, pulse), (18, instruments), (24, commands), (30, chord)]:
            patch(data, index, values)
        # Only the combination of a retained porta command and inline >= $c0
        # has the documented relocation-dependent lookup quirk.
        porta = case % 2 == 0
        supers = list(range(1, 10)) + [0x41, 0x61, *range(0x81, 0x90),
                                      *range(0xA0, 0xC0)]
        if not porta:
            supers.remove(8)  # command index 8 has opcode 7
            supers += list(range(0xC0, 0x100))
        for voice in range(3):
            for sequence in (voice * 2 + 1, voice * 2 + 2):
                raw = []
                for row in range(24):
                    if row >= 9 and rng.randrange(4) == 0:
                        raw.extend([0xF0, 0xF0, 0x60, 0])
                        continue
                    raw.extend([0xC0 + rng.randrange(1, count + 1),
                                0x5F if row and rng.randrange(4) == 0 else 0xF0])
                    note = rng.choice([0, 1, 2, rng.randrange(24, 60)]) if row else rng.randrange(24, 60)
                    raw.extend([0x60 + note, supers[row % len(supers)] if row < 9 else rng.choice(supers)])
                raw.append(0xBF)
                lo = struct.unpack_from('<H', data, 0xFA0 + 22 * 2)[0]
                hi = struct.unpack_from('<H', data, 0xFA0 + 23 * 2)[0]
                addr = data[lo + sequence] | data[hi + sequence] << 8
                data[addr:addr + 256] = bytes(raw).ljust(256, b'\0')
            order = bytes([0xA0 + rng.randrange(-12, 13), voice * 2 + 1,
                           0xA0 + rng.randrange(-12, 13), voice * 2 + 2, 0xF0, 2])
            start = 65536 + 256 + 5 + 160 + 2048 + voice * 1024
            data[start:start + 1024] = order.ljust(1024, b'\0')
            patch(data, 19 + voice, order.ljust(1024, b'\0'))
        # Two subtunes have separate transposes, speeds and nonzero loop targets.
        tracks = 65536 + 256 + 5 + 160 + 2048
        for voice in range(3):
            order = bytes([0x98, voice * 2 + 2, 0xA5, voice * 2 + 1, 0xF0, 2])
            data[tracks + (3 + voice) * 1024:tracks + (4 + voice) * 1024] = order.ljust(1024, b'\0')
        multiplier = (case % 4) + 1
        data[65538] = multiplier
        data[65541:65573] = bytes([case % 2, rng.choice([0, 1, 2, 3])]) + bytes([3]) * 30
        # Custom image tuning must survive model and optimized export alike.
        addr = struct.unpack_from('<H', data, 0xFA0 + 12 * 2)[0]
        for i in range(96):
            value = (data[addr + i] | data[addr + 96 + i] << 8) + rng.randrange(-2, 3)
            data[addr + i], data[addr + 96 + i] = value & 255, (value >> 8) & 255
        return data

    def test_differential_fuzz(self):
        rng = random.Random(0xCC407)
        cases = int(os.environ.get('CTPLAYER_FUZZ_CASES', '128'))
        calls = int(os.environ.get('CTPLAYER_FUZZ_FRAMES', '240'))
        started = time.perf_counter()
        coverage = Counter()
        compared = mismatches = 0
        for case in range(cases):
            with self.subTest(case=case):
                image = self.make_song(rng, case)
                ct, sid, trace = (self.directory / name for name in ('song.ct', 'song.sid', 'song.trace'))
                ct.write_bytes(b'CC2' + zlib.compress(image))
                self.run_tool('sid', str(ct), '-o', str(sid))
                self.run_tool('sidtrace', str(sid), '-s', str(case % 2 + 1), '-f', str(calls), '-o', str(trace))
                expected = parse_trace(trace.read_text())
                player = CTPlayer(image, subtune=case % 2)
                actual = []
                for _ in range(calls):
                    actual += player.frames(1)
                    coverage[f'multiplier-{player.multiplier}'] += 1
                    coverage[f'subtune-{case % 2}'] += 1
                    coverage['swing'] += player.speed < 2
                    coverage['order-loop'] += any(v.trackpos == 2 for v in player.voices)
                    for v in player.voices:
                        definition = player._instrument(v.shinst)
                        coverage[f'hr-{definition[2] & 0xE0:02x}'] += v.synccnt == 0
                        coverage['instrument-16'] += v.shinst == 16
                        if v.synccnt == 0:
                            coverage[f'hr-wave-{definition[3]}'] += 1
                            coverage[f'hr-sr-{definition[6]}'] += 1
                        coverage['absolute-note'] += v.wavetrans >= 128
                        coverage['negative-transpose'] += v.shtrans >= 128
                        coverage['tie'] += bool(v.tie)
                        coverage['duration'] += v.duration > 0
                        coverage['chord-loop'] += v.chordpos < 128
                        coverage['chord-negative'] += v.chordvalue >= 128
                        coverage['wave-long'] += v.wavepos % 16 >= 8
                        coverage['wave-jump'] += player._read(14, (v.wavepos + 1) & 255) == 127
                        coverage['wave-stop'] += player._read(14, (v.wavepos + 1) & 255) == 126
                        if v.shsuper < 64 and v.shsuper:
                            coverage[f'command-{player._read(24, v.shsuper)}'] += 1
                        if v.shsuper >= 192:
                            coverage[f'inline-{v.shsuper:02x}'] += 1
                        coverage['speed-super'] += v.shsuper > 240
                        for name, table, pos in [('pulse', 17, v.pulsecur),
                                                 ('filter', 16, player.filtcur)]:
                            nxt = player._read(table, pos + 3)
                            coverage[name + '-advance'] += nxt == 0
                            coverage[name + '-stop'] += nxt == 127
                            coverage[name + '-jump'] += 0 < nxt < 127
                            coverage[name + '-loop'] += 0 < nxt < 127 and nxt * 4 <= pos
                            coverage[name + '-keep'] += player._read(table, pos + 2) == 255
                for call, (left, right) in enumerate(zip(actual, expected)):
                    compared += 1
                    coverage['filter-mode-' + str((right[24] >> 4) & 7)] += 1
                    coverage['filter-route-' + str(right[23] & 15)] += 1
                    coverage[f'filter-combination-{(right[24] >> 4) & 7}-{right[23] & 15}'] += 1

                    if left != right:
                        mismatches += 1
                        self.fail(f'case={case} call={call} multiplier={player.multiplier} '
                                  f'model={left.hex()} SID={right.hex()}')
                self.assertEqual(len(expected), calls)
        if cases >= 128 and calls >= 240:
            features = ['swing', 'order-loop', 'instrument-16', 'absolute-note',
                        'negative-transpose', 'tie', 'duration', 'chord-loop',
                        'chord-negative', 'wave-long', 'wave-jump', 'wave-stop', 'speed-super']
            features += [f'{table}-{kind}' for table in ('pulse', 'filter')
                         for kind in ('advance', 'stop', 'jump', 'loop', 'keep')]
            features += [f'command-{op}' for op in (0, 1, 2, 4, 5, 7, 8)]
            features += [f'hr-{hr:02x}' for hr in (0, 0x40, 0x80, 0xA0, 0xC0, 0xE0)]
            features += [f'inline-{byte:02x}' for byte in range(192, 256)]
            features += [f'multiplier-{m}' for m in range(1, 5)]
            features += [f'subtune-{sub}' for sub in range(2)]
            self.assertGreater(sum(key.startswith('hr-wave-') for key in coverage), 16)
            self.assertGreater(sum(key.startswith('hr-sr-') for key in coverage), 16)
            for feature in features:
                self.assertGreater(coverage[feature], 0, feature)
            for mode in range(8):
                self.assertGreater(coverage[f'filter-mode-{mode}'], 0)
                for route in range(16):
                    self.assertGreater(coverage[f'filter-combination-{mode}-{route}'], 0, (mode, route))
            for route in range(16):
                self.assertGreater(coverage[f'filter-route-{route}'], 0)
        print(f'CTPlayer: {compared} frames compared, {mismatches} mismatches, '
              f'{time.perf_counter() - started:.2f} s')

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

    def test_voice_full_note_registers(self):
        image = self.make_song(random.Random(19), 1)
        # Retain a silent wave chunk for the two inactive voices, and give
        # the selected voice a sustained pulse/filter note followed by release.
        patch(image, 30, [0, 0, 0x80])
        patch(image, 14, [0, 126, 0, 7, 0, 127])
        patch(image, 15, [0, 0, 0x41, 0x41, 0x41, 2])
        definitions = [0] * 384
        for col, value in enumerate([0x24, 0xA8, 0x80, 0x08, 1, 1, 0x09, 2]):
            definitions[col * 48 + 1] = value
        patch(image, 18, definitions)
        patch(image, 17, [0, 0, 255, 127, 2, 19, 0x48, 1])
        patch(image, 16, [0, 0, 255, 127, 0xB0, 0xF1, 64, 2,
                          3, 5, 255, 2])
        # No frequency in the silent chunk; the inactive voices remain zero.
        freq = struct.unpack_from('<H', image, 0xFA0 + 12 * 2)[0]
        if freq == struct.unpack_from('<H', image, 0xFA0 + 13 * 2)[0]:
            freq += 1
        image[freq] = image[freq + 96] = 0
        for sequence, raw in [(1, [0xC1, 0xF0, 0x90, 0] +
                                   [0xF0, 0xF0, 0x60, 0] * 15 +
                                   [0xF0, 0xF0, 0x61, 0] +
                                   [0xF0, 0xF0, 0x60, 0] * 15 + [0xBF]),
                              (2, [0xC0, 0xF0, 0x60, 0, 0xBF])]:
            lo = struct.unpack_from('<H', image, 0xFA0 + 22 * 2)[0]
            hi = struct.unpack_from('<H', image, 0xFA0 + 23 * 2)[0]
            addr = image[lo + sequence] | image[hi + sequence] << 8
            image[addr:addr + 256] = bytes(raw).ljust(256, b'\0')
        tracks = 65536 + 256 + 5 + 160 + 2048
        for voice in range(3):
            order = bytes([0xA0, 1 if voice == 0 else 2, 0xF0, 0]).ljust(1024, b'\0')
            image[tracks + voice * 1024:tracks + (voice + 1) * 1024] = order
            patch(image, 19 + voice, order)
        image[65538] = 1
        image[65541] = 3
        ct, sid, trace = (self.directory / name for name in
                          ('full-note.ct', 'full-note.sid', 'full-note.trace'))
        ct.write_bytes(b'CC2' + zlib.compress(image))
        self.run_tool('sid', str(ct), '-o', str(sid))
        self.run_tool('sidtrace', str(sid), '-f', '110', '-o', str(trace))
        expected = parse_trace(trace.read_text())
        actual = simulate_voice(1, [(2, 48), (66, 1)], 110, image)
        self.assertTrue(any(frame[4] & 1 for frame in expected[4:66]))
        self.assertFalse(expected[-1][4] & 1)
        self.assertEqual(actual, expected)
        print('simulate_voice: 110 full-register frames compared, 0 mismatches')

    def test_voice_entry_point(self):
        image = self.make_song(random.Random(7), 0)
        result = simulate_voice(1, [(0, 36), (12, 40, 3, True), (24, 1)], 80, image)
        self.assertEqual(len(result), 80)
        self.assertTrue(all(len(frame) == 25 for frame in result))
        self.assertTrue(any(frame[4] & 1 for frame in result))


if __name__ == '__main__':
    unittest.main()
