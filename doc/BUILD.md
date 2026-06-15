# Building CheeseCutter-Extended

This is the canonical developer setup guide for **macOS**, **Linux** and
**Windows**. Each platform has a one-command path (`mise run setup` or a
bootstrap script) and a manual path. The toolchains here are the same ones the
CI jobs in `.github/workflows/build.yml` use, so a green CI means these steps
work.

## Toolchain at a glance

Every platform needs the same four things:

| Component | macOS (Homebrew) | Linux (apt/dnf/pacman) | Windows (MSYS2 MINGW64) |
|-----------|------------------|------------------------|-------------------------|
| D compiler | `ldc` | `ldc` | `mingw-w64-x86_64-ldc` |
| 6502 assembler | `acme` | `acme` * | from source * |
| SDL2 | `sdl2` | `libsdl2-dev` / `SDL2-devel` / `sdl2` | `mingw-w64-x86_64-SDL2` |
| libcurl | (bundled) | `libcurl4-openssl-dev` / `libcurl-devel` / `curl` | `mingw-w64-x86_64-curl` |

Plus a C/C++ toolchain (`gcc`/`g++`/`clang`) and `make`.

\* **acme** is packaged on Debian/Ubuntu and Homebrew, but **not** on Fedora,
Arch (AUR only), or MSYS2. Where it is missing, build it from source — the
setup scripts do this automatically:

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

## Windows (MSYS2 / mingw-w64)

The canonical Windows build is a **native** build in an MSYS2 `MINGW64` shell
(the `windows` CI job uses exactly this). Cross-building from macOS/Linux is not
supported by stock LDC — see the header of `Makefile.win`.

1. Install [MSYS2](https://www.msys2.org/) and open the **"MSYS2 MINGW64"**
   shell (not the plain MSYS or UCRT64 shell).
2. From the repo root:

```sh
./bootstrap-windows.sh        # installs the toolchain, builds acme, release-builds
# or do it by hand:
pacman -S --needed make git \
  mingw-w64-x86_64-ldc mingw-w64-x86_64-gcc \
  mingw-w64-x86_64-SDL2 mingw-w64-x86_64-curl
# acme is NOT a mingw package — build from source (see the acme note above),
# then:
make -f Makefile.win release
```

Package a redistributable zip (bundles the SDL2/curl/mingw runtime DLLs the
executables depend on):

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
  Install `sdl2` (macOS) / `libsdl2-dev` (Linux) / `mingw-w64-x86_64-SDL2`
  (Windows). On macOS, check `LIBSPATH` matches `$(brew --prefix)/lib`.
- **Link error: undefined `curl_*`** → install the libcurl dev package
  (`libcurl4-openssl-dev` / `libcurl-devel` / `mingw-w64-x86_64-curl`).
- **`acme: command not found`** → install acme or build it from source (see the
  acme note at the top).
- **Windows: wrong shell** → builds must run in the **MINGW64** shell; UCRT64 /
  MSYS shells use a different runtime and won't match `Makefile.win`.
