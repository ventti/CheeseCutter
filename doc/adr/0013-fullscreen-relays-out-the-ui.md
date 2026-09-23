# 0013 — Fullscreen re-lays the UI out instead of scaling it

**Status:** Accepted.

## Context

The editor draws its character grid 1:1 (8×14 px cells) at the top-left of the
renderer. Fullscreen (`SDL_WINDOW_FULLSCREEN_DESKTOP`) made the window as big as
the screen but kept the window-sized grid, so most of the screen stayed black.

Scaling the grid up was the cheap option. The ratio between a window and its
screen is usually a small fraction (about 1.1×), so the pixel font would either
come out uneven (nearest-neighbour) or blurry (linear). The user asked for the
screen to be used for more editor instead: more columns and sequencer rows at
the same text size.

The layout is computed once, in the constructors (`UI`, `Toplevel`,
`Sequencer`, the dialogs), from `screen.width/height`. There is no relayout path.

## Decision

A window size change, which is how a fullscreen toggle arrives (asynchronously
on macOS), goes to `ui.ui.fitToWindow`:

- `com.fb.gridForWindow` picks the grid that fills the window 1:1, clamped to
  160×50 … 200×74 cells (the sequencer shows at most 64 rows).
- If the grid changes, a new `Screen` is installed (`Video.setScreen`) and a
  **new `UI` is built** without the splash (each UI owns its own shortcut
  registry, so a rebuild re-registers cleanly).
- State that lives outside the UI (song, undo history, `com.session.state`
  including the cursor's `seqPos`) carries over by itself. The UI-owned view
  state is copied explicitly: active window, Sound Editor, oscilloscope,
  visualisation mode, and the file dialogs' directories and names.
- Cursor offsets are stored relative to an anchor that depends on the sequencer
  height, so they are re-anchored before the new sequencer is built.
- A window larger than the largest layout shows the grid centred (renderer
  viewport; `Video.rect` keeps the offset for mouse mapping).

The same change places a new window inside the display's usable area (no
menu bar or Dock overlap) and sizes the default window from that area.

## Consequences

- Fullscreen uses the screen with crisp text; leaving it restores the window layout.
- Open dialogs close on a size change, and the view re-centres on the cursor row.
- Undo entries keep references to the old UI's windows. Their data restore
  works (the song is global); `tests/test_window_fit.py` locks that down.
- New UI-owned view state that should survive fullscreen must be added to
  `UI.takeViewState` / `restoreViewState`.
