# FIXME — Sound Editor code review findings

Source: automated code review (`/code-review high`) of `git diff master...HEAD -- src/ui/`
on branch `feat/sound-editor` at `c443a33` — 13 files, +6842/−42, dominated by the new
6195-line `src/ui/soundedit.d`.

Date: 2026-07-27.

**Status: mostly unverified.** Items 1–7 are review findings, not reproduced bugs — nobody has
run those repros or touched the code. Confirm each before fixing. Item 8 is user-reported from
actual use and its mechanism is confirmed by code analysis (arithmetic traced, not yet run).
Line numbers are as of `c443a33` and will drift.

---

## High

### [x] 8. FIXED — Pitch-band drag: value written was ~8x the value drawn
`src/ui/soundedit.d:2331` (hit-test) vs `src/ui/soundedit.d:4472` (draw)

**Fixed 2026-07-27** (uncommitted). All three defects below addressed:

1. Draw and hit-test now share one mapping — `freqBandScale` / `yForPitch` / `pitchForY`
   in `src/ui/soundedit.d`. The scale is latched in `waveGraphScale` for the duration of a
   drag so the axis cannot re-fit under the cursor, and released in `releasedAt`.
2. `drawFreqBand`'s recording branch now also draws the authored staircase
   (`drawAuthoredPitchStaircase`) on the editable mapping, so the blocks being dragged are
   visible and hit-testable in that view instead of only the unrelated log2-Hz trace.
3. Sub-cell precision: `com.fb.mousePixelX/Y` publish the letterbox-corrected mouse
   position in grid pixels (set by `publishMousePixel` in `src/main.d`); the pitch drag
   reads it via `pitchDragPixelY`, which falls back to the cell centre when the pixel does
   not correspond to the dispatched cell (synthetic/driver clicks). Measured: 41 distinct
   values across 3 character cells, where cell granularity allowed at most 3.

Verified: clean build of all three targets, full suite green (119 passed / 257 subtests).
New regression tests in `tests/test_sound_editor_wave_gestures.py` —
`test_pitch_drag_value_tracks_the_bands_auto_fit_scale` (the ratio property the bug broke)
and `test_pitch_drag_resolves_below_one_character_cell`. Two existing tests
(`test_relative_absolute_and_carry_rows_use_pitch_only_vertical_drag`,
`test_pitch_program_structure`) had expectations baked against the buggy fixed-$5F axis and
were updated to the correct values with a comment explaining why. `ccdriver` gained
`dragpx:` for pixel-precise drags (documented in the run-cheesecutter skill).

**Still open from this item:** the sibling drags noted at the end still reconstruct cell
centres and were left alone — see the last paragraph.

<details><summary>Original diagnosis</summary>

Reported symptom: in pitch edit mode the pitch blocks do not follow the mouse — there is an
offset and/or scaling error mapping mouse position to the widget. Confirmed: the draw and
hit-test use **different vertical scales**, so they are not inverses of each other.

**Draw** — `drawFreqBand` (4466–4472) auto-fits the band to the data:

```d
int scale = 12;
foreach(f; 0 .. n) if(s.transOf[f] > scale) scale = s.transOf[f];
int y = botPx - pv * h / scale;
```

**Hit-test** — `updateWaveGraphDragRaw` (2328–2331) assumes a fixed full-scale band:

```d
int py = y * FONT_Y + FONT_Y / 2;
int pitch = clampInt(cast(int)lround(cast(double)(botPx - py) * 0x5f / h), 0, 0x5f);
```

`0x5f` occurs *nowhere else* in the file — the drawing side never uses it. The two agree only
when `scale == 0x5f == 95`. For a typical arp (`scale == 12`) the written value is
**0x5f/12 ≈ 7.9x too large**; grabbing a block and dropping it one third up the band writes
~32 semitones instead of ~4.

Worse, `scale` is recomputed from the data each frame, so writing a larger value *rescales the
whole band* on the next redraw — the block moves away from the cursor and every other block in
the program jumps too. That feedback loop is likely what reads as "doesn't follow the mouse".

Three separate defects here, in order of severity:

1. **Scale mismatch (dominant).** Fixed `0x5f` hit-test vs auto-fitted `scale` draw. Fix: share
   one value↔pixel mapping between draw and hit-test — extract a `pitchForY()` /
   `yForPitch()` pair off the *same* `scale`, and hold `scale` fixed for the duration of a drag
   so the axis can't move under the cursor.
2. **`useRec` path is not even linear.** When a recorded note is showing, `drawFreqBand`
   (4431–4446) plots `log2(freq)` auto-fitted to the recorded min/max, while the hit-test stays
   linear in semitones. No offset/scale constant can reconcile those — the shared mapping in
   (1) has to cover this branch too.
