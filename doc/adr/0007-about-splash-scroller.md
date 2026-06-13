# 0007 — About-splash scroller renders directly over the SDL renderer

**Status:** Accepted

## Context

We wanted a classic demo-style horizontal scroller on the Help → About splash
(`F11` / `Alt-S`): arbitrary-length text, scrolling right-to-left, the same width
as the splash and scaled the same way, light gray by default but with inline C64
color changes.

The splash is special-cased in the renderer: while `splashActive`, `updateFrame`
calls `VideoStandard.drawSplash` (`src/com/fb.d`), which blits the 320×200
indexed artwork as one texture at `SPLASH_SCALE` and `SDL_RenderPresent`s it — it
does **not** go through the `Screen` character-cell grid that the rest of the UI
uses. The editor's text grid is also fixed at the 8×14 `font.psf` cell, with no
sub-cell positioning, so it cannot express a pixel-smooth horizontal scroll.

## Decision

Render the scroller directly onto the SDL renderer inside `drawSplash`, in
between the artwork `SDL_RenderCopy` and the `SDL_RenderPresent`, rather than via
the `Screen` grid:

- **Own font.** A second font, `scrollfont`, is loaded from `src/font/petscii.psf`
  — a PSF1 **8×8** PETSCII face — alongside the editor's 8×14 `font.psf`, using the
  same loader pattern (4-byte header skip, MSB-left rows) at an 8-byte stride. The
  build already string-imports `src/font` (`-J./src/font`), so no Makefile change.
- **Layout once, scroll by pixels.** The message (`scrollText`) is expanded once
  into one `SCell{glyph,color}` per drawn glyph; a control byte `0x00..0x0f` is
  consumed as a color change (→ `PALETTE[0..15]`, the 16 C64 colors; the initial
  color is `SCROLL_DEFAULT_COL`) and occupies no width. A floating `scrollX` (font-space px) advances
  by wall-clock time (`SDL_GetTicks`) so the speed is frame-rate independent
  (`SCROLL_SPEED = 50` px/s = one scaled pixel per 50 Hz tick), and wraps when it
  passes the end. A frame gap > 500 ms is read as a fresh open: `scrollX` restarts
  off the right edge (this also avoids a huge first-frame jump from a stale
  timestamp). Glyphs are drawn as `SPLASH_SCALE`-sized fill rects, clipped to a
  band the width of the splash so partial glyphs cut cleanly at both edges.
- **Only on the user-opened About, not the startup splash.** Both share the same
  `splashActive`/`drawSplash` path and the same `AboutDialog` instance, so a
  second `Video.splashScroll` flag gates the scroller: `AboutDialog.withScroller`
  (set by the `F11`/`Alt-S` handler, cleared on deactivate) drives it in
  `activate()`; the startup activation leaves it false, showing the artwork only.
- **Placed in the black margin just below the artwork**, not overlaid on the
  bottom rows of the image: the splash artwork already has static credits baked
  into its bottom rows, so an overlay there collides with them.

## Consequences

- The scroller reuses the existing splash render path and palette; no `Screen`
  grid, no new event loop, no new shortcut — `drawSplash` already runs every frame
  while the About dialog is open, and any unmodified key still dismisses it.
- A separate 8×8 font asset now ships and is loaded at startup. Only the scroller
  uses it; the editor UI is unaffected.
- Because advance is wall-clock based *and* a > 500 ms frame gap restarts it,
  headless driver shots must render frames at < 500 ms spacing while wall-clock
  time passes (e.g. repeated `sleep:200` + `frames:1`) to see the scroller move;
  the real main loop renders every ~40 ms (`SDL_Delay(40)` in `mainloop`), so it
  animates continuously there.
- The default text and its color codes live in `scrollText` in `src/com/fb.d`;
  changing the message is a one-line edit there (the version is interpolated from
  `APP_VERSION`).
