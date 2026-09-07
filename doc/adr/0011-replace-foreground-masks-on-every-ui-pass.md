# 0011 — Replace foreground masks on every UI pass

**Status:** Accepted. Supersedes the mask-lifetime consequence of
[0010](0010-menu-overlays-are-the-topmost-layer.md); its foreground draw order remains.

## Context

Menus, tooltips, the command palette and dialogs append pixel masks to cover
graphs with the finished character grid. The classic editor does not clear the
graph draw-list, so repeated menu updates accumulated masks even after closing
the menu. Every rendered frame replayed the entire history.

Clearing all overlays during idle updates would erase retained Sound Editor
graphs, because those updates can run without an audio tick or graph redraw.

## Decision

At the end of both `UI.timerEvent()` and `UI.update()`, replace the foreground
masks with the currently visible menu, tooltip, palette and dialog rectangles.
`Video.olClearMasks()` removes only masks, preserves graph operations in order,
and requests a repaint when removing masks. `drawMenu()` paints character cells;
`updateOverlayMasks()` owns mask lifetime and runs after the content passes.

## Consequences

- Repeated idle updates have bounded overlay work.
- Closing foreground windows removes their masks without losing graph content.
- Screenshots retain the same current overlay list as normal frame rendering.
- `tests/test_overlay_lifetime.py` checks idle accumulation, close, palette and
  dialog lifetime, and preservation of Sound Editor graphs.