3. **Half-cell offset + coarse quantization.** Mouse coords are cell-granular
   (`src/main.d:185` does `y / FONT_Y`; see the note at soundedit.d:280), and the hit-test
   reconstructs a pixel as the cell *centre* (`+ FONT_Y / 2`), a constant ~7px downward bias
   against the exactly-placed drawn line. At the 160x50 minimum window the pitch band is only
   **67px ≈ 4.8 character rows** tall, so a drag has just **4 distinct mouse positions** across
   the whole band and one cell step moves the value by **~20 of 96 units**. Even with the scale
   fixed, pitch is undraggable at any useful resolution. Consider tracking sub-cell pixel Y for
   drags (plumb raw `evt.motion.y` through alongside the cell coords) and/or giving the band
   more height.

</details>

### [x] 8c. FIXED — the axis re-fitted on release, so the block jumped away from the cursor

Reported 2026-07-27: "in the expanded view mode the blocks move in a different pace than my
mouse drag". Measured with a new `pitchprobe` oracle (drawn-block pixel vs mouse pixel) at
both the 160x50 layout minimum and a ~90-row autoscale grid:

- **Mid-drag tracking was already correct** after 8: `delta` stayed within ±2px and the
  block/mouse movement ratio averaged 1.0 at both geometries (the 0.87–1.25 spread is
  integer semitone rounding — one semitone is 0.9px at the minimum, 3.25px at autoscale).
- **The jump was at release**: the auto-fit axis re-fitted the moment the gesture ended.
  Lowering the row that *was* the program's peak collapsed the scale (48 → 12), moving the
  block **−16px at the minimum window and −10px at autoscale** with the mouse stationary.
  Repeated gestures therefore felt like the block moved at its own pace.

Fix: the axis no longer re-fits as a result of the edit. `freqScaleSticky` holds the fitted
scale for as long as the editor stays on one instrument and only ever **grows** (so a value
raised above the top stays visible); it re-fits when the instrument changes or
`beginSession()` runs. Release jump measured **0px** at both geometries afterwards. A side
benefit: the axis now holds the program's true peak instead of collapsing, so steps are
finer (0.54px/semitone at the minimum).

Also fixed a latent trap this exposed: the driver was hardcoded to `new Screen(160, 50)`,
the layout **minimum**, so nothing in the suite had ever exercised the geometry the real
autoscaled app uses. `ccdriver` gained `screen:COLSxROWS`, plus `presspx`/`movepx`/
`releasepx` (mid-gesture oracles) and `pitchprobe`.

Tests: `SoundEditorPitchTrackingTests.test_dragged_block_follows_the_cursor` in
`tests/test_sound_editor_drag_precision.py` asserts |delta| ≤ half a semitone step during
the drag and a 0px jump on release, parametrized over both geometries. Three tests that
pinned drag *magnitudes* (`test_relative_absolute_and_carry_rows_use_pitch_only_vertical_drag`,
`test_pitch_program_structure`, and the ratio test added in 8) now assert the encoding-class
and W2-untouched contracts instead — the magnitude depends on the axis policy and pinning it
is what let the original bug hide. Clean build + full suite green (122 passed / 259 subtests).

**Known consequence of the policy:** after lowering a program's peak the axis stays zoomed
out until you switch instruments or re-enter the editor. That is deliberate — an axis that
shrinks in response to your own edit is what caused the jump. If a shrink-on-demand control
is wanted, the natural home is the existing `se_fit` action.

### [x] 8b. FIXED — sibling drags: same cell-granularity defect, no scale mismatches

Investigated 2026-07-27, after item 8. **Good news: the pitch band was the only place where
the draw and hit-test disagreed.** Every sibling mapping checked is already a proper inverse
pair — `adsrHandlePositions` is explicitly shared by drawer and hit-test, `filterCutoffY` ↔
`filterCutoffValue` match, and `drawValueBand` ↔ `sweepLevelDragUpdate` match. So defect 1
was unique to the frequency band.

Defect 3 (cell-granular quantization) was real in two more continuous-value drags, and both
are fixed by reading the exact pixel via `dragPixelY` (renamed from `pitchDragPixelY`, now
shared by all three):

- **`sweepLevelDragUpdate`** — pulse width (0..4095, step 16) and filter cutoff (0..2047)
  off a ~5-row band, i.e. ~745 pulse units per cell step. Measured 3 → 24 distinct levels.
  Added `filterCutoffValueAtPixel`; the cell-based `filterCutoffValue` now delegates to it,
  so its other (correctly cell-snapped) callers are untouched.
