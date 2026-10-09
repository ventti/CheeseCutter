#!/usr/bin/env python3
"""Build the libsidplayfp 3.x audio-validation helper, reporting wall time."""
import argparse
from pathlib import Path
import shlex
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, help='Local libsidplayfp prefix; uses its static library.')
    parser.add_argument('--cxx', default='c++')
    args = parser.parse_args()
    start = time.monotonic()
    try:
        if args.prefix:
            flags = ['-I'+str(args.prefix/'include'), str(args.prefix/'lib/libsidplayfp.a'), '-pthread']
        else:
            version = subprocess.check_output(['pkg-config', '--modversion', 'libsidplayfp'], text=True).strip()
            if int(version.split('.')[0]) != 3:
                raise ValueError('Renderer requires libsidplayfp 3.x.')
            flags = shlex.split(subprocess.check_output(
                ['pkg-config', '--cflags', '--libs', 'libsidplayfp'], text=True))
        command = [args.cxx, '-std=c++17', '-O2', str(ROOT/'tools/sid_render.cpp'),
                   '-o', str(ROOT/'tools/sid_render'), *flags]
        subprocess.run(command, check=True)
        print(f'Built tools/sid_render in {time.monotonic()-start:.2f}s')
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f'Build failed after {time.monotonic()-start:.2f}s: {error}')
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
