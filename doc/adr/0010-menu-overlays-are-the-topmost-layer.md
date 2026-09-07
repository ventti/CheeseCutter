# 0010 — Menu bar, dropdown and command palette are the topmost layer

**Status:** Accepted. Amends the draw-order clause of
[0008](0008-oscilloscope-overlay-non-modal.md) (which said the oscilloscope is
drawn last); the rest of 0008 stands.

## Context

The editor has no z-order concept. Everything paints into one shared character
grid (`com.fb.Screen`), plus two pixel layers composited after it in
`Video.renderGrid()`: the oscilloscope trace (`drawScopeTrace`, `src/com/fb.d:710`)
and the immediate-mode overlay draw-list (`drawOverlay`, `src/com/fb.d:711`).
"Above" therefore means only one thing: painted later in the frame.

Two passes ran after the menu bar had already drawn and so erased an open
dropdown or command palette:

- **The playback ADSR row tint** (`SequenceTable.renderVisualization`), which
  recolours every track-column cell whose background is still 0 — including the
  cells a dropdown occupies.
- **The oscilloscope** (`drawScope`), which 0008 deliberately put last. Its
  window is centred on screen (`UI.this`, `scope_x/scope_y`), exactly where a
  dropdown hanging down from row 1 reaches, and its `update()` paints a frame and
  title into the grid before setting the pixel trace.

Both overlays are non-modal and stay open while the song plays, so this is the
normal case, not a corner one. Dialogs were already safe: the tint is skipped
while `dialog !is null`, and `drawScope` suppresses itself the same way.

## Decision

The menu bar, its dropdown, the hover tooltip and the command palette are the
**topmost layer**. `drawMenu()` is called last in `UI.timerEvent()` — after both
the tint and `drawScope()` — and, in `UI.update()`, after `drawScope()`.

Ordering the *grid* is only half of it: the scope's trace is a pixel layer
composited after the whole grid, so painting the dropdown later cannot cover it.
The existing mask machinery closes that half — `drawMenu()` re-emits
`menubar.maskOverlay()` / `palette.maskOverlay()`, whose `Video.olMaskRect` ops
re-render the covered cells from the grid *after* the trace, because
`drawOverlay()` runs after `drawScopeTrace()` in `renderGrid()`. Calling
`drawMenu()` every frame is what keeps that mask alive while a menu is open.

Alternatives rejected:

- **Suppress the scope while a menu is open** (the rule 0008 uses for dialogs).
  One line, but it blanks a live trace to open an unrelated menu, and it answers
  a z-order question by removing the loser rather than ordering the two.
- **Clip the tint / scope to a rectangle excluding the overlay.** Real clipping
  in a grid with no layer model means every future overlay teaches every future
  painter about itself.

## Consequences

- A dropdown or palette opened over the scope or over tinted track rows stays
  fully readable; the scope keeps running and animating underneath.
- The rule is "re-assert the top layer last", not "each painter avoids the top
  layer". It costs one extra `drawMenu()` per timer tick (a bar repaint plus
  early-outs when nothing is open) and, in exchange, no future painter has to
  know that menus exist. Any *new* pass added after `drawMenu()` re-introduces
  the bug — the invariant lives in `UI.timerEvent`/`UI.update` alone.
- `olMaskRect` ops accumulate in the draw-list while a menu is open, because only
  the Sound Editor calls `olClear()` per frame; the classic view never does. It
  is bounded by how long a menu stays open and costs a re-render per frame, but
  it is a latent wart this decision leans on rather than fixes.
- The Sound Editor is unaffected: it forces keyjam on
  (`toplevel.startSoundEditor`, `src/ui/toplevel.d:591`), and the keyjam branch
  draws no tint at all.
