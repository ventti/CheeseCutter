#!/usr/bin/env bash
#
# Run ccutter under lldb non-interactively and, on a crash, print a full
# backtrace of every thread plus registers — so an agent (or you) can capture
# the stack of a segfault without an interactive session. macOS has no automatic
# segfault backtrace (druntime's handler is Linux-only), so this is the way to
# get one. For best results build the debug binary first:
#
#     make -f Makefile.mac debug
#     tools/lldb-run.sh --ultimate 192.168.2.134 tunes/vent-arkijuusto.ct
#
# Anything after the script name is passed straight to ccutter.
#
# Env:
#   BIN=./ccutter   path to the binary to run (default ./ccutter)
#   HEADLESS=1      run with the dummy SDL video/audio drivers (no window)
#
# Notes:
#   * lldb runs the program to completion; if it never crashes (e.g. the editor
#     just sits in its main loop) this won't return on its own — Ctrl-C it, or
#     point it at an input that crashes quickly.
#   * A clean exit returns lldb's normal status; a crash prints the stack and
#     leaves lldb with the crash recorded.
set -u

BIN="${BIN:-./ccutter}"
if [ ! -x "$BIN" ]; then
	echo "lldb-run: '$BIN' not found or not executable." >&2
	echo "          build it first:  make -f Makefile.mac debug" >&2
	exit 1
fi
if ! command -v lldb >/dev/null 2>&1; then
	echo "lldb-run: lldb not found (install the Xcode Command Line Tools)." >&2
	exit 1
fi
if [ "${HEADLESS:-0}" = "1" ]; then
	export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy
fi

# --batch: execute the commands and exit.
# -o run : launch the program.
# -k ... : commands run only if the target crashes (one-line-on-crash), giving
#          us the backtrace + registers right at the fault.
exec lldb --batch \
	-o "run" \
	-k "bt all" \
	-k "register read" \
	-k "quit" \
	-- "$BIN" "$@"
