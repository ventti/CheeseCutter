import random
import struct
import tempfile
import unittest
from pathlib import Path

from sid2ct import corpus


def psid(author='Test (Handle)', version=2, load=0x1000, init=0x1000, play=0x1003, songs=3, start=2, flags=0, rsid=False):
    header = bytearray(124)
    header[:4] = b'RSID' if rsid else b'PSID'
    struct.pack_into('>7H', header, 4, version, 124, load, init, play, songs, start)
    header[0x36:0x36+len(author)] = author.encode('latin1')
    header[118:120] = flags.to_bytes(2, 'big')
    return bytes(header)+bytes([0x60]*16)


class Corpus(unittest.TestCase):
    def test_author_matching(self):
        self.assertEqual(corpus.author(psid('Antti Hannula (Flex)')), 'Antti Hannula (Flex)')
        self.assertTrue(corpus.author_matches('Flex', 'Antti Hannula (Flex)'))
        self.assertTrue(corpus.author_matches('Blues Muz', "Blues Muz'"))
        self.assertTrue(corpus.author_matches('DRAX', 'JCH & Thomas Mogensen (DRAX)'))
        self.assertFalse(corpus.author_matches('Flex', 'Flexible Person'))
        self.assertFalse(corpus.author_matches('PRI', 'Prince'))

    def test_usable_filters(self):
        self.assertEqual(corpus.usable(psid()), 2)
        self.assertIsNone(corpus.usable(psid(rsid=True)))
        self.assertIsNone(corpus.usable(psid(flags=2 << 2)))  # NTSC only
        self.assertIsNone(corpus.usable(psid(play=0)))
        self.assertIsNone(corpus.usable(psid(version=1)))
        self.assertIsNone(corpus.usable(b'PSID'))

    def test_stil_digi_flag(self):
        stil = corpus.parse_stil('/MUSICIANS/A/X/a.sid\n COMMENT: Uses digi drums.\n\n/MUSICIANS/A/X/b.sid\n COMMENT: Nice.\n')
        self.assertEqual(set(stil), {'/MUSICIANS/A/X/a.sid', '/MUSICIANS/A/X/b.sid'})
        self.assertTrue(corpus.digi_flag(stil['/MUSICIANS/A/X/a.sid']))
        self.assertFalse(corpus.digi_flag(stil['/MUSICIANS/A/X/b.sid']))
        self.assertFalse(corpus.digi_flag(None))
        self.assertFalse(corpus.digi_flag('digi', ask=lambda q, t: 'no'))
        self.assertTrue(corpus.digi_flag('digi', ask=lambda q, t: 'unknown'))

    def test_split_is_stratified_and_deterministic(self):
        def run():
            entries = [{'path': f'p{i}'} for i in range(6)]
            corpus.split_group(entries, random.Random(1))
            return {e['path']: e['split'] for e in entries}
        first = run()
        self.assertEqual(first, run())
        self.assertEqual(sum(v == 'heldout' for v in first.values()), 2)
        single = [{'path': 'only'}]
        corpus.split_group(single, random.Random(1))
        self.assertEqual(single[0]['split'], 'dev')
        pair = [{'path': 'a'}, {'path': 'b'}]
        corpus.split_group(pair, random.Random(1))
        self.assertEqual(sorted(e['split'] for e in pair), ['dev', 'heldout'])

    def test_select_respects_exclusions_and_limit(self):
        found = {'X': [f'x{i}' for i in range(10)], 'Y': ['y0']}
        chosen = corpus.select(found, random.Random(1), 6, exclude={'x0'}, flagged={'y0'})
        self.assertEqual(len(chosen['X']), 6)
        self.assertNotIn('x0', chosen['X'])
        self.assertEqual(chosen['Y'], [])
        self.assertEqual(chosen, corpus.select(found, random.Random(1), 6, exclude={'x0'}, flagged={'y0'}))

    def test_build_on_synthetic_tree_and_manifest_roundtrip(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root/'MUSICIANS/H/Hannula_Antti'
            folder.mkdir(parents=True)
            for i in range(4):
                (folder/f'song{i}.sid').write_bytes(psid('Antti Hannula (Flex)'))
            (folder/'rsid.sid').write_bytes(psid('Antti Hannula (Flex)', rsid=True))
            (folder/'other.sid').write_bytes(psid('Someone Else'))
            (root/'DOCUMENTS').mkdir()
            (root/'DOCUMENTS/STIL.txt').write_text('/MUSICIANS/H/Hannula_Antti/song0.sid\n COMMENT: digi drums\n')
            result = corpus.build(root)
            paths = {s['path'] for s in result['songs']}
            self.assertEqual(paths, {f'MUSICIANS/H/Hannula_Antti/song{i}.sid' for i in (1, 2, 3)})
            self.assertEqual(result['digi'], ['MUSICIANS/H/Hannula_Antti/song0.sid'])
            self.assertEqual(result['folders']['Flex'], {'H/Hannula_Antti'})
            self.assertTrue(all(s['subtune'] == 2 and s['composer'] == 'Flex' for s in result['songs']))
            manifest = root/'corpus.toml'
            manifest.write_text(corpus.dump(result['songs'], result['digi']))
            self.assertEqual(corpus.load(manifest), sorted(result['songs'], key=lambda s: (s['composer'], s['path'])))
            self.assertIn('excluded flag=digi', manifest.read_text())


if __name__ == '__main__':
    unittest.main()
