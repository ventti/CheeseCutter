"""Identify players and count them in the benchmark corpus and HVSC folders."""
import json
from collections import Counter
from pathlib import Path

from .. import corpus
from .sidid import editor_hint, family, identify, load_signatures, sid_payload


def census(hvsc, songs, signatures=None, llm=False, ask=None):
    signatures = load_signatures() if signatures is None else signatures
    corpus_paths = {s['path'] for s in songs}
    # MUSICIAN/letter/composer, with separate composers under Mitch_and_Dane.
    folders = set()
    for song in songs:
        parts = Path(song['path']).parts
        depth = 4 if len(parts) > 4 and parts[2] == 'Mitch_and_Dane' else 3
        folders.add(Path(*parts[:depth]))
    folder_paths = set()
    missing_folders = []
    for folder in sorted(folders):
        directory = hvsc / folder
        if not directory.is_dir():
            missing_folders.append(folder.as_posix())
        else:
            folder_paths.update(p.relative_to(hvsc).as_posix() for p in directory.rglob('*')
                                if p.is_file() and p.suffix.lower() == '.sid')
    records = {}
    candidates = {family(n) for n in signatures}
    for rel in sorted(corpus_paths | folder_paths):
        record = {'matches': [], 'families': [], 'hint': None}
        try:
            raw = (hvsc / rel).read_bytes()
            record['matches'] = identify(raw, signatures)
            record['families'] = sorted({family(n) for n in record['matches']})
            if llm and not record['matches']:
                record['hint'] = editor_hint(sid_payload(raw), candidates, ask)
        except (OSError, ValueError) as error:
            record['error'] = str(error)
        records[rel] = record

    def summary(paths):
        counts = Counter()
        unidentified = errors = 0
        for rel in paths:
            r = records[rel]
            errors += 'error' in r
            if not r['families']:
                unidentified += 1
            counts.update(r['families'] or ['Unidentified'])
        return {'total': len(paths), 'counts': dict(sorted(counts.items())),
                'unidentified': unidentified,
                'unidentified_share': unidentified / len(paths) if paths else 0,
                'errors': errors}
    return {'corpus': summary(corpus_paths), 'composer_folders': summary(folder_paths),
            'folders': [p.as_posix() for p in sorted(folders)],
            'missing_folders': missing_folders, 'files': records}


def add_arguments(parser):
    commands = parser.add_subparsers(dest='players_command', required=True)
    scan = commands.add_parser('census', help='Count players in the corpus and composer folders.')
    scan.add_argument('--split', choices=('all', 'dev', 'heldout'), default='all')
    scan.add_argument('--llm', action='store_true', help='Ask the local decision model for editor hints.')


def run_command(args):
    hvsc = corpus.default_root()
    if not (hvsc / 'MUSICIANS').is_dir():
        print(f'error: no MUSICIANS directory under {hvsc}; set HVSC_ROOT.')
        return 1
    songs = corpus.load()
    if args.split != 'all':
        songs = [s for s in songs if s['split'] == args.split]
    result = census(hvsc, songs, llm=args.llm)
    result.update(hvsc_root=str(hvsc), split=args.split)
    print(f'{"Player family":36} {"Corpus":>8} {"Folders":>8}')
    for name in sorted(set(result['corpus']['counts']) | set(result['composer_folders']['counts'])):
        print(f'{name:36} {result["corpus"]["counts"].get(name, 0):8} '
              f'{result["composer_folders"]["counts"].get(name, 0):8}')
    for key in ('corpus', 'composer_folders'):
        s = result[key]
        print(f'{key}: {s["total"]} files, unidentified {s["unidentified"]} '
              f'({s["unidentified_share"]:.1%}), errors {s["errors"]}')
    print('Counts include every matching family; a file can count in several families.')
    output = Path.home() / '.cache/sid2ct/players.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(f'Saved {output}')
    for folder in result['missing_folders']:
        print(f'Missing folder: {folder}')
    if args.llm:
        for path, record in result['files'].items():
            if record['hint']:
                print(f'hint: {path}: {record["hint"]["player"]}')
    return 1 if result['missing_folders'] or any(s['errors'] for s in (result['corpus'], result['composer_folders'])) else 0
