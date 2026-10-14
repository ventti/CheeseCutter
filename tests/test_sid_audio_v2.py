"""Check legacy equivalence, perceptual scoring, guarded selection and render reuse."""
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from sid2ct import audio
from sid2ct.rendercache import render
from sid2ct.search import select_by_mix
from tests.test_sid_audio_compare import save, tone


class AudioV2(unittest.TestCase):
    def test_numpy_matches_python(self):
        if audio.np is None:
            self.skipTest('numpy is optional')
        with tempfile.TemporaryDirectory() as directory:
            a, b = Path(directory)/'a.wav', Path(directory)/'b.wav'
            samples = [0]*1600+tone(duration=.2)+[0]*3200+tone(660,duration=.3)
            save(a,samples)
            save(b,[0]*800+[round(v*.8) for v in samples[:-800]])
            fast = audio.compare_wavs(a,b)
            audio._cached_spectral_features.cache_clear()
            with patch.object(audio,'np',None), patch.dict('os.environ',{'SID2CT_WORKERS':'1'}):
                slow = audio.compare_wavs(a,b)
            audio._cached_spectral_features.cache_clear()
            for key in ('score_v1','spectral_similarity','envelope_similarity','normalized_pcm_error'):
                self.assertAlmostEqual(fast[key],slow[key],delta=1e-6)
            self.assertEqual(fast['alignment_ms'],slow['alignment_ms'])
            self.assertAlmostEqual(fast['score_v2'],slow['score_v2'],delta=1e-6)

    def test_v2_pitch_and_alignment(self):
        with tempfile.TemporaryDirectory() as directory:
            a,b=Path(directory)/'a.wav',Path(directory)/'b.wav'
            save(a,tone(duration=.3));save(b,tone(660,duration=.3))
            wrong=audio.compare_wavs(a,b,fixed_alignment_ms=0)
            save(b,[round(v*.9) for v in tone(duration=.3)])
            close=audio.compare_wavs(a,b,fixed_alignment_ms=0)
            self.assertGreater(close['score_v2'],wrong['score_v2'])
            self.assertGreater(close['score_v2_components']['chroma_similarity'],wrong['score_v2_components']['chroma_similarity'])
            for result in (wrong,close):
                self.assertTrue(0<=result['score_v2']<=1)
                self.assertEqual(result['similarity'],result['score_v1'])

    def test_v1_guard_and_score_flag(self):
        records=[dict(name=name,mix=dict(score_v1=v1,score_v2=v2,similarity=v1))
                 for name,v1,v2 in [('before',.8,.5),('loss',.7,.9),('good',.795,.7)]]
        self.assertEqual(select_by_mix(records)['name'],'good')
        self.assertEqual(select_by_mix(records, 'v1')['name'],'before')
        self.assertEqual(select_by_mix(records,v1_tolerance=.2)['name'],'loss')

    def test_render_cache_keys_and_reuse(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            binary,source,out=root/'renderer',root/'source.sid',root/'out.wav'
            binary.write_bytes(b'binary');source.write_bytes(b'sid')
            def fake(command,**kwargs):
                save(Path(command[2]),tone(duration=.1))
                return subprocess.CompletedProcess(command,0,'metadata','')
            with patch('sid2ct.rendercache.subprocess.run',side_effect=fake) as run:
                command=[binary,source,out,1,1,16000,'8580','all']
                self.assertEqual(render(command,cache_dir=root/'cache'),'metadata')
                original=out.read_bytes();out.unlink()
                render(command,cache_dir=root/'cache')
                self.assertEqual(out.read_bytes(),original)
                self.assertEqual(run.call_count,1)
                command[-1]='1';render(command,cache_dir=root/'cache')
                source.write_bytes(b'new sid');render(command,cache_dir=root/'cache')
                binary.write_bytes(b'new binary');render(command,cache_dir=root/'cache')
                command[3]=2;render(command,cache_dir=root/'cache')
                self.assertEqual(run.call_count,5)

    def test_v2_uses_fixed_alignment_and_overlap(self):
        with tempfile.TemporaryDirectory() as directory:
            a,b=Path(directory)/'a.wav',Path(directory)/'b.wav'
            source=[0]*1600+tone(duration=.15)+[0]*1600+tone(660,duration=.15)
            save(a,source);save(b,[0]*800+source[:-800])
            aligned=audio.compare_wavs(a,b,fixed_alignment_ms=50)
            shifted=audio.compare_wavs(a,b,fixed_alignment_ms=0)
            self.assertGreater(aligned['score_v2'],shifted['score_v2'])
            self.assertLessEqual(aligned['score_v2'],aligned['overlap_fraction']+1e-6)
            save(b,[0]*len(source))
            self.assertIsNone(audio.compare_wavs(a,b)['score_v2'])

    def test_full_validation_guards_v1_when_v2_improves(self):
        from sid2ct.optimize import select_validated
        from tests.test_sid_optimize import diagnostic
        entries={'before':diagnostic(.8),'trial':diagnostic(.9)}
        for name,entry in entries.items():
            def update(value):
                if isinstance(value,dict):
                    if 'similarity' in value:
                        value.update(score_v1=.8 if name=='before' else .7,
                                     score_v2=.5 if name=='before' else .9)
                    for child in value.values():
                        update(child)
                elif isinstance(value,list):
                    for child in value: update(child)
            update(entry)
        records=[dict(name='before'),dict(name='trial')]
        report=dict(candidates=entries)
        self.assertEqual(select_validated(records,report)[0]['name'],'before')
        self.assertEqual(select_validated(records,report,v1_tolerance=.2)[0]['name'],'trial')
