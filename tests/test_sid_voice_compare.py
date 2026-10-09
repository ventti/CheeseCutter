"""Generic A/B, voice isolation, model selection and timing diagnostics."""
import json
from pathlib import Path
import subprocess
import struct
import tempfile
import unittest

from tests.test_sid_reconstruct import ROOT, unknown_sid
from sid2ct.convert import parse_trace
from sid2ct.audio import load_wav, rms
from sid2ct.compare import source_multiplier, subtract_background


class Timing(unittest.TestCase):
    def test_source_rate_uses_timing_metadata(self):
        self.assertEqual(source_multiplier('play speed VBI; CIA1 timerA 0'),1)
        self.assertEqual(source_multiplier('play speed CIA; CIA1 timerA 9827'),2)
        self.assertEqual(source_multiplier('play speed CIA; CIA1 timerA 4913'),4)
        self.assertEqual(source_multiplier('play speed CIA; CIA1 timerA 16375',
                                          'Trace CIA1 timerA: 9827; variable: no'),2)
        with self.assertRaisesRegex(ValueError,'changes'):
            source_multiplier('play speed CIA; CIA1 timerA 16375',
                              'Trace CIA1 timerA: 9827; variable: yes')
        for info in ('old renderer','play speed CIA; CIA1 timerA 1','play speed CIA; CIA1 timerA 14000'):
            with self.assertRaises(ValueError): source_multiplier(info)


