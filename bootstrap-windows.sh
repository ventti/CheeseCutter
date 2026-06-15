#!/usr/bin/env bash
#
# CheeseCutter Windows Bootstrap (run inside an MSYS2 "MINGW64" shell).
# Mirrors the "windows" job in .github/workflows/build.yml so a local toolchain
# matches CI exactly. Installs the mingw-w64 toolchain + builds acme from source
# (acme is not a mingw package), then does a release build.
# See doc/BUILD.md for details.
#
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; }

if [[ "$MSYSTEM" != "MINGW64" ]]; then
    err "This script must run from an MSYS2 'MINGW64' shell (MSYSTEM=$MSYSTEM)."
    err "Open 'MSYS2 MINGW64' from the Start menu and re-run."
    exit 1
fi

echo "Installing mingw-w64 toolchain (ldc, gcc, SDL2, curl) + make/git..."
pacman -S --needed --noconfirm make git \
    mingw-w64-x86_64-ldc mingw-w64-x86_64-gcc \
    mingw-w64-x86_64-SDL2 mingw-w64-x86_64-curl
log "Toolchain installed"

# acme is not a mingw package -- build it from source (same as CI).
if ! command -v acme &> /dev/null; then
    echo "Building acme from source (github.com/meonwax/acme)..."
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/meonwax/acme "$tmp/acme"
    make -C "$tmp/acme/src"
    cp "$tmp/acme/src/acme.exe" /mingw64/bin/ 2>/dev/null \
        || cp "$tmp/acme/src/acme" /mingw64/bin/acme.exe
fi
acme --version >/dev/null && log "acme: $(command -v acme)"

echo "Building CheeseCutter (release)..."
make -f Makefile.win release
log "Build complete: ccutter.exe + ct2util.exe"

echo ""
echo "Package a redistributable zip with DLLs:  ./make-wintest.sh"
echo "See doc/BUILD.md for details."
