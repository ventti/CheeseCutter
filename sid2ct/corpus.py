"""Builds the fixed benchmark corpus (tools/sid_corpus.toml) from an HVSC checkout by PSID author handle."""
import argparse
import importlib.util
import os
import random
import re
import struct
import sys
from pathlib import Path

from .convert import read_sid

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT/'tools/sid_corpus.toml'
SEED = 1
PER_COMPOSER = 6
HELDOUT_FRACTION = 0.3
HANDLES = ('Agemixer', 'PRI', 'Deetsay', 'Flex', 'Shogoon', 'Dane', 'Blues Muz', 'DRAX', 'Jammer')
# (composer label, file name stem); the 7 evaluation songs of SID_RECONSTRUCTION.md.
EVAL_SONGS = (('TBB', 'Meanwhile_the_Planet'), ('TBB', 'Viidakko'), ('TBB', 'Orivesi'), ('TBB', 'Panimo'),
              ('TBB', '0_N_0'), ('DRAX', 'Regrets'), ('Laxity', 'Crosswords'))
DIGI_WORDS = re.compile(r'\b(digi|digis|digital|digitized|digitised|sample|samples|sampled)\b', re.I)
DIGI_QUESTION = 'Does this tune use digitized samples (digi drums or sampled speech)?'


def default_root():
    return Path(os.environ.get('HVSC_ROOT') or ROOT.parent/'shallowsid/_hvsc-source')


def author(raw):
    """PSID author field (offset 0x36, 32 bytes)."""
    return raw[0x36:0x56].split(b'\0')[0].decode('latin1').strip()


def author_matches(handle, text):
    """True when the handle is in parentheses or is the whole author name (case-insensitive)."""
    handle = handle.lower()
    text = text.lower()
    if re.sub(r'[^a-z0-9 ]', '', text).strip() == handle:
        return True
    return any(part.strip() == handle for part in re.findall(r'\(([^)]*)\)', text))


def start_song(raw):
    return struct.unpack_from('>H', raw, 0x10)[0]


def usable(raw):
    """Subtune (the default start song) if the PSID passes the converter's header checks, else None."""
    if raw[:4] != b'PSID' or len(raw) < 124:
        return None
    subtune = start_song(raw)
    try:
        read_sid(raw, subtune)
    except (ValueError, struct.error):
        return None
    return subtune


def parse_stil(text):
    """Map '/MUSICIANS/..sid' to its entry text."""
    entries, key, lines = {}, None, []
    for line in text.splitlines():
        if line.startswith('/') and line.rstrip().lower().endswith('.sid'):
            if key:
                entries[key] = '\n'.join(lines)
            key, lines = line.strip(), []
        elif key:
            lines.append(line)
    if key:
        entries[key] = '\n'.join(lines)
    return entries


