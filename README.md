CheeseCutter-Extended 0.3.0

CheeseCutter-Extended is based on CheeseCutter 2.9.

New in 0.3.0: rectangular block selection in the sequencer — drag with the mouse
(or set start/end markers with Ctrl-B / Ctrl-Shift-B) to select a range of rows
across one or more voices, then copy / cut / paste / merge / "paste as new
track(s)". Works in both the note column (F6) and the track column (F5). See the
Block Selection section of the guide.

Also new: **optimized export from the editor**. Alongside the verbatim live-image
`.prg` (Shift-F10), the editor now exports a **packed `.prg`** (Ctrl-Shift-F10) and
a **PSID `.sid`** (Alt-F10) — both purged/relocated like `ct2util`, through a small
options dialog (relocation address, zero page, subtune selection). The packed
`.prg` can either embed the self-running player + on-screen UI (same look & feel as
the live `.prg`, with opt-out toggles for the title/author/release display, the
raster-time meter and the playback clock) or contain just the player routine +
compacted song data. See the Exporting section of the guide.

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
