#!/usr/bin/env bash
#
# CheeseCutter Windows Bootstrap (run from a Git Bash shell on Windows x64).
# Mirrors the "windows" job in .github/workflows/build.yml so a local toolchain
# matches CI: the native x64 build uses ldc2 for D and clang for the reSID
# C/C++ sources, linked against the MSVC runtime. SDL2 comes from vcpkg; libcurl
# is not linked (Phobos loads it at runtime). See doc/BUILD.md for details.
#
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }

# Install the toolchain via Chocolatey if pieces are missing.
need_choco=()
command -v ldc2  >/dev/null 2>&1 || need_choco+=(ldc)
command -v clang >/dev/null 2>&1 || need_choco+=(llvm)
command -v make  >/dev/null 2>&1 || need_choco+=(make)
if [ ${#need_choco[@]} -gt 0 ]; then
    if command -v choco >/dev/null 2>&1; then
        echo "Installing via Chocolatey: ${need_choco[*]}"
        choco install -y "${need_choco[@]}"
    else
        err "Missing tools (${need_choco[*]}) and Chocolatey not found."
        err "Install LDC, LLVM (clang) and make, or install Chocolatey first."
        exit 1
    fi
fi

# SDL2 from vcpkg. Honour VCPKG_INSTALLATION_ROOT (set on CI) or VCPKG_ROOT.
VCPKG="${VCPKG_INSTALLATION_ROOT:-${VCPKG_ROOT:-}}"
if [ -z "$VCPKG" ]; then
    err "vcpkg not found. Set VCPKG_ROOT to your vcpkg checkout and re-run."
    err "  git clone https://github.com/microsoft/vcpkg && ./vcpkg/bootstrap-vcpkg.bat"
    exit 1
fi
echo "Installing SDL2 (vcpkg, x64-windows)..."
"$VCPKG/vcpkg" install sdl2:x64-windows
SDL2="$VCPKG/installed/x64-windows"
log "SDL2: $SDL2"

echo "Building CheeseCutter (release)..."
make -f Makefile.win release \
    SDL2_INC="$SDL2/include" SDL2_LIBDIR="$SDL2/lib"
log "Build complete: ccutter.exe + ct2util.exe"

echo ""
echo "Package a redistributable zip with SDL2.dll:  ./make-wintest.sh"
echo "See doc/BUILD.md for details."