def load_semantic_if():
    path = ROOT/'tools/semantic_if.py'
    spec = importlib.util.spec_from_file_location('semantic_if', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.semantic_if


def digi_flag(stil_text, ask=None):
    """True if the STIL entry mentions digi/samples (confirmed by `ask` when given; unknown keeps the hit)."""
    if not stil_text or not DIGI_WORDS.search(stil_text):
        return False
    if ask is None:
        return True
    return ask(DIGI_QUESTION, stil_text) != 'no'


def split_group(entries, rng):
    """Mark entries dev/heldout in place: about 30% heldout, at least one when there are two or more."""
    order = sorted(entries, key=lambda e: e['path'])
    rng.shuffle(order)
    heldout = round(len(order)*HELDOUT_FRACTION) if len(order) > 1 else 0
    heldout = max(heldout, 1) if len(order) > 1 else 0
    for index, entry in enumerate(order):
        entry['split'] = 'heldout' if index < heldout else 'dev'


def scan(hvsc, handles=HANDLES):
    """Return {handle: [relative path, ...]} of usable PSIDs under MUSICIANS, plus the folder names seen."""
    found = {h: [] for h in handles}
    folders = {h: set() for h in handles}
    for directory, dirs, files in os.walk(hvsc/'MUSICIANS'):
        dirs.sort()
        for name in sorted(files):
            if not name.lower().endswith('.sid'):
                continue
            path = Path(directory)/name
            raw = path.read_bytes()
            if raw[:4] != b'PSID':
                continue
            who = author(raw)
            for handle in handles:
                if author_matches(handle, who):
                    rel = path.relative_to(hvsc).as_posix()
                    folders[handle].add(Path(rel).parts[1]+'/'+Path(rel).parts[2])
                    if usable(raw):
                        found[handle].append(rel)
    return found, folders


def select(found, rng, per_composer=PER_COMPOSER, exclude=(), flagged=()):
    chosen = {}
    skip = set(exclude) | set(flagged)
    for handle in sorted(found):
        pool = [p for p in sorted(found[handle]) if p not in skip]
        chosen[handle] = rng.sample(pool, min(per_composer, len(pool)))
    return chosen


def find_eval(hvsc):
    wanted = {stem.lower(): (composer, stem) for composer, stem in EVAL_SONGS}
    result, missing = {}, set(wanted)
    for directory, dirs, files in os.walk(hvsc/'MUSICIANS'):
        dirs.sort()
        folder = Path(directory).name
        for name in sorted(files):
            stem = name[:-4].lower() if name.lower().endswith('.sid') else None
            if stem in wanted and wanted[stem][0].lower() == folder.lower() and stem not in result:
                result[stem] = Path(directory, name).relative_to(hvsc).as_posix()
    return [(wanted[s][0], result[s]) for s in wanted if s in result], [wanted[s][1] for s in wanted if s not in result]


def build(hvsc, ask=None, per_composer=PER_COMPOSER, seed=SEED):
    stil_file = hvsc/'DOCUMENTS/STIL.txt'
    stil = parse_stil(stil_file.read_text(encoding='latin1')) if stil_file.is_file() else {}

    def flagged_digi(rel):
        return digi_flag(stil.get('/'+rel), ask)

    found, folders = scan(hvsc)
    digi = {p for paths in found.values() for p in paths if flagged_digi(p)}
    eval_found, eval_missing = find_eval(hvsc)
    eval_paths = {rel for _, rel in eval_found}
    rng = random.Random(seed)
    picks = select(found, rng, per_composer, exclude=eval_paths, flagged=digi)
    groups = {}
    for handle, paths in picks.items():
        groups.setdefault(handle, []).extend({'path': p, 'composer': handle, 'eval': False} for p in paths)
    excluded_eval = []
    for composer, rel in eval_found:
        raw = (hvsc/rel).read_bytes()
        subtune = usable(raw)
        if subtune is None or rel in digi:
            excluded_eval.append(rel)
            continue
        groups.setdefault(composer, []).append({'path': rel, 'composer': composer, 'eval': True})
    songs = []
    for composer in sorted(groups):
        entries = groups[composer]
        split_group(entries, rng)
        for entry in sorted(entries, key=lambda e: e['path']):
            entry['subtune'] = start_song((hvsc/entry['path']).read_bytes())
            songs.append(entry)
    return {'songs': songs, 'digi': sorted(digi & {p for ps in found.values() for p in ps}), 'folders': folders,
            'eval_missing': eval_missing, 'eval_excluded': excluded_eval}


def dump(songs, digi=(), seed=SEED):
    lines = ['# Generated by `python3 -m sid2ct corpus build`; paths are relative to HVSC_ROOT.',
             f'# seed = {seed}, dev/heldout split 70/30 stratified per composer.', '']
    for s in songs:
        lines += ['[[song]]', f'path = "{s["path"]}"', f'composer = "{s["composer"]}"', f'split = "{s["split"]}"',
                  f'subtune = {s["subtune"]}', f'eval = {"true" if s["eval"] else "false"}', '']
    for path in digi:
        lines.append(f'# excluded flag=digi: {path}')
    return '\n'.join(lines).rstrip()+'\n'


def load(path=MANIFEST):
    """Parse the manifest written by dump(): [[song]] tables of string/int/bool values."""
    songs = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if line == '[[song]]':
            songs.append({})
        elif songs and '=' in line and not line.startswith('#'):
            key, value = (part.strip() for part in line.split('=', 1))
            if value.startswith('"'):
                songs[-1][key] = value.strip('"')
            elif value in ('true', 'false'):
                songs[-1][key] = value == 'true'
            else:
                songs[-1][key] = int(value)
    return songs


def add_arguments(parser):
    sub = parser.add_subparsers(dest='corpus_command', required=True)
    build_parser = sub.add_parser('build', help='Scan HVSC and write the corpus manifest.')
    build_parser.add_argument('--hvsc', type=Path, default=default_root(), help='HVSC root (default: $HVSC_ROOT or ../shallowsid/_hvsc-source).')
    build_parser.add_argument('-o', '--output', type=Path, default=MANIFEST, help='Manifest path (default: tools/sid_corpus.toml).')
    build_parser.add_argument('--per-composer', type=int, default=PER_COMPOSER, help='Songs per composer (default: 6).')
    build_parser.add_argument('--llm', action='store_true', help='Confirm STIL digi hits with the local ollama model when it answers.')


def run_command(args):
    hvsc = args.hvsc
    if not (hvsc/'MUSICIANS').is_dir():
        print(f'error: no MUSICIANS directory under {hvsc}; set HVSC_ROOT or --hvsc.')
        return 1
    ask = load_semantic_if() if args.llm else None
    result = build(hvsc, ask, args.per_composer)
    args.output.write_text(dump(result['songs'], result['digi']))
    counts = {}
    for s in result['songs']:
        counts.setdefault(s['composer'], {'dev': 0, 'heldout': 0})[s['split']] += 1
    for composer, c in sorted(counts.items()):
        print(f'{composer}: dev={c["dev"]} heldout={c["heldout"]}')
    for handle, seen in sorted(result['folders'].items()):
        print(f'handle {handle} -> {", ".join(sorted(seen)) or "no match"}')
    if result['eval_missing']:
        print('evaluation songs not found: '+', '.join(result['eval_missing']))
    if result['eval_excluded']:
        print('evaluation songs rejected: '+', '.join(result['eval_excluded']))
    print(f'wrote {len(result["songs"])} songs to {args.output} ({len(result["digi"])} digi-flagged excluded)')
    return 0
