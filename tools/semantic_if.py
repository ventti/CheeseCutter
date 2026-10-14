#!/usr/bin/env python3
"""Tiny yes/no and choice questions answered by a local ollama model, for tooling only (never conversion).

Uses the model's /v1/systemone endpoint. Answers are cached in a sqlite file;
any connection or parse error gives "unknown".
"""
import contextlib
import hashlib
import json
import os
import sqlite3
import urllib.request
from pathlib import Path

DEFAULT_MODEL = 'clef-flash:9b'
URL = 'http://localhost:11434/v1/systemone'
CACHE = Path(os.environ.get('SID2CT_LLM_CACHE', Path.home()/'.cache/sid2ct/llm.sqlite3'))
MAX_TEXT = 6000
MAX_BATCH = 64
YES_AT, NO_AT = 0.7, 0.3
FORBIDDEN_MODEL_PREFIX = 'qwen3.8'


def _post(payload, timeout):
    request = urllib.request.Request(URL, json.dumps(payload).encode(), {'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode())


def _key(*parts):
    return hashlib.sha256('\0'.join(parts).encode()).hexdigest()


def _db():
    CACHE.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(CACHE)
    db.execute('create table if not exists llm (key text primary key, answer text)')
    return db


def _cache_get(key):
    try:
        with contextlib.closing(_db()) as db:
            row = db.execute('select answer from llm where key=?', (key,)).fetchone()
        return json.loads(row[0]) if row else None
    except (sqlite3.Error, OSError, ValueError):
        return None


def _cache_put(key, value):
    try:
        with contextlib.closing(_db()) as db, db:
            db.execute('insert or replace into llm values (?,?)', (key, json.dumps(value)))
    except (sqlite3.Error, OSError):
        pass


def _check(model):
    if model.startswith(FORBIDDEN_MODEL_PREFIX):
        raise ValueError('This model is too slow for semantic_if.')


def _ask(model, text, questions, timeout):
    payload = {'model': model, 'keep_alive': '10m', 'state': text[:MAX_TEXT], 'questions': questions}
    return _post(payload, timeout)['answers']


def _yes_no(probability, yes_at, no_at):
    if probability >= yes_at:
        return 'yes'
    if probability <= no_at:
        return 'no'
    return 'unknown'


def semantic_if_many(questions, text, model=DEFAULT_MODEL, yes_at=YES_AT, no_at=NO_AT, timeout=120):
    """Return {name: "yes"|"no"|"unknown"} for {name: question}; up to 64 questions per request."""
    _check(model)
    text = text[:MAX_TEXT]
    result, todo = {}, {}
    for name, question in questions.items():
        probability = _cache_get(_key(model, 'noul', question, text))
        if isinstance(probability, float):
            result[name] = _yes_no(probability, yes_at, no_at)
        else:
            todo[name] = question
    names = list(todo)
    for start in range(0, len(names), MAX_BATCH):
        batch = names[start:start+MAX_BATCH]
        body = {n: {'type': 'noul', 'instructions': todo[n]} for n in batch}
        try:
            answers = _ask(model, text, body, timeout)
        except (OSError, ValueError, KeyError, TypeError):
            answers = {}
        for name in batch:
            try:
                probability = float(answers[name]['noul'])
            except (KeyError, TypeError, ValueError):
                result[name] = 'unknown'
                continue
            _cache_put(_key(model, 'noul', todo[name], text), probability)
            result[name] = _yes_no(probability, yes_at, no_at)
    return result


def semantic_if(question, text, model=DEFAULT_MODEL, yes_at=YES_AT, no_at=NO_AT, timeout=120):
    """Return "yes", "no" or "unknown" for one short question about text."""
    return semantic_if_many({'q': question}, text, model, yes_at, no_at, timeout)['q']


def semantic_choice(question, text, options, model=DEFAULT_MODEL, timeout=120):
    """Pick one option (list of names, or dict name -> criterion text).

    Returns {"choice": name|None, "probabilities": {...}, "confidence": float}; choice is None on any error.
    """
    _check(model)
    text = text[:MAX_TEXT]
    criteria = dict(options) if isinstance(options, dict) else {o: None for o in options}
    key = _key(model, 'choice', question, json.dumps(criteria, sort_keys=True), text)
    cached = _cache_get(key)
    if isinstance(cached, dict) and 'choice' in cached:
        return cached
    body = {'q': {'type': 'choice', 'instructions': question, 'criteria': criteria}}
    try:
        answer = _ask(model, text, body, timeout)['q']
        result = {'choice': answer['choice'], 'probabilities': dict(answer.get('probabilities', {})),
                  'confidence': float(answer.get('confidence', 0.0))}
    except (OSError, ValueError, KeyError, TypeError):
        return {'choice': None, 'probabilities': {}, 'confidence': 0.0}
    _cache_put(key, result)
    return result


if __name__ == '__main__':
    import sys
    print(semantic_if(sys.argv[1], sys.stdin.read()))
