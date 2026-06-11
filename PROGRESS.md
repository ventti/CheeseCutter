# PROGRESS — feat/selection (loop-engineering state)

Durable loop memory. The model forgets; this file doesn't. Update at the end of
every iteration. Plan: `~/.claude/plans/stateful-gathering-lovelace.md`.

- **Goal:** mouse-drag + keyboard selection and copy/cut/paste/merge/paste-new for
  the sequencer note column (F6) and track column (F5).
- **Tier:** 2 (multi-file cross-module feature; phases sequential, not parallel).
- **Swarm:** inline implement → `general-purpose` verifier subagent (separate grader)
  → fix loop; behavioral verify via run-cheesecutter (`./ccdriver`).
- **Worktree:** `.claude/worktrees/feat-selection` · **branch:** `feat/selection` off `develop`.
- **Build gate:** `make -f Makefile.mac LIBSPATH=/opt/homebrew/lib` (run `clean` first after base-class/asset change).
- **Iteration budget:** 6 per phase; escalate to user after ~2 unproductive iterations on a sub-task.

## Final done condition
All four phases `verified`; final full build + end-to-end ccdriver verify pass;
docs regenerated; PR opened; human review requested.

---

## Phase 0 — scaffolding
- [x] worktree + branch created
- [x] baseline `make -f Makefile.mac LIBSPATH=/opt/homebrew/lib` succeeds (exit 0, ccutter+ccdriver built)
- status: **verified**

Key facts learned:
- Build: `make -f Makefile.mac LIBSPATH=/opt/homebrew/lib` (+`ccdriver` target). ~20s.
- Driver: `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ./ccdriver load:<ct> key:<spec> click:cx,cy[,btn[,clicks]] shot:f.bmp state serve`. `key:` supports `Ctrl-`/`Shift-`/`Alt-` prefixes. No drag/button-up command yet → Phase 2 will add one.
- Dispatch: `UI.keypress` calls `sm.handleKeypress` FIRST; registry callbacks re-dispatch via `invokeKey`→`toplevel.keypress` (bypasses sm, no recursion). So widget-level key handling works pre-registration; Phase-4 registration is additive.
- Selection coords: note-column absRow(rowIdx) = `voices[v].pos.rowCounter + rowIdx - anchor` (mirrors renderVisualization, seqtable.d:296). Cursor absRow = `activeVoice.pos.rowCounter + posTable.pointerOffset`.

## Phase 1 — selection engine + note-column (F6) hooks
Stopping condition: builds; Ctrl+B/Ctrl+Shift+B build a selection; highlight renders;
Ctrl+C→Ctrl+V overwrites within sequence (overflow dropped); Ctrl+X blanks keeping
row count; Ctrl+Shift+V fills only empties; Ctrl+Shift+N paste-new; Ctrl+D clears;
Ctrl+Z undoes each; verifier reports clean.
- status: **VERIFIED** (independent verifier: PHASE 1 PASS, all 9 conditions, no blocking findings) · iterations: 1

