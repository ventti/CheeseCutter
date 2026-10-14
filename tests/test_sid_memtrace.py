"""ct2util sidtrace --mem-reads and sid2ct.memtrace structure discovery.

A known song is built (4 calls per row, a new note on every row, 8-row
sequences), exported to SID, and traced. Row boundaries and sequence start
addresses recovered from memory reads alone must match the real timing
(from the SID register trace) and the real sequence locations (found in the
exported image from the song's own sequence data). Point SID2CT_CT2UTIL at
another ct2util build to test it.
"""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib

from sid2ct import memtrace
from sid2ct.ctplayer import CTPlayer, TRACKS
from sid2ct.native import native_song

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get('SID2CT_CT2UTIL', ROOT / 'ct2util'))
ROW_FRAMES = 4
ROWS = 96
CALLS = ROWS * ROW_FRAMES + 16


def tool(*args):
    return subprocess.run([str(TOOL), *map(str, args)], cwd=ROOT, capture_output=True,
                          text=True)


def song_frames():
    frames = []
    for i in range(ROWS * ROW_FRAMES):
        f = bytearray(25)
        f[24] = 15
        for v in range(3):
            note = 36 + v * 7 + ((i // ROW_FRAMES) * (v + 2)) % 12
            freq = round(268 * 2 ** (note / 12))
            f[v * 7:v * 7 + 7] = bytes((freq & 255, freq >> 8, 0, 8,
                                        0x11 if i % ROW_FRAMES < 3 else 0x10, 0, 0xF0))
        frames.append(bytes(f))
    return frames


def psid_image(sid):
    offset = struct.unpack('>H', sid[6:8])[0]
    body = sid[offset:]
    return body[0] | body[1] << 8, body[2:]


class MemTraceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not TOOL.is_file():
            raise unittest.SkipTest(f'{TOOL} not built')
        if '--mem-reads' not in tool().stdout:
            raise unittest.SkipTest('ct2util lacks sidtrace --mem-reads')
        cls.temp = tempfile.TemporaryDirectory(prefix='memtrace-')
        d = Path(cls.temp.name)
        assert tool('init', ROOT / 'src/c64/player.bin', '-o', d / 't.ct').returncode == 0
        song, _ = native_song((d / 't.ct').read_bytes(), song_frames(), 1, ROW_FRAMES,
                              ['Mem', '', ''], layout='compact', loop_start=64)
        (d / 's.ct').write_bytes(song)
        assert tool('sid', d / 's.ct', '-o', d / 's.sid').returncode == 0
        plain = tool('sidtrace', d / 's.sid', '-f', CALLS, '-o', d / 'plain.trace')
        traced = tool('sidtrace', d / 's.sid', '-f', CALLS, '-o', d / 'mem.trace',
                      '--mem-reads', d / 'mem.txt')
        assert plain.returncode == 0 and traced.returncode == 0, traced.stdout
        cls.plain = (d / 'plain.trace').read_bytes()
        cls.with_flag = (d / 'mem.trace').read_bytes()
        cls.calls = memtrace.load(d / 'mem.txt')
        cls.structure = memtrace.analyze(cls.calls)
        cls.sid = (d / 's.sid').read_bytes()
        cls.image = zlib.decompress(song[3:])

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def test_default_output_unchanged(self):
        self.assertEqual(self.plain, self.with_flag)

    def test_one_line_per_call_with_ordered_sid_writes(self):
        self.assertEqual(len(self.calls), CALLS)
        for call in self.calls:
            cycles = [c for _, _, c in call.writes]
            self.assertEqual(cycles, sorted(cycles))
            self.assertTrue(all(r < 0x19 for r, _, _ in call.writes))
            for a, b in call.reads:
                self.assertFalse(0x100 <= a <= 0x1ff or 0xd000 <= a <= 0xdfff)
            for a, b in call.zp:
                self.assertLess(b, 0x100)

    def test_row_boundaries_match_register_timing(self):
        s = self.structure
        self.assertEqual(s.row_period, ROW_FRAMES)
        # Ground truth: gate rises of voice 0 in the real register trace.
        rises, prev = [], None
        for i, line in enumerate(self.plain.decode().split()):
            ctl = bytes.fromhex(line)[4]
            if prev is not None and ctl & 1 and not prev & 1:
                rises.append(i)
            prev = ctl
        self.assertGreaterEqual(len(rises), ROWS - 1)
        bounds = set(s.row_boundaries)
        self.assertLessEqual(set(rises) - {rises[-1]}, bounds)
        # every later boundary is a real row start, and none is skipped
        first = min(rises)
        inner = [b for b in s.row_boundaries if first <= b <= rises[-1]]
        self.assertEqual(inner, list(range(first, rises[-1] + 1, ROW_FRAMES)))
        self.assertEqual(set(inner), {r for r in rises if r <= rises[-1]})

    def test_sequence_starts_match_real_locations(self):
        load, body = psid_image(self.sid)
        player = CTPlayer(self.image)
        expected = set()
        for packed in player.sequences[1:]:
            data = bytes(packed)
            data = data[:data.index(191) + 1]
            if len(data) < 5 or data[0] < 192:
                continue
            # export renumbers instruments, so match after the first byte
            at = body.find(data[1:])
            if at > 0 and body.count(data[1:]) == 1:
                expected.add(load + at - 1)
        self.assertGreaterEqual(len(expected), 6)
        recovered = {a for a, _ in self.structure.sequence_starts}
        self.assertEqual(recovered, expected)

    def test_orderlist_starts_match_real_locations(self):
        # Export compresses repeated entries, so compare each voice's first
        # entry (transpose, sequence) at the recovered address.
        load, body = psid_image(self.sid)
        firsts = sorted(bytes(self.image[TRACKS + v * 1024:TRACKS + v * 1024 + 2])
                        for v in range(3))
        starts = self.structure.orderlist_candidates
        self.assertEqual(len(starts), 3)
        self.assertEqual(sorted(bytes(body[a - load:a - load + 2]) for a in starts), firsts)


class ParseTests(unittest.TestCase):
    def test_parse_roundtrip_format(self):
        calls = memtrace.parse('0\tR:1000-1002,1010\tZ:fb-fc\tW:04:41@12 18:0f@40\n'
                               '1\tR:\tZ:\tW:\n')
        self.assertEqual(calls[0].reads, [(0x1000, 0x1002), (0x1010, 0x1010)])
        self.assertEqual(calls[0].zp, [(0xfb, 0xfc)])
        self.assertEqual(calls[0].writes, [(4, 0x41, 12), (0x18, 0x0f, 40)])
        self.assertEqual(calls[1].reads, [])
        with self.assertRaises(ValueError):
            memtrace.parse('garbage')


if __name__ == '__main__':
    unittest.main()
