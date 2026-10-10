import unittest
from sid2ct.joint_voice import temporal_dependency_groups, group_trajectory
from sid2ct.coupling import dependency_masks


def frame(controls=(0, 0, 0), frequencies=(100, 200, 400)):
    f = bytearray(25)
    for v, (c, hz) in enumerate(zip(controls, frequencies)):
        f[v*7:v*7+2] = hz.to_bytes(2, 'little')
        f[v*7+4] = c
    return bytes(f)


class JointVoiceTests(unittest.TestCase):
    def test_silent_source_gate_release_and_local_overlap(self):
        frames = [frame(), frame((0x13, 0, 0)), frame((0x12, 0, 0)), frame(), frame((0, 0x13, 0))]
        groups = temporal_dependency_groups(frames)
        self.assertEqual([(g.start, g.stop, g.voices) for g in groups], [(1, 3, (0, 2)), (4, 5, (0, 1))])
        self.assertEqual(group_trajectory(frames, groups[0]).waveform_off_voices, (2,))

    def test_upstream_waveform_off_chain(self):
        frames = [frame((0x13, 0, 2))]
        group, = temporal_dependency_groups(frames)
        self.assertEqual(group.voices, (0, 1, 2))
        self.assertEqual(group_trajectory(frames, group).waveform_off_voices, (1, 2))

    def test_masks_agree_for_all_control_combinations(self):
        from itertools import product
        for controls in product((0, 2, 8, 0x14, 0x16, 0x23, 0x34), repeat=3):
            f = frame(controls)
            actual = 0
            for g in temporal_dependency_groups([f]):
                for v in g.voices:
                    actual |= 1 << v
            self.assertEqual(actual, dependency_masks([f])[0], controls)

    def test_effect_change_splits_but_gate_does_not(self):
        groups = temporal_dependency_groups([frame((0x15, 0, 0)), frame((0x14, 0, 0)), frame((0x13, 0, 0))])
        self.assertEqual([(g.start, g.stop, g.roots) for g in groups], [(0, 2, ((0, 4),)), (2, 3, ((0, 2),))])
        self.assertEqual(temporal_dependency_groups([frame((0x35, 0, 0))]), ())

    def test_joint_transposition_and_source_changes(self):
        frames = [frame((0x13, 0, 0), (100, 200, 400)), frame((0x13, 0, 8), (200, 200, 600))]
        group, = temporal_dependency_groups(frames)
        a = group_trajectory(frames, group)
        transposed = [frame((0x13, 0, 0), (200, 400, 800)), frame((0x13, 0, 8), (400, 400, 1200))]
        self.assertEqual(a, group_trajectory(transposed, group))
        changed = [frames[0], frame((0x13, 0, 8), (200, 200, 400))]
        self.assertNotEqual(a, group_trajectory(changed, group))
        changed = [frames[0], frame((0x13, 0, 0), (200, 200, 600))]
        self.assertNotEqual(a, group_trajectory(changed, group))

    def test_zero_filter_duration_and_bounded_endpoints(self):
        frames = [frame((0x13, 0, 0), (0, 100, 0))]*100
        g, = temporal_dependency_groups(frames)
        features = group_trajectory(frames, g, max_samples=4)
        self.assertEqual(features.duration, 100)
        self.assertEqual(features.offsets, (0, 33, 66, 99))
        self.assertIsNone(features.samples[0][0][0][0])
        other = bytearray(frames[-1]); other[23] = 0x84
        self.assertNotEqual(features, group_trajectory(frames[:-1]+[bytes(other)], g, max_samples=4))
        self.assertEqual(len(group_trajectory(frames, g, max_samples=None).samples), 100)

    def test_empty_validation_and_determinism(self):
        self.assertEqual(temporal_dependency_groups([]), ())
        with self.assertRaises(ValueError):
            temporal_dependency_groups([bytes(24)])
        frames = [frame((0x13, 0, 0))]*4
        g, = temporal_dependency_groups(frames)
        with self.assertRaises(ValueError):
            group_trajectory(frames, g, max_samples=1)
        self.assertEqual(group_trajectory(frames, g), group_trajectory(frames, g))


if __name__ == '__main__':
    unittest.main()
