"""Run with python3 -m sid2ct."""
import argparse
import json
from pathlib import Path

from . import compare, convert
from .audio import compare_wavs


def main(argv=None):
    parser = argparse.ArgumentParser(prog='python3 -m sid2ct',
                                     description='Generic SID to CheeseCutter conversion and audio verification.')
    commands = parser.add_subparsers(dest='command', required=True)
    for name, module, help_text in (
        ('convert', convert, 'Convert a SID to editable CT and compare mix, voices and time windows.'),
        ('compare', compare, 'Convert or use an existing CT and compare mix, voices and time windows.'),
    ):
        command = commands.add_parser(name, help=help_text, description=module.__doc__)
        module.add_arguments(command)
        command.set_defaults(handler=module.run_command)
    score = commands.add_parser('score', help='Compare two existing mono PCM16 WAVs.')
    score.add_argument('source', type=Path)
    score.add_argument('reconstruction', type=Path)
    score.add_argument('--max-lag-ms', type=float, default=250)
    score.add_argument('--alignment-ms', type=float, help='Use this fixed offset instead of searching.')
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
