"""Packed NP20 extraction, including real HVSC timelines when available."""
import os
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

from sid2ct.convert import parse_trace
from sid2ct.memtrace import Call, find_streams, load
from sid2ct.players.hints import gate_rise_agreement
from sid2ct.players.jch import extract
from sid2ct.players.sidid import identify

ROOT = Path(__file__).resolve().parents[1]
HVSC = Path(os.environ.get('HVSC_ROOT', ROOT.parent / 'shallowsid/_hvsc-source'))


def fixture(base=0x2000, frames_count=60):
    """Relocatable miniature packed song with independent, hand-set read times.

    Code fragments encode table access, not an executable music player.
    Data: two patterns, transpose +2, loop to the first order entry;
    duration 1, tie/duration 0, bare note, rest; then duration 2 and bare note.
    """
    data = bytearray(0x1000)

    def put(offset, value):
        data[offset:offset + len(value)] = value

    def word(offset):
        return (base + offset).to_bytes(2, 'little').hex(' ')

    def code(offset, template):
        put(offset, bytes.fromhex(template))

    # These snippets deliberately live at unrelated offsets in the payload.
    code(0x20, f'0a 0a 0a a8 a2 00 b9 {word(0x300)} 9d {word(0x400)} '
         f'9d {word(0x406)} b9 {word(0x301)} 9d {word(0x403)} '
         f'9d {word(0x409)} c8 c8 e8 e0 03 d0 e7')
    code(0x80, f'bd {word(0x400)} 85 fb bd {word(0x403)} 85 fc a0 00 98 '
         f'9d {word(0x410)} b1 fb 10 0f 0a 9d {word(0x413)} fe {word(0x400)} '
         f'd0 03 fe {word(0x403)} c8 b1 fb a8 b9 {word(0x600)} 85 fb '
         f'b9 {word(0x602)} 85 fc')
    code(0xc0, f'68 0a 0a 0a 9d {word(0x420)} a8 b9 {word(0x700)} '
         f'9d {word(0x423)} fe {word(0x426)} 4c 00 20')
    code(0xe0, f'68 29 3f 0a a8 b9 {word(0x800)} 48 29 0f')
    code(0x100, f'ad {word(0x430)} f0 0e c9 02 d0 0f bd {word(0x426)} '
         f'f0 03 4c 00 20 de {word(0x426)} 30 03')
    # SIDId's generic and version-specific recognition snippets.
    code(0x140, 'b1 fb 30 03 f0 03 c9 7e f0 03')
    code(0x160, f'48 a5 fc 48 ce {word(0x430)} 10 1d ad {word(0x431)} '
         f'8d {word(0x430)} c9 02 b0 13 ac {word(0x432)} b9 {word(0x900)} '
         f'8d {word(0x430)} ce {word(0x432)} 10 05 a9 01')
    for v in range(3):
        put(0x300 + v * 2, (base + 0x500 + 8 * v).to_bytes(2, 'little'))
        put(0x500 + 8 * v, bytes([0x82, 0, 1, 0xff]))
    put(0x306, bytes([3, 7]))  # four calls per row, all three voices enabled
    put(0x600, bytes([(base + 0x610) & 255, (base + 0x630) & 255]))
    put(0x602, bytes([(base + 0x610) >> 8, (base + 0x630) >> 8]))
    put(0x610, bytes([0xa3, 0x81, 0x30, 0xa4, 0x90, 0x32, 0x34, 0, 0x7f]))
    put(0x630, bytes([0xa5, 0x82, 0x35, 0x36, 0x7f]))
    put(0x700, bytes(range(256)))
    events = [(0, 0x610, 0x613, True), (8, 0x613, 0x616, False),
              (12, 0x616, 0x617, True), (16, 0x617, 0x618, False),
              (20, 0x630, 0x633, True), (32, 0x633, 0x634, True),
              (44, 0x610, 0x613, True), (52, 0x613, 0x616, False),
              (56, 0x616, 0x617, True)]
    calls = [Call(i, [], [], []) for i in range(frames_count)]
    frames = [bytearray(25) for _ in calls]
    for call, lo, hi, attack in events:
        if call < len(calls):
            calls[call].reads = [(base + lo, base + hi)]
        if attack and call + 2 < len(frames):
            for v in range(3):
                frames[call + 2][v * 7 + 4] = 1
    header = bytearray(124)
    header[:4] = b'PSID'
    struct.pack_into('>7H', header, 4, 2, 124, base, base + 0x20, base + 0x80, 1, 1)
    return bytes(header + data), [bytes(f) for f in frames], calls