- **`adsrDragUpdate`** — sustain level, both via the `ADSR_SUSTAIN` handle and the
  `ADSR_DECAY` handle's Y component. Measured **5 of 16** levels reachable (0, 4, 8, 13, 15)
  → **all 16**. `tests/test_sound_editor_master_usage.py` had a comment documenting that old
  limitation and worked around it with arrow keys; corrected to point at the new contract.

Regression tests: `tests/test_sound_editor_drag_precision.py` (pulse level resolution, all-16
sustain reachability). Clean build + full suite green (121 passed / 257 subtests).

**Deliberately NOT changed** — the sweep *winding/slope* family
(`sweepValueForCell`, `sweepUnwrappedValueForCell`, `sweepEndDragUpdate`). These still use
cell centres, but `sweepUnwrappedValueForCell` *intentionally* compensates for cell
granularity: it maps the reachable cell-centre range onto the value range via `railTop`/
`railBot` so the band's exact max/min stay reachable, and deliberately extrapolates past them
for ramp winding (see its comment). Converting it to pixels means redesigning that rail
compensation and re-baselining the winding tests — a separate, riskier change with its own
design decision to make. Left for a deliberate follow-up rather than folded in here.

### [ ] 1. Keyjam mode leaks into the classic editor when exiting during playback
`src/ui/toplevel.d:611`

`startSoundEditor()` sets `state.keyjamStatus = true` *directly* (toplevel.d:573/595), but
`stopSoundEditor()` restores it via `ui.enableKeyjamMode(prevKeyjamStatus)` — and
`UI.enableKeyjamMode` begins with `if(audio.player.isPlaying) return;` (`src/ui/ui.d:844`).

Repro: keyjam off → **F2** (play song) → **Ctrl-E** in → **Ctrl-E** out.

`state.keyjamStatus` stays `true`, so `Toplevel.keypress` (toplevel.d:360) routes *every* key
to `inputKeyjam` instead of `activeWindow` — note entry, hex entry and cursor keys in the
tracker are dead. `com.fb.keyjamBackground` was left `false`, so the usual blue tint gives the
user no clue why.

Fix: restore `state.keyjamStatus` / `keyjamBackground` unconditionally on exit rather than
through the playback-gated helper.

### [ ] 2. `HelpDialog` render clamp is an absolute screen row, so help pages truncate
`src/ui/dialogs.d:170`

`if(ypos >= 36) break;` compares against an absolute screen row, but `area.y` is dynamic:
`src/ui/keymap.d:61` builds the dialog as `helpdlg_height = 36`,
`helpdlg_y = screen.height/2 - 18`, and `src/main.d:83` guarantees
`screen.height >= DEFAULT_ROWS == 50` (autoscale computes `dm.h * 0.9 / FONT_Y`, so a 1440p
display yields ~92 rows).

- At the 50-row minimum, `area.y == 7`, rendering starts at `ypos == 9` and stops at 36 → only
  27 of the 31 lines of `HELPSOUNDEDITOR` page 2 appear (the "Ctrl-Shift-J / Insert",
  "Ctrl-Shift-D / Delete" and "Drag the loop grip" lines vanish).
- On a 92-row grid, `area.y == 28`, so only ~6 lines of *any* help page render.

Fix: bound should be `area.y + area.height - 1`.

---

## Medium

### [ ] 3. `simPulse` accepts row 0 and walks into a foreign program
`src/ui/soundedit.d:4973`

Guard is `if(startRow < 0 || startRow >= 0x40)`, whereas every sibling uses `<= 0`:
`simFilter` (5026), `pulseProgramExtent` (981), `sweepProgramRows` (2732),
`sweepCloseRow` (3177).

Pulse pointer `$00` means "no pulse program" — `drawRawData` prints `Pulse: EMPTY` for it, and
`createSweepProgram` comments that "row 0 is the player's inert/stop sentinel". With
`ptr == 0`, `simPulse(0)` emits one frame from the zeroed row 0, sees `b3 == 0`, falls through
to row 1, and then simulates *whatever program lives at row 1* — i.e. another instrument's
pulse sweep. `drawPulseBand` (4343: `else if(ptr < 0x80)`) and
`drawSweepLoopIndicatorsForInstrument` (5505: `if(pp < 0x80)`) both take that path, so
selecting a pulse-less instrument shows a phantom pulse staircase plus phantom LOOP/END
triangles belonging to a different sound.

### [ ] 4. Wave program starting at row 0 bypasses the copy-on-write fork
`src/ui/soundedit.d:1935`

`waveProgramRows` returns an all-false set for `startRow <= 0`, but row 0 *is* a legal wave
program start: `createNewIsolatedSound` (1983) allocates `base = song.tWave.seekTableEnd()`,
which returns `0` for an empty wave table, and `tWave.isValid(0)` is true (`getChunks` starts
chunk 0 at offset 0).