Independent verifier confirmed (byte-level seqdump/tracks + screenshots): build clean;
markers+highlight+clear; copy/paste-overwrite exact; overflow drop at seq end; cut blanks
keeping rows=64; merge fills empty-only; paste-new inserts track + sized new seq (multi-voice
allocates distinct seqs); undo+redo byte-restore; multi-voice via Alt+1/2/3 (NOT Tab — Tab is
global window switch) routes per-column correctly.
Post-verify tweak applied + rebuilt + re-checked: Ctrl+Shift+V / Ctrl+Shift+N now fall through
(don't swallow) when clipboard empty/wrong-kind.
Non-blocking deferred: copySel zero-fills out-of-range cells (only if selection runs past song data).

Implemented: `src/com/selection.d` (Selection struct + ClipBlock + global rowClip);
VoiceTable engine (sel field, verbs, mouse hooks, handleSelectionKey, renderSelection)
in sequencer.d; note-column hooks + block undo (snapshot all seqs+tracklists) in
seqtable.d; `selectionBarColor=5`; Makefile.objects.mk += selection.o.
Driver oracle added: `seqdump:<n>` (hex, accepts 0x) + `tracks` in driver.d.

Author self-check (clean build + ccdriver): selection highlight renders (4 rows/1 voice,
status line correct); copy rows0-3 of seq0x11 → paste at row10 overwrote EXACTLY rows
10-13 with the block (4 rows, nothing else); Ctrl-Z restored byte-identical. Overwrite +
undo are byte-perfect.

GOTCHAS for verifier:
- Driver swallows the FIRST injected key after `load:` — always prime with a key
  (e.g. `key:F6`) before the real sequence.
- `make ccdriver` does NOT recompile driver.d when only driver.d changed (it's not a
  prereq of the target) → `rm -f ccdriver .claude/skills/run-cheesecutter/driver.o` first.
- After a base-class (VoiceTable/sequencer.d) change, `make -f Makefile.mac clean` first.
- Oracle: `seqdump:0x11` dumps seq bytes (4/row); `tracks` dumps each voice's tracklist.
  Voice0's first seq is 0x11 (64 rows) in tunes/abaddon-starfish.ct.
- Not yet independently verified: overflow-drop at seq end, Ctrl+X blank-keeps-count,
  Ctrl+Shift+V merge-empty-only, Ctrl+Shift+N paste-new (insert track + sized new seq),
  multi-voice parallel selection, Ctrl+D clear.

## Phase 2 — mouse drag plumbing
Stopping condition: builds; left-drag (single + multi-voice) builds same selection as
keyboard markers; plain left-click clears + positions; button-up finalizes; verifier clean.
- status: **VERIFIED** (independent verifier: PHASE 2 PASS, all 7 conditions, no blocking findings) · iterations: 1

Verifier confirmed: build clean; single + multi-voice drag select rectangles; drag-select payload
byte-identical to keyboard-marker path; multi-voice paste routes each column to its own sequence
(no cross-contamination); plain click clears selection + positions cursor; button-up finalizes;
keyboard Phase-1 flows regression-free; F5/trackmap drag is a safe no-op. Non-blocking only:
MOUSEMOTION uses evt.motion vs SDL_GetMouseState elsewhere (equivalent); theoretical dialog-opens-
mid-drag leaves dragging=true (unreachable without a mid-drag key event).

Implemented: Window base gained no-op `draggedTo`/`releasedAt` (ui.d); UI.draggedTo/releasedAt
route to toplevel (guard dialog/menubar); WindowSwitcher forwards to activeWindow; Sequencer
clickedAt now `beginDragAtCursor()` on left button, plus draggedTo/releasedAt overrides;
VoiceTable gained beginDragAtCursor/dragToRow/screenRowToAbs; main.d handles SDL_MOUSEBUTTONUP
and SDL_MOUSEMOTION(LMASK held). Driver: added `drag:x1,y1,x2,y2`; `click:` now also sends
button-up (full gesture).

Author self-check: drag 8,26→8,29 highlights voice0 rows 1-4; drag 8,26→34,29 highlights
rows 1-4 across all 3 voices (rectangular). Drag-select rows1-4 → copy → paste at row20 gave
seq0x11 rows 20-23 == the dragged block (byte-perfect, matches keyboard path).

KEY DESIGN NOTE: drag anchor = cursor position the click just set (`beginDragAtCursor`/activeRowAbs),
so anchor + drag-motion share one scroll frame (an earlier attempt anchored via stale post-scroll
screen-y and selected rows above the data). No auto-scroll while dragging past screen edges (clamped).
Not yet independently verified: plain-click clears selection, multi-voice PASTE routing via mouse,
button-up finalize semantics, code review of the mouse plumbing.

## Phase 3 — track column (F5) hooks + no-selection fallback
Stopping condition: builds; F5 select/copy/cut/paste/merge/paste-new work; no-selection
Ctrl+C/Ctrl+V keep the legacy number-prompt behavior; verifier clean.
- status: **open** · iterations: 0

## Phase 4 — shortcuts registry + docs + version
Stopping condition: `make docs` regenerates man pages/`doc/KEYBOARD.md` with new keys;
F12 help lists them; guide/README.md + README.md + Version updated; verifier confirms docs match code.
- status: **open** · iterations: 0

---

## Log
- (init) worktree created off develop @ 0d31149; PROGRESS.md written; baseline build pending.