class PackedNP20(unittest.TestCase):
    def test_notes_duration_ties_order_loop_and_instruments(self):
        raw, frames, calls = fixture()
        self.assertIn('(JCH_NewPlayer_V20)', identify(raw))
        hints = extract(raw, 1, frames, calls)
        self.assertIsNotNone(hints)
        self.assertEqual(hints.player, 'JCH NewPlayer')
        self.assertEqual(hints.version, '20')
        self.assertEqual(hints.tempo_calls, [4])
        self.assertEqual(hints.loop_call, 46)
        for voice in hints.voices:
            self.assertEqual(voice.row_calls, [2, 10, 14, 18, 22, 34, 46, 54, 58])
            self.assertEqual(voice.pattern_calls, [2, 22, 46])
            self.assertEqual(voice.orderlist, [(0, 2), (1, 2)])
            self.assertEqual(voice.loop_index, 0)
            self.assertEqual([n.note for n in voice.notes], [48, 50, 52, 53, 54, 48, 50, 52])
            self.assertEqual([n.tie for n in voice.notes], [False, True, False, False, False, False, True, False])
            self.assertIsNone(voice.notes[2].instrument)
        self.assertEqual(hints.instruments[3]['raw'], bytes(range(24, 32)))
        self.assertEqual(gate_rise_agreement(hints, frames, tolerance=0), 1)

    def test_relocation_and_embedded_load_address(self):
        for base in (0x1000, 0x3800, 0x8100):
            raw, frames, calls = fixture(base)
            header = bytearray(raw[:124])
            header[8:10] = b'\0\0'
            embedded = bytes(header) + base.to_bytes(2, 'little') + raw[124:]
            for sid in (raw, embedded):
                hints = extract(sid, 1, frames, calls)
                self.assertIsNotNone(hints)
                self.assertEqual(hints.voices[0].notes[0].note, 48)

    def test_unsupported_or_inconsistent_inputs(self):
        raw, frames, calls = fixture()
        self.assertIsNone(extract(b'not a SID', 1, frames, calls))
        for subtune in (0, 2):
            self.assertIsNone(extract(raw, subtune, frames, calls))
        self.assertIsNone(extract(raw, 1, frames, []))
        self.assertIsNone(extract(raw, 1, frames[:-1], calls))
        calls[12].reads = []
        self.assertIsNone(extract(raw, 1, frames, calls))
        raw, frames, calls = fixture()
        for offset, value in ((0x306, 1), (0x307, 3), (0x160, 0)):
            edited = bytearray(raw)
            edited[124 + offset] = value
            self.assertIsNone(extract(bytes(edited), 1, frames, calls))

    def test_invalid_pointer_and_speed_command(self):
        raw, frames, calls = fixture()
        for offset, values in ((0x602, b'\xff\xff'), (0x610, b'\xc1'),
                               (0x618, b'\x80' * 256)):
            edited = bytearray(raw)
            edited[124 + offset:124 + offset + len(values)] = values
            if offset == 0x610:
                edited[124 + 0x802:124 + 0x804] = b'\xe0\x05'
            self.assertIsNone(extract(bytes(edited), 1, frames, calls))

    def test_commands_and_duration_across_pattern_boundaries(self):
        raw, frames, calls = fixture()
        edited = bytearray(raw)
        # A volume command replaces the instrument prefix without changing
        # any read addresses. Keep its source opcode and parameter verbatim.
        edited[124 + 0x610] = 0xc1
        edited[124 + 0x802:124 + 0x804] = b'\xf0\x0e'
        hints = extract(bytes(edited), 1, frames, calls)
        self.assertIsNotNone(hints)
        self.assertEqual(hints.voices[0].notes[0].command, ((0xc1, 0xf0, 14),))
        self.assertIsNone(hints.voices[0].notes[0].instrument)
        # Pattern 1 has no duration prefix: inherit duration 0 from pattern 0.
        edited[124 + 0x630:124 + 0x633] = b'\xa5\xc1\x35'
        hints = extract(bytes(edited), 1, frames[:24], calls[:24])
        self.assertIsNotNone(hints)
        self.assertEqual(hints.voices[0].row_calls[-1], 22)
        # At call 24 the bare note must be read, proving duration did carry.
        calls[24].reads = [(0x2633, 0x2634)]
        hints = extract(bytes(edited), 1, frames[:28], calls[:28])
        self.assertIsNotNone(hints)
        self.assertEqual(hints.voices[0].row_calls[-1], 26)

    def test_short_trace_and_no_frames_outside_window(self):
        raw, frames, calls = fixture(frames_count=1)
        hints = extract(raw, 1, frames, calls)
        self.assertIsNotNone(hints)
        self.assertEqual(hints.voices[0].notes, [])
        self.assertEqual(hints.voices[0].pattern_calls, [])


