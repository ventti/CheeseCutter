"""Independent note/timing oracles for the generic SID prototype."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest

from sid2ct.convert import parse_trace, pitch, read_sid, reconstruct
from tests.test_goat_import import read_ct, timeline

ROOT = Path(__file__).resolve().parents[1]


def frame(freq=0x1168, gate=True, pulse=0):
    out = bytearray(25)
    out[:7] = bytes([freq & 255, freq >> 8, pulse & 255, pulse >> 8,
                     0x41 if gate and pulse else 0x11 if gate else 0x10, 0, 0xF0])
    out[24] = 15
    return bytes(out)


def unknown_sid():
    # Independent player: C4 triangle, eight calls on / eight calls off.
    init = bytes.fromhex('a9688d00d4a9118d01d4a9f08d06d4a90f8d18d4a900850260')
    play = bytes.fromhex('e602a502290fc908b006a9118d04d460a9108d04d460')
    header = bytearray(124)
    header[:4] = b'PSID'
    struct.pack_into('>7H', header, 4, 2, 124, 0x1000, 0x1000,
                     0x1000 + len(init), 1, 1)
    header[22:29] = b'Unknown'
    return bytes(header) + init + play


class Reconstruction(unittest.TestCase):
    def test_independent_pal_pitch(self):
        # 261.626 Hz -> PAL SID register approx 4455, C4 = semitone 48.
        self.assertEqual(pitch(4455)[0], 48)
        self.assertEqual(pitch(8909)[0], 60)
        self.assertIsNone(pitch(0))

    def test_multiplier_preserves_duration_and_note_layout(self):
        source = [frame()] * 6 + [frame(gate=False)] * 6
        a, ra = reconstruct(source, 1, 3)
        b, rb = reconstruct([f for f in source for _ in range(4)], 4, 3)
        self.assertEqual(a, b)
        self.assertEqual(ra['captured_seconds'], rb['captured_seconds'])
        self.assertEqual(rb['source_calls_per_second'], 200)
        self.assertEqual(rb['output_multiplier'], 1)

    def test_static_timbre_dedup_and_quantization_report(self):
        source = [frame()] * 4 + [frame(gate=False)] + [frame(freq=0x22D0)] * 7
        _, report = reconstruct(source, 1, 6)
        self.assertEqual(report['instruments'], 1)
        self.assertGreater(report['row_collisions'], 0)
        self.assertGreater(report['quantized_events'], 0)

    def test_instrument_budget_reports_merges(self):
        source = []
        for ad in range(60):
            f = bytearray(frame())
            f[5] = ad
            source.extend([bytes(f)] * 6 + [frame(gate=False)] * 6)
        _, report = reconstruct(source, 1, 3)
        self.assertEqual(report['instruments'], 47)
        self.assertEqual(report['approximated_instrument_attacks'], 13)

    def test_recognized_cc_uses_native_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp)/'native.ct'
            source = ROOT/'tests/fixtures/sid/So_You_Died_Man_Up.sid'
            result = subprocess.run(['python3', '-m', 'sid2ct', 'convert',
                                     str(source), '-o', str(output), '--skip-audio'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(output.with_suffix('.json').read_text())['mode'],
                             'recognized-cheesecutter')
            self.assertTrue(timeline(read_ct(output)))

    def test_malformed_trace_and_unsupported_sid(self):
        for text in ('', '00', 'zz'*25):
            with self.assertRaises(ValueError):
                parse_trace(text)
        raw = bytearray(unknown_sid())
        raw[12:14] = b'\0\0'
        with self.assertRaisesRegex(ValueError, 'IRQ'):
            read_sid(raw, 1)
        with self.assertRaises(ValueError):
            read_sid(unknown_sid(), 2)

    def test_unknown_player_end_to_end_and_cc_export(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            sid, ct, exported = tmp/'source.sid', tmp/'out.ct', tmp/'out.sid'
            sid.write_bytes(unknown_sid())
            result = subprocess.run(['python3', '-m', 'sid2ct', 'convert',
                                     str(sid), '-o', str(ct), '--seconds', '0.48',
                                     '--multiplier', '2', '--row-frames', '3', '--skip-audio'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(ct.with_suffix('.json').read_text())
            self.assertEqual(report['mode'], 'trace-reconstruction')
            self.assertEqual(report['source_calls'], 48)
            data = read_ct(ct)
            notes = [r[2] for r in timeline(data) if 0x63 <= r[2] < 0xBF]
            self.assertTrue(notes)
            self.assertEqual(set(notes), {0x90})
            result = subprocess.run([str(ROOT/'ct2util'), 'sid', str(ct), '-o', str(exported)],
                                    cwd=ROOT, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(exported.read_bytes()[:4], b'PSID')
            # Confirm the resulting CC player drives a C4 frequency.
            trace = tmp/'export.trace'
            result = subprocess.run([str(ROOT/'ct2util'), 'sidtrace', str(exported),
                                     '-f', '48', '-o', str(trace)], cwd=ROOT,
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            frequencies = {f[0] | f[1] << 8 for f in parse_trace(trace.read_text()) if f[4] & 1}
            self.assertIn(0x1168, frequencies)
            # Existing output stays intact on an accidental second invocation.
            before = ct.read_bytes()
            result = subprocess.run(['python3', '-m', 'sid2ct', 'convert',
                                     str(sid), '-o', str(ct)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(ct.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
