import unittest
from sid2ct.segmentation import detect_boundaries


def snapshot(freq=1000, control=0x11, voice=0):
    result = bytearray(25)
    b = voice * 7
    result[b:b+2] = freq.to_bytes(2, 'little')
    result[b+4] = control
    return bytes(result)


def changes(frames, **options):
    return [(x.frame, x.reasons) for x in detect_boundaries(frames, **options)
            if x.voice == 0 and x.frame]


class SegmentationTests(unittest.TestCase):
    def test_gate_edges_and_release_preserved(self):
        frames = [snapshot(control=c) for c in [0, 9, 8, 9, 9]]
        self.assertEqual(changes(frames), [(1, ('gate_rise',)),
                         (2, ('gate_release',)), (3, ('gate_rise',))])
        release = next(x for x in detect_boundaries(frames) if x.frame == 2)
        self.assertFalse(release.gate_on)
        self.assertEqual(release.control, 8)

    def test_sustained_pitch_backdated_and_transient_rejected(self):
        frames = [snapshot(f) for f in [1000, 2000, 1000, 1500, 1501, 1502]]
        self.assertEqual(changes(frames), [(3, ('pitch',))])

    def test_control_persistence_and_coincident_reasons(self):
        frames = [snapshot(), snapshot(control=0x81), snapshot(),
                  *[snapshot(2000, 0x23)] * 3]
        self.assertEqual(changes(frames), [(3, ('pitch', 'control'))])

    def test_hidden_oscillator_zero_and_test_sync_changes(self):
        frames = [snapshot(0, 0), *[snapshot(1000, 10)] * 3,
                  *[snapshot(0, 0)] * 3]
        self.assertEqual(changes(frames), [(1, ('pitch', 'control')),
                                         (4, ('pitch', 'control'))])

    def test_vibrato_and_alternating_excursions(self):
        self.assertEqual(changes([snapshot(f) for f in
                         [1000, 1020, 990, 1010, 1000]]), [])
        self.assertEqual(changes([snapshot(f) for f in
                         [1000, 1500, 500, 1500, 500, 1000]]), [])

    def test_transposition_invariance(self):
        pitches = [1000, 1000, 1200, 1200, 1200, 1200]
        self.assertEqual(changes([snapshot(f) for f in pitches]),
                         changes([snapshot(f*2) for f in pitches]))

    def test_gate_resets_attack_anchor_and_eof_pending(self):
        self.assertEqual(changes([snapshot(1000, 0),
                         *[snapshot(2000, 0x11)] * 4]), [(1, ('gate_rise',))])
        self.assertEqual(changes([snapshot(), snapshot(2000)]), [])

    def test_voice_independence_repeatability_and_input_preservation(self):
        frames = [snapshot(1000, 0, 2), *[snapshot(2000, 0, 2)] * 3]
        original = list(frames)
        result = detect_boundaries(frames)
        self.assertEqual(result, detect_boundaries(frames))
        self.assertEqual(frames, original)
        self.assertEqual([(b.frame, b.voice) for b in result],
                         [(0, 0), (0, 1), (0, 2), (1, 2)])

    def test_limits_validation_and_empty(self):
        self.assertEqual(detect_boundaries([]), ())
        for kwargs in ({'sustain': 0}, {'sustain': 1.5},
                       {'pitch_cents': float('nan')}, {'max_frames': 0}):
            with self.assertRaises(ValueError):
                detect_boundaries([snapshot()], **kwargs)
        for frame in (bytes(24), [256]*25, ['x']*25):
            with self.assertRaises(ValueError):
                detect_boundaries([frame])

    def test_sustain_one_and_stable_trace(self):
        self.assertEqual(changes([snapshot(), snapshot(2000)], sustain=1),
                         [(1, ('pitch',))])
        self.assertEqual(len(detect_boundaries([snapshot()] * 10000)), 3)


if __name__ == '__main__':
    unittest.main()
