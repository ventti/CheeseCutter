import struct
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from sid2ct.players import census
from sid2ct.players.sidid import (editor_hint, family, identify, load_signatures,
                                 match, parse_signatures, sid_payload)

ROOT = Path(__file__).resolve().parents[1]


def sid(payload, load=0):
    header = bytearray(124)
    header[:4] = b'PSID'
    struct.pack_into('>HHH', header, 4, 2, 124, load)
    return bytes(header) + (b'\x00\x10' if load == 0 else b'') + payload


class MatcherTests(unittest.TestCase):
    def test_bytes_wildcards_final_byte_and_alternatives(self):
        db = parse_signatures('Player_V2 AA ?? FF END 01 02 END Other FF END')
        self.assertEqual(match(b'\x00\xaa\x0a\xff', db), ['Player_V2', 'Other'])
        self.assertEqual(match(b'\x01\x02', db), ['Player_V2'])
        self.assertEqual(match(b'\xaa\xff', db), ['Other'])
        self.assertEqual(match(b'\x01\x03', db), [])

    def test_gap_zero_long_false_start_order_and_nonoverlap(self):
        db = parse_signatures('P AA BB AND CC DD AND EE END')
        for payload in (bytes.fromhex('AA BB CC DD EE'),
                        bytes.fromhex('AA BB CC 00 CC DD 00 EE'),
                        bytes.fromhex('AA 00 AA BB 00 CC DD EE')):
            self.assertEqual(match(payload, db), ['P'])
        self.assertEqual(match(bytes.fromhex('CC DD AA BB EE'), db), [])
        self.assertEqual(match(b'\xaa', parse_signatures('P AA AND AA END')), [])
        self.assertEqual(match(b'\xaa\x00\xff', parse_signatures('P AA AND ?? FF END')), ['P'])

    def test_multiline_and_lowercase(self):
        self.assertEqual(match(b'\xaa\x00\xbb', parse_signatures('P\naa\nand\nbb\nend')), ['P'])

    def test_invalid_config(self):
        for text in ('AA END', 'P AA', 'P AND AA END', 'P AA AND END', 'P AA Q BB END'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                parse_signatures(text)

    def test_payload_excludes_header_and_load_address(self):
        for load in (0, 0x1000):
            self.assertEqual(sid_payload(sid(b'abc', load)), b'abc')
        raw = bytearray(sid(b'abc'))
        raw[22:24] = b'\xaa\xbb'
        self.assertEqual(identify(raw, parse_signatures('P AA BB END')), [])
        with self.assertRaises(ValueError):
            sid_payload(b'PSID')
        raw = bytearray(sid(b''))
        struct.pack_into('>H', raw, 6, 123)
        with self.assertRaises(ValueError):
            sid_payload(raw)

    def test_database_and_versions(self):
        db = load_signatures()
        self.assertGreater(len(db), 100)
        self.assertIn('(JCH_NewPlayer_V2)', db)
        self.assertEqual(family('(JCH_NewPlayer_V2)'), 'JCH NewPlayer')
        self.assertEqual(family('CheeseCutter_4.x'), 'CheeseCutter')

    def test_hint_mock_and_unknown(self):
        ask = Mock(return_value={'choice': 'CheeseCutter', 'confidence': .9})
        self.assertEqual(editor_hint(b'\x00made with CheeseCutter\x00', ['CheeseCutter'], ask),
                         {'label': 'hint', 'player': 'CheeseCutter', 'confidence': .9})
        self.assertIn('made with CheeseCutter', ask.call_args.args[1])
        self.assertIn('unknown', ask.call_args.args[2])
        ask.return_value = {'choice': None}
        self.assertIsNone(editor_hint(b'unknown credits', ['CheeseCutter'], ask))

    def test_census_recursive_deduplicated_and_hint_opt_in(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'MUSICIANS/A/Artist'
            (folder / 'Worktunes').mkdir(parents=True)
            (folder / 'one.sid').write_bytes(sid(b'\xaa'))
            (folder / 'Worktunes/two.SID').write_bytes(sid(b'editor credit'))
            songs = [{'path': 'MUSICIANS/A/Artist/one.sid'}]
            db = parse_signatures('Player_V1 AA END (Player_V2) AA END')
            ask = Mock(return_value={'choice': 'Player', 'confidence': .8})
            result = census(root, songs, db, ask=ask)
            ask.assert_not_called()
            self.assertEqual(result['corpus']['total'], 1)
            self.assertEqual(result['composer_folders']['total'], 2)
            self.assertEqual(result['composer_folders']['unidentified_share'], .5)
            result = census(root, songs, db, llm=True, ask=ask)
            ask.assert_called_once()
            self.assertEqual(result['composer_folders']['unidentified'], 1)
            self.assertEqual(result['files']['MUSICIANS/A/Artist/Worktunes/two.SID']['hint']['label'], 'hint')

    @unittest.skipUnless((ROOT / 'ct2util').is_file(), 'ct2util is not built')
    def test_cheesecutter_export(self):
        with tempfile.TemporaryDirectory() as directory:
            for index, tune in enumerate(('tunes/abaddon-trouble.ct', 'tunes/vent-arkijuusto.ct')):
                output = Path(directory) / f'{index}.sid'
                process = subprocess.run([str(ROOT / 'ct2util'), 'sid', str(ROOT / tune), '-o', str(output)],
                                         capture_output=True, text=True)
                self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
                self.assertIn('CheeseCutter_4.x', identify(output.read_bytes()))
        self.assertNotIn('CheeseCutter_4.x', identify((ROOT / 'tests/fixtures/sid/not_cheesecutter.sid').read_bytes()))


if __name__ == '__main__':
    unittest.main()
