---
name: run-cheesecutter
description: Build, run, screenshot, and drive CheeseCutter-Extended (the SDL2 SID music editor) and its ct2util CLI. Use when asked to run, start, build, launch, test, screenshot, or drive CheeseCutter / ccutter / the editor, or to export a .sid/.prg or regenerate the docs.
---

CheeseCutter-Extended is an SDL2 desktop SID-music editor written in D (built
with `Makefile.mac` via `ldc2` + the embedded ACME assembler). It normally
opens a window, but it **renders fine headless**: under `SDL_VIDEODRIVER=dummy`
SDL still software-renders to a readable framebuffer, so the editor's own
`saveScreenshot` produces a real BMP. The agent path is **`./ccdriver`** — a
small D harness (`.claude/skills/run-cheesecutter/driver.d`) that builds the
real editor UI, loads a song, injects keypresses, advances playback, and writes
screenshots. Non-visual checks use the editor's own `--dump-*` flags and
`ct2util`.

All paths below are relative to the repo root (the unit). Verified on macOS
(Apple Silicon, Homebrew). A Linux `Makefile` also exists but isn't covered here.

## Prerequisites

```sh
brew install ldc acme sdl2 imagemagick
```
(verified present: ldc 1.41, acme 0.97, sdl2 2.32.10, imagemagick 7.1.1.
`imagemagick` is only needed to convert the BMP screenshots to PNG.)

## Build

```sh
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib
```
Builds `./ccutter` (the editor). `LIBSPATH=/usr/local/lib` on Intel Macs. The
default goal is `ccutter`; build the others explicitly:

```sh
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib ccdriver   # the headless driver
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib ct2util    # the CLI utility
```

After changing a base class or a string-imported asset (`src/c64/*.acme`,
`src/c64/player.bin`, the `Version` file) run `make -f Makefile.mac clean`
first — the Makefiles have no inter-module dependency tracking, and a stale
object with a shifted struct layout crashes at runtime.

## Run — agent path (`./ccdriver`, headless)

Drive the editor with a sequence of `cmd:value` args. Always set the dummy
drivers:

```sh
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccdriver \
  load:tunes/vent-arkijuusto.ct key:F2 ff:30 shot:/tmp/cc.bmp state
```
Commands (in order, repeatable):
- `load:<file.ct>` — load a song
- `key:<spec>` — inject a keypress; `spec = [Ctrl-][Alt-][Shift-]NAME`, where
  NAME is `F1`..`F12`, `ESC`, `RET`, `SPACE`, `TAB`, `UP`/`DOWN`/`LEFT`/`RIGHT`,
  `HOME`/`END`/`PGUP`/`PGDN`, or a single char (`a`, `2`, `y`). Useful keys:
  `F2` play-from-start, `F3` play-from-cursor, `F4` stop, `Esc Esc y` quit,
  `Shift-F10` save playable `.prg`, `F12` help.
- `ff:<n>` — advance playback by `n*16` frames deterministically (calls the
  player directly; no audio device needed — that's how SID state changes here)
- `frames:<n>` — render n UI frames
- `shot:<file.bmp>` — write a screenshot (BMP)
- `state` — print title/author/seqs/playing/octave/speed + the first SID
  registers to stderr

The screenshot is a BMP; convert and view it:

```sh
magick /tmp/cc.bmp /tmp/cc.png
```
The run above prints e.g. `state: title='arkijuusto (toinen siivu)' ... playing=true ... SID $d400..: 4c 68 00 00 80 13 ...` (non-zero SID = the player advanced), and `/tmp/cc.png` shows the editor with the tune loaded and `Time: 00:04` in the status bar.

## Non-visual checks (no driver needed)

```sh
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --help
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-keys   # keyboard ref (Markdown)
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-man fi # man page (roff); also fr/de/sv or none for English
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib docs               # regenerate doc/ccutter*.1 + doc/KEYBOARD.md
```
`--help` and the man pages share one option list (`cliOptions()` in
`src/main.d`); `--dump-keys` and F12 help come from the `com.shortcuts` registry.

## Export with ct2util

```sh
./ct2util sid tunes/vent-arkijuusto.ct -o /tmp/song.sid   # PSID
./ct2util prg tunes/vent-arkijuusto.ct -o /tmp/song.prg   # relocated PRG ($1000)
```
`./ct2util` with no args prints all commands/options.

## Run the exported self-running .prg in VICE (optional, for real audio/visuals)

`Shift-F10` in the editor (or the `--ultimate` path) exports a **self-running**
`.prg` that plays on a C64. Drive it in VICE headless and screenshot:

```sh
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy x64sc -warp -limitcycles 30000000 \
  -exitscreenshot /tmp/play.png -autostart /tmp/song.prg
```
(Captured audio: drop `-warp`, add `-sounddev wav -soundarg /tmp/out.wav`. Needs
a self-running PRG from the editor — `ct2util prg` output is a player blob, not
self-running.)

## Run — human path

`./ccutter [file.ct]` opens a real editor window (Cocoa) on a Mac with a
display. Useless headless and it never returns — use `./ccdriver` instead for
any automated/headless work.

## Gotchas

- **Headless screenshots actually work.** `SDL_VIDEODRIVER=dummy` software-
  renders to a real framebuffer, so `saveScreenshot` (and thus `shot:`) writes
  a genuine 1280×700 BMP — not a blank. This is the whole reason `ccdriver`
  exists.
- **Screenshots are BMP, not PNG.** `saveScreenshot` uses `SDL_SaveBMP`. Convert
  with `magick` (macOS `sips` fails on this 32-bit BMP variant).
- **Playback needs `ff:`, not wall-clock.** With dummy audio the SDL audio
  callback never fires, so the song won't advance on its own. `ff:N` calls the
  player synchronously — that's how you get the player to write SID registers /
  advance `Time:` in a headless run.
- **`driver.d` is `module main`** and links against every object **except**
  `src/main.o` (which has its own `main`). The `ccdriver` target does the
  `filter-out`. If you add a new module that `import main;` references a symbol
  from `src/main.d` other than its ModuleInfo, the link will break.
- **`-J.` is required.** The version is string-imported from the repo-root
  `Version` file (`import("Version")` in `src/com/util.d`); the Makefiles add
  `-J.` for it. Bump the version by editing `Version` only.
- **macOS deployment target** is pinned to 15.0 (`MACOSX_DEPLOYMENT_TARGET`,
  override with `make … MACDEPLOY=…`). Homebrew's SDL2 dylib is built for a
  newer macOS, so `ld` prints one unavoidable "linking with dylib … newer
  version" warning — that's brew's lib, not our objects.

## Troubleshooting

- **`SDL video init failed`** / `ccdriver` exits 1 → you didn't set
  `SDL_VIDEODRIVER=dummy` (and there's no display). Prefix every invocation.
- **Runtime crash right after a struct/UI change, but the build "succeeded"** →
  stale object with an old struct layout (no dep tracking). `make -f
  Makefile.mac clean` then rebuild.
- **`ld: warning: … built for newer 'macOS' version`** for *our* `.o` files →
  the `MACOSX_DEPLOYMENT_TARGET` export in `Makefile.mac` is missing/overridden;
  every compile must see it. (The SDL2 *dylib* warning is expected.)
- **`make` only rebuilds `src/com/util.o` and nothing relinks** → a rule was
  added to the *included* `Makefile.objects.mk` and hijacked the default goal;
  dependency rules belong in `Makefile.mac` after the first real target.
