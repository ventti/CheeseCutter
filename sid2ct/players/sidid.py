"""SIDId byte signatures and optional editor-credit hints (no emulation)."""
import importlib.util
import re
import struct
from pathlib import Path

SIGNATURES = Path(__file__).parent / 'signatures'


def parse_signatures(text):
    """Parse whitespace-separated SIDId tokens; END alternatives are ORed."""
    result, name, parts, chunk = {}, None, [], bytearray()
    for token in text.split():
        upper = token.upper()
        if upper == 'END':
            if name is None or not chunk:
                raise ValueError('END without a player or byte sequence')
            parts.append(re.compile(bytes(chunk), re.DOTALL))
            result[name].append(tuple(parts))
            parts, chunk = [], bytearray()
        elif upper == 'AND':
            if not chunk:
                raise ValueError('AND without a byte sequence')
            parts.append(re.compile(bytes(chunk), re.DOTALL))
            chunk = bytearray()
        elif token == '??' or re.fullmatch(r'[0-9a-fA-F]{2}', token):
            if name is None:
                raise ValueError('Bytes without a player name')
            chunk.extend(b'.' if token == '??' else re.escape(bytes([int(token, 16)])))
        else:
            if chunk or parts:
                raise ValueError('Signature missing END')
            name = token
            result.setdefault(name, [])
    if chunk or parts:
        raise ValueError('Signature missing END')
    return result


def load_signatures():
    result = {}
    for path in sorted(SIGNATURES.glob('*.cfg')):
        for name, signatures in parse_signatures(path.read_text(encoding='latin1')).items():
            result.setdefault(name, []).extend(signatures)
    return result


def match(payload, signatures=None):
    """Return all matching names, retaining upstream version labels verbatim.

    AND searches forward, allowing zero bytes between nonoverlapping chunks.
    The earliest full chunk is sufficient: it leaves the most remaining data.
    """
    if signatures is None:
        signatures = load_signatures()
    found = []
    for name, alternatives in signatures.items():
        for chunks in alternatives:
            offset = 0
            for chunk in chunks:
                hit = chunk.search(payload, offset)
                if hit is None:
                    break
                offset = hit.end()
            else:
                found.append(name)
                break
    return found


def sid_payload(raw):
    """Strip PSID/RSID header and optional little-endian load address."""
    if len(raw) < 118 or raw[:4] not in (b'PSID', b'RSID'):
        raise ValueError('Not a PSID/RSID file')
    version, offset, load = struct.unpack_from('>HHH', raw, 4)
    minimum = 118 if version == 1 else 124
    if not 1 <= version <= 4 or not minimum <= offset <= len(raw):
        raise ValueError('Invalid SID header')
    if load == 0:
        if offset + 2 > len(raw):
            raise ValueError('Missing load address')
        offset += 2
    return raw[offset:]


def identify(raw, signatures=None):
    return match(sid_payload(raw), signatures)


def family(name):
    """Group version variants; preserve unrelated player names."""
    name = name.strip('()')
    for prefix, label in (('CheeseCutter', 'CheeseCutter'), ('JCH_NewPlayer', 'JCH NewPlayer'),
                          ('GoatTracker', 'GoatTracker'), ('DMC', 'DMC'),
                          ('Hermit/SidWizard', 'SID-Wizard'), ('SidWizard', 'SID-Wizard'),
                          ('SidFactory_II', 'SID Factory II')):
        if name.startswith(prefix):
            return label
    return re.sub(r'[_/]V?\d[\w.+?-]*$', '', name)


def load_semantic_choice():
    path = Path(__file__).resolve().parents[2] / 'tools/semantic_if.py'
    spec = importlib.util.spec_from_file_location('sid2ct_semantic_choice', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.semantic_choice


def editor_hint(payload, candidates, ask=None):
    """Ask only about printable credits; a choice is a hint, never a match."""
    strings = '\n'.join(s.decode('ascii') for s in re.findall(rb'[ -~]{4,}', payload))[:6000]
    if not strings:
        return None
    options = sorted(set(candidates))
    answer = (ask or load_semantic_choice())(
        'Which music editor is explicitly credited in these strings? Choose unknown if none.',
        strings, options + ['unknown'])
    choice = answer.get('choice')
    if choice in options:
        return {'label': 'hint', 'player': choice, 'confidence': answer.get('confidence', 0)}
    return None
