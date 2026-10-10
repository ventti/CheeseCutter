"""Loop boundaries are player-state recurrences, not repeated musical phrases."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import wave
import zlib
from sid2ct.loops import CC_BASE_RATE, capture, pattern_spans
from sid2ct.native import native_song
from tests.test_sid_reconstruct import ROOT, unknown_sid, frame

class SongLoops(unittest.TestCase):
    def test_patterns_split_at_intro_and_restart_there(self):
        spans, restart = pattern_spans(150, 6, 420)
        self.assertEqual(spans, [(0,64),(64,70),(70,134),(134,150)])
        self.assertEqual(restart,2)

    def test_motif_does_not_shorten_state_loop(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); sid=d/'source.sid'; sid.write_bytes(unknown_sid())
            frames, info = capture(ROOT/'ct2util',sid,1,d)
            # Music repeats every 16 calls, but its counter takes 256 calls.
            self.assertTrue(info['detected'])
            self.assertEqual(info['end_call']-info['start_call'],256)
            self.assertEqual(len(frames),info['end_call'])

    def test_intro_state_is_excluded_from_loop(self):
        import struct
        raw = bytearray(unknown_sid())
        play = struct.unpack_from('>H', raw, 12)[0]
        at = 124 + play - 0x1000
        # One permanent state change on the first play call creates an intro.
        raw[at:at] = bytes.fromhex('a9018505')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); sid = d/'source.sid'; sid.write_bytes(raw)
            _, info = capture(ROOT/'ct2util', sid, 1, d)
            self.assertEqual(info['start_call'], 1)
            self.assertEqual(info['end_call'], 257)
            self.assertEqual(info['status'], 'loop_found')
            self.assertIn('exact replay comparison', info['method'])

    def test_no_loop_automatically_keeps_finite_capture(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); sid=d/'source.sid'; sid.write_bytes(unknown_sid())
            frames, info = capture(ROOT/'ct2util',sid,1,d,max_seconds=.1)
            self.assertEqual(len(frames),5)
            self.assertFalse(info['detected'])
            self.assertEqual(info['status'], 'no_loop_within_limit')
            self.assertEqual(info['duration_seconds'], .1)
            self.assertIsNone(info['loop_start_frame'])
            self.assertTrue(info['warnings'])
            frames, info = capture(ROOT/'ct2util',sid,1,d,seconds=.1)
            self.assertEqual(len(frames),5)
            self.assertFalse(info['detected'])

    def test_long_counter_does_not_turn_repeated_audio_into_loop(self):
        import struct
        raw = bytearray(unknown_sid())
        play = struct.unpack_from('>H', raw, 12)[0]
        # Carry a 24-bit counter while the audible motif still repeats every
        # 16 calls. Its actual state period is far outside this capture.
        at = 124 + play - 0x1000
        raw[at:at+2] = bytes.fromhex('e602d006e603d002e604')
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); sid = d/'source.sid'; sid.write_bytes(raw)
            frames, info = capture(ROOT/'ct2util', sid, 1, d, max_seconds=6)
            self.assertFalse(info['detected'])
            self.assertEqual(info['status'], 'no_loop_within_limit')
            self.assertEqual(len(frames), round(6*CC_BASE_RATE))

    def test_no_loop_conversion_needs_no_seconds(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); sid = d/'source.sid'; sid.write_bytes(unknown_sid())
            ct = d/'song.ct'
            p = subprocess.run(['python3', '-m', 'sid2ct', 'convert', str(sid),
                '-o', str(ct), '--max-seconds', '.48', '--skip-audio'],
                cwd=ROOT, capture_output=True, text=True, timeout=90)
            self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
            report = json.loads(ct.with_suffix('.json').read_text())
            self.assertEqual(report['loop_detection']['status'], 'no_loop_within_limit')
            self.assertEqual(report['captured_seconds'], .48)
            self.assertIn('none found', p.stdout)

    def test_native_intro_restart_survives_export(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); template=d/'fresh.ct'
            subprocess.run([str(ROOT/'ct2util'),'init',str(ROOT/'src/c64/player.bin'),'-o',str(template)],check=True,capture_output=True)
            frames=[frame(freq=0x1168 if i<60 else 0x15ED, gate=(i%12)<6) for i in range(180)]
            song,_=native_song(template.read_bytes(),frames,1,3,['Test','',''],loop_start=60)
            data=zlib.decompress(song[3:]); track=65536+256+5+160+2048
            self.assertEqual(data[track+4:track+6],bytes([0xF0,2]))
            ct=d/'song.ct';ct.write_bytes(song)
            exported=d/'song.sid'
            subprocess.run([str(ROOT/'ct2util'),'sid',str(ct),'-o',str(exported)],check=True,capture_output=True)
            trace=d/'render.trace'
            subprocess.run([str(ROOT/'ct2util'),'sidtrace',str(exported),'-f','420','-o',str(trace)],check=True,capture_output=True)
            from sid2ct.convert import parse_trace
            playback=parse_trace(trace.read_text())
            first={f[0]|f[1]<<8 for f in playback[:50] if f[4]&1}
            later={f[0]|f[1]<<8 for f in playback[200:] if f[4]&1}
            self.assertIn(0x1168,first)
            self.assertNotIn(0x1168,later)
            self.assertTrue(any(abs(f-0x15ED)<4 for f in later))

    def test_default_conversion_validates_whole_song(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); sid=d/'source.sid'; sid.write_bytes(unknown_sid()); ct=d/'song.ct'
            p=subprocess.run(['python3','-m','sid2ct','convert',str(sid),'-o',str(ct),'--sound-programs','static','--skip-diagnostics'],cwd=ROOT,capture_output=True,text=True,timeout=90)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            report=json.loads(ct.with_suffix('.json').read_text())
            duration=report['loop_detection']['duration_seconds']
            self.assertEqual(report['audio_validation']['tested_seconds'],duration)
            with wave.open(str(ct.with_suffix('.source.wav'))) as wav:
                self.assertAlmostEqual(wav.getnframes()/wav.getframerate(),duration,places=3)

    def test_compare_existing_ct_defaults_to_source_loop(self):
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); sid=d/'source.sid'; sid.write_bytes(unknown_sid()); ct=d/'song.ct'
            p=subprocess.run(['python3','-m','sid2ct','convert',str(sid),'-o',str(ct),'--skip-audio'],cwd=ROOT,capture_output=True,text=True,timeout=90)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            out=d/'ab'
            p=subprocess.run(['python3','-m','sid2ct','compare',str(sid),str(ct),'-o',str(out)],cwd=ROOT,capture_output=True,text=True,timeout=90)
            self.assertEqual(p.returncode,0,p.stdout+p.stderr)
            a=json.loads((out/'report.json').read_text())
            self.assertEqual(a['seconds'],a['loop_detection']['duration_seconds'])
            self.assertEqual(a['seconds'],json.loads(ct.with_suffix('.json').read_text())['captured_seconds'])

    def test_variable_cia_periods_are_integrated_and_resampled(self):
        import struct
        raw = bytearray(unknown_sid())
        play = struct.unpack_from('>H', raw, 12)[0]
        # Alternate $2080/$2000 latches using the player's existing counter.
        setup = bytes.fromhex('a5022901f004a980d002a9008d04dca9208d05dc')
        at = 124+play-0x1000
        raw[at:at] = setup
        struct.pack_into('>I', raw, 18, 1)
        with tempfile.TemporaryDirectory() as d:
            d = Path(d); sid = d/'source.sid'; sid.write_bytes(raw)
            frames, info = capture(ROOT/'ct2util', sid, 1, d)
            measured = json.loads((d/'loop.json').read_text())
            duration = sum((t+1)/985248 for t in measured['timer_latches'])
            self.assertTrue(info['variable_timer'])
            self.assertAlmostEqual(info['duration_seconds'], duration)
            self.assertEqual(len(frames), round(duration*info['destination_calls_per_second']))
            self.assertEqual(info['timing_basis'], 'cia')
            # Explicit timing overrides remain authoritative.
            _, override = capture(ROOT/'ct2util', sid, 1, d, multiplier=4)
            self.assertAlmostEqual(override['duration_seconds'], override['trace_calls']/200)
            # A VBI header makes these CIA writes irrelevant to call timing.
            struct.pack_into('>I', raw, 18, 0); sid.write_bytes(raw)
            frames, vbi = capture(ROOT/'ct2util', sid, 1, d)
            self.assertEqual(len(frames), vbi['trace_calls'])
            self.assertEqual(vbi['timing_basis'], 'pal-vbi')

    def test_noninteger_cia_rate_uses_physical_cc_cadence(self):
        import struct
        raw=bytearray(unknown_sid())
        play=struct.unpack_from('>H',raw,12)[0]
        # An arbitrary CIA rate, deliberately not a nominal PAL multiple.
        timer=4200
        setup=bytes([0xA9,timer&255,0x8D,4,0xDC,0xA9,timer>>8,0x8D,5,0xDC])
        at=124+play-0x1000-1
        raw[at:at]=setup
        struct.pack_into('>H',raw,12,play+len(setup))
        struct.pack_into('>I',raw,18,1)
        with tempfile.TemporaryDirectory() as d:
            d=Path(d); sid=d/'source.sid';sid.write_bytes(raw)
            frames,info=capture(ROOT/'ct2util',sid,1,d)
            self.assertAlmostEqual(info['source_calls_per_second'],985248/(timer+1))
            self.assertEqual(info['destination_calls_per_second'],CC_BASE_RATE*info['source_multiplier'])
            self.assertEqual(len(frames),round(info['duration_seconds']*info['destination_calls_per_second']))
            self.assertLess(abs(len(frames)/info['destination_calls_per_second']-info['duration_seconds']),1/info['destination_calls_per_second'])
