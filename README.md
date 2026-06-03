CheeseCutter-Extended 0.1.0

CheeseCutter-Extended is based on CheeseCutter 2.9.

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
