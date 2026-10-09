"""Native sound-program inference and export, checked against SID registers."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib

from sid2ct.coupling import analyze, dependency_masks, effect_bits, trajectory_distance, register_comparison
from sid2ct.native import dmc_tuning, indexed_tuning, native_song, sound_distance
from sid2ct.convert import parse_trace
from tests.test_sid_reconstruct import ROOT, frame
from tests.test_goat_import import offset, table


class NativeReconstruction(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory()
        cls.dir=Path(cls.temp.name)
        template=cls.dir/'fresh.ct'
        r=subprocess.run([str(ROOT/'ct2util'),'init',str(ROOT/'src/c64/player.bin'),'-o',str(template)],
                         cwd=ROOT,capture_output=True,text=True)
        if r.returncode: raise RuntimeError(r.stdout+r.stderr)
        cls.template=template.read_bytes()

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def trace(self, data, calls=80):
        ct,sid,trace=(self.dir/n for n in ['out.ct','out.sid','out.trace'])
        ct.write_bytes(data)
        for command in [
                [str(ROOT/'ct2util'),'sid',str(ct),'-o',str(sid)],
                [str(ROOT/'ct2util'),'sidtrace',str(sid),'-f',str(calls),'-o',str(trace)]]:
            r=subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        return parse_trace(trace.read_text())

    def coupled_frame(self, source, destination, source_freq, control=0, receiver_control=0x15):
        f = bytearray(25)
        f[24] = 15
        for voice, freq, c in ((source, source_freq, control),
                               (destination, 4455, receiver_control)):
            b = voice*7
            f[b:b+7] = bytes([freq&255, freq>>8, 0, 0, c, 0, 0xF0])
        return bytes(f)

    def test_ring_source_oscillator_survives_waveform_and_gate_off(self):
        tuning = [min(65535,round(268*2**(i/12))) for i in range(96)]
        for destination in range(3):
            source = (destination+2)%3
            with self.subTest(destination=destination+1):
                values = [tuning[36]]*12+[tuning[43]]*12+[tuning[36]]*24
                frames = [self.coupled_frame(source,destination,value) for value in values]
                data, report = native_song(self.template, frames, 1, 4, ['Ring source','',''],
                    frequencies=tuning, coupled_programs='preserve', pitch_programs='attack')
                rendered = self.trace(data,calls=80)
                b, s = destination*7, source*7
                start = next(i for i,f in enumerate(rendered) if f[b+4]==0x15 and (f[b]|f[b+1]<<8))
                self.assertEqual([f[s]|f[s+1]<<8 for f in rendered[start:start+36]], values[:36])
                self.assertTrue(all(f[s+4]==0 for f in rendered[start:start+36]))
                self.assertEqual(report['waveform_off_modulator_events'], 1)
                self.assertEqual(report['coupled_voices'],sorted([source+1,destination+1]))

    def test_coupled_source_test_and_zero_frequency_are_preserved(self):
        tuning = [min(65535,round(268*2**(i/12))) for i in range(96)]
        controls = [0]*12+[8]*4+[0]*32
        values = [tuning[36]]*12+[0]*4+[tuning[43]]*32
        frames = [self.coupled_frame(2,0,value,control=control,receiver_control=0x13)
                  for value,control in zip(values,controls)]
        data, _ = native_song(self.template,frames,1,4,['Sync TEST','',''],
                              frequencies=tuning,coupled_programs='preserve')
        rendered = self.trace(data)
        start = next(i for i,f in enumerate(rendered) if f[4]==0x13 and (f[0]|f[1]<<8))
        self.assertEqual([f[18] for f in rendered[start:start+32]],controls[:32])
        self.assertEqual([f[14]|f[15]<<8 for f in rendered[start:start+32]],values[:32])

    def test_wave_table_exhaustion_does_not_make_hidden_modulator_audible(self):
        tuning = [min(65535,round(268*2**(i/12))) for i in range(96)]
        frames = [self.coupled_frame(0,1,tuning[36+i%12]) for i in range(400)]
        data, report = native_song(self.template,frames,1,4,['Long hidden source','',''],
                                   frequencies=tuning,coupled_programs='preserve')
        rendered = self.trace(data,calls=120)
        start = next(i for i,f in enumerate(rendered) if f[11]==0x15 and (f[7]|f[8]<<8))
        self.assertTrue(all(f[4]==0 for f in rendered[start:]))
        self.assertEqual(report['waveform_off_modulator_approximations'],1)

    def test_only_note_segments_overlapping_coupling_use_full_oscillator_pitch(self):
        tuning = [min(65535,round(268*2**(i/12))) for i in range(96)]
        frames = []
        for i in range(96):
            control = 0x10 if 24 <= i < 32 else 0x11
            n = 36 if i < 8 or 32 <= i < 48 else 43
            frames.append(self.coupled_frame(0,1,tuning[n],control,
                                             0x15 if i >= 64 else 0x11))
        legacy, _ = native_song(self.template,frames,1,4,['Local coupling','',''],frequencies=tuning)
        preserve, report = native_song(self.template,frames,1,4,['Local coupling','',''],
            frequencies=tuning,coupled_programs='preserve')
        before,after = self.trace(legacy,calls=120),self.trace(preserve,calls=120)
        start = next(i for i,f in enumerate(after) if f[4]==0x11 and (f[0]|f[1]<<8))
        self.assertEqual([f[0:2] for f in before[start:start+24]],
                         [f[0:2] for f in after[start:start+24]])
        self.assertEqual(after[start+52][0]|after[start+52][1]<<8,tuning[43])
        self.assertEqual(report['coupled_oscillator_events'],2)

    def test_coupled_register_audit_measures_hidden_source_and_frequency_ratio(self):
        frames = [self.coupled_frame(0,1,2000)]*8
        coupling = analyze(frames,50)
        exact = register_comparison(frames,50,frames,50,coupling,0)['edges'][0]
        self.assertEqual(exact['source_frequency_mean_absolute_error'],0)
        self.assertEqual(exact['frequency_ratio_mean_absolute_error_cents'],0)
        silent_source = bytearray(frames[0]);silent_source[:2] = bytes(2)
        wrong = register_comparison(frames,50,[bytes(silent_source)]*8,50,coupling,0)['edges'][0]
        self.assertEqual(wrong['source_frequency_mean_absolute_error'],2000)
        self.assertEqual(wrong['frequency_ratio_zero_mismatch_ticks'],8)
        waveform_change = bytearray(frames[0]);waveform_change[4] = 0x11
        oscillator = register_comparison(frames,50,[bytes(waveform_change)]*8,50,coupling,0)['edges'][0]
        self.assertEqual(oscillator['source_test_or_sync_mismatch_ticks'],0)
        offset = register_comparison(frames,50,[bytes(25)]*2+frames,50,coupling,40)['edges'][0]
        self.assertEqual(offset['frequency_ratio_mean_absolute_error_cents'],0)

    def test_sync_chain_keeps_hidden_upstream_oscillator(self):
        f = bytearray(self.coupled_frame(2,0,3000,receiver_control=0x13))
        f[18] = 2  # Hidden voice 3 is itself synced by hidden voice 2.
        self.assertEqual(dependency_masks([bytes(f)]),[7])
        # Gate state does not disconnect a source or a released destination.
        f[4] = 0x12
        self.assertEqual(dependency_masks([bytes(f)]),[7])

    def test_ring_analysis_rejects_waveforms_without_triangle_or_with_saw(self):
        self.assertEqual(effect_bits(0x15),4)
        self.assertEqual(effect_bits(0x55),4)
        self.assertEqual(effect_bits(0x45),0)
        self.assertEqual(effect_bits(0x35),0)
        frames = [self.coupled_frame(0,1,3000)]*8
        report = analyze(frames,50)
        self.assertEqual(report['edges'][0]['source_voice'],1)
        self.assertEqual(report['edges'][0]['destination_voice'],2)
        self.assertEqual(report['edges'][0]['source_waveform_off_ticks'],8)
        self.assertEqual(report['edges'][0]['source_gate_off_ticks'],8)
        self.assertEqual(report['edges'][0]['intervals'][0]['end_seconds'],.16)

    def test_coupled_fallback_prefers_correct_pitch_contour_and_dependency_bits(self):
        target = ((0,0x17),(7,0x17),(0x7E,0))
        wrong_contour = ((0,0x17),(0,0x17),(0x7E,0))
        wrong_dependency = ((0,0x11),(7,0x11),(0x7E,0))
        self.assertEqual(trajectory_distance(target,target),0)
        self.assertGreater(trajectory_distance(target,wrong_contour),0)
        self.assertGreater(trajectory_distance(target,wrong_dependency),
                           trajectory_distance(target,wrong_contour))

    def test_short_gate_survives_coarse_grid(self):
        frames=[frame()]*3+[frame(gate=False)]*9
        data,report=native_song(self.template,frames,1,6,['Gate','',''])
        rendered=self.trace(data)
        first=next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        release=next(i for i in range(first+1,len(rendered)) if not rendered[i][4]&1)
        self.assertEqual(release-first,3)
        self.assertEqual(report['row_collisions'],0)

    def test_terminal_holds_share_one_instrument(self):
        frames = ([frame()]*8 + [frame(gate=False)]*8 +
                  [frame()]*8 + [frame(gate=False)]*24)
        data, report = native_song(self.template, frames, 1, 4, ['Hold','',''], pitch_programs='full')
        self.assertEqual(report['instruments'], 1)
        rendered = self.trace(data)
        start = next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        self.assertTrue(rendered[start+7][4]&1)
        self.assertFalse(rendered[start+8][4]&1)

    def test_extended_pitch_changes_without_retriggering_envelope(self):
        tuning = [min(65535,round(268*2**(i/12))) for i in range(96)]
        frames = [frame(freq=tuning[36])]*80 + [frame(freq=tuning[43])]*24
        data, report = native_song(self.template, frames, 1, 4, ['Legato','',''],
                                   frequencies=tuning, pitch_programs='full')
        rendered = self.trace(data, calls=140)
        start = next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        self.assertEqual([f[0]|f[1]<<8 for f in rendered[start:start+96]],
                         [tuning[36]]*80 + [tuning[43]]*16)
        self.assertTrue(all(f[4]&1 for f in rendered[start:start+96]))
        self.assertEqual(report['events'], 1)

    def test_descending_transposed_arpeggios_share_an_instrument(self):
        tuning = [min(65535, round(268*2**(i/12))) for i in range(96)]
        frames = []
        for low in (36,48):
            frames += ([frame(freq=tuning[low+7])]*24 +
                       [frame(freq=tuning[low])]*12 +
                       [frame(freq=tuning[low],gate=False)]*6)
        data, report = native_song(self.template, frames, 1, 3, ['Arp','',''],
                                   frequencies=tuning, pitch_programs='full')
        self.assertEqual(report['instruments'], 1)
        rendered = self.trace(data, calls=100)
        notes = {f[0]|f[1]<<8 for f in rendered if f[4]&1}
        self.assertTrue(set(tuning[n] for n in (36,43,48,55)) <= notes)

    def test_exact_wave_suffixes_share_native_storage(self):
        noise = bytearray(frame()); noise[4] = 0x81
        frames = ([bytes(noise)]*8 + [frame()]*8 + [frame(gate=False)]*8 +
                  [frame()]*8 + [frame(gate=False)]*8)
        _, report = native_song(self.template, frames, 1, 4, ['Suffix','',''],
                                pitch_programs='full')
        self.assertEqual(report['shared_wave_programs'], 1)
        self.assertEqual(report['instruments'], 2)

    def test_fallback_compares_pulse_and_filter_timbre(self):
        wave = ((0,0x41),(0x7E,0))
        pulse = ((0,0,0x22,127),)
        filt = ((0x90,0x81,64,127),)
        original = (0x12,0xA3,wave,pulse,filt)
        near = (0x12,0xA3,wave,((0,0,0x32,127),),filt)
        far = (0x12,0xA3,wave,((0,0,0xCC,127),),filt)
        unrouted = (0x12,0xA3,wave,pulse,())
        self.assertLess(sound_distance(original,near),sound_distance(original,far))
        self.assertLess(sound_distance(original,near),sound_distance(original,unrouted))

    def test_pulse_sweep_is_translated_into_player_behavior(self):
        frames=[frame(pulse=512+i*32) for i in range(8)]+[frame(gate=False,pulse=768)]*8
        data,report=native_song(self.template,frames,1,8,['Pulse','',''])
        rendered=self.trace(data)
        start=next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        values=[(f[2]|f[3]<<8)&4095 for f in rendered[start:start+5]]
        self.assertEqual(values[:4],[512,544,576,608])
        self.assertGreater(report['pulse_rows'],1)

    def test_compact_constant_pulse_ignores_note_duration(self):
        frames = ([frame(pulse=512)]*8 + [frame(gate=False,pulse=512)]*8 +
                  [frame(pulse=512)]*8 + [frame(gate=False,pulse=512)]*40)
        data, report = native_song(self.template, frames, 1, 4, ['Pulse hold','',''],
                                  pitch_programs='full', modulation_programs='compact')
        self.assertEqual(report['instruments'], 1)
        self.assertEqual(report['pulse_rows'], 2)
        rendered = self.trace(data)
        start = next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        self.assertEqual([(f[2]|f[3]<<8)&4095 for f in rendered[start:start+24]], [512]*24)

    def test_compact_pulse_discontinuities_reset_instead_of_clipping(self):
        values = [512,544,576,2048,2080,2112,2112,2112]
        data, _ = native_song(self.template, [frame(pulse=v) for v in values]+[frame(pulse=values[-1])]*24,
                              1, 4, ['Reset pulse','',''], modulation_programs='compact')
        rendered = self.trace(data)
        start = next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        self.assertEqual([(f[2]|f[3]<<8)&4095 for f in rendered[start:start+8]], values)

    def test_compact_pulse_preserves_low_bits_and_sentinel_width(self):
        for width in (513, 0xFF0, 0xFFF):
            with self.subTest(width=width):
                data, _ = native_song(self.template, [frame(pulse=width)]*16,
                                      1, 4, ['Width','',''], modulation_programs='compact')
                rendered = self.trace(data)
                start = next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
                self.assertEqual([(f[2]|f[3]<<8)&4095 for f in rendered[start:start+8]], [width]*8)

    def test_compact_pulse_sweep_wrap_and_terminal_hold(self):
        values = [4032,4064,0,32,64]+[64]*11
        data, _ = native_song(self.template, [frame(pulse=v) for v in values],
                              1, 4, ['Wrap','',''], modulation_programs='compact')
        rendered = self.trace(data)
        start = next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        self.assertEqual([(f[2]|f[3]<<8)&4095 for f in rendered[start:start+16]], values)

    def test_filter_routing_and_cutoff_are_audible_player_state(self):
        frames=[]
        for i in range(8):
            f=bytearray(frame())
            f[22],f[23],f[24]=64+i,0x81,0x1F
            frames.append(bytes(f))
        data,report=native_song(self.template,frames,1,4,['Filter','',''])
        rendered=self.trace(data)
        state=[f for f in rendered if f[23]&1]
        self.assertTrue(state)
        self.assertIn(0x81,{f[23] for f in state})
        self.assertTrue(all(f[24]&0x10 for f in state))
        self.assertGreater(report['filter_rows'],1)
        self.assertGreater(len({f[22] for f in state}),1)

    def test_source_multiplier_preserves_native_program_timing(self):
        frames=[frame(pulse=512+i*32) for i in range(8)]+[frame(gate=False)]*8
        a,_=native_song(self.template,frames,1,4,['Rate','',''])
        b,_=native_song(self.template,[f for f in frames for _ in range(2)],2,4,['Rate','',''])
        self.assertEqual(a,b)

    def test_source_rate_preserves_between_frame_pulse_and_gate(self):
        frames=[frame(pulse=512+i*16) for i in range(5)]+[frame(gate=False,pulse=592)]*15
        data,report=native_song(self.template,frames,2,5,['Fast','',''],output_multiplier=2)
        rendered=self.trace(data)
        start=next(i for i,f in enumerate(rendered) if f[4]&1 and f[4]&0xF0)
        # Multispeed initializes pulse one tick before applying the waveform.
        pulse_start=next(i for i,f in enumerate(rendered) if (f[2]|f[3]<<8)&4095)
        values=[(f[2]|f[3]<<8)&4095 for f in rendered[pulse_start:pulse_start+5]]
        self.assertEqual(values,[512,528,544,560,576])
        release=next(i for i in range(start+1,len(rendered)) if not rendered[i][4]&1)
        self.assertEqual(release-start,5)
        self.assertEqual(report['output_multiplier'],2)

    def test_filter_discontinuity_and_row_boundaries_match_source(self):
        values=[67,69,71,73,32,34,36,38]
        frames=[]
        for value in values:
            f=bytearray(frame())
            f[22],f[23],f[24]=value,0x81,0x1F
            frames.append(bytes(f))
        data,_=native_song(self.template,frames,1,4,['Reset','',''])
        rendered=self.trace(data)
        start=next(i for i,f in enumerate(rendered) if f[23]==0x81)
        self.assertEqual([f[22] for f in rendered[start:start+8]],values)

    def test_indexed_tuning_requires_repeated_code_and_observed_pitches(self):
        load=0x2000
        values=[round(268*2**(i/12)) for i in range(96)]
        payload=bytearray(0x400)
        payload[0x100:0x160]=bytes(v&255 for v in values)
        payload[0x160:0x1C0]=bytes(v>>8 for v in values)
        pair=bytes.fromhex('bd00218d00d4bd60218d01d4')
        payload[:12]=pair
        payload[16:28]=pair
        header=bytearray(124)
        header[:4]=b'PSID'
        struct.pack_into('>7H',header,4,2,124,load,load,load+3,1,1)
        frames=[frame(freq=v) for v in values[24:30]]
        self.assertEqual(indexed_tuning(header+payload,frames),values)
        struct.pack_into('>H',header,8,0)
        self.assertEqual(indexed_tuning(header+struct.pack('<H',load)+payload,frames),values)
        self.assertIsNone(indexed_tuning(header+struct.pack('<H',load)+payload,[frame()]*20))
        payload[16:28]=bytes(12)
        self.assertIsNone(indexed_tuning(header+struct.pack('<H',load)+payload,frames))

    def test_indexed_tuning_rejects_ambiguous_tables(self):
        load=0x2000
        values=[round(268*2**(i/12)) for i in range(96)]
        payload=bytearray(0x400)
        for lo,sites in [(0x100,(0,16)),(0x240,(32,48))]:
            payload[lo:lo+96]=bytes(v&255 for v in values)
            payload[lo+96:lo+192]=bytes(v>>8 for v in values)
            pair=b'\xb9'+struct.pack('<H',load+lo)+b'\x8d\x00\xd4\xb9'+struct.pack('<H',load+lo+96)
            for site in sites: payload[site:site+len(pair)]=pair
        header=bytearray(124)
        struct.pack_into('>HH',header,6,124,load)
        self.assertIsNone(indexed_tuning(header+payload,[frame(freq=v) for v in values[24:30]]))

    def test_custom_tuning_survives_optimized_export(self):
        tuning=[round(268*2**(i/12)) for i in range(96)]
        tuning=[min(65535,v) for v in tuning]
        data,report=native_song(self.template,[frame(freq=4291)]*16,1,4,['Tune','',''],tuning)
        rendered=self.trace(data)
        frequencies={f[0]|f[1]<<8 for f in rendered if f[4]&1}
        self.assertIn(tuning[48],frequencies)
        self.assertNotIn(0x1168,frequencies)

    def test_dmc_anchor_requires_confirmed_body_and_table(self):
        payload=bytearray(0x900)
        load=0x2000
        payload[:6]=bytes([0x4C,0x1D,0x20,0x4C,0x85,0x20])
        payload[0x85:0x88]=bytes([0xCE,0x18,0x27])
        payload[0x100:0x10C]=bytes([0xB9,0x47,0x26,0x9D,0,0x30,0xB9,0xA7,0x26,0x9D,3,0x30])
        values=[min(65535,round(268*2**(i/12))) for i in range(96)]
        payload[0x647:0x6A7]=bytes(v&255 for v in values)
        payload[0x6A7:0x707]=bytes(v>>8 for v in values)
        header=bytearray(124)
        header[:4]=b'PSID'
        struct.pack_into('>7H',header,4,2,124,load,load,load+3,1,1)
        self.assertEqual(dmc_tuning(header+payload),values)
        payload[0x86]=0x19
        self.assertIsNone(dmc_tuning(header+payload))

    def test_full_pulse_table_exports_without_out_of_bounds(self):
        source=[frame(pulse=0x300)]*3+[frame(gate=False,pulse=0x300)]*9
        song,_=native_song(self.template,source,1,3,['Full pulse','',''])
        import zlib
        data=bytearray(zlib.decompress(song[3:]))
        addr=offset(data,17)
        for i in range(64):
            row=[0,0,0x30,1] if i==0 else [1,i,255,i+1 if i<63 else 127]
            data[addr+i*4:addr+i*4+4]=bytes(row)
        # Point the inferred instrument at the 63-row linked programme.
        data[offset(data,18)+5*48+1]=1
        self.trace(b'CC2'+zlib.compress(data))


if __name__=='__main__': unittest.main()
