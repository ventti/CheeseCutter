"""Packed GT2 rows, relocation and real HVSC timelines (no bundled music)."""
from pathlib import Path
import os
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from sid2ct import convert, memtrace
from sid2ct.players import goattracker
from sid2ct.players.hints import gate_rise_agreement
from sid2ct.players.sidid import identify

ROOT = Path(__file__).resolve().parents[1]
HVSC = Path(os.environ.get('HVSC_ROOT', ROOT.parent / 'shallowsid/_hvsc-source'))
TOOL = ROOT / 'ct2util'


def fixture(load=0x2000):
    payload = bytearray(0x300)
    def word(n):
        return struct.pack('<H', load + n)
    def pointers(lo, hi):
        return b'\xb9' + word(lo) + b'\x85\x02\xb9' + word(hi) + b'\x85\x03'
    payload[0x10:0x1e] = pointers(0x100, 0x103) + b'\xb1\x02\xc9\xff'
    payload[0x40:0x47] = b'\xbd\x00\x02\xc9\x02\xf0\x16'
    payload[0x60:0x6e] = pointers(0x106, 0x107) + b'\xb1\x02\xc9\x40'
    payload[0x80:0x8d] = b'\xa9\x03\x9d\x00\x02\xa9\x01\x9d\x01\x02\x9d\x02\x02'
    for v in range(3):
        address = load + 0x110 + v * 3
        payload[0x100 + v] = address & 255
        payload[0x103 + v] = address >> 8
        payload[0x110 + v * 3:0x113 + v * 3] = b'\x00\xff\x00'
    payload[0x106], payload[0x107] = (load + 0x130) & 255, (load + 0x130) >> 8
    payload[0x130:0x136] = b'\x01\x60\xfe\x61\xbd\x00'
    header = bytearray(124)
    header[:4] = b'PSID'
    struct.pack_into('>7H', header, 4, 2, 124, load, load, load + 3, 1, 1)
    return bytes(header + payload)


class PackedRows(unittest.TestCase):
    def test_packed_rests_and_persistent_effects(self):
        rows = goattracker._pattern(bytes([1, 0x41, 7, 0x60, 0xFE, 0x50, 0x61, 0]), 0)
        self.assertEqual([r.note for r in rows], [0x60, 0xBD, 0xBD, 0xBD, 0x61])
        self.assertEqual([r.instrument for r in rows], [1, None, None, None, None])
        self.assertEqual([r.command for r in rows], [(1, 7)] * 3 + [(0, 0)] * 2)
        self.assertEqual([r.address for r in rows], [0, 4, 4, 5, 6])

    def test_repeat_follows_pattern_and_transpose_survives(self):
        entries, loop = goattracker._orders(bytes([0xEE, 0, 0xD2, 1, 255, 0]), [[], []])
        self.assertEqual(entries, [(0, -2)] * 3 + [(1, -2)])
        self.assertEqual(loop, 0)

    def test_relocated_shared_pattern_timing(self):
        for load in (0x1000, 0x4800):
            with self.subTest(load=load), patch.object(goattracker, 'identify', return_value=['GoatTracker_V2.x']):
                raw = fixture(load)
                calls = []
                for i, offset in enumerate((0x130, 0x132, 0x132, 0x133, 0x134)):
                    calls.append(memtrace.Call(2 + i * 4,
                                 [(load + 0x106, load + 0x107),
                                  (load + offset, load + offset + 1)], [], []))
                frames = [bytes(25)] * 24
                for call in (4, 16):
                    f = bytearray(25)
                    for voice in range(3):
                        f[4 + 7 * voice] = 1
                    frames[call] = bytes(f)
                hints = goattracker.extract(raw, 1, frames, calls)
                self.assertIsNotNone(hints)
                for voice in hints.voices:
                    self.assertEqual(voice.row_calls, [4, 8, 12, 16, 20])
                    self.assertEqual([n.note for n in voice.notes], [0, 1])
                    self.assertEqual(voice.pattern_calls, [4])
                self.assertEqual(hints.tempo_calls, [4] * 4)
                self.assertEqual(gate_rise_agreement(hints, frames), 1)

    def test_tempo_change_uses_observed_fetch_spacing(self):
        load = 0x2000
        raw = bytearray(fixture(load))
        raw[124 + 0x130:124 + 0x137] = b'\x01\x4f\x06\x60\xfe\x61\x00'
        calls = [memtrace.Call(call, [(load + 0x106, load + 0x107),
                                      (load + address, load + address)], [], [])
                 for call, address in ((2, 0x130), (8, 0x134), (14, 0x134), (20, 0x135))]
        with patch.object(goattracker, 'identify', return_value=['GoatTracker_V2.x']):
            hints = goattracker.extract(bytes(raw), 1, [bytes(25)] * 30, calls)
        self.assertIsNotNone(hints)
        self.assertEqual(hints.tempo_calls, [6, 6, 6])
        self.assertEqual(hints.voices[0].row_calls, [4, 10, 16, 22])
        self.assertEqual([n.command for n in hints.voices[0].notes], [(15, 6)] * 2)

    def test_invalid_and_unrecognised_inputs(self):
        for raw in (b'', b'PSID', bytes(124), fixture()):
            self.assertIsNone(goattracker.extract(raw, 1, [bytes(25)], []))
        with patch.object(goattracker, 'identify', return_value=['GoatTracker_V2.x']):
            self.assertIsNone(goattracker.extract(fixture(), 2, [bytes(25)], []))
        with self.assertRaises(ValueError):
            goattracker.to_sng(fixture())


