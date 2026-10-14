"""Benchmark runner: converts every corpus song in parallel and records scores in a sqlite results DB."""
import fnmatch
import json
import os
import signal
import sqlite3
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from . import corpus

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get('SID2CT_CACHE', Path.home()/'.cache/sid2ct'))
TIMEOUT = 15*60
COLUMNS = ('mix', 'voice1', 'voice2', 'voice3', 'instruments', 'approximated_attacks', 'observed_variants',
           'score_v1', 'score_v2')
SCHEMA = '''
create table if not exists runs (id integer primary key autoincrement, label text, git_sha text,
    started text, options text);
create table if not exists results (run_id integer, song text, split text, composer text, status text,
    error text, wall_seconds real, mix real, voice1 real, voice2 real, voice3 real, instruments integer,
    approximated_attacks integer, observed_variants integer, report text, primary key (run_id, song));
'''
MIGRATIONS = ('alter table results add column score_v1 real', 'alter table results add column score_v2 real')


def song_name(entry):
    return f'{entry["composer"]}__{Path(entry["path"]).stem}'.replace(' ', '_')


def select_songs(songs, split='all', only=None):
    chosen = [s for s in songs if split == 'all' or s['split'] == split]
    if only:
        chosen = [s for s in chosen if fnmatch.fnmatch(song_name(s).lower(), only.lower())
                  or fnmatch.fnmatch(s['path'].lower(), only.lower())]
    return chosen


def extract_scores(report):
    """Pull mix/voice scores and instrument counts out of a convert report (missing values are None)."""
    def similarity(block):
        try:
            value = block['similarity']
        except (KeyError, TypeError):
            return None
        return value if isinstance(value, (int, float)) else None
    scores = dict.fromkeys(COLUMNS)
    scores['mix'] = similarity(report.get('audio_validation'))
    voices = report.get('diagnostics', {}).get('candidates', {}).get('reconstruction', {}).get('voices', {})
    for number in (1, 2, 3):
        voice = voices.get(str(number), {})
        scores[f'voice{number}'] = similarity(voice.get('fixed_alignment'))
    scores['instruments'] = report.get('instruments')
    scores['approximated_attacks'] = report.get('approximated_instrument_attacks')
    scores['observed_variants'] = report.get('observed_instrument_variants')
    audio = report.get('audio_validation') or {}
    scores['score_v1'] = _number(audio.get('score_v1', audio.get('similarity')))
    scores['score_v2'] = _number(audio.get('score_v2'))
    return scores


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def backfill_scores(db, run_id):
    """Score v2 (and v1) for older results whose report predates it, from the WAVs the run kept."""
    from .audio import compare_wavs
    rows = db.execute('select song, report from results where run_id=? and status=? and '
                      '(score_v2 is null or score_v1 is null)', (run_id, 'ok')).fetchall()
    for song, report_path in rows:
        try:
            audio = json.loads(Path(report_path).read_text())['audio_validation']
            result = compare_wavs(audio['source_wav'], audio['reconstructed_wav'])
        except (OSError, KeyError, ValueError, TypeError):
            continue
        db.execute('update results set score_v1=?, score_v2=? where run_id=? and song=?',
                   (_number(result.get('score_v1')), _number(result.get('score_v2')), run_id, song))
    db.commit()


def connect(path=None):
    path = Path(path or CACHE/'bench.sqlite3')
    path.parent.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(path)
    db.executescript(SCHEMA)
    for statement in MIGRATIONS:
        try:
            db.execute(statement)
        except sqlite3.OperationalError:
            pass  # column already present
    db.commit()
    return db


def start_run(db, label, sha, options):
    cursor = db.execute('insert into runs (label, git_sha, started, options) values (?,?,?,?)',
                        (label, sha, time.strftime('%Y-%m-%d %H:%M:%S'), json.dumps(options)))
    db.commit()
    return cursor.lastrowid


def record(db, run_id, entry, name, status, error, wall, scores, report_path):
    db.execute('insert or replace into results (run_id, song, split, composer, status, error, wall_seconds, mix, '
               'voice1, voice2, voice3, instruments, approximated_attacks, observed_variants, report, '
               'score_v1, score_v2) values (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
               (run_id, name, entry['split'], entry['composer'], status, error, wall,
                scores['mix'], scores['voice1'], scores['voice2'], scores['voice3'], scores['instruments'],
                scores['approximated_attacks'], scores['observed_variants'], str(report_path),
                scores.get('score_v1'), scores.get('score_v2')))
    db.commit()


def previous_run(db, label, before_id):
    row = db.execute('select id from runs where label=? and id<? order by id desc limit 1', (label, before_id)).fetchone()
    return row[0] if row else None


