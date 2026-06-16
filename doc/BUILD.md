# Building CheeseCutter-Extended

This is the canonical developer setup guide for **macOS**, **Linux** and
**Windows**. Each platform has a one-command path (`mise run setup` or a
bootstrap script) and a manual path. The toolchains here are the same ones the
CI jobs in `.github/workflows/build.yml` use, so a green CI means these steps
work.

## Toolchain at a glance

Every platform needs the same four things:

| Component | macOS (Homebrew) | Linux (apt/dnf/pacman) | Windows (LLVM/MSVC) |
|-----------|------------------|------------------------|---------------------|
| D compiler | `ldc` | `ldc` | `ldc` (official build, MSVC-target) |
| 6502 assembler | `acme` | `acme` * | not needed † |
| SDL2 | `sdl2` | `libsdl2-dev` / `SDL2-devel` / `sdl2` | `sdl2:x64-windows` (vcpkg) |
| libcurl | (bundled) | `libcurl4-openssl-dev` / `libcurl-devel` / `curl` | runtime only ‡ |

Plus a C/C++ toolchain (`gcc`/`g++`/`clang`) and `make`. On Windows the C/C++
(reSID) sources are built with **clang**, which defaults to the
`x86_64-pc-windows-msvc` target and so links cleanly with the MSVC-target `ldc2`.

† The committed `src/c64/player.bin` is used as-is on Windows, so no acme is
needed there. ‡ libcurl is not linked — Phobos `std.net.curl` loads it at
runtime via `LoadLibraryA`, so it is only needed (as a DLL on `PATH`) if you use
the Ultimate-hardware playback feature.

\* **acme** is packaged on Debian/Ubuntu and Homebrew, but **not** on Fedora or
Arch (AUR only). Where it is missing, build it from source — the setup scripts
do this automatically (it is not needed on Windows, which uses the committed
`player.bin`):

```sh
git clone --depth 1 https://github.com/meonwax/acme /tmp/acme
make -C /tmp/acme/src
# then copy /tmp/acme/src/acme (or acme.exe) onto your PATH
```

`acme` assembles `src/c64/player.bin`; the D/C/C++ sources are then compiled and
linked into `ccutter` (the editor) and `ct2util` (the CLI converter).

---

## macOS

**Quick start:**

```sh
./bootstrap.sh        # installs Homebrew, ldc/acme/sdl2, mise; does a test build
# or, if you already have Homebrew + mise:
mise run setup        # brew install ldc acme sdl2
mise run build        # build (also refreshes doc/ARCHITECTURE.md)
mise run run          # build and run
```

**Manual:**

```sh
brew install ldc acme sdl2
make -f Makefile.mac LIBSPATH=/opt/homebrew/lib   # Apple Silicon
make -f Makefile.mac LIBSPATH=/usr/local/lib      # Intel
```

`LIBSPATH` points at the Homebrew `lib` dir (`$(brew --prefix)/lib`) so the link
finds `libphobos2-ldc.a`, `libdruntime-ldc.a` and `libSDL2`. `make -f
Makefile.mac release` produces `CheeseCutter-Extended.app`; `make -f
Makefile.mac dist` produces the `.dmg`.

## Linux

**Quick start:**

```sh
./bootstrap.sh        # detects apt/dnf/pacman, installs deps, does a test build
# or:
mise run setup        # installs deps for your distro
mise run build
mise run run
```

**Manual — by distro:**

```sh
# Debian / Ubuntu
sudo apt-get install -y ldc acme libsdl2-dev libcurl4-openssl-dev g++ make git

# Fedora  (acme is built from source — see the acme note above)
sudo dnf install -y ldc SDL2-devel libcurl-devel gcc-c++ make git

# Arch  (acme is in the AUR: e.g. `yay -S acme`)
sudo pacman -S --needed ldc sdl2 curl gcc make git
```

Then just:

```sh
make            # builds ccutter + ct2util (the default Makefile is the Linux one)
make release    # optimized, stripped
make dist       # tarball
```

## Windows (x64, LLVM/MSVC)

The canonical Windows build is a **native** x64 build with the LLVM toolchain —
`ldc2` for the D sources and `clang`/`clang++` for the reSID C/C++ sources,
linked against the MSVC runtime (the `windows` CI job uses exactly this). It
replaces the old mingw-w64 path: LDC was dropped from MSYS2 and the only official
LDC Windows builds target the MSVC ABI. Run the commands from a **Git Bash**
shell (bundled with Git for Windows).

1. Install [LDC](https://github.com/ldc-developers/ldc/releases) (official
   Windows build) and put `bin/` on `PATH`; ensure `clang` is available
   (LLVM ships with Visual Studio / the LLVM installer).
2. From the repo root:

```sh
./bootstrap-windows.sh        # installs make + SDL2 (vcpkg) and release-builds
# or do it by hand:
choco install make llvm ldc -y
vcpkg install sdl2:x64-windows
SDL2="$VCPKG_INSTALLATION_ROOT/installed/x64-windows"
make -f Makefile.win release SDL2_INC="$SDL2/include" SDL2_LIBDIR="$SDL2/lib"
```

Package a redistributable zip (bundles `SDL2.dll`, the only mandatory runtime
DLL):

```sh
./make-wintest.sh             # produces cheesecutter-<version>-win64.zip
```

---

## Common gotchas

- **No inter-module dependency tracking.** The Makefiles don't track header /
  base-class / asset dependencies. After changing a base class or a
  string-imported asset (`src/c64/*.acme`, `src/c64/player.bin`, the `Version`
  file), run `make clean` (or `make -f Makefile.win clean`) so dependents
  rebuild.
- **Shared object paths.** All three Makefiles write `.o` files to the same
  per-source paths. When switching between a host build and the Windows build in
  the same tree, run a `clean` first.
- **Version** lives only in the repo-root `Version` file; it is string-imported
  at compile time (build flag `-J.`). Bump it by editing `Version` and
  rebuilding.
- **Docs are generated.** `make docs` regenerates the man pages
  (`doc/ccutter*.1`), `doc/KEYBOARD.md` and `doc/ARCHITECTURE.md` from the tool
  itself. `make map` regenerates just the architecture map. Don't hand-edit
  those. (See `CLAUDE.md`.)

## Troubleshooting

- **Link error: undefined symbols `SDL_*`** → SDL2 isn't installed/linked.
  Install `sdl2` (macOS) / `libsdl2-dev` (Linux) / `sdl2:x64-windows` via vcpkg
  (Windows). On macOS, check `LIBSPATH` matches `$(brew --prefix)/lib`; on
  Windows, check `SDL2_INC`/`SDL2_LIBDIR` point at the vcpkg install.
- **Link error: undefined `curl_*`** (macOS/Linux only) → install the libcurl
  dev package (`libcurl4-openssl-dev` / `libcurl-devel`). On Windows curl is not
  linked (Phobos loads it at runtime).
- **`acme: command not found`** (macOS/Linux) → install acme or build it from
  source (see the acme note at the top). Not needed on Windows — the committed
  `player.bin` is used.
- **Windows: `clang` not found** → install LLVM (`choco install llvm`) or use the
  clang that ships with Visual Studio; `Makefile.win` builds the reSID C/C++
  sources with clang so they match the MSVC-target `ldc2`.
