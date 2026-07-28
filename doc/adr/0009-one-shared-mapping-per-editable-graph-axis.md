# 0009 — An editable graph axis has exactly one shared value↔pixel mapping, latched for a drag

**Status:** Accepted

## Context

The Sound Editor draws instrument data as graph bands you can edit by dragging. Every
such band needs two directions of the same mapping: one to *place* a value on screen,
one to turn a mouse position *back* into a value. Both were written separately, and
they disagreed — repeatedly, in three different bands.

What that cost, measured with the `pitchprobe` oracle (`ccdriver`), on the frequency
band alone:

- The band was drawn on an **auto-fitted** vertical scale (`max(12, peak semitone)`)
  while the drag hit-test used a **fixed 0..$5F**. The value written was
  `$5F / scale` too large — **~8x** at the one-octave floor. The dragged block landed
  22px from the cursor and, because the axis then re-fitted to the new peak, every
  other block moved too.
- After that was unified, the axis still **re-fitted on mouse-up**, so releasing the
  button moved the block **-16px** (minimum window) / **-10px** (autoscale) with the
  mouse stationary. Repeated gestures felt like the block moved at its own pace.
- When the band was later redesigned as a **piano roll**, the hit-test was not updated
  with it: the draw used a fitted `[lo,hi]` absolute-note window (span 23–24) and an
  origin of `lo`, the hit-test still used 0..$5F over the whole band with no origin.
  That is **~4x** plus a wrong zero point.

The same class of bug existed in the sibling drags: pulse width / filter cutoff and
ADSR sustain read a cell *centre* rather than the mouse pixel, so a ~5-row-tall band
could express only ~5 of 4096 pulse widths, and 5 of 16 sustain levels (0, 4, 8, 13,
15 — a limitation the test suite had a comment working around rather than fixing).

The through-line: a value↔pixel mapping that is **derived twice** will drift, and an
axis **fitted to the data being edited** moves under the user's cursor as they edit.

## Decision

1. **One mapping object per editable axis.** The drawing code and the hit-test call
   the *same* function pair. For the Pitch band that is `PitchAxis.yOf` / `.noteAt`
   (`src/ui/soundedit.d`); the draw path fits it once per frame and the drag inverts
   that same instance. Deriving the inverse separately is the defect, not the fix.
2. **Latch the axis for the duration of a gesture.** A fitted axis depends on the
   content being edited (and, for the piano roll, on the played note, which keyjam can
   change mid-drag). It is frozen on button-down and released on button-up, so an edit
   can never move the axis it is measured against.
3. **Continuous drags read the exact mouse pixel, not the cell.** SDL mouse input
   reaches the UI as character cells, which is far too coarse for a band a few rows
   tall. `com.fb.mousePixelX/Y` publish the letterbox- and scale-corrected pixel and
   `dragPixelY()` uses it, falling back to the cell centre when there is no pixel for
   the event (synthetic clicks from `ccdriver`/tests).
4. **Mouse input is converted from window points to renderer pixels.**
   `Video.scalePosition` had its scaling commented out; on a HiDPI or stretched
   surface the pointer and the graphics move at different rates. It now derives the
   factor from the live SDL sizes, and reports the geometry once at startup.

## Consequences

- The contract is testable as a user-visible property rather than as arithmetic:
  `tests/test_sound_editor_drag_precision.py` asserts the drawn cell stays within half
  a value-step of the cursor, across two window geometries, and that mouse-up does not
  move it. Magnitude expectations were deliberately *removed* from three older tests —
  pinning them is what let the original mismatch hide.
- Because the axis is latched per gesture and re-fits on release, and the window snaps
  to whole octaves, releasing can still shift a cell by **under one semitone step**.
  The authored value does not change. Holding the axis until the instrument changes
  would remove even that, at the cost of a view that no longer follows its content.
- A relative wave row stores an **unsigned** offset (`$00..$5F`), so no note below the
  played-note reference line is representable and dragging there clamps to `$00`. That
  is the file format, not the mapping; only absolute rows (`$80..$DF`) sit below it.
- Bands whose sweep values *deliberately* compensate for cell granularity
  (`sweepUnwrappedValueForCell`'s rail logic, used for ramp winding) were left alone.
  Converting them means redesigning that compensation — a separate decision.
- Diagnosing this needed oracles, not screenshots: `pitchprobe`,
  `presspx`/`movepx`/`releasepx` (so state can be read *mid*-gesture) and
  `screen:COLSxROWS` (the driver previously only ever ran at the 160x50 layout
  minimum, so no test had exercised a real autoscaled window).
