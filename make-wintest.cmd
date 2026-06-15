@echo off
REM Local Windows x64 packaging helper. Run from an MSYS2/mingw-w64 shell via
REM make-wintest.sh, or build directly with: make -f Makefile.win release
REM The canonical build is the "windows" job in .github\workflows\build.yml.

set /p VER=<Version
set ZIPNAME=cheesecutter-%VER%-win64.zip
del %ZIPNAME%
make -f Makefile.win clean release
zip %ZIPNAME% ccutter.exe ct2util.exe README.md LICENSE.md tunes\*.*
REM Remember to add the required SDL2 / libcurl / mingw runtime DLLs to %ZIPNAME%.
set ZIPNAME=
set VER=