@unittest.skipUnless(HVSC.is_dir() and TOOL.is_file(), 'HVSC and ct2util required')
class HVSCTimelines(unittest.TestCase):
    SONGS = ('Adriana', 'Armageddon', 'Attitude_20', 'A_New_Beginning', 'Airwolf', 'Alvar')

    def test_corpus_and_full_composer_folder(self):
        for name in self.SONGS:
            with self.subTest(song=name), tempfile.TemporaryDirectory() as tmp:
                path = HVSC / 'MUSICIANS/H/Hannula_Antti' / (name + '.sid')
                if not path.exists():
                    self.skipTest(f'Missing HVSC song: {name}')
                tmp = Path(tmp)
                trace, reads = tmp / 'registers.trace', tmp / 'reads.tsv'
                with (tmp / 'command.log').open('w') as log:
                    subprocess.run([str(TOOL), 'sidtrace', str(path), '-s', '1', '-f', '3000',
                                    '--mem-reads', str(reads), '-o', str(trace)],
                                   stdout=log, stderr=log, check=True)
                raw = path.read_bytes()
                self.assertIn('GoatTracker_V2.x', identify(raw))
                frames = convert.parse_trace(trace.read_text())
                calls = memtrace.load(reads)
                hints = goattracker.extract(raw, 1, frames, calls)
                self.assertIsNotNone(hints)
                self.assertGreater(sum(len(v.notes) for v in hints.voices), 100)
                self.assertGreaterEqual(gate_rise_agreement(hints, frames), 0.98)
                layout = goattracker._layout(raw, 1)
                fetches = [c.index for c in calls if any(
                    a < layout.pattern_hi and b >= layout.pattern_lo
                    for a, b in c.reads)]
                # Measured row gaps, rather than an assumed six-call grid.
                for voice in hints.voices:
                    row_gaps = {b - a for a, b in zip(voice.row_calls, voice.row_calls[1:])}
                    read_gaps = {b - a for a, b in zip(fetches, fetches[1:])}
                    self.assertTrue(read_gaps)
                    self.assertTrue(row_gaps & read_gaps)

    def test_rebuilt_sng_import(self):
        path = HVSC / 'MUSICIANS/H/Hannula_Antti/Armageddon.sid'
        if not path.exists():
            self.skipTest('Missing Armageddon.sid')
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            source, output = tmp / 'recovered.sng', tmp / 'recovered.ct'
            raw = path.read_bytes()
            layout = goattracker._layout(raw, 1)
            self.assertEqual(set(layout.tables), {'wave', 'pulse', 'filter', 'speed'})
            self.assertTrue(layout.instruments)
            source.write_bytes(goattracker.to_sng(raw))
            self.assertEqual(source.read_bytes()[:4], b'GTS5')
            with (tmp / 'import.log').open('w') as log:
                result = subprocess.run([str(TOOL), 'sng2ct', str(source), '-o', str(output)],
                                        stdout=log, stderr=log)
            self.assertEqual(result.returncode, 0, (tmp / 'import.log').read_text())
            self.assertGreater(output.stat().st_size, 100)


if __name__ == '__main__':
    unittest.main()
