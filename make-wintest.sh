#!/bin/sh
# Local Windows x64 packaging helper (run inside an MSYS2/mingw-w64 shell, or
# adapt for a cross toolchain -- see Makefile.win). The canonical build is the
# "windows" job in .github/workflows/build.yml.
VER=`cat Version`
ZIPNAME=cheesecutter-$VER-win64.zip
rm -f $ZIPNAME
make -f Makefile.win clean release
zip $ZIPNAME ccutter.exe ct2util.exe README.md LICENSE.md tunes/*
# Bundle the mingw runtime + SDL2/curl DLLs the executables depend on.
for exe in ccutter.exe ct2util.exe; do
	for dll in `ldd $exe | grep -i '/mingw64/bin/' | awk '{print $3}'`; do
		zip -j $ZIPNAME "$dll"
	done
done
