"""GoatTracker import: generated GTS5 fixtures, editable data and SID playback.

Expected pitches/timing are specified independently of the converter. No
upstream songs are needed for this reproducible suite.
"""
from __future__ import annotations

import re
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

from tests.ccdriver_session import CCDriverSession

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "ct2util"
REST = (0xBD, 0, 0, 0)
INSTRUMENT = bytes([0x09, 0xF0, 1, 0, 0, 0, 0, 0x82, 9])
TABLES = ([(0x11, 0), (255, 0)], [], [], [])


def song(patterns=None, orders=None, instruments=None, tables=None, title="Goat fixture"):
    patterns = patterns if patterns is not None else [[(0x90, 1, 0, 0), REST, REST, REST]]
    orders = orders if orders is not None else [[([0], 0)] * 3]
    instruments = instruments if instruments is not None else [(INSTRUMENT, "Triangle")]
    tables = tables if tables is not None else TABLES
    data = bytearray(b"GTS5")
    for name in (title, "Test composer", "2026"):
        data += name.encode("ascii").ljust(32, b"\0")
    data.append(len(orders))
    for voices in orders:
        for order, restart in voices:
            data.append(len(order) + 1)
            data += bytes(order) + bytes([255, restart])
    data.append(len(instruments))
    for definition, name in instruments:
        data += definition + name.encode().ljust(16, b"\0")
    for table in tables:
        data.append(len(table))
        data += bytes(x for x, _ in table) + bytes(y for _, y in table)
    data.append(len(patterns))
    for pattern in patterns:
        data.append(len(pattern) + 1)
        for row in pattern:
            data += bytes(row)
        data += bytes([255, 0, 0, 0])
    return bytes(data)


def read_ct(path):
    return zlib.decompress(path.read_bytes()[3:])


def offset(data, index):
    return struct.unpack_from("<H", data, 0xFA0 + index * 2)[0]


def table(data, index, size):
    start = offset(data, index)
    return data[start:start + size]


def tracks(data, voice=0):
    raw = table(data, 19 + voice, 1024)
    entries = []
    for i in range(0, len(raw), 2):
        trans, number = raw[i:i + 2]
        if trans >= 0xF0:
            return entries, number
        entries.append(number)
    raise AssertionError("unterminated orderlist")


def rows(data, number):
    lo = offset(data, 22)
    hi = offset(data, 23)
    start = data[lo + number] | (data[hi + number] << 8)
    result = []
    for i in range(start, start + 256, 4):
        if data[i] == 0xBF:
            return result
        result.append(tuple(data[i:i + 4]))
    return result  # Full 64-row sequences have no room for an end marker.


def timeline(data, voice=0):
    order, _ = tracks(data, voice)
    return [r for number in order for r in rows(data, number)]


def screen(session):
    return "\n".join(line.split(":", 1)[1] for line in session.run("screendump").splitlines()
                     if re.match(r"screen\d+:", line))


