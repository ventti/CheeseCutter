"""Lossless compact layouts and native register playback checks."""
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

from sid2ct.layout import (Row, compress, expand, encode, comparison, chunk_layout,
                          verify_player, player_for_layout, without_repeated_instruments, Layout)
import struct
import zlib
from sid2ct.native import native_song

ROOT = Path(__file__).resolve().parents[1]
TOOL = str(ROOT/'ct2util') if (ROOT/'ct2util').is_file() else shutil.which('ct2util')


class LayoutTests(unittest.TestCase):
    def test_random_roundtrip(self):
        rng = random.Random(71)
        for _ in range(20):
            count = rng.randrange(1, 100)
            voices = tuple(tuple(rng.choice((Row(), Row(gate=1, rest=False),
                Row(note=rng.randrange(3, 95), instrument=rng.randrange(4),
                    command=rng.randrange(3), tie=bool(rng.randrange(2)), rest=False)))
                for _ in range(count)) for _ in range(3))
            boundary = rng.randrange(count)
            plan = compress(voices, loop_start=boundary, preferred_cut_points=[(boundary,)]*3)
            self.assertEqual(expand(plan), voices)
            for order, restart in zip(plan.orders, plan.restarts):
                self.assertEqual(sum(len(plan.sequences[s-1]) for _, s in order[:restart]), boundary)
            self.assertLessEqual(len(plan.sequences), 127)
            self.assertTrue(all(len(o) <= 511 for o in plan.orders))
            self.assertTrue(all(len(s) <= 64 and len(encode(s)) <= 256 for s in plan.sequences))

    def test_transposed_repeats_and_savings(self):
        voices = tuple(tuple(Row(note=36+shift+i%8, instrument=1, rest=False)
                       if i%4 == 0 else Row() for i in range(256)) for shift in (0, 7, 12))
        plan = compress(voices)
        self.assertEqual(expand(plan), voices)
        self.assertTrue(any(t for order in plan.orders for t, _ in order))
        stats = comparison(voices, plan)
        print('Synthetic layout savings:', stats)
        self.assertGreater(stats['saved_bytes'], 0)

    def test_off_grid_blocks_shared_across_voices(self):
        block = (Row(note=36,instrument=1,rest=False),)+(Row(),)*16
        voices = (block*12,)*3
        plan = compress(voices)
        self.assertEqual(expand(plan),voices)
        self.assertTrue(any(len(seq)%16 for seq in plan.sequences))
        used = [set(seq for _,seq in order) for order in plan.orders]
        self.assertTrue(set.intersection(*used))
        stats = comparison(voices,plan)
        self.assertLessEqual(stats['compact_sequence_bytes'],
                             .7*stats['chunks_sequence_bytes'])

    def test_duration_and_instrument(self):
        note = Row(note=36, instrument=1, rest=False)
        self.assertEqual(encode((note,)+ (Row(),)*15), bytes((0xC1, 0xFF, 36, 0xBF)))
        self.assertEqual(encode((note, note)), bytes((0xC1, 0xF0, 36, 36, 0xBF)))
        self.assertEqual(Row.from_native(note.native()), note)
        self.assertEqual(encode((note,Row(tie=True))),bytes((0xC1,0xF1,36,0xBF)))

    def test_command_and_tie_refuse_transposition(self):
        for options in ({'tie': True}, {'command': 7}, {'command': 0x81}):
            voices = tuple(tuple(Row(note=40+shift, instrument=1, rest=False,
                                    **options) for _ in range(32))
                           for shift in (0,7,12))
            plan = compress(voices)
            self.assertEqual(expand(plan), voices)
            self.assertFalse(any(t for order in plan.orders for t,_ in order))

    def test_duration_remainder_matches_export(self):
        note = Row(note=36, instrument=1, rest=False)
        self.assertEqual(encode((note,)+(Row(),)*17),
                         bytes((0xC1,0xF1,36,0xFF,0,0xBF)))

    @unittest.skipUnless(TOOL, 'ct2util is missing')
    def test_out_of_range_wave_lookup_refuses_reuse(self):
        # Airfunk class: 42 + relative wave offset 67 indexes past note 95.
        # Equal notes and equal editable-image register output are insufficient:
        # exported memory after the tuning table contains relocated pointers.
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory)/'fresh.ct'
            result = subprocess.run([TOOL,'init',str(ROOT/'src/c64/player.bin'),
                                     '-o',str(template)],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            image = bytearray(zlib.decompress(template.read_bytes()[3:]))
            pointers = struct.unpack_from('<39H',image,0xFA0)
            image[pointers[14]:pointers[14]+4] = bytes((67,0x7E,0,0x7E))
            image[pointers[15]:pointers[15]+4] = bytes((0x11,0,0x11,0))
            image[pointers[18]+7*48+1] = 0
            image[65541:65573] = bytes((5,))*32
            voices = ((Row(note=42,instrument=1,rest=False),)+(Row(),)*63,)*3
            representative = (Row(note=36,instrument=1,rest=False),)+(Row(),)*31
            plan = Layout((representative,(Row(),)*32),
                          (((6,1),(6,2)),)*3, (0,0,0))
            baseline = chunk_layout(voices)
            self.assertEqual(player_for_layout(image,baseline).frames(400),
                             player_for_layout(image,plan).frames(400))
            with self.assertRaisesRegex(ValueError,'109.*outside'):
                verify_player(image,voices,plan)
            exported = []
            for name, layout in (('baseline',baseline),('unsafe',plan)):
                data = bytearray(image)
                for seq, rows in enumerate(layout.sequences,1):
                    addr = data[pointers[22]+seq] | data[pointers[23]+seq]<<8
                    raw = bytes(x for row in rows for x in row.native())
                    if len(rows)<64:
                        raw += b'\xbf'
                    data[addr:addr+256] = raw.ljust(256,b'\0')
                tracks = 65536+256+5+160+2048
                empty = bytes((0xA0,0,0xF0,0)).ljust(1024,b'\0')
                data[tracks:tracks+32*3*1024] = empty*(32*3)
                for vid,order in enumerate(layout.orders):
                    raw = bytes(x for trans,seq in order for x in (0xA0+trans,seq))
                    raw = (raw+b'\xf0\0').ljust(1024,b'\0')
                    data[tracks+vid*1024:tracks+(vid+1)*1024] = raw
                    data[pointers[19+vid]:pointers[19+vid]+1024] = raw
                ct,sid,trace = (Path(directory)/(name+ext)
                                for ext in ('.ct','.sid','.trace'))
                ct.write_bytes(b'CC2'+zlib.compress(data))
                for args in (('sid',ct,'-o',sid),
                             ('sidtrace',sid,'-f',400,'-o',trace)):
                    result = subprocess.run([TOOL,*map(str,args)],capture_output=True)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                exported.append(trace.read_bytes())
            self.assertNotEqual(*exported)
            # Also refuse exact reuse: relocation is unsafe without transpose.
            with self.assertRaisesRegex(ValueError,'outside'):
                verify_player(image,voices,baseline)

    @unittest.skipUnless(TOOL, 'ct2util is missing')
    def test_instrument_omission_is_proved_by_player(self):
        with tempfile.TemporaryDirectory() as directory:
            template = Path(directory)/'fresh.ct'
            result = subprocess.run([TOOL,'init',str(ROOT/'src/c64/player.bin'),
                                     '-o',str(template)],capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            image = bytearray(zlib.decompress(template.read_bytes()[3:]))
            pointers = struct.unpack_from('<39H',image,0xFA0)
            image[pointers[14]:pointers[14]+2] = bytes((0,0x7E))
            image[pointers[15]:pointers[15]+2] = bytes((0x11,0))
            image[pointers[18]+7*48+1] = 0
            image[65541:65573] = bytes((5,))*32
            voices = ((Row(note=36,instrument=1,rest=False),)*128,)*3
            reduced = without_repeated_instruments(voices)
            verify_player(image,voices,compress(reduced))
            # An actual instrument change cannot be dropped merely because
            # the note and waveform match.
            image[pointers[18]+2] = 0xAB
            image[pointers[18]+48+2] = 0xCD
            changed = list(voices[0])
            changed[64] = Row(note=36,instrument=2,rest=False)
            changed = (tuple(changed),)*3
            with self.assertRaisesRegex(ValueError,'changed player registers'):
                verify_player(image,changed,compress(reduced))

    def test_limits(self):
        with self.assertRaises(ValueError):
            compress(((Row(),)*32705,), search_row_budget=0)
        with self.assertRaises(ValueError):
            compress(((Row(),),), max_sequences=128)

    @unittest.skipUnless(TOOL, 'ct2util is missing')
    def test_playback_and_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            template = directory/'fresh.ct'
            def run(args):
                result = subprocess.run([TOOL, *map(str, args)], cwd=ROOT,
                                        capture_output=True, text=True, timeout=120)
                self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            run(['init', ROOT/'src/c64/player.bin', '-o', template])
            frames = []
            for i in range(384):
                f = bytearray(25)
                f[24] = 15
                for voice in range(3):
                    b = voice*7
                    freq = round(268*2**((36+voice*7+(i//16)%4)/12))
                    f[b:b+7] = bytes((freq&255, freq>>8, 0, 8,
                                     0x11 if i%16 < 12 else 0x10, 0, 0xF0))
                frames.append(bytes(f))
            traces = []
            songs = []
            for mode in ('chunks', 'compact'):
                started = time.perf_counter()
                song, report = native_song(template.read_bytes(), frames, 1, 4,
                                          ['Layout', '', ''], layout=mode, loop_start=64)
                print(f"{mode} song build: {time.perf_counter()-started:.3f}s")
                songs.append(song)
                ct, sid, trace = (directory/(mode+ext) for ext in ('.ct', '.sid', '.trace'))
                ct.write_bytes(song)
                run(['sid', ct, '-o', sid])
                run(['sidtrace', sid, '-f', 1000, '-o', trace])
                traces.append(trace.read_bytes())
                if mode == 'compact':
                    self.assertTrue(report['helpers']['layout']['applied'])
                    self.assertGreaterEqual(report['helpers']['layout']['verified_export_calls'], 15000)
            self.assertEqual(*traces)
            with patch('sid2ct.layout.compress', side_effect=ValueError('forced capacity failure')):
                fallback, report = native_song(template.read_bytes(), frames, 1, 4,
                    ['Layout', '', ''], layout='compact', loop_start=64)
            self.assertEqual(fallback, songs[0])
            self.assertFalse(report['helpers']['layout']['applied'])
            # A model-equivalent plan must still fall back if assembly changes
            # the exported trace (as seen at Baboon's first loop restart).
            with patch('sid2ct.layout.verify_export',
                       side_effect=ValueError('Compact export changed SID registers at call 6022')):
                fallback, report = native_song(template.read_bytes(), frames, 1, 4,
                    ['Layout', '', ''], layout='compact', loop_start=64)
            self.assertEqual(fallback, songs[0])
            self.assertIn('call 6022', report['helpers']['layout']['reason'])


if __name__ == '__main__':
    unittest.main()
