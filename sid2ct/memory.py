"""Persistent memory (~/.cache/sid2ct/memory.sqlite3) shared by every conversion.

Per song (SID hash and subtune) it keeps the captured trace, so a repeat run skips
the slow tracing, and the best parameters found. Per player family it lets
a new song start its Optuna search from the best parameters of past songs
of the same family (warm start). Every search trial is recorded.
A failing database never fails a conversion: every call degrades to "no memory".
`--no-memory` bypasses all reads and writes, so a fixed seed gives the same
result with or without a database on disk.
"""
import hashlib
import json
import os
from pathlib import Path
import pickle
import sqlite3
import time
import zlib

CAPTURE_VERSION = 1      # bump when capture output changes meaning
SCHEMA = '''
create table if not exists captures (key text primary key, created text, data blob);
create table if not exists best (song text primary key, name text, family text, params text,
    score_v1 real, score_v2 real, updated text);
create table if not exists trials (id integer primary key autoincrement, song text, family text,
    name text, params text, score_v1 real, score_v2 real, regdist real, state text, seed integer,
    effort text, wall_seconds real, created text);
create index if not exists trials_family on trials (family, score_v2);
'''


def cache_dir():
    return Path(os.environ.get('SID2CT_CACHE') or Path.home()/'.cache/sid2ct')


def song_key(raw_sid, subtune):
    return hashlib.sha256(raw_sid).hexdigest()[:32] + f':{subtune}'


def capture_key(parts):
    digest = hashlib.sha256(repr((CAPTURE_VERSION, parts)).encode()).hexdigest()
    return digest


def player_family(raw_sid):
    """First recognised player family of a SID (sorted for stability), else 'unknown'."""
    try:
        from .players import family, identify
        families = sorted({family(name) for name in identify(raw_sid)})
    except Exception:
        return 'unknown'
    return families[0] if families else 'unknown'


class Memory:
    """Thin sqlite wrapper; `enabled` is False (and every call a no-op) when it cannot be opened."""

    def __init__(self, path=None, enabled=True):
        self.db = None
        if not enabled:
            return
        try:
            path = Path(path or cache_dir()/'memory.sqlite3')
            path.parent.mkdir(parents=True, exist_ok=True)
            self.db = sqlite3.connect(path, timeout=30)
            self.db.executescript(SCHEMA)
            self.db.commit()
        except (OSError, sqlite3.Error):
            self.db = None

    @property
    def enabled(self):
        return self.db is not None

    def _write(self, sql, args=()):
        if self.db is None:
            return
        try:
            self.db.execute(sql, args)
            self.db.commit()
        except sqlite3.Error:
            pass

    def _read(self, sql, args=()):
        if self.db is None:
            return []
        try:
            return self.db.execute(sql, args).fetchall()
        except sqlite3.Error:
            return []

    # Captures ---------------------------------------------------------------

    def load_capture(self, key):
        rows = self._read('select data from captures where key=?', (key,))
        if not rows:
            return None
        try:
            return pickle.loads(zlib.decompress(rows[0][0]))
        except Exception:
            return None

    def save_capture(self, key, value):
        try:
            blob = zlib.compress(pickle.dumps(value, protocol=4), 3)
        except Exception:
            return
        self._write('insert or replace into captures (key, created, data) values (?,?,?)',
                    (key, time.strftime('%Y-%m-%d %H:%M:%S'), blob))

    # Trials and best parameters ---------------------------------------------

    def record_trial(self, song, family, name, params, v1, v2, regdist, state, seed, effort, wall):
        self._write('insert into trials (song, family, name, params, score_v1, score_v2, regdist, state, seed, '
                    'effort, wall_seconds, created) values (?,?,?,?,?,?,?,?,?,?,?,?)',
                    (song, family, name, json.dumps(params, sort_keys=True), v1, v2, regdist, state, seed,
                     effort, wall, time.strftime('%Y-%m-%d %H:%M:%S')))

    def record_best(self, song, family, name, params, v1, v2):
        """Keep the better v2 per song."""
        old = self._read('select score_v2 from best where song=?', (song,))
        if old and old[0][0] is not None and v2 is not None and old[0][0] >= v2:
            return
        self._write('insert or replace into best (song, name, family, params, score_v1, score_v2, updated) '
                    'values (?,?,?,?,?,?,?)',
                    (song, name, family, json.dumps(params, sort_keys=True), v1, v2,
                     time.strftime('%Y-%m-%d %H:%M:%S')))

    def warm_params(self, family, song, k=3):
        """Parameter dicts to try first: this song's own best, then the top-k other songs of its family by v2."""
        found = []
        for (text,) in self._read('select params from best where song=?', (song,)):
            found.append(json.loads(text))
        if family and family != 'unknown':
            for (text,) in self._read('select params from best where family=? and song<>? and score_v2 is not null '
                                      'order by score_v2 desc, song limit ?', (family, song, k)):
                found.append(json.loads(text))
        unique = []
        for params in found:
            if params not in unique:
                unique.append(params)
        return unique

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None
