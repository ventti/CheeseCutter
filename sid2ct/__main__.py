"""Run with python3 -m sid2ct."""
import argparse
import json
from pathlib import Path

from . import bench, compare, convert, corpus, search, players
from .audio import compare_wavs


def main(argv=None):
    parser = argparse.ArgumentParser(prog='python3 -m sid2ct',
                                     description='Convert SID music to editable CheeseCutter songs and compare how they sound.')
    commands = parser.add_subparsers(dest='command', required=True)
    for name, module, help_text in (
        ('convert', convert, 'Convert a SID file to an editable CheeseCutter song.'),
        ('search', search, 'Try different conversion methods, keep the best result and save each version.'),
        ('compare', compare, 'Compare the original song with converted versions, including each voice.'),
    ):
        command = commands.add_parser(name, help=help_text, description=help_text)
        module.add_arguments(command)
        command.set_defaults(handler=module.run_command)
    for name, module, help_text in (
        ('players', players, 'Identify music players in the SID corpus and composer folders.'),
        ('corpus', corpus, 'Build the fixed benchmark corpus from an HVSC checkout.'),
        ('bench', bench, 'Convert the corpus songs and record scores to compare runs.'),
    ):
        command = commands.add_parser(name, help=help_text, description=help_text)
        module.add_arguments(command)
        command.set_defaults(handler=module.run_command)
    score = commands.add_parser('score', help='Compare two mono 16-bit WAV files.')
    score.add_argument('source', type=Path, help='Original WAV file.')
    score.add_argument('reconstruction', type=Path, help='Converted WAV file.')
    score.add_argument('--max-lag-ms', type=float, default=250, help='Maximum timing shift to try in milliseconds (default: 250).')
    score.add_argument('--alignment-ms', type=float, help='Shift the converted audio by this many milliseconds before comparing.')
    score.set_defaults(handler=score_wavs)
    args = parser.parse_args(argv)
    return args.handler(args)


def score_wavs(args):
    try:
        import math
        if not math.isfinite(args.max_lag_ms) or args.max_lag_ms < 0:
            raise ValueError('Maximum lag must be finite and nonnegative.')
        result = compare_wavs(args.source, args.reconstruction, args.max_lag_ms,
                              fixed_alignment_ms=args.alignment_ms)
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError) as error:
        print('sid2ct score: '+str(error))
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