class GoatImport(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)
        self.source = self.dir / "source.sng"
        self.output = self.dir / "converted.ct"

    def convert(self, data, success=True):
        self.source.write_bytes(data)
        proc = subprocess.run([str(TOOL), "sng2ct", str(self.source), "-o", str(self.output)],
                              cwd=ROOT, text=True, capture_output=True, timeout=15)
        self.assertEqual(proc.returncode == 0, success, proc.stdout + proc.stderr)
        self.assertNotIn("core.exception", proc.stdout + proc.stderr)
        return read_ct(self.output) if success else proc.stdout + proc.stderr

    def trace(self, data, frames=120):
        self.convert(data)
        sid, trace = self.dir / "song.sid", self.dir / "song.trace"
        for args in [("sid", "-q", str(self.output), "-o", str(sid)),
                     ("sidtrace", "-q", "-f", str(frames), str(sid), "-o", str(trace))]:
            proc = subprocess.run([str(TOOL), *args], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return [bytes.fromhex(line.strip()) for line in trace.read_text().splitlines()]

    def test_metadata_instruments_and_default_tempo(self):
        data = self.convert(song())
        title = 65536 + 261
        self.assertEqual(data[title:title + 32].rstrip(), b"Goat fixture")
        self.assertEqual(data[title + 32:title + 64].rstrip(), b"Test composer")
        self.assertEqual(data[title + 64:title + 96].rstrip(), b"2026")
        self.assertEqual(data[65536 + 5], 5)
        instr = table(data, 18, 384)
        self.assertEqual(instr[1], 9)
        self.assertEqual(instr[49], 0xF0)
        self.assertEqual(data[title + 160 + 32:title + 160 + 64].rstrip(), b"Triangle")
        trace = self.trace(song())
        self.assertTrue(any(r[4] & 1 for r in trace))
        # Source note 90 is C-4: PAL frequency $1168, without an octave shift.
        self.assertIn(0x1168, [r[0] | r[1] << 8 for r in trace])

    def test_exported_note_timing_matches_independent_goattracker_trace(self):
        # Independent gt2reloc/siddump reference: C4, C#4, D4 start on
        # frames 8, 32, 56. CC's note pipeline begins three frames earlier,
        # but the musical intervals must remain exactly 24 play calls.
        fixture = song(patterns=[[(0x90, 1, 0, 0)] + [REST] * 3 +
                                 [(0x91, 1, 0, 0)] + [REST] * 3 +
                                 [(0x92, 1, 0, 0)] + [REST] * 3])
        trace = self.trace(fixture, 100)
        pitches = [r[0] | r[1] << 8 for r in trace]
        onsets = [pitches.index(pitch) for pitch in (0x1168, 0x126E, 0x1388)]
        self.assertEqual(onsets, [5, 29, 53])

    def test_adjacent_recovery_report_restores_hard_restart_and_sid_model(self):
        import json
        self.source.with_suffix(".json").write_text(json.dumps({
            "playback_settings": {"hard_restart_adsr": "FA00", "sid_model": "8580"}}))
        definition = bytearray(INSTRUMENT)
        definition[7] = 2  # Enable GoatTracker hard restart.
        fixture = song(patterns=[[(0x90, 1, 0, 0), REST, (0x91, 1, 0, 0), REST]],
                       instruments=[(bytes(definition), "Hard restart")])
        data = self.convert(fixture)
        self.assertEqual(data[65536 + 3], 1)
        self.assertEqual(table(data, 24, 192)[64], 0xFA)
        trace = self.trace(fixture)
        self.assertTrue(any(r[5:7] == bytes([0xFA, 0]) for r in trace))

    def test_repeat_transpose_and_nonzero_restart(self):
        fixture = song(patterns=[[(0x90, 1, 0, 0)], [(0x91, 0, 0, 0)]],
                       orders=[[([0, 0xF2, 0xD1, 1], 1)] * 3])
        data = self.convert(fixture)
        notes = [r[2] for r in timeline(data) if 0x63 <= r[2] < 0xBF]
        self.assertEqual(notes[:3], [0x90, 0x93, 0x93])
        order, restart = tracks(data)
        self.assertGreater(restart, 0)
        self.assertLess(restart, len(order))
        trace = self.trace(fixture, 160)
        pitches = [r[0] | r[1] << 8 for r in trace]
        self.assertIn(0x1168, pitches[:20])
        self.assertNotIn(0x1168, pitches[20:])  # intro plays once
        self.assertGreater(pitches.count(0x14AF), 50)  # repeated D#4

    def test_long_patterns_split_without_losing_rows(self):
        pattern = [(0x90, 1, 0, 0)] + [REST] * 126 + [(0x94, 0, 0, 0)]
        data = self.convert(song(patterns=[pattern]))
        order, _ = tracks(data)
        self.assertTrue(all(len(rows(data, n)) == 64 for n in order))
        sequence = timeline(data)
        self.assertEqual(sequence[127][2], 0x94)

    def test_source_pattern_lengths_preserved_with_empty_last_row(self):
        for length in (4, 32, 63, 64):
            with self.subTest(length=length):
                pattern = [(0x90, 1, 0, 0)] + [REST] * (length - 1)
                data = self.convert(song(patterns=[pattern]))
                order, restart = tracks(data)
                self.assertTrue(all(len(rows(data, n)) == length for n in order))
                self.assertLess(restart, len(order))
                for n in order:
                    self.assertEqual(rows(data, n)[-1][2], 0x60)

    def test_full_pattern_last_row_and_wrap_play_at_original_times(self):
        pattern = [(0x90, 1, 0, 0)] + [REST] * 62 + [(0x94, 1, 0, 0)]
        trace = self.trace(song(patterns=[pattern]), 800)
        pitches = [r[0] | r[1] << 8 for r in trace]
        changes = [(i, pitch) for i, pitch in enumerate(pitches)
                   if pitch in (0x1168, 0x15EB) and (i == 0 or pitch != pitches[i - 1])]
        self.assertEqual([pitch for _, pitch in changes[:5]],
                         [0x1168, 0x15EB, 0x1168, 0x15EB, 0x1168])
        self.assertEqual([b[0] - a[0] for a, b in zip(changes, changes[1:])],
                         [63 * 6, 6, 63 * 6, 6])

    def test_rest_gate_off_gate_on_and_tie(self):
        pattern = [(0x90, 1, 0, 0), REST, (0xBE, 0, 0, 0), (0xBF, 0, 0, 0), (0x92, 0, 3, 0)]
        data = self.convert(song(patterns=[pattern]))
        imported = timeline(data)[:5]
        self.assertEqual([r[2] for r in imported], [0x90, 0x60, 0x61, 0x62, 0x92])
        self.assertEqual(imported[4][1], 0x5F)

    def test_fixed_slide_on_rest_changes_playback(self):
        fixture = song(patterns=[[(0x90, 1, 0, 0), (0xBD, 0, 1, 1), REST, REST]],
                       tables=(TABLES[0], [], [], [(0, 32)]))
        trace = self.trace(fixture)
        pitch = [r[0] | r[1] << 8 for r in trace]
        deltas = [b - a for a, b in zip(pitch, pitch[1:])]
        self.assertGreaterEqual(deltas.count(32), 10)
        data = read_ct(self.output)
        row = timeline(data)[1]
        cmd = table(data, 24, 192)
        self.assertEqual((cmd[row[3]], cmd[row[3] + 64], cmd[row[3] + 128]), (0, 0, 32))

    def test_zero_slide_stops_without_reusing_previous_parameter(self):
        pattern = [(0x90, 1, 1, 1), (0xBD, 0, 1, 0), REST]
        data = self.convert(song(patterns=[pattern], tables=(TABLES[0], [], [], [(0, 32)])))
        cmd = table(data, 24, 192)
        self.assertEqual(cmd[timeline(data)[1][3]], 8)

    def test_vibrato_modes_and_depth_mapping(self):
        pattern = [(0x90, 1, 4, 1), (0xBD, 0, 4, 2), REST]
        data = self.convert(song(patterns=[pattern], tables=(TABLES[0], [], [], [(4, 8), (0x84, 4)])))
        cmd = table(data, 24, 192)
        first, second = [r[3] for r in timeline(data)[:2]]
        self.assertEqual((cmd[first], cmd[first + 64], cmd[first + 128]), (5, 3, 2))
        self.assertEqual((cmd[second], cmd[second + 128]), (2, 0x24))
        trace = self.trace(song(patterns=[[(0x90, 1, 4, 1)] + [REST] * 7],
                               tables=(TABLES[0], [], [], [(4, 8)])))
        pitch = [r[0] | r[1] << 8 for r in trace]
        self.assertTrue(any(abs(b - a) == 8 for a, b in zip(pitch, pitch[1:])))

    def test_instrument_vibrato_delay_keeps_compact_tempo(self):
        definition = bytearray(INSTRUMENT)
        definition[5:7] = bytes([1, 9])
        fixture = song(instruments=[(bytes(definition), "Vibrato")],
                       patterns=[[(0x90, 1, 0, 0)] + [REST] * 31],
                       tables=(TABLES[0], [], [], [(4, 8)]))
        data = self.convert(fixture)
        self.assertEqual(data[65536 + 5], 5)
        self.assertLess(len(tracks(data)[0]), 10)
        self.assertIn("vibrato delay rounded", subprocess.run(
            [str(TOOL), "sng2ct", "-q", str(self.source), "-o", str(self.output)],
            capture_output=True, text=True).stdout)

    def test_funktempo_and_channel_local_tempo(self):
        patterns = [[(0x90, 1, 14, 1), (0x91, 0, 0, 0), (0x92, 0, 0, 0)],
                    [(0x95, 1, 15, 0x83), (0x96, 0, 0, 0), REST], [REST] * 3]
        data = self.convert(song(patterns=patterns, orders=[[([0], 0), ([1], 0), ([2], 0)]],
                                 tables=(TABLES[0], [], [], [(9, 6)])))
        speed = data[65536 + 5]
        self.assertEqual(speed, 2)
        a = timeline(data, 0)
        b = timeline(data, 1)
        self.assertEqual([i * (speed + 1) for i, r in enumerate(a[:8]) if r[2] >= 0x63], [0, 9, 15])
        self.assertEqual([i * (speed + 1) for i, r in enumerate(b[:3]) if r[2] >= 0x63], [0, 3])
        self.trace(song(patterns=patterns, orders=[[([0], 0), ([1], 0), ([2], 0)]],
                        tables=(TABLES[0], [], [], [(9, 6)])), 200)

    def test_global_tempo_change_updates_other_voices(self):
        patterns = [[(0x90, 1, 15, 3), (0x91, 0, 0, 0)],
                    [(0x93, 1, 0, 0), (0x94, 0, 0, 0)]]
        data = self.convert(song(patterns=patterns, orders=[[([0], 0), ([1], 0), ([1], 0)]]))
        self.assertEqual(data[65536 + 5], 2)
        self.assertEqual([r[2] for r in timeline(data, 1)[:2]], [0x93, 0x94])

    def test_adsr_commands_preserve_the_other_register(self):
        pattern = [(0x90, 1, 0, 0), (0xBD, 0, 5, 0x21), (0xBD, 0, 6, 0xE8)]
        data = self.convert(song(patterns=[pattern]))
        cmd = table(data, 24, 192)
        a, b = [r[3] for r in timeline(data)[1:3]]
        self.assertEqual((cmd[a], cmd[a + 64], cmd[a + 128]), (4, 0x21, 0xF0))
        self.assertEqual((cmd[b], cmd[b + 64], cmd[b + 128]), (4, 0x21, 0xE8))

    def test_signed_wave_arpeggio_preserves_pitch(self):
        fixture = song(tables=([(0x11, 0x74), (0x11, 0), (255, 1)], [], [], []))
        data = self.convert(fixture)
        self.assertEqual(timeline(data)[0][2], 0x84)  # C4 shifted down an octave
        trace = self.trace(fixture)
        values = {r[0] | r[1] << 8 for r in trace}
        self.assertIn(0x08B4, values)  # C3
        self.assertIn(0x1168, values)  # C4

    def test_pulse_filter_pointer_relocation_and_sweep_loops(self):
        definition = bytearray(INSTRUMENT)
        definition[3:5] = bytes([1, 1])
        tables = (TABLES[0], [(0x88, 0), (3, 16), (255, 2)],
                  [(0x90, 0xF1), (0, 0x40), (4, 1), (255, 3)], [])
        fixture = song(instruments=[(bytes(definition), "Filtered")], tables=tables,
                       patterns=[[(0x90, 1, 0, 0), (0xBD, 0, 9, 2), (0xBD, 0, 10, 3), REST]])
        data = self.convert(fixture)
        instr = table(data, 18, 384)
        self.assertNotEqual(instr[1 + 4 * 48], 0)
        self.assertNotEqual(instr[1 + 5 * 48], 0)
        self.assertEqual(table(data, 17, 256)[4:8], bytes([0, 0, 8, 2]))
        self.trace(fixture)

    def test_zero_duration_pulse_holds_width_and_never_reaches_next_row(self):
        definition = bytearray(INSTRUMENT)
        definition[3] = 1
        fixture = song(instruments=[(bytes(definition), "Held pulse")],
                       tables=([(0x41, 0), (255, 0)],
                               [(0x88, 0), (0, 32), (0x84, 0), (255, 1)], [], []))
        data = self.convert(fixture)
        pulse = table(data, 17, 256)
        self.assertEqual(pulse[4:12], bytes([0, 0, 8, 2, 0, 0, 255, 127]))
        trace = self.trace(fixture, 90)
        widths = [r[2] | (r[3] & 15) << 8 for r in trace]
        self.assertIn(0x800, widths)
        self.assertTrue(all(width == 0x800 for width in widths[20:]))

    def test_envelope_nibble_changes_use_inline_commands(self):
        fixture = song(patterns=[[(0x90, 1, 5, 0x19), (0xBD, 0, 5, 0x12),
                                 (0xBD, 0, 6, 0xE0), (0xBD, 0, 6, 0xE5),
                                 (0xBD, 0, 6, 0x46)]])
        data = self.convert(fixture)
        converted = timeline(data)[:5]
        self.assertEqual([r[3] for r in converted[:4]], [0xA1, 0xB2, 0xCE, 0xD5])
        cmd = table(data, 24, 192)
        last = converted[4][3]
        self.assertEqual((cmd[last], cmd[last + 64], cmd[last + 128]), (4, 0x12, 0x46))
        trace = self.trace(fixture, 90)
        self.assertTrue(any(r[5:7] == bytes([0x12, 0x46]) for r in trace))

    def test_filter_mode_and_cutoff_share_one_programme_row(self):
        definition = bytearray(INSTRUMENT)
        definition[4] = 1
        fixture = song(instruments=[(bytes(definition), "Filter")],
                       tables=(TABLES[0], [], [(0x90, 0xF1), (0, 0x40), (255, 0)], []))
        data = self.convert(fixture)
        self.assertEqual(table(data, 16, 256)[4:8], bytes([0x90, 0xF1, 0x40, 127]))
        trace = self.trace(fixture)
        self.assertTrue(any(r[22:24] == bytes([0x40, 0xF1]) for r in trace))

    def test_subtunes_are_independent(self):
        fixture = song(patterns=[[(0x90, 1, 0, 0)], [(0x94, 1, 0, 0)]],
                       orders=[[([0], 0)] * 3, [([1], 0)] * 3])
        data = self.convert(fixture)
        self.assertEqual(data[65536 + 5:65536 + 7], bytes([5, 5]))
        base = 65536 + 261 + 160 + 2048
        self.assertNotEqual(data[base + 1], data[base + 3072 + 1])
        self.trace(fixture)

    def test_identical_instruments_are_deduplicated(self):
        fixture = song(patterns=[[(0x90, 63, 0, 0)]],
                       instruments=[(INSTRUMENT, f"Inst {i}") for i in range(63)])
        data = self.convert(fixture)
        self.assertEqual(timeline(data)[0][0], 0xC1)

    def test_unused_self_loop_table_rows_do_not_block_import(self):
        self.convert(song(tables=(TABLES[0], [(255, 1)], [(255, 1)], [])))

    def test_unsupported_wavetable_command_is_reported(self):
        fixture = song(tables=([(0x11, 0), (0xF7, 0x21), (255, 1)], [], [], []))
        self.convert(fixture)
        proc = subprocess.run([str(TOOL), "sng2ct", "-q", str(self.source), "-o", str(self.output)],
                              text=True, capture_output=True)
        self.assertIn("Wavetable command 721", proc.stdout)
        self.assertIn("omitted", proc.stdout)

    def test_command_capacity_retries_with_reported_envelope_approximations(self):
        # Every update changes both SR nibbles; inline commands cannot hide
        # the command-capacity overflow. Long blank spans must retain timing.
        pattern = [(0x90, 1, 0, 0)]
        for value in range(1, 81):
            pattern.append((0xBD, 0, 6, (value * 17) & 255))
        fixture = song(patterns=[pattern, [REST] * 127 + [(0x94, 1, 0, 0)]],
                       orders=[[([0, 1], 0)] * 3])
        data = self.convert(fixture)
        proc = subprocess.run([str(TOOL), "sng2ct", str(self.source), "-o", str(self.output)],
                              text=True, capture_output=True)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("Best-effort import", proc.stdout)
        self.assertIn("Envelope", proc.stdout)
        self.assertIn("approximated as", proc.stdout)
        self.assertTrue(all(row[1] in (0xF0, 0x5F) for row in timeline(data)))
        self.assertTrue(all(len(rows(data, n)) <= 64 for n in tracks(data)[0]))
        first_target = next(i for i, row in enumerate(timeline(data)) if row[2] == 0x94)
        self.assertEqual(first_target * (data[65536 + 5] + 1), (81 + 127) * 6)
        trace = self.trace(fixture, 1300)
        pitches = [r[0] | r[1] << 8 for r in trace]
        self.assertEqual(pitches.index(0x15EB) - pitches.index(0x1168), (81 + 127) * 6)

    def test_truncated_files_rejected_without_crashing_or_writing(self):
        fixture = song()
        for length in list(range(0, 105)) + list(range(105, len(fixture), 5)) + [len(fixture) - 1]:
            with self.subTest(length=length):
                self.convert(fixture[:length], success=False)
                self.assertFalse(self.output.exists())

    def test_invalid_pointers_loops_and_signatures_rejected(self):
        fixtures = [song().replace(b"GTS5", b"GTS4", 1), song() + b"garbage",
                    song(orders=[[([0], 1)] * 3]), song(orders=[[([0xD1, 0xF1, 0], 0)] * 3]),
                    song(tables=([(0x11, 0), (255, 99)], [], [], [])),
                    song(tables=(TABLES[0], [], [], []), patterns=[[(0x90, 1, 4, 1)]]),
                    song(tables=([(255, 1)], [], [], []))]
        for fixture in fixtures:
            with self.subTest(fixture=fixture):
                self.convert(fixture, success=False)
                self.assertFalse(self.output.exists())

    def test_capacity_failure_does_not_truncate_or_write_output(self):
        patterns = [[(0x90, 1, 0, 0), (0x70 + i % 64, 0, 0, 0),
                     (0x80 + i // 64, 0, 0, 0)] for i in range(129)]
        fixture = song(patterns=patterns, orders=[[(list(range(129)), 0)] * 3])
        message = self.convert(fixture, success=False)
        self.assertIn("127 playable", message)
        self.assertFalse(self.output.exists())

    def test_editor_import_is_unsaved_and_report_is_readable(self):
        self.source.write_bytes(song())
        with CCDriverSession("key:ESC") as session:
            session.run(f"open:{self.source}")
            self.assertIn("GoatTracker import mappings", screen(session))
            session.run("key:ESC")
            text = screen(session)
            self.assertIn("Goat fixture", text)
            self.assertRegex(text, r"Filename:\s+\*")
            self.assertIn("GoatTracker song imported", text)

    def test_menu_picker_and_load_picker_import_sng(self):
        with tempfile.TemporaryDirectory(prefix="goat_fixture_", dir=ROOT) as directory:
            fixture = Path(directory) / "fixture.sng"
            fixture.write_bytes(song())
            for mode in ("menu", "open"):
                with self.subTest(mode=mode), CCDriverSession("key:ESC") as session:
                    if mode == "menu":
                        session.run("key:ESC")
                        rows_text = {int(m[1]): m[2] for line in session.run("screendump").splitlines()
                                     if (m := re.match(r"screen(\d+):(.*)", line))}
                        y = next(y for y, text in rows_text.items() if "Import song..." in text)
                        session.run(f"hover:{rows_text[y].index('Import song')},{y}")
                        session.run("key:RETURN")
                        session.run("key:RIGHT")
                        session.run("key:RETURN")
                        title = "Import GoatTracker .sng"
                    else:
                        session.run("key:Ctrl-o")
                        title = "Load Song"
                    for name in (Path(directory).name, "fixture.sng"):
                        rows_text = {int(m[1]): m[2] for line in session.run("screendump").splitlines()
                                     if (m := re.match(r"screen(\d+):(.*)", line))}
                        top = next(y for y, text in rows_text.items() if title in text)
                        y = next(y for y, text in rows_text.items() if name in text)
                        for _ in range(y - top - 2):
                            session.run("key:DOWN")
                        session.run("key:RETURN")
                    self.assertIn("GoatTracker import mappings", screen(session))
                    session.run("key:ESC")
                    self.assertIn("Goat fixture", screen(session))

    def test_editor_failed_import_preserves_current_song(self):
        self.source.write_bytes(song())
        bad = self.dir / "bad.sng"
        bad.write_bytes(b"GTS5")
        before, after = self.dir / "before.ct", self.dir / "after.ct"
        with CCDriverSession("key:ESC") as session:
            session.run(f"open:{self.source}")
            session.run("key:ESC")
            session.run(f"save:{before}")
            session.run(f"open:{bad}")
            self.assertIn("Truncated GoatTracker", screen(session))
            session.run(f"save:{after}")
        a, b = read_ct(before), read_ct(after)
        # stop() changes emulated SID/CPU state; editable song data must match.
        self.assertEqual(a[65536:], b[65536:])
        for index, size in [(14, 512), (16, 256), (17, 256), (18, 384), (24, 192)]:
            self.assertEqual(table(a, index, size), table(b, index, size))
        for voice in range(3):
            self.assertEqual(tracks(a, voice), tracks(b, voice))
        for number in range(128):
            self.assertEqual(rows(a, number), rows(b, number))


if __name__ == "__main__":
    unittest.main()
