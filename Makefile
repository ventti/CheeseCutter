# make install DESTDIR=/home/yamo/devel/cc2/snap/parts/ccutter/install

PREFIX?=/usr
EXAMPLESDIR?=/usr/share/examples/ccutter
# SDL2 is bound at link time (DerelictSDL2_Static), so it must be linked here
# just like the macOS/Windows makefiles do. Provided by libsdl2-dev / SDL2-devel.
LIBS=-L-ldl -L-lstdc++ -L-lcurl -L-lSDL2
COMFLAGS=-O2
VERSION=$(shell cat Version)
DFLAGS=-d-version=DerelictSDL2_Static $(COMFLAGS) -I./src -J. -J./src/c64 -J./src/font
CFLAGS=$(COMFLAGS)
CXXFLAGS=$(COMFLAGS) -I./src 
COMPILE.d = $(DC) $(DFLAGS) -c
DC=ldc2
EXE=
TARGET=ccutter
OBJ_EXT=.o

include Makefile.objects.mk

PYTHON?=python3

.PHONY: install release dist clean dclean tar docs map check-map

all: ct2util ccutter

# Regenerate the man page and keyboard reference from the tool itself
# (single source of truth: src/main.d cliOptions() and the com.shortcuts registry).
docs: ccutter map
	SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-man     > doc/ccutter.1
	SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-man fr  > doc/ccutter.fr.1
	SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-man de  > doc/ccutter.de.1
	SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-man sv  > doc/ccutter.sv.1
	SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-man fi  > doc/ccutter.fi.1
	SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccutter --dump-keys    > doc/KEYBOARD.md

# Regenerate the architecture map (doc/ARCHITECTURE.md) from the source itself.
# Pure text parse — no build needed (see tools/genmap.py).
map:
	$(PYTHON) tools/genmap.py

# CI/pre-commit guard: fail if doc/ARCHITECTURE.md is stale vs the source.
check-map:
	$(PYTHON) tools/genmap.py
	git diff --exit-code -- doc/ARCHITECTURE.md

ccutter: $(C64OBJS) $(OBJS) $(CXX_OBJS) $(C_OBJS)
	$(DC) $(COMFLAGS) -of=$@ $(OBJS) $(CXX_OBJS) $(C_OBJS) $(LIBS)

.cpp.o : $(CXX_SRCS)
	$(CXX) $(CXXFLAGS) -c $< -o $@

.c.o : $(C_SRCS)
	$(CC) -c $< -o $@

ct: $(C64OBJS) $(CTOBJS)

ct2util: $(C64OBJS) $(UTILOBJS)
	$(DC) $(COMFLAGS) -of=$@ $(UTILOBJS)

c64: $(C64OBJS)

install: all
	strip ccutter$(EXE)
	strip ct2util$(EXE)
	cp ccutter$(EXE) $(DESTDIR)$(PREFIX)/bin
	cp ct2util$(EXE) $(DESTDIR)$(PREFIX)/bin
	mkdir -p $(DESTDIR)/$(EXAMPLESDIR)/example_tunes
	cp -r tunes/* $(DESTDIR)/$(EXAMPLESDIR)/example_tunes

# release version with additional optimizations
release: DFLAGS += -frelease -fno-bounds-check
release: all
	strip ccutter$(EXE)
	strip ct2util$(EXE)

# tarred release
dist:	release
	tar --transform 's,^\.,cheesecutter-$(VERSION),' -cvf cheesecutter-$(VERSION)-linux-x86.tar.gz $(DIST_FILES)

clean: 
	rm -f *.o *~ resid/*.o resid-fp/*.o ccutter ct2util \
		$(C64OBJS) $(OBJS) $(CTOBJS) $(CXX_OBJS) $(UTILOBJS) $(C_OBJS)

dclean: clean
	rm -f cheesecutter-$(VERSION)-linux-x86.tar.gz

# tarred source from master
tar:
	git archive master --prefix=cheesecutter-$(VERSION)/ | bzip2 > cheesecutter-$(VERSION)-src.tar.bz2
# --------------------------------------------------------------------------------

src/c64/player.bin: src/c64/player_v4.acme
	acme -f cbm --outfile $@ $<

src/ct/base.o: src/c64/player.bin
src/ct/build.o: src/c64/player_v4.acme src/c64/ultimate_host.acme
$(VERSION_USERS): Version
src/ui/ui.o: src/ui/help.o

%.o: %.d
	$(COMPILE.d) -of=$@ $<



