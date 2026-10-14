import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

PATH = Path(__file__).resolve().parents[1]/'tools/semantic_if.py'


def load():
    spec = importlib.util.spec_from_file_location('semantic_if_under_test', PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SemanticIf(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.module = load()
        self.module.CACHE = Path(self.temp.name)/'llm.sqlite3'
        self.calls = []

    def tearDown(self):
        self.temp.cleanup()

    def fake(self, probability):
        def post(payload, timeout):
            self.calls.append(payload)
            return {'answers': {name: {'type': 'noul', 'noul': probability} for name in payload['questions']}}
        return post

    def test_thresholds_and_request_shape(self):
        for probability, expected in ((0.9, 'yes'), (0.1, 'no'), (0.5, 'unknown')):
            self.module.CACHE = Path(self.temp.name)/f'{probability}.sqlite3'
            with patch.object(self.module, '_post', self.fake(probability)):
                self.assertEqual(self.module.semantic_if('Is it digi?', 'text'), expected)
        payload = self.calls[0]
        self.assertEqual(payload['model'], 'clef-flash:9b')
        self.assertEqual(payload['state'], 'text')
        self.assertEqual(payload['questions']['q'], {'type': 'noul', 'instructions': 'Is it digi?'})

    def test_cache_avoids_second_request(self):
        with patch.object(self.module, '_post', self.fake(0.95)):
            self.assertEqual(self.module.semantic_if('q?', 't'), 'yes')
            self.assertEqual(self.module.semantic_if('q?', 't'), 'yes')
        self.assertEqual(len(self.calls), 1)

    def test_errors_give_unknown_and_are_not_cached(self):
        with patch.object(self.module, '_post', side_effect=OSError('refused')):
            self.assertEqual(self.module.semantic_if('q?', 't'), 'unknown')
        with patch.object(self.module, '_post', return_value={'nonsense': 1}):
            self.assertEqual(self.module.semantic_if('q?', 't'), 'unknown')
        with patch.object(self.module, '_post', self.fake(0.0)):
            self.assertEqual(self.module.semantic_if('q?', 't'), 'no')

    def test_batches_are_split_at_64(self):
        questions = {f'q{i}': f'question {i}?' for i in range(70)}
        with patch.object(self.module, '_post', self.fake(0.99)):
            result = self.module.semantic_if_many(questions, 't')
        self.assertEqual(set(result.values()), {'yes'})
        self.assertEqual([len(c['questions']) for c in self.calls], [64, 6])

    def test_choice(self):
        def post(payload, timeout):
            return {'answers': {'q': {'type': 'choice', 'choice': 'a', 'probabilities': {'a': .8, 'b': .2}, 'confidence': .5}}}
        with patch.object(self.module, '_post', post):
            result = self.module.semantic_choice('which?', 't', ['a', 'b'])
        self.assertEqual(result['choice'], 'a')
        with patch.object(self.module, '_post', side_effect=OSError):
            self.assertIsNone(self.module.semantic_choice('other?', 't', {'a': None})['choice'])

    def test_large_model_refused(self):
        with self.assertRaises(ValueError):
            self.module.semantic_if('q?', 't', model='qwen3.8:latest')


if __name__ == '__main__':
    unittest.main()
