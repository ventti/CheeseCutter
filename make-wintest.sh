#!/bin/sh
# Local Windows x64 packaging helper (run from Git Bash on Windows). The
# canonical build is the "windows" job in .github/workflows/build.yml.
VER=`cat Version`
ZIPNAME=cheesecutter-$VER-win64.zip
rm -f $ZIPNAME

# SDL2 from vcpkg (override SDL2_PREFIX if yours lives elsewhere).
SDL2_PREFIX="${SDL2_PREFIX:-${VCPKG_INSTALLATION_ROOT:-$VCPKG_ROOT}/installed/x64-windows}"

make -f Makefile.win clean release \
	SDL2_INC="$SDL2_PREFIX/include" SDL2_LIBDIR="$SDL2_PREFIX/lib"
zip $ZIPNAME ccutter.exe ct2util.exe README.md LICENSE.md tunes/*
# SDL2.dll is the only mandatory runtime DLL. (libcurl is loaded lazily by
# Phobos and only needed for the Ultimate-hardware feature.)
zip -j $ZIPNAME "$SDL2_PREFIX/bin/SDL2.dll"