@unittest.skipUnless((ROOT/'tools/sid_render').exists(),'Build renderer first')
class VoiceComparison(unittest.TestCase):
    def test_trace_reports_initialized_and_variable_timers(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp)
            original=unknown_sid();header=bytearray(original[:124])
            prefix=bytes.fromhex('a9318d04dca9138d05dc')
            play=struct.unpack_from('>H',header,12)[0]
            struct.pack_into('>H',header,12,play+len(prefix))
            payload=prefix+original[124:]
            for variable in (False,True):
                body=payload
                if variable:
                    index=play-0x1000+len(prefix)
                    body=payload[:index]+bytes.fromhex('ce04dc')+payload[index:]
                sid,trace=tmp/'timer.sid',tmp/'timer.trace'
                sid.write_bytes(header+body)
                result=subprocess.run([str(ROOT/'ct2util'),'sidtrace',str(sid),'-f','8','-o',str(trace)],
                                      capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                self.assertIn('Trace CIA1 timerA: 4913; variable: '+('yes' if variable else 'no'),result.stdout)
                self.assertEqual(len(parse_trace(trace.read_text())),8)

    def test_renderer_isolates_each_physical_voice(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp)
            for active in range(3):
                raw=unknown_sid()
                for offset in (0,1,4,6):
                    old=(0xD400+offset).to_bytes(2,'little')
                    new=(0xD400+offset+7*active).to_bytes(2,'little')
                    raw=raw.replace(b'\x8d'+old,b'\x8d'+new)
                sid=tmp/f'voice{active}.sid';sid.write_bytes(raw)
                paths={mask:tmp/f'{mask}.wav' for mask in ('all','none','1','2','3')}
                for mask,path in paths.items():
                    result=subprocess.run([str(ROOT/'tools/sid_render'),str(sid),str(path),
                                           '.4','1','16000','8580',mask],capture_output=True,text=True,timeout=60)
                    self.assertEqual(result.returncode,0,result.stderr)
                for voice in (1,2,3):
                    out=tmp/'contribution.wav'
                    self.assertEqual(subtract_background(paths[str(voice)],paths['none'],out),0)
                    energy=rms(load_wav(out)[1])
                    if voice==active+1: self.assertGreater(energy,100)
                    else: self.assertEqual(energy,0)

    def test_muted_ring_source_keeps_driving_receiver_and_pair_diagnostics(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            def ring_sid(source_frequency):
                # Voice 1 has no waveform/gate; its oscillator drives voice 2.
                init = (b'\xa9'+bytes([source_frequency&255])+b'\x8d\x00\xd4'+
                        b'\xa9'+bytes([source_frequency>>8])+b'\x8d\x01\xd4'+
                        bytes.fromhex('a9008d04d4a9688d07d4a9118d08d4a9158d0bd4a9f08d0dd4a90f8d18d460'))
                header = bytearray(unknown_sid()[:124])
                struct.pack_into('>H',header,12,0x1000+len(init))
                return bytes(header)+init+b'\x60'
            paths = []
            for index,frequency in enumerate((2000,5000)):
                sid, wav = tmp/f'{index}.sid',tmp/f'{index}.wav'
                sid.write_bytes(ring_sid(frequency))
                result = subprocess.run([str(ROOT/'tools/sid_render'),str(sid),str(wav),
                    '.4','1','16000','8580','2'],capture_output=True,text=True,timeout=60)
                self.assertEqual(result.returncode,0,result.stderr)
                paths.append(wav)
            # Muting the source's audio must not mute its oscillator input.
            self.assertNotEqual(load_wav(paths[0])[1],load_wav(paths[1])[1])
            self.assertGreater(rms(load_wav(paths[0])[1]),100)
            out = tmp/'comparison'
            result = subprocess.run(['python3','-m','sid2ct','compare',str(tmp/'0.sid'),
                str(tmp/'0.sid'),'-o',str(out),'--seconds','.4','--window-seconds','.2'],
                capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            report = json.loads((out/'report.json').read_text())
            edge = report['cross_channel_effects']['edges'][0]
            self.assertEqual((edge['source_voice'],edge['destination_voice']),(1,2))
            pair = report['candidates']['reconstruction']['coupled_pairs']['12']
            self.assertTrue(pair['fixed_alignment']['exact_match'])
            registers = report['candidates']['reconstruction']['coupled_registers']['edges'][0]
            self.assertEqual(registers['frequency_ratio_mean_absolute_error_cents'],0)
            self.assertEqual(len(pair['active_windows']),2)
            self.assertTrue(all(w['coupling_intervals'] for w in pair['active_windows']))
            ct = tmp/'coupled.ct'
            result = subprocess.run(['python3','-m','sid2ct','convert',str(tmp/'0.sid'),
                '-o',str(ct),'--seconds','.4','--skip-diagnostics'],
                capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            conversion = json.loads(ct.with_suffix('.json').read_text())
            candidates = conversion['sound_program_search']
            self.assertEqual({c['coupled_programs'] for c in candidates},{'legacy','preserve'})
            self.assertTrue(conversion['cross_channel_effects']['edges'])
            valid = [c['audio']['similarity'] for c in candidates
                     if c.get('audio') and c['audio']['similarity'] is not None]
            self.assertEqual(conversion['audio_validation']['similarity'],max(valid))


    def test_sid_only_then_existing_ct_and_model_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp=Path(tmp);sid=tmp/'generic.sid'
            raw=bytearray(unknown_sid());raw[119]=0x20  # Prefer 8580.
            sid.write_bytes(raw)
            automatic=tmp/'automatic'
            command=['python3','-m', 'sid2ct', 'compare',str(sid),'-o',str(automatic),
                     '--seconds','.6','--window-seconds','.2','--selection-seconds','.3']
            result=subprocess.run(command,capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            report=json.loads((automatic/'report.json').read_text())
            self.assertEqual(report['sid_model'],'8580')
            self.assertEqual(report['source_multiplier'],1)
            self.assertEqual(report['conversion'],'automatic')
            ct=automatic/'reconstruction.ct'
            self.assertTrue(ct.is_file())
            conversion=json.loads((automatic/'reconstruction.json').read_text())
            self.assertTrue(Path(conversion['audio_validation']['reconstructed_wav']).is_file())
            supplied=tmp/'supplied'
            result=subprocess.run(['python3','-m', 'sid2ct', 'compare',str(sid),str(ct),
                                   '-o',str(supplied),'--sid','6581','--seconds','.6','--window-seconds','.2'],
                                  capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            report=json.loads((supplied/'report.json').read_text())
            self.assertEqual(report['sid_model'],'6581')
            self.assertEqual(report['conversion'],'supplied candidates')
            candidate=report['candidates']['reconstruction']
            self.assertEqual(set(candidate['voices']),{'1','2','3'})
            self.assertEqual(len(candidate['mix_windows']),3)
            for voice in candidate['voices'].values():
                self.assertEqual(len(voice['windows']),3)
                self.assertTrue(Path(voice['source_wav']).is_file())
            original=(supplied/'report.json').read_bytes()
            result=subprocess.run(['python3','-m', 'sid2ct', 'compare',str(sid),str(ct),
                                   '-o',str(supplied)],capture_output=True,text=True,timeout=60)
            self.assertNotEqual(result.returncode,0)
            self.assertEqual((supplied/'report.json').read_bytes(),original)


if __name__=='__main__': unittest.main()
