"""DMC structure decoding: synthetic data plus optional full-folder HVSC songs."""
import os
import random
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from sid2ct.convert import parse_trace
from sid2ct.memtrace import Call, load
from sid2ct.players import dmc
from sid2ct.players.hints import NoteHint, SequenceInfo, StructureHints, VoiceHints, gate_rise_agreement
from sid2ct.players.sidid import identify

ROOT = Path(__file__).resolve().parents[1]
HVSC = Path(os.environ.get('HVSC_ROOT', str(ROOT.parent / 'shallowsid/_hvsc-source')))


def fixture(base=0x2000, modern=False, embedded_load=False):
    """Small invented song, with relocated operands; no copyrighted song data."""
    data = bytearray(0x1000)
    def word(at, value):
        struct.pack_into('<H', data, at, value)
    def instruction(at, opcode, target):
        data[at] = opcode
        word(at + 1, base + target)
    instruction(0, 0x4c, 0x37)
    instruction(3, 0x4c, 0xa1 if modern else 0x85)
    if modern:
        data[0xa1:0xa9] = bytes.fromhex('a5 f8 48 a5 f9 48 a2 00')
        instruction(0xa9, 0xad, 0x842)
        instruction(0xb4, 0xce, 0x13)
        plo, phi, inst, work = 0x14e, 0x153, 0x2cb, 0x7cf
    else:
        instruction(0x85, 0xce, 0x718)
        data[0x125:0x127] = b'\xc9\x7e'
        plo, phi, inst, work = 0x102, 0x107, 0x226, 0x707
    instruction(0x40, 0xb9, 0x900)
    instruction(0x43, 0x9d, work)
    instruction(plo, 0xb9, 0x920)
    data[plo + 3:plo + 5] = b'\x85\xf8'
    instruction(phi, 0xb9, 0x930)
    data[phi + 3:phi + 5] = b'\x85\xf9'
    instruction(inst, 0xb9, 0x980)
    for v in range(3):
        word(0x900 + v * 2, base + 0x940 + v * 4)
        # Distinct pattern streams prevent a read by one voice matching another.
        data[0x940 + v * 4:0x944 + v * 4] = bytes((v, 0xff, 0, 0xfe))
        ptr = base + 0xa00 + v * 0x20
        data[0x920 + v], data[0x930 + v] = ptr & 255, ptr >> 8
        pattern = bytes((0xfc, 2, 0xfd, 1, 24, 0xf5, 25, 0xfe, 0xff)) if modern else bytes((0x62, 0x81, 24, 0x7c, 25, 0x7e, 0x7f))
        data[0xa00 + v * 0x20:0xa00 + v * 0x20 + len(pattern)] = pattern
    data[0x906] = 3  # four play calls per source row
    data[0x980:0xa00] = bytes(range(128))
    header = bytearray(124)
    header[:4] = b'PSID'
    struct.pack_into('>7H', header, 4, 2, 124, 0 if embedded_load else base, base, base + 3, 1, 1)
    raw = bytes(header) + (base.to_bytes(2, 'little') if embedded_load else b'') + data
    calls = []
    for i in range(12):
        reads = []
        if i in (0, 4, 8):
            for v in range(3):
                ptr = base + 0xa00 + v * 0x20
                lo, hi = ((0, 5), (5, 7), (7, 8))[i // 4] if modern else ((0, 3), (3, 5), (5, 6))[i // 4]
                reads.extend([(base + 0x940 + v * 4, base + 0x940 + v * 4), (ptr + lo, ptr + hi)])
        calls.append(Call(i, reads, [], []))
    frames = [bytes(25)] * 12
    return raw, frames, calls


class DmcSyntheticTests(unittest.TestCase):
    def extract(self, raw, frames, calls):
        with patch.object(dmc, 'identify', return_value=['DMC']):
            return dmc.extract(raw, 1, frames, calls, validate=False)

    def test_relocated_classic_and_embedded_load(self):
        for base, embedded in ((0x2000, False), (0x4000, True)):
            raw, frames, calls = fixture(base, embedded_load=embedded)
            h = self.extract(raw, frames, calls)
            self.assertIsNotNone(h)
            self.assertEqual(h.version, '4')
            self.assertEqual(h.tempo_calls, [4])
            for v in h.voices:
                self.assertEqual(v.row_calls, [0, 4, 8])
                self.assertEqual([(n.call, n.note, n.instrument, n.tie) for n in v.notes if n.kind == 'note'],
                                 [(1, 24, 2, False), (5, 25, None, True)])
                self.assertEqual(v.loop_index, 0)
                self.assertEqual(v.row_durations, [4, 4, 4])
                self.assertEqual(next(iter(v.sequences.values())).length, 7)
                self.assertEqual([n.kind for n in v.notes], ['note', 'note', 'rest'])
            self.assertEqual(h.instruments[2]['raw'], tuple(range(22, 33)))
            self.assertEqual(h.speed_commands, [(0, 4)])

    def test_modern_commands_and_same_call_attacks(self):
        raw, frames, calls = fixture(modern=True)
        h = self.extract(raw, frames, calls)
        self.assertIsNotNone(h)
        self.assertEqual(h.version, '5')
        self.assertEqual([(n.call, n.note, n.tie) for n in h.voices[0].notes if n.kind == 'note'],
                         [(0, 24, False), (4, 25, True)])
        self.assertEqual(h.instruments[2]['raw'], tuple(range(16, 24)))

    def test_signed_transpose_and_loop(self):
        raw, frames, calls = fixture()
        data = bytearray(raw)
        for v in range(3):
            off = 124 + 0x940 + v * 4
            data[off:off + 4] = bytes((0x83, v, 0xff, 0))
            for c in calls:
                if c.reads:
                    c.reads.append((0x2940 + v * 4 + 1, 0x2940 + v * 4 + 1))
        h = self.extract(bytes(data), frames, calls)
        self.assertEqual(h.voices[0].orderlist, [(0, -3)])
        self.assertEqual([n.note for n in h.voices[0].notes if n.kind == 'note'], [21, 22])
        self.assertEqual(h.voices[0].loop_index, 0)

    def test_wave_program_and_trace_independence(self):
        raw, frames, calls = fixture(modern=True)
        raw = bytearray(raw)
        for offset, target in ((0x386, 0xb00), (0x390, 0xb04)):
            raw[124 + offset - 1] = 0xb9
            struct.pack_into('<H', raw, 124 + offset, 0x2000 + target)
        raw[124 + 0xb00:124 + 0xb08] = bytes((0, 0x40, 0x41, 0x90, 0, 0, 0, 1))
        raw[124 + 0x980 + 2 * 8 + 2] = 1
        for i, pointer in ((1, 1), (2, 2), (3, 3), (4, 2)):
            calls[i].reads.append((0x2b00 + pointer, 0x2b00 + pointer))
        hints = self.extract(bytes(raw), frames, calls)
        self.assertIn((2, 'effect', False), [(n.call, n.kind, n.tie)
                      for n in hints.voices[0].notes])
        rng = random.Random(37)
        flipped = [bytes(rng.randrange(256) for _ in range(25)) for _ in frames]
        self.assertIsNotNone(hints)
        self.assertEqual(hints, self.extract(bytes(raw), [], calls))
        self.assertEqual(hints, self.extract(bytes(raw), flipped, calls))
        self.assertEqual(hints, self.extract(bytes(raw), [bytes(25)] * len(frames), calls))
        calls[2].reads.clear()
        missing = self.extract(bytes(raw), frames, calls)
        self.assertFalse(any(n.kind == 'effect' and not n.tie
                             for n in missing.voices[0].notes))

    def test_wave_speed_and_source_gate_toggle(self):
        # 95 wave speed 1 holds each source row for two calls.
        voice = VoiceHints(notes=[NoteHint(0, 24, 1),
                                 NoteHint(3, 24, None, True, (0xf4,), 'effect'),
                                 NoteHint(4, 24, None, True, (0xf4,), 'effect')])
        hints = StructureHints('DMC', '5', (voice, VoiceHints(), VoiceHints()),
            instruments={1: {'raw': (0, 0, 0, 0, 0, 0, 0x10, 0)}},
            tables={'wave': {'address': 0x3000, 'left': bytes((0x40, 0x41, 0x90)),
                             'right': bytes((0, 0, 0))}})
        calls = [Call(i, [(0x3000 + pointer, 0x3000 + pointer)], [], [])
                 for i, pointer in enumerate((0, 0, 0, 1, 1, 2, 0, 1))]
        dmc._wave_effects(hints, calls, '95')
        self.assertIn((3, 'gate_off', True), [(n.call, n.kind, n.tie) for n in voice.notes])
        self.assertIn((4, 'effect', False), [(n.call, n.kind, n.tie) for n in voice.notes])

    def test_gate_command_and_sequence_parameter_markers(self):
        raw, frames, calls = fixture(modern=True)
        raw = bytearray(raw)
        raw[124 + 0xa07] = 0xf4
        frame = bytearray(25)
        frame[4] = 0x41
        frames[8] = bytes(frame)
        hints = self.extract(bytes(raw), frames, calls)
        event = hints.voices[0].notes[-1]
        self.assertEqual((event.call, event.kind, event.tie, event.command), (8, 'effect', True, (0xf4,)))
        self.assertEqual(hints.voices[0].sequences[0], SequenceInfo(0x2a00, 9))
        frames[6] = frames[7] = frames[8]
        frames[8] = bytes(25)
        hints = self.extract(bytes(raw), frames, calls)
        self.assertEqual(hints.voices[0].notes[-1].kind, 'effect')
        self.assertTrue(hints.voices[0].notes[-1].tie)
        memory = bytes((0xfb, 1, 24, 0xff, 0xfe, 0xff))
        self.assertEqual(dmc._sequence(memory, 0, True, 0xfe, 0, len(memory)), SequenceInfo(0, 6))
        classic = bytes((0x62, 0x81, 24, 0xfd, 0xfe, 0xff))
        self.assertEqual(dmc._sequence(classic, 0, False, 0xfe, 0, len(classic)), SequenceInfo(0, 6))

    def test_safe_rejection(self):
        raw, frames, calls = fixture()
        for bad in (b'', raw[:130], b'RSID' + raw[4:]):
            self.assertIsNone(dmc.extract(bad, 1, frames, calls))
        with patch.object(dmc, 'identify', return_value=['DMC']):
            self.assertIsNone(dmc.extract(raw, 2, frames, calls))
        self.assertIsNone(dmc.extract(raw, 1, frames, calls[:-1]))
        calls[4].index = 5
        self.assertIsNone(self.extract(raw, frames, calls))

    def test_loop_call_and_pattern_boundary(self):
        raw, frames, calls = fixture()
        frames += [bytes(25)] * 4
        calls += [Call(i, list(calls[0].reads) if i == 12 else [], [], [])
                  for i in range(12, 16)]
        h = self.extract(raw, frames, calls)
        self.assertEqual(h.loop_call, 12)
        self.assertEqual(h.voices[0].pattern_calls, [0, 12])
        self.assertEqual(h.voices[0].notes[-1].call, 13)
        self.assertFalse(h.voices[0].notes[-1].tie)

    def test_selected_subtune_record(self):
        raw, frames, calls = fixture()
        data = bytearray(raw)
        struct.pack_into('>H', data, 14, 2)
        data[124 + 0x908:124 + 0x910] = data[124 + 0x900:124 + 0x908]
        data[124 + 0x900:124 + 0x908] = bytes(8)
        with patch.object(dmc, 'identify', return_value=['DMC']):
            h = dmc.extract(bytes(data), 2, frames, calls, validate=False)
        self.assertIsNotNone(h)
        self.assertEqual(h.voices[0].notes[0].note, 24)

    def test_tempo_mismatch_and_missing_command_read(self):
        raw, frames, calls = fixture()
        calls[5].reads, calls[4].reads = calls[4].reads, []
        self.assertIsNone(self.extract(raw, frames, calls))
        raw, frames, calls = fixture()
        calls[0].reads = [(a, a) for a, b in calls[0].reads]
        self.assertIsNone(self.extract(raw, frames, calls))

    def test_anchor_and_pattern_reads_are_required(self):
        raw, frames, calls = fixture()
        broken = bytearray(raw)
        broken[124 + 0x86] ^= 1
        self.assertIsNone(self.extract(bytes(broken), frames, calls))
        for c in calls:
            c.reads = [(a, b) for a, b in c.reads if a < 0x2a00]
        self.assertIsNone(self.extract(raw, frames, calls))


@unittest.skipUnless(HVSC.is_dir() and (ROOT / 'ct2util').is_file(), 'HVSC or ct2util missing')
class DmcHvscTests(unittest.TestCase):
    def test_retrigger_recall(self):
        songs = ('P/PRI/Slap_Chill-Out', 'A/Agemixer/Azmagutah_8580',
                 'S/Shogoon/Bilinski', 'A/Agemixer/Moonspire-The_Draxx_War_preview')
        with tempfile.TemporaryDirectory(prefix='dmc-recall-') as tmp:
            for song in songs:
                with self.subTest(song=song):
                    sid = HVSC / ('MUSICIANS/' + song + '.sid')
                    if not sid.is_file():
                        self.skipTest(f'HVSC song missing: {song}')
                    trace, reads, log = [Path(tmp) / x for x in ('trace', 'reads', 'command.log')]
                    with log.open('w') as output:
                        subprocess.run([str(ROOT / 'ct2util'), 'sidtrace', str(sid), '-s', '1',
                                        '-f', '2400', '-o', str(trace), '--mem-reads', str(reads)],
                                       stdout=output, stderr=output, check=True, timeout=60)
                    frames, calls = parse_trace(trace.read_text()), load(reads)
                    hints = dmc.extract(sid.read_bytes(), 1, frames, calls, validate=False)
                    rng = random.Random(37)
                    flipped = []
                    for frame in frames:
                        frame = bytearray(frame)
                        for control in (4, 11, 18):
                            frame[control] ^= rng.randrange(2)
                        flipped.append(bytes(frame))
                    self.assertEqual(hints, dmc.extract(sid.read_bytes(), 1, flipped, calls, validate=False))
                    self.assertEqual(hints, dmc.extract(sid.read_bytes(), 1, [bytes(25)] * len(frames), calls, validate=False))
                    self.assertIsNotNone(hints)
                    self.assertEqual(hints, dmc.extract(sid.read_bytes(), 1, frames, calls))
                    self.assertIsNone(dmc.extract(sid.read_bytes(), 1, [bytes(25)] * len(frames), calls))
                    total = matched = predicted = correct = 0
                    for v, voice in enumerate(hints.voices):
                        control = 4 + 7 * v
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
                    self.assertTrue(hints.tables['wave'])
                    if song.endswith(('Bilinski', 'Moonspire-The_Draxx_War_preview')):
                        self.assertTrue(any(n.kind == 'effect' and not n.tie
                                            for v in hints.voices for n in v.notes))

    def test_corpus_and_full_composer_folders(self):
        songs = [
            ('A/Agemixer/Al-Qaekeuda', '4'),
            ('A/Agemixer/Audio_Man', '4'),
            ('P/PRI/Introwave_edit', '4'),
            ('D/Deetsay/Cappucino', '5'),
            ('D/Deetsay/Inst-Del', '5'),
            ('P/PRI/Short_Fusion', '5'),
            ('P/PRI/Final', '5'),
            ('P/PRI/Neeeaung', '5'),
            ('A/Agemixer/2_Hours_of_Work', '5'),
        ]
        with tempfile.TemporaryDirectory(prefix='dmc-test-') as tmp:
            for song, version in songs:
                with self.subTest(song=song):
                    sid = HVSC / ('MUSICIANS/' + song + '.sid')
                    if not sid.is_file():
                        self.skipTest(f'HVSC song missing: {song}')
                    trace, reads, log = [Path(tmp) / x for x in ('trace', 'reads', 'command.log')]
                    with log.open('w') as output:
                        result = subprocess.run([str(ROOT / 'ct2util'), 'sidtrace', str(sid),
                                                 '-s', '1', '-f', '1200', '-o', str(trace),
                                                 '--mem-reads', str(reads)], stdout=output,
                                                stderr=output, timeout=60)
                    self.assertEqual(result.returncode, 0, log.read_text())
                    frames, calls = parse_trace(trace.read_text()), load(reads)
                    self.assertTrue(any('DMC' in x for x in identify(sid.read_bytes())))
                    h = dmc.extract(sid.read_bytes(), 1, frames, calls)
                    self.assertIsNotNone(h)
                    self.assertEqual(h.version, version)
                    self.assertGreater(sum(len(v.notes) for v in h.voices), 50)
                    self.assertGreaterEqual(gate_rise_agreement(h, frames), 0.98)
                    period = h.tempo_calls[0]
                    for voice in h.voices:
                        self.assertGreater(len(voice.row_calls), 10)
                        self.assertTrue(all((b - a) % period == 0 for a, b in
                                            zip(voice.row_calls, voice.row_calls[1:])))
                        self.assertTrue(all(calls[i].reads for i in voice.row_calls))
                        self.assertTrue(voice.orderlist)
                    self.assertTrue(h.instruments)


if __name__ == '__main__':
    unittest.main()
