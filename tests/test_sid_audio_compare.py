"""Audio comparison must distinguish equality, timbre/pitch changes and silence."""
import json
import math
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import wave

from sid2ct.audio import compare_wavs
from tests.test_sid_reconstruct import ROOT, unknown_sid


def save(path, pcm, rate=16000):
    with wave.open(str(path), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(rate)
        wav.writeframes(struct.pack('<'+'h'*len(pcm), *pcm))


def tone(hz=440, duration=1, amplitude=10000):
    return [round(amplitude*math.sin(2*math.pi*hz*i/16000)) for i in range(round(duration*16000))]


class AudioComparison(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.a, self.b = Path(self.temp.name)/'a.wav', Path(self.temp.name)/'b.wav'

    def compare(self, a, b):
        save(self.a, a)
        save(self.b, b)
        return compare_wavs(self.a, self.b)

    def test_identical_non_silent_pcm_is_exact(self):
        result = self.compare(tone(), tone())
        self.assertTrue(result['exact_match'])
        self.assertEqual(result['verdict'], 'exact')
        self.assertEqual(result['similarity'], 1)

    def test_silence_is_inconclusive_even_when_equal(self):
        result = self.compare([0]*16000, [0]*16000)
        self.assertTrue(result['pcm_equal'])
        self.assertFalse(result['exact_match'])
        self.assertEqual(result['verdict'], 'inconclusive')
        self.assertIsNone(result['similarity'])

    def test_changed_pitch_scores_worse_than_changed_phase(self):
        a = tone()
        phase = [round(10000*math.cos(2*math.pi*440*i/16000)) for i in range(16000)]
        phase_result = self.compare(a, phase)
        pitch_result = self.compare(a, tone(880))
        self.assertFalse(phase_result['exact_match'])
        self.assertGreater(phase_result['similarity'], pitch_result['similarity'] + 0.2)

    def test_alignment_reports_delay_and_overlap(self):
        source = [0]*1600 + tone(duration=0.2) + [0]*3200 + tone(660, duration=0.3) + [0]*3200
        result = self.compare(source, [0]*800 + source[:-800])
        self.assertEqual(result['alignment_ms'], 50)
        self.assertGreater(result['similarity'], 0.9)
        self.assertFalse(result['exact_match'])
        self.assertLess(result['overlap_fraction'], 1)

    def test_truncated_output_cannot_be_exact(self):
        result = self.compare(tone(), tone(duration=0.5))
        self.assertFalse(result['exact_match'])
        self.assertLessEqual(result['similarity'], 0.5)

    def test_module_score_subcommand_matches_library(self):
        save(self.a,tone());save(self.b,tone(880))
        result=subprocess.run(['python3','-m','sid2ct','score',str(self.a),str(self.b),
                               '--alignment-ms','0'],cwd=ROOT,capture_output=True,text=True,timeout=60)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(json.loads(result.stdout),compare_wavs(self.a,self.b,fixed_alignment_ms=0))
        result=subprocess.run(['python3','-m','sid2ct','score',str(self.a),str(self.b),
                               '--max-lag-ms','-1'],cwd=ROOT,capture_output=True,text=True,timeout=60)
        self.assertNotEqual(result.returncode,0)

    def test_rate_mismatch_rejected(self):
        save(self.a, tone())
        save(self.b, tone(), 8000)
        with self.assertRaisesRegex(ValueError, 'sample rates'):
            compare_wavs(self.a, self.b)

    def test_fixed_alignment_keeps_timing_errors_visible(self):
        source=[0]*1600+tone(duration=.2)+[0]*3200+tone(660,duration=.3)+[0]*3200
        save(self.a,source);save(self.b,[0]*800+source[:-800])
        fixed=compare_wavs(self.a,self.b,fixed_alignment_ms=50)
        unshifted=compare_wavs(self.a,self.b,fixed_alignment_ms=0)
        self.assertEqual(fixed['alignment_ms'],50)
        self.assertGreater(fixed['similarity'],unshifted['similarity'])
        for alignment in (float('nan'),10000):
            with self.assertRaises(ValueError): compare_wavs(self.a,self.b,fixed_alignment_ms=alignment)


@unittest.skipUnless((ROOT/'tools/sid_render').exists(), 'Build libsidplayfp renderer first')
class LibSidPlayIntegration(unittest.TestCase):
    def test_renderer_is_deterministic_and_makes_audible_pcm(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            sid, a, b = temp/'input.sid', temp/'a.wav', temp/'b.wav'
            sid.write_bytes(unknown_sid())
            for out in (a, b):
                result = subprocess.run([str(ROOT/'tools/sid_render'), str(sid), str(out),
                                         '1', '1', '16000', '8580'],
                                        capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn('libsidplayfp', result.stdout)
            result = compare_wavs(a, b)
            self.assertTrue(result['exact_match'])
            self.assertGreater(result['source_rms'], 2)

    def test_converter_exports_wavs_and_searches_row_grid(self):
        with tempfile.TemporaryDirectory() as temp:
            temp = Path(temp)
            sid, ct = temp/'input.sid', temp/'out.ct'
            sid.write_bytes(unknown_sid())
            result = subprocess.run(['python3', '-m', 'sid2ct', 'convert',
                                     str(sid), '-o', str(ct), '--seconds', '1',
                                     '--audio-seconds', '0.5', '--auto-row-frames', '--window-seconds', '.25'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(ct.with_suffix('.json').read_text())
            self.assertEqual({c['row_frames'] for c in report['row_grid_search']}, {3, 4, 5, 6, 8, 12})
            self.assertEqual({c['modulation_programs'] for c in report['row_grid_search']}, {'legacy', 'compact'})
            valid = [c for c in report['row_grid_search'] if c.get('audio', {}).get('similarity') is not None]
            self.assertTrue(valid)
            best = max(valid, key=lambda c: c['audio']['similarity'])
            # The v1 guard reference is the best v1 among all candidates (not the first one built).
            reference=max(c['audio']['score_v1'] for c in valid)
            best=max((c for c in valid if c['audio']['score_v1']>=reference-.01),key=lambda c:c['audio']['score_v2'])
            self.assertEqual(report['row_frames'], best['row_frames'])
            self.assertEqual(report['effort']['selection']['reference_v1'], reference)
            self.assertEqual(report['audio_validation']['tested_seconds'], 0.5)
            self.assertTrue(ct.with_suffix('.source.wav').exists())
            self.assertTrue(ct.with_suffix('.reconstructed.wav').exists())
            self.assertEqual(report['audio_validation']['sample_rate'], 16000)
            diagnostics=report['diagnostics']['candidates']['reconstruction']
            self.assertEqual(set(diagnostics['voices']),{'1','2','3'})
            self.assertEqual(len(diagnostics['mix_windows']),2)
            self.assertTrue(Path(report['diagnostics_report']).is_file())
            for voice in diagnostics['voices'].values():
                self.assertTrue(Path(voice['candidate_wav']).is_file())
                self.assertEqual(len(voice['windows']),2)
            for text in ('Mix:','Voice 1:','Window (s)','envelope=','spectral=','PCM error='):
                self.assertIn(text,result.stdout)
            blocked=temp/'blocked.ct'
            folder=blocked.with_suffix('.comparison');folder.mkdir()
            sentinel=folder/'keep.txt';sentinel.write_text('preserve')
            rejected=subprocess.run(['python3','-m','sid2ct','convert',str(sid),'-o',str(blocked),
                                     '--seconds','1','--audio-seconds','.5','--force'],
                                    cwd=ROOT,capture_output=True,text=True,timeout=60)
            self.assertNotEqual(rejected.returncode,0)
            self.assertEqual(sentinel.read_text(),'preserve')
            self.assertFalse(blocked.exists())


    def test_converter_searches_sound_rates_and_records_winner(self):
        with tempfile.TemporaryDirectory() as temp:
            temp=Path(temp)
            sid,ct=temp/'input.sid',temp/'out.ct'
            sid.write_bytes(unknown_sid())
            result=subprocess.run(['python3','-m', 'sid2ct', 'convert',str(sid),
                                   '-o',str(ct),'--seconds','1','--audio-seconds','0.5',
                                   '--multiplier','2','--sound-programs','dynamic'],
                                  capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            report=json.loads(ct.with_suffix('.json').read_text())
            candidates=report['sound_program_search']
            self.assertEqual({c['output_multiplier'] for c in candidates},{1,2})
            reference=max(c['audio']['score_v1'] for c in candidates if c.get('audio'))
            best=max((c for c in candidates if c.get('audio') and c['audio']['score_v1']>=reference-.01),key=lambda c:c['audio']['score_v2'])
            self.assertEqual(report['output_multiplier'],best['output_multiplier'])
            self.assertEqual(report['tuning'],best['tuning'])
            self.assertEqual(report['audio_validation']['similarity'],best['audio']['similarity'])

    def test_native_recovery_audio_has_high_similarity(self):
        with tempfile.TemporaryDirectory() as temp:
            out = Path(temp)/'native.ct'
            sid = ROOT/'tests/fixtures/sid/So_You_Died_Man_Up.sid'
            result = subprocess.run(['python3', '-m', 'sid2ct', 'convert',
                                     str(sid), '-o', str(out), '--seconds', '1'],
                                    capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = json.loads(out.with_suffix('.json').read_text())
            self.assertEqual(report['mode'], 'recognized-cheesecutter')
            self.assertGreater(report['audio_validation']['similarity'], 0.95)




class ParallelSpectralAnalysis(unittest.TestCase):
    def test_worker_default_uses_all_available_cores_and_keeps_overrides(self):
        import os
        from unittest.mock import patch
        from sid2ct.audio import analysis_workers
        with patch.dict(os.environ, {}, clear=True):
            with patch('sid2ct.audio.os.process_cpu_count', return_value=64, create=True):
                self.assertEqual(analysis_workers(), 64)
            with patch('sid2ct.audio.os.process_cpu_count', return_value=None, create=True):
                self.assertEqual(analysis_workers(), 1)
        with patch.dict(os.environ, {'SID2CT_WORKERS':'2'}):
            self.assertEqual(analysis_workers(), 2)
        with patch.dict(os.environ, {'SID2CT_WORKERS':'0'}):
            with self.assertRaisesRegex(ValueError, 'positive'):
                analysis_workers()

    def test_parallel_fft_blocks_match_serial_at_boundaries(self):
        from array import array
        from unittest.mock import patch
        from sid2ct.audio import spectral_features
        # Over two 128-window blocks, with a partial final block.
        samples = array('h', ((i*7919)%65536-32768 for i in range(140000)))
        with patch('sid2ct.audio.np',None), patch.dict('os.environ', {'SID2CT_WORKERS':'1'}):
            serial = spectral_features(samples, 16000)
        with patch('sid2ct.audio.np',None), patch.dict('os.environ', {'SID2CT_WORKERS':'2'}):
            parallel = spectral_features(samples, 16000)
        self.assertEqual(parallel.tolist() if hasattr(parallel,'tolist') else parallel,
                         serial.tolist() if hasattr(serial,'tolist') else serial)


if __name__ == '__main__': unittest.main()
