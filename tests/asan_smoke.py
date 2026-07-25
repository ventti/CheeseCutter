#!/usr/bin/env python3
"""Layer-5 AddressSanitizer smoke (see the sdl2-ui-debug-qa skill).

Deliberately NOT named ``test_*`` so ``unittest discover`` never runs it in the
normal (release-binary) corpus. It is meant to run against an ASan-instrumented
``ccdriver`` (``make -f Makefile.mac sanitize-asan``) and is wired into CI only as
a MANUAL, non-blocking job.

Why a single short smoke rather than the full corpus: the D-side ASan
instrumentation is ~80x slower here (a bare load+state that runs in ~1s takes
~90s under ASan), so re-running the ~115-test functional suite would take hours.
ASan's value is memory safety, not re-verifying numerics the release-binary
`test` job already covers — so we just drive one broad editor session through the
instrumented binary and fail on any sanitizer finding (ASan aborts non-zero).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "ccdriver"

# One short session that still touches a broad set of D code paths: open the
# Sound Editor, move/edit a step, multi-select, undo/redo, help overlay, exit.
SMOKE = [
    "load:tunes/vent-arkijuusto.ct",
    "key:ESC", "key:Ctrl-e", "ff:2",
    "key:DOWN", "key:DOWN", "key:RIGHT", "key:LEFT",
    "click:20,10", "shiftclick:24,10",
    "key:Ctrl-z", "key:Ctrl-r",
    "key:F12", "key:ESC",
    "state",
]

# Generous because the instrumented binary is slow; override via env in CI.
TIMEOUT = float(os.environ.get("CCDRIVER_ASAN_SMOKE_TIMEOUT", "900"))


def main() -> int:
    if not DRIVER.exists():
        print(f"ccdriver not built at {DRIVER}", file=sys.stderr)
        return 2
    env = os.environ.copy()
    env.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    # halt hard on any finding; a non-zero exit is how ASan signals it.
    env.setdefault(
        "ASAN_OPTIONS",
        "detect_leaks=0:halt_on_error=1:abort_on_error=1:exitcode=99",
    )
    print(f"running ASan smoke ({len(SMOKE)} commands, timeout {TIMEOUT:.0f}s)...")
    try:
        proc = subprocess.run(
            [str(DRIVER), *SMOKE],
            cwd=ROOT, env=env, text=True, capture_output=True, timeout=TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        print(f"FAIL: ASan smoke exceeded {TIMEOUT:.0f}s", file=sys.stderr)
        return 1
    output = proc.stdout + proc.stderr
    if "AddressSanitizer" in output or "runtime error:" in output:
        print("FAIL: sanitizer finding\n" + output, file=sys.stderr)
        return 1
    if proc.returncode != 0:
        print(f"FAIL: ccdriver exited {proc.returncode}\n{output}", file=sys.stderr)
        return 1
    print("PASS: ASan smoke clean (no sanitizer findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
