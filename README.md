CheeseCutter-Extended 0.3.0

CheeseCutter-Extended is based on CheeseCutter 2.9.

New in 0.3.0: rectangular block selection in the sequencer — drag with the mouse
(or set start/end markers with Ctrl-B / Ctrl-Shift-B) to select a range of rows
across one or more voices, then copy / cut / paste / merge / "paste as new
track(s)". Works in both the note column (F6) and the track column (F5). See the
Block Selection section of the guide.

Also new: separate **Export song** (Shift-F10) and **Render audio**
(Ctrl-Shift-F10) dialogs. *Export song* picks a C64 **format** — *Full player .prg*
(the verbatim live image), *Optimized .prg* (purged/relocated like `ct2util`), or
*PSID .sid* — with the relevant `ct2util` options (relocation address, zero page,
subtune selection) and, for the executable `.prg`, opt-out toggles for the
title/author/release display, the raster-time meter and the playback clock; the
optimized `.prg` can also drop the player UI to leave just the player routine +
compacted song data. *Render audio* renders the chosen subtune offline to *.wav*
(or *.flac* when the `flac` tool is installed) with Duration, linear Fade-out,
**Normalize** (to −1 dBFS), **WAV bit depth** (8 / 16 / 24 / 32-float), **sample
rate** (22.05 / 44.1 / 48 kHz, actually re-rendered at that rate) and an editable
**FLAC options** field (default `--best`). Options that don't apply to the chosen
format are greyed out. See the Exporting section of the guide.

Also new: **instrument color tags** — put `$X` or `$XY` (hex digits `0`–`F`,
the 16 C64 palette colors) anywhere in an instrument's description to recolor
that instrument's number in the instruments list and the track view. `$X` sets
the number's foreground color; `$XY` sets foreground `X` and background `Y`. It
only replaces the default gray — the cursor, the playback/selection highlight
and the active-instrument color always take precedence. See the Player Tables
section of the guide.

Also new: the **About / splash screen** (Help → About, `F11` / `Alt-S`) now has a
PETSCII scroller running below the artwork — arbitrary-length text scrolling
right-to-left with inline C64 color changes.

Programmed by abaddon 2009-2017.

Mac OSX and D2 port by Ruk 2013.

reSID engine by Dag Lem & A. Lankila.

Parts of reSID interface (sid.cpp) by Cadaver / CovertBitops.

Includes Acme Assembler 0.91 by Marco Baye

libSDL by the SDL team.

derelict, http://www.dsource.org/projects/derelict

Special thanks to Vent/Triad, Blackspawn, Mr Ammo, Scarzix/Offence, 
SuperNoise, Wisdom/Crescent and the forgotten ones...

Licensed under GNU General Public License (see the file COPYING for details).

Binary packages are available for some distributions via:
https://repology.org/metapackage/cheesecutter/versions

NOTE: authors of CheeseCutter-Extended take no responsibility of binaries downloaded
from any third party website, including the one above.

## Menus

The top row is a dropdown menu bar — press `Esc` to open it. Every command
(everything except live note entry) is reachable from the menus, grouped as
File / Edit / View / Playback / Window / Help plus a context menu that follows
what you are editing. Navigate with the arrow keys and `Enter`, or with the
mouse; the bar remembers the last menu and item you used. The menus, the `F12`
help and `doc/KEYBOARD.md` are all generated from one shortcut registry, so a
command's key and label are defined in a single place. Quit now lives in
**File → Quit** (it no longer has a hotkey).

With the menu bar open, just start typing to open the **command palette**: a
`>` prompt that searches every command by name/description (case-insensitive)
plus the `.ct`/`.ct2` songs in the current directory. Arrows + `Enter` run the
command or load the song; `Esc` dismisses. Also reachable as
**Help → Command palette**.

The load/save dialogs support **type-ahead** (type the beginning of a dir/file
name to jump to it) and show the focused song's **Title / Author / Release** as
a preview.

## Documentation

The consolidated user guide is in `guide/` and is prepared for GitHub Pages
deployment. In-app help is available with `F12`.

## How to build

### Quick Start (macOS) - Automated Setup

The easiest way to set up the development environment is using the bootstrap script:

```sh
./bootstrap.sh
```

This script will:
- Install Homebrew (if not present)
- Install mise (for environment management and build tasks)
- Install all required dependencies via Homebrew (ldc, acme, SDL)
- Verify Xcode Command Line Tools
- Build the project

After running the bootstrap script, you can use:

```sh
mise run build        # Build CheeseCutter-Extended
mise run build-utils  # Build ct2util utility
mise run clean        # Clean build artifacts
```

Or use make directly:

```sh
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib  # Apple Silicon
make -f Makefile.mac LIBSPATH=/usr/local/lib     # Intel Mac
```

### macOS - Manual Setup

Pre-requisites

* homebrew
* ldc
* SDL framework
* acme assembler

```sh
brew install ldc acme sdl12-compat
```

```sh
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib
```