class HVSCNP20(unittest.TestCase):
    SONGS = (
        'MUSICIANS/D/DRAX/Regrets.sid',
        'MUSICIANS/D/DRAX/Worktunes/JRRR.sid',
        'MUSICIANS/M/Mitch_and_Dane/Dane/Nick_De_Caro_and_Orchestra.sid',
        'MUSICIANS/M/Mitch_and_Dane/Dane/Tasty.sid',
        'MUSICIANS/D/DRAX/Advanced.sid',
        'MUSICIANS/D/DRAX/Black_Jack.sid',
    )

    def test_gate_agreement_and_memory_row_timing(self):
        if not (ROOT / 'ct2util').is_file() or not HVSC.is_dir():
            self.skipTest('ct2util and HVSC_ROOT are required')
        tested = 0
        with tempfile.TemporaryDirectory(prefix='sid-jch-') as directory:
            d = Path(directory)
            for relative in self.SONGS:
                sid = HVSC / relative
                if not sid.is_file():
                    continue
                with self.subTest(song=relative):
                    with (d / 'command.log').open('w') as log:
                        result = subprocess.run(
                            [str(ROOT / 'ct2util'), 'sidtrace', str(sid), '-s', '1', '-f', '2400',
                             '-o', str(d / 'sid.trace'), '--mem-reads', str(d / 'reads.txt')],
                            stdout=log, stderr=log, timeout=60)
                    self.assertEqual(result.returncode, 0, (d / 'command.log').read_text())
                    frames = parse_trace((d / 'sid.trace').read_text())
                    calls = load(d / 'reads.txt')
                    hints = extract(sid.read_bytes(), 1, frames, calls)
                    self.assertIsNotNone(hints)
                    self.assertGreater(sum(len(v.notes) for v in hints.voices), 50)
                    self.assertGreaterEqual(gate_rise_agreement(hints, frames), 0.98)
                    period, = hints.tempo_calls
                    # Only read streams overlapping independently decoded rows
                    # count here: table programs also produce slow read streams.
                    row_reads = {r - 2 for v in hints.voices for r in v.row_calls}
                    streams = [s for s in find_streams(calls)
                               if len(set(s.calls) & row_reads) >= 3
                               and set(s.calls) <= row_reads]
                    self.assertTrue(streams)
                    for stream in streams:
                        self.assertTrue(all((b - a) % period == 0
                                            for a, b in zip(stream.calls, stream.calls[1:])))
                    tested += 1
        if tested < 3:
            self.skipTest(f'Only {tested} validation songs present; need at least three')


if __name__ == '__main__':
    unittest.main()