def deltas(db, run_id, other_id):
    """Rows (song, split, mix, other_mix, delta) for songs of run_id; delta is None unless both have a mix."""
    rows = []
    for name, split, mix in db.execute('select song, split, mix from results where run_id=? order by song', (run_id,)):
        row = db.execute('select mix from results where run_id=? and song=?', (other_id, name)).fetchone()
        other = row[0] if row else None
        rows.append((name, split, mix, other, None if mix is None or other is None else mix-other))
    return rows


def failure_reason(log_text):
    lines = [line.strip() for line in log_text.splitlines() if line.strip()]
    for line in lines:
        if 'CPU error' in line:
            return line[line.index('CPU error'):][:200]
    for line in reversed(lines):
        if line.startswith('error:') or 'Error' in line:
            return line[:200]
    return lines[-1][:200] if lines else 'no output'


def convert_command(sid, output, entry, seconds, full, effect_programs=None, extra=()):
    command = [sys.executable, '-m', 'sid2ct', 'convert', str(sid), '-o', str(output), '--force',
               '--subtune', str(entry['subtune']), '--workers', '1']
    if not full:
        command += ['--seconds', f'{seconds:g}']
    if effect_programs:
        command += ['--effect-programs', effect_programs]
    return command + list(extra)


def run_song(entry, hvsc, song_dir, seconds, full, timeout=TIMEOUT, effect_programs=None, extra=()):
    """Run one conversion; returns (status, error, wall_seconds, scores, report_path)."""
    song_dir.mkdir(parents=True, exist_ok=True)
    output = song_dir/'song.ct'
    report_path = output.with_suffix('.json')
    report_path.unlink(missing_ok=True)
    command = convert_command(hvsc/entry['path'], output, entry, seconds, full, effect_programs, extra)
    started = time.monotonic()
    status, error = 'ok', None
    with open(song_dir/'convert.log', 'w') as log:
        log.write('$ '+' '.join(command)+'\n')
        log.flush()
        process = subprocess.Popen(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code, status, error = None, 'timeout', f'exceeded {timeout} s'
    wall = time.monotonic()-started
    scores = dict.fromkeys(COLUMNS)
    if status == 'ok' and code != 0:
        status, error = 'error', failure_reason((song_dir/'convert.log').read_text(errors='replace'))
    if status == 'ok':
        try:
            scores = extract_scores(json.loads(report_path.read_text()))
        except (OSError, ValueError) as problem:
            status, error = 'error', f'unreadable report: {problem}'
    return status, error, wall, scores, report_path


def git_sha():
    try:
        sha = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(['git', 'status', '--porcelain', '--', 'sid2ct', 'tools'], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    except OSError:
        return 'unknown'
    return (sha or 'unknown')+('+dirty' if dirty else '')


def fmt(value):
    return '   -  ' if value is None else f'{value:.4f}'


def mean(values):
    values = [v for v in values if v is not None]
    return sum(values)/len(values) if values else None


def format_table(db, run_id, compare_id):
    other = {r[0]: r[3] for r in deltas(db, run_id, compare_id)} if compare_id else {}
    lines = [f'{"song":44} {"split":8} {"status":8} {"mix":>6} {"v1":>6} {"v2":>6} {"v3":>6} {"wall":>6}'
             + ('  delta' if compare_id else '')]
    rows = db.execute('select song, split, status, mix, voice1, voice2, voice3, wall_seconds, error from results '
                      'where run_id=? order by split, song', (run_id,)).fetchall()
    for name, split, status, mix, v1, v2, v3, wall, error in rows:
        line = f'{name[:44]:44} {split:8} {status:8} {fmt(mix)} {fmt(v1)} {fmt(v2)} {fmt(v3)} {wall:6.0f}'
        if compare_id:
            base = other.get(name)
            line += '  ' + ('   n/a' if mix is None or base is None else f'{mix-base:+.4f}')
        lines.append(line)
        if error:
            lines.append(f'    ! {error}')
    for split in ('dev', 'heldout'):
        values = [r[3] for r in rows if r[1] == split and r[2] == 'ok']
        if values:
            text = f'mean mix {split}: {mean(values):.4f} (n={len(values)})'
            if compare_id:
                pairs = [d for _, s, _, _, d in deltas(db, run_id, compare_id) if s == split and d is not None]
                if pairs:
                    text += f', mean delta {sum(pairs)/len(pairs):+.4f} over {len(pairs)} songs'
            lines.append(text)
    lines += score_summary(db, run_id, compare_id)
    failed = sum(1 for r in rows if r[2] != 'ok')
    lines.append(f'{len(rows)-failed} ok, {failed} failed')
    return '\n'.join(lines)


def score_summary(db, run_id, compare_id, threshold=0.01):
    """Mean v1/v2 per split and the songs whose v1 or v2 fell by more than threshold against compare_id."""
    lines = []
    query = 'select song, split, score_v1, score_v2 from results where run_id=? and status=? order by song'
    current = db.execute(query, (run_id, 'ok')).fetchall()
    other = {r[0]: r for r in db.execute(query, (compare_id, 'ok')).fetchall()} if compare_id else {}
    for split in ('dev', 'heldout'):
        part = [r for r in current if r[1] == split]
        for index, label in ((2, 'score_v1'), (3, 'score_v2')):
            values = [r[index] for r in part if r[index] is not None]
            if not values:
                continue
            text = f'mean {label} {split}: {mean(values):.4f} (n={len(values)})'
            pairs = [(r[index], other[r[0]][index]) for r in part if r[0] in other
                     and r[index] is not None and other[r[0]][index] is not None]
            if pairs:
                text += f', mean delta {sum(a-b for a, b in pairs)/len(pairs):+.4f} over {len(pairs)} songs'
            lines.append(text)
    for song, split, v1, v2 in current:
        if song not in other:
            continue
        d1 = None if v1 is None or other[song][2] is None else v1-other[song][2]
        d2 = None if v2 is None or other[song][3] is None else v2-other[song][3]
        if (d1 is not None and d1 < -threshold) or (d2 is not None and d2 < -threshold):
            lines.append(f'  regression {song}: score_v1 {fmt(d1) if d1 is None else f"{d1:+.4f}"}'
                         f' score_v2 {fmt(d2) if d2 is None else f"{d2:+.4f}"}')
    return lines


def add_arguments(parser):
    parser.add_argument('--split', choices=('dev', 'heldout', 'all'), default='dev', help='Corpus split to run (default: dev).')
    parser.add_argument('--workers', type=int, default=max(1, (os.cpu_count() or 2)//2), help='Parallel conversions (default: half the cores).')
    parser.add_argument('--seconds', type=float, default=60, help='Explicit capture length in seconds (default: 60).')
    parser.add_argument('--full', action='store_true', help='Convert the detected loop instead of an explicit capture.')
    parser.add_argument('--label', default='adhoc', help='Name of this run, for example baseline.')
    parser.add_argument('--compare', default='baseline', help='Label of the earlier run to compare with (default: baseline).')
    parser.add_argument('--only', help='Only songs whose name or path matches this glob, for example "*Viidakko*".')
    parser.add_argument('--hvsc', type=Path, default=corpus.default_root(), help='HVSC root (default: $HVSC_ROOT or ../shallowsid/_hvsc-source).')
    parser.add_argument('--corpus', type=Path, default=corpus.MANIFEST, help='Corpus manifest (default: tools/sid_corpus.toml).')
    parser.add_argument('--effect-programs', choices=('auto', 'off', 'on'), help='Pass --effect-programs to every conversion (default: the converter default).')
    parser.add_argument('--instrument-allocation', choices=('legacy', 'trajectory', 'budget', 'solve'), help='Pass --instrument-allocation to every conversion.')
    parser.add_argument('--structure-hints', choices=('auto', 'off'), help='Pass --structure-hints to every conversion.')
    parser.add_argument('--solve-time-limit', type=float, help='Pass --solve-time-limit to every conversion.')
    parser.add_argument('--timeout', type=float, default=TIMEOUT, help='Per-song limit in seconds (default: 900).')


def run_command(args):
    if not args.corpus.is_file():
        print(f'error: {args.corpus} missing; run python3 -m sid2ct corpus build.')
        return 1
    songs = select_songs(corpus.load(args.corpus), args.split, args.only)
    if not songs:
        print('error: no songs match.')
        return 1
    db = connect()
    options = {'split': args.split, 'seconds': None if args.full else args.seconds, 'full': args.full, 'only': args.only,
               'effect_programs': args.effect_programs, 'instrument_allocation': args.instrument_allocation,
               'structure_hints': args.structure_hints, 'solve_time_limit': args.solve_time_limit}
    extra = [x for flag, value in (('--instrument-allocation', args.instrument_allocation), ('--structure-hints', args.structure_hints),
                                   ('--solve-time-limit', args.solve_time_limit)) if value is not None for x in (flag, str(value))]
    run_id = start_run(db, args.label, git_sha(), options)
    base = CACHE/'bench'/args.label
    print(f'run {run_id} label={args.label} songs={len(songs)} workers={args.workers}', flush=True)

    def work(entry):
        name = song_name(entry)
        outcome = run_song(entry, args.hvsc, base/name, args.seconds, args.full, args.timeout, args.effect_programs, extra)
        print(f'{name}: {outcome[0]} {outcome[2]:.0f}s mix={fmt(outcome[3]["mix"])}', flush=True)
        return entry, name, outcome

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for entry, name, (status, error, wall, scores, report) in pool.map(work, songs):
            record(db, run_id, entry, name, status, error, wall, scores, report)
    compare_id = previous_run(db, args.compare, run_id)
    for backfill_id in (run_id, compare_id):
        if backfill_id:
            backfill_scores(db, backfill_id)
    print(format_table(db, run_id, compare_id))
    if not compare_id:
        print(f'(no earlier run labelled {args.compare!r} to compare with)')
    return 0
