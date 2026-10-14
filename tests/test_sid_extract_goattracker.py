"""Packed GT2 rows, relocation and real HVSC timelines (no bundled music)."""
from pathlib import Path
import os
import random
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from sid2ct import convert, memtrace
from sid2ct.players import goattracker
from sid2ct.players.hints import NoteHint, SequenceInfo, VoiceHints, gate_rise_agreement
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
                hints = goattracker.extract(raw, 1, frames, calls, validate=False)
                self.assertIsNotNone(hints)
                for voice in hints.voices:
                    self.assertEqual(voice.row_calls, [4, 8, 12, 16, 20])
                    self.assertEqual([n.note for n in voice.notes if n.kind == 'note'], [0, 1])
                    self.assertEqual(voice.pattern_calls, [4])
                    self.assertEqual(voice.row_durations, [4] * 5)
                    self.assertEqual(voice.sequences, {0: SequenceInfo(load + 0x130, 6)})
                    self.assertEqual([n.kind for n in voice.notes], ['note', 'rest', 'rest', 'note', 'rest'])
                self.assertEqual(hints.tempo_calls, [4] * 4)
                self.assertEqual(gate_rise_agreement(hints, frames), 1)

    def test_tempo_change_uses_observed_fetch_spacing(self):
        load = 0x2000
        raw = bytearray(fixture(load))
        raw[124 + 0x130:124 + 0x137] = b'\x01\x4f\x05\x60\xfe\x61\x00'
        calls = [memtrace.Call(call, [(load + 0x106, load + 0x107),
                                      (load + address, load + address)], [], [])
                 for call, address in ((2, 0x130), (8, 0x134), (14, 0x134), (20, 0x135))]
        with patch.object(goattracker, 'identify', return_value=['GoatTracker_V2.x']):
            hints = goattracker.extract(bytes(raw), 1, [bytes(25)] * 30, calls, validate=False)
        self.assertIsNotNone(hints)
        self.assertEqual(hints.tempo_calls, [6, 6, 6])
        self.assertEqual(hints.voices[0].row_calls, [4, 10, 16, 22])
        self.assertEqual(hints.voices[0].row_durations, [6] * 4)
        self.assertEqual(hints.speed_commands, [(4, 6), (10, 6), (16, 6), (22, 6)])
        self.assertEqual([n.command for n in hints.voices[0].notes if n.kind == 'note'], [(15, 5)] * 2)

    def test_gate_rows_apply_at_fetch_time(self):
        load = 0x2000
        raw = bytearray(fixture(load))
        raw[124 + 0x130:124 + 0x136] = bytes((1, 0x60, 0xbe, 0xbf, 0xbd, 0))
        calls = [memtrace.Call(call, [(load + 0x106, load + 0x107),
                                     (load + address, load + address)], [], [])
                 for call, address in ((2, 0x130), (6, 0x132), (10, 0x133), (14, 0x134))]
        frames = [bytes(25)] * 20
        frame = bytearray(25)
        for v in range(3):
            frame[4 + 7 * v] = 0x41
        frames[4] = frames[10] = bytes(frame)
        with patch.object(goattracker, 'identify', return_value=['GoatTracker_V2.x']):
            hints = goattracker.extract(bytes(raw), 1, frames, calls, validate=False)
        self.assertIsNotNone(hints)
        for voice in hints.voices:
            self.assertEqual([(n.call, n.kind, n.tie) for n in voice.notes],
                             [(4, 'note', False), (6, 'gate_off', True),
                              (10, 'effect', False), (16, 'rest', True)])
        self.assertEqual(gate_rise_agreement(hints, frames), 1)

    def test_wave_program_and_trace_independence(self):
        voice = VoiceHints(notes=[NoteHint(1, 24, 1, command=(0, 0))])
        layout = goattracker.Layout(bytes(65536), [], [], 0, 0, 2, 4,
                                   {1: {'wave': 1, 'first_wave': 0x41}},
                                   {'wave': {'address': 0x3000,
                                    'left': bytes((0x50, 0x51, 255)),
                                    'right': bytes((0, 0, 1)), 'wave_delay': True}})
        calls = [memtrace.Call(i, [(0x3000 + (i - 2) % 2,
                                   0x3000 + (i - 2) % 2)] if i >= 2 else [], [], [])
                 for i in range(6)]
        goattracker._wave_effects(voice, 0, layout, calls)
        self.assertIn((3, 'effect', ('wave', 2, 0x51, 0)),
                      [(n.call, n.kind, n.command) for n in voice.notes])
        load = 0x2000
        raw = fixture(load)
        calls = [memtrace.Call(2 + i * 4, [(load + 0x106, load + 0x107),
                                          (load + offset, load + offset + 1)], [], [])
                 for i, offset in enumerate((0x130, 0x132, 0x132, 0x133, 0x134))]
        zero = [bytes(25)] * 24
        rng = random.Random(37)
        flipped = [bytes(rng.randrange(256) for _ in range(25)) for _ in zero]
        with patch.object(goattracker, 'identify', return_value=['GoatTracker_V2.x']):
            expected = goattracker.extract(raw, 1, zero, calls, validate=False)
            self.assertIsNotNone(expected)
            self.assertEqual(expected, goattracker.extract(raw, 1, [], calls, validate=False))
            self.assertEqual(expected, goattracker.extract(raw, 1, flipped, calls, validate=False))

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

    def test_gate_and_wave_recall(self):
        for song in ('J/Jammer/Club_Stylier', 'S/Shogoon/Goorale_part_3'):
            with self.subTest(song=song), tempfile.TemporaryDirectory() as tmp:
                path = HVSC / ('MUSICIANS/' + song + '.sid')
                if not path.is_file():
                    self.skipTest(f'Missing HVSC song: {song}')
                tmp = Path(tmp)
                trace, reads = tmp / 'trace', tmp / 'reads'
                with (tmp / 'command.log').open('w') as output:
                    subprocess.run([str(TOOL), 'sidtrace', str(path), '-s', '1', '-f', '2400',
                                    '-o', str(trace), '--mem-reads', str(reads)],
                                   stdout=output, stderr=output, check=True, timeout=60)
                frames = convert.parse_trace(trace.read_text())
                calls = memtrace.load(reads)
                hints = goattracker.extract(path.read_bytes(), 1, frames, calls, validate=False)
                rng = random.Random(37)
                flipped = []
                for frame in frames:
                    frame = bytearray(frame)
                    for control in (4, 11, 18):
                        frame[control] ^= rng.randrange(2)
                    flipped.append(bytes(frame))
                self.assertEqual(hints, goattracker.extract(path.read_bytes(), 1, flipped, calls, validate=False))
                self.assertEqual(hints, goattracker.extract(path.read_bytes(), 1, [bytes(25)] * len(frames), calls, validate=False))
                self.assertIsNotNone(hints)
                self.assertEqual(hints, goattracker.extract(path.read_bytes(), 1, frames, calls))
                self.assertIsNone(goattracker.extract(path.read_bytes(), 1, [bytes(25)] * len(frames), calls))
                total = matched = predicted = correct = 0
                for v, voice in enumerate(hints.voices):
                    control = 4 + v * 7
                    eligible = [n for n in voice.notes if n.kind == 'note' and not n.tie
                                or n.kind == 'effect' and not n.tie]
                    rises = [i for i in range(1, len(frames))
                             if frames[i][control] & 1 and not frames[i - 1][control] & 1
                             and any(f[control] & 0xf0 for f in frames[i:i + 4])]
                    predicted += len(eligible)
                    total += len(rises)
                    # Sorted greedy matching is maximal for a fixed +/- one-call window.
                    remaining = iter(rises)
                    rise = next(remaining, None)
                    for event in sorted(eligible, key=lambda n: n.call):
                        while rise is not None and rise < event.call - 1:
                            rise = next(remaining, None)
                        if rise is not None and rise <= event.call + 1:
                            matched += 1
                            correct += 1
                            rise = next(remaining, None)
                    self.assertEqual(len(voice.row_calls), len(voice.row_durations))
                    self.assertTrue(voice.sequences)
                self.assertGreater(total, 100)
                print(f'METRIC {song}: recall={matched / total:.6f} precision={correct / predicted:.6f} rises={total} hints={predicted}', flush=True)
                self.assertGreater(matched, 0)
                self.assertGreaterEqual(gate_rise_agreement(hints, frames), 0.98)
                self.assertEqual(set(hints.tables), {'wave', 'pulse', 'filter', 'speed'})
                self.assertFalse(any('packed_tables' in d for d in hints.instruments.values()))

    def test_twenty_packed_exports(self):
        songs = {
            'J/Jammer': ('3_6-Not_Great_Not_Terrible', '424', '5_A_Dub', '80squares',
                         '90s_Still_Within', 'A_Better_Place', 'Ad_Astra', 'Advanced_Chemistry',
                         'Adventures_of_Pippin_Tom', 'Al-Risah'),
            'S/Shogoon': ('Akron', 'And_Trumpets_for_All', 'Anoushka', 'Ballad_for_Jeff',
                         'Beat_Cut', 'Chinese_Happy_People', 'Chopin_Calling', 'Circles',
                         'Crack_and_Curry', 'Creatures_3'),
        }
        for folder, names in songs.items():
            for name in names:
                with self.subTest(song=name):
                    path = HVSC / 'MUSICIANS' / folder / (name + '.sid')
                    if not path.is_file():
                        self.skipTest(f'Missing HVSC song: {name}')
                    raw = path.read_bytes()
                    layout = goattracker._layout(raw, 1)
                    song = goattracker.to_sng(raw)
                    self.assertEqual(song[:4], b'GTS5')
                    self.assertEqual(set(layout.tables), {'wave', 'pulse', 'filter', 'speed'})
                    self.assertTrue(layout.instruments)
                    for definition in layout.instruments.values():
                        self.assertEqual(set(definition), {'ad', 'sr', 'wave', 'pulse', 'filter',
                                         'speed', 'vibrato_delay', 'gate_timer', 'first_wave'})
                    # Read past orders and instruments to check the four exported tables.
                    offset = 101
                    for _ in range(3):
                        offset += song[offset] + 2
                    count = song[offset]
                    offset += 1 + count * 25
                    for table_name in ('wave', 'pulse', 'filter', 'speed'):
                        size = song[offset]
                        self.assertEqual(size, len(layout.tables[table_name]['left']))
                        offset += 1 + size * 2
                    self.assertEqual(song[offset], len(layout.patterns))
                    if name == '3_6-Not_Great_Not_Terrible':
                        self.assertEqual(layout.instruments[1]['speed'], 0)
                        self.assertEqual(layout.instruments[1]['vibrato_delay'], 0)
                    if name == '424':
                        self.assertTrue(all(d['gate_timer'] == 2 and d['first_wave'] == 9
                                            for d in layout.instruments.values()))
                    if name == 'Chopin_Calling':
                        self.assertEqual(layout.tables['pulse']['left'], b'')

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
                hints = goattracker.extract(raw, 1, frames, calls, validate=False)
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