The editing path accepts it — `waveCloseRow` (1963) only rejects `start < 0`, so
`selectedWaveNormal` and `waveGraphRowAt` happily target rows `0..close`. But
`waveProgramShared(ins)` (1947) intersects the empty set and therefore always returns `false`,
so `authorizeWaveMutation` (2157) computes `makePrivate == false` and writes in place.

Consequence: two instruments both pointing at wave row 0 → dragging a pitch row, painting a
control-bit lane, Insert or Delete on one silently rewrites the other, with no fork and no
warning.

### [ ] 5. `doSweepRowOp` insert has no upper bound on the new row index
`src/ui/soundedit.d:3320`

`int nr = sel + 1;` with `sel == 0x3f` gives `nr == 0x40`, then
`ct.purge.pulseInsertRow(song, 0x40)` → `genericInsertRow` (`src/ct/purge.d:514`) trips
`assert(row < 64 && row >= 0)`, and line 3332 writes `t[nr*4 + 0]` = `t[256]` on a 256-byte
table.

`Makefile:72` builds releases with `--release --boundscheck=off`, so **in a release build both
are silent memory corruption rather than a clean abort.**

The `sweepTableFull()` pre-check in `sweepRowOp` only rejects a *non-empty* row `0x3f`; a
program that falls through into a zeroed row `0x3f` is reachable (`simPulse`/`simFilter` emit
`rowOf == 0x3f` for a `b3 == 0` chain out of `0x3e`, and clicking there sets
`selectedSweepRow = 0x3f`), and Insert there is unguarded. The filter logical-block branch 20
lines above *does* guard (`if(nr + 1 >= 0x40 ...) return;`) — the generic path just missed it.

### [ ] 6. `beginSession()` never clears the private keyjam's held-key set
`src/ui/soundedit.d:829`

`Toplevel.keyrelease` (toplevel.d:376) forwards releases to `activeWindow` only while
`soundEditorActive`; once you leave, releases go to the *global* `inputKeyjam`. Ctrl-E is
resolved by the shortcut registry before `Toplevel.keypress`, so:

Repro: hold a note key → **Ctrl-E** (exit) → release the key → **Ctrl-E** (re-enter).

The SoundEditor's own `InputKeyjam.heldKeys` still contains that keycode, and `beginSession()`
resets `keyjamChannel` / selection / linked-edit state but not the keyjam. `noteHeld()` is now
permanently true, so `retriggerIfSounding()` (1883) takes the
`inputKeyjam.retrigger(); renderKeyjamCapture(extent)` branch on *every* subsequent edit — a
phantom note fires and the capture is overwritten on each parameter change with no key held.

Fix: `beginSession()` should reset the held-key set (or `Toplevel` should forward the release
on exit).

---

## Low

### [ ] 7. ADSR handles can be placed outside the reachable viewport, ungrabbable
`src/ui/soundedit.d:2530`

`hf = [aF, aF+dF, sustMid, gateEnd+rF]` is unclamped, while `computeContentMax` (1036) caps
the pannable extent at `nominalGateFrames + rFmax` (its own `aF` / `dF` locals are computed and
never used).

With `AD == $FF` and the default 50-tick gate at multiplier 1: `aF ≈ 401`, `dF ≈ 1203`, so the
decay/sustain-level handle sits at frame ≈ 1604, but `contentMaxFrames == 50 + 1203 == 1253`
and `clampViewport` refuses to scroll past it → `frameInView(1604)` is false → `inView[1]` is
false in both `drawAdsrHandles` and `adsrHandleAt`, so that handle can never be drawn or
grabbed at any zoom.

Fix: either clamp `hf[]` into `[−prerollTicks, contentMaxFrames]`, or fold `aF + dF` into
`computeContentMax` (presumably what those two dead locals were for).

---

## Checked and cleared (non-findings)

Recorded so they don't get re-investigated:

- `string actionId = id.dup;` (`src/ui/keymap.d:560`) does compile — verified with `ldc2`;
  `dup` on `immutable(char)[]` yields `string`.
- `src/ui/ui.d:485` `if(dialog is handledDialog) closeDialog();` is correct — `activateDialog`
  already closes the predecessor.
- `src/ui/ui.d:966` `maskDialogOverlay` relies on `dialog.area` being current; the diff
  converted all four dialogs that previously drew a frame without assigning `area`, and
  `grep 'drawFrame(Rectangle('` now finds none left.
- `src/ui/statusbar.d`'s new 42-column reservation is safe — `src/main.d:82` floors
  `screen.width` at `DEFAULT_COLUMNS == 160`, so `rightEdge()` always sits right of the
  column-55 clear done by `cycle_visualization`.
- `x+8+21+i*3` → `x+29+i*3` in the extracted `drawRegisterStatus` is an arithmetic no-op.
