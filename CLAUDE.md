# CheeseCutter-Extended — notes for Claude

## Keep docs in sync with code (in the SAME change)

When you add or change a **feature, fix, CLI option, or keyboard shortcut**,
update the relevant documentation as part of that same change — never leave the
docs trailing behind the code. A behavior change with no doc update is
incomplete.

Doc surfaces — check each that applies:

- **`README.md`** — top-level feature/usage summary and the version line.
- **`guide/README.md`** — the user guide (rendered through `guide/index.md`).
  Update the *Global Shortcuts* / *Playback* tables and add or extend a section
  when you introduce a feature.
- **`doc/ccutter.1`** and **`doc/KEYBOARD.md` are GENERATED — do not hand-edit.**
  For a CLI flag, add it to `cliOptions()` in `src/main.d` (the single source
  for both `--help` and the man page). For a shortcut, add a `com.shortcuts`
  `register(...)` entry (drives F12 help + the keyboard reference). Then run
  `make docs` (or `make -f Makefile.mac docs`) to regenerate both files from the
  tool. The `doc/*.fr.1` French man pages are hand-maintained and may lag — note
  when they need a translation pass.
- **`doc/ct2util.1`** — still hand-maintained; update for ct2util CLI changes.
- **`Version`** file and the `APP_VERSION` enum in `src/com/util.d` on a version
  bump (they must match; the version is shown in-app and baked into exported PRGs).

There is no fully-automatic generator for the prose docs — treat the list above
as the checklist to run through before considering a feature/fix done.

## Build note

The Makefiles have no inter-module dependency tracking: run `make clean` after
changing a base class or a string-imported asset (`src/c64/*.acme`,
`src/c64/player.bin`) so dependents are rebuilt.
