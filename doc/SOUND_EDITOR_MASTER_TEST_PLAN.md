# Sound Editor master usability test plan

## Final executable contract

This is the executable plan and acceptance contract. The terminology, requirements,
fixture, byte oracles and ordered sequence are executed by
`test_master_sound_creation_sequence` in one uninterrupted headless session; the
ownership sequence in section 5.1 is an additional uninterrupted usage test.

Status (2026-07-16): the uninterrupted 34-step master and complete focused ownership
matrix pass; `mise run test` passes all 115 discovered tests with no expected failures.

## 1. Fixed terminology

1. A **player tick** is one sound-player call and one recorded graph sample. Pulse and
   filter state are evaluated on each tick, while wave rows advance according to the
   instrument wave speed and per-row delay bytes. The UI shall call this a **Tick**,
   not a video frame.
2. A **track row** is a musical duration of
   `(effectiveSpeed + 1) * callsPerFrameMultiplier` player ticks.
3. The deterministic fixture uses effective speed `4` and multiplier `2`, so one
   track row is exactly `10` ticks.
4. **Rows** and **Ticks** are separate, first-class duration units. The UI and tests
   must always state the active unit; they must never silently conflate the two.
5. **Fixed sustain duration** means the keyjam SID gate remains high for the configured
   duration. It does not mean time measured only after the SID envelope reaches its
   Sustain phase.
6. **Keyjam channel** means SID voice 1, 2, or 3. It is not a stereo channel.
7. **Last-note baseline** means the last successfully keyjammed note used for silent
   reSID rerendering after an edit. Before any note has been played, it is C-4.
8. A **logical filter block** is one CONFIG row and the following SWEEP row. Adding or
   deleting such a block must keep those two rows together.
9. **WYSIWYG** means the vivid graph samples shown after a keyjam or completed edit
   are the same discrete reSID-recorded values used by the automated oracle, mapped
   onto the shared axis with only deterministic pixel rounding.
10. `W0`, `P0`, and `F0` below are the wave, pulse, and filter start rows allocated for
    the new test sound. Assertions use these discovered row addresses rather than
    assuming fixed global table positions.
11. In the fixed keyboard layout, at Octave 3 `q` is C-4 (internal note `48`) and
    `b` is G-3 (internal note `43`); at Octave 2 `x` is D-2 (internal note `26`).
    Restoring Octave 3 after D-2 must not replace D-2 as the last-note baseline.
12. **EMPTY** means an absent programme pointer or canonical sentinel owned by no live
    sound; unused instrument slots do not contribute owners, so a new empty song has
    nothing shared or used.
13. **Genuinely shared** means the same non-EMPTY programme is referenced by at least
    two live sounds. `Linked edits` is an explicit, visible mode for the current sound;
    it remains active until disabled, a programme is created/replaced, the instrument
    changes, or the Sound Editor session closes.

## 2. Preconditions and deterministic fixture

1. Run a single `ccdriver serve` process with dummy SDL video and audio drivers.
2. Use a dedicated disposable PAL song fixture with:
   - effective speed `4`;
   - calls-per-frame multiplier `2`;
   - reSID as the local emulation backend;
   - enough unused wave, pulse, and filter rows for every insertion;
   - a known current instrument slot that begins EMPTY, with no live Wave/Pulse/Filter
     owner and no sentinel counted as shared or used;
   - a 160-by-50 character viewport.
3. Work on a fresh in-memory fixture for each full test run; never modify a tune in
   the repository as test output.
4. Run the whole master scenario without reloading the fixture or restarting ccdriver.
5. Use ordinary UI keys, clicks, presses, moves, releases, and drags. Direct table
   mutation is forbidden; table dumps are read-only oracles.
6. Prefer semantic and byte assertions over platform-sensitive screenshot goldens.
   Pixel assertions must derive expected coordinates from the same visible viewport
   and recorded values rather than compare a whole image hash.

## 3. Added deterministic requirements

These extend the existing R03-R39 requirements.

Revised base requirements:

- **R25 — Empty direct creation:** An empty song has no shared/used programme. Its
  first Pulse or Filter graph drag shall allocate the minimal editable programme and
  apply that same gesture without a modal or second attempt. Converting a fixed Pulse
  value shall preserve the audible width before applying the drag. Creation plus edit
  is one undo transaction.
- **R36 — Non-modal ownership:** A mutation of a genuinely shared Wave/Pulse/Filter
  programme shall automatically fork only the active sound and then complete. Shared
  bytes may change only in visibly active, persistent `Linked edits` mode. Repeated
  gestures shall never prompt; capacity failure shall report through CheeseCutter's
  existing status/help mechanism and change nothing; one undo restores pointer and bytes.

1. **R40 — Explicit time units:** Duration controls shall support Rows and Ticks;
   switching the displayed unit shall not rewrite the program.
2. **R41 — Fixed keyjam gate duration:** A fixed gate-high duration shall be selectable
   in Rows or Ticks, and physical keypress length shall not change its gate-off tick.
3. **R42 — Predictable note baseline:** Before the first keyjam the baseline shall be
   C-4; afterward it shall be the last played note and survive edit rerenders.
4. **R43 — New sound creation:** A new isolated sound with editable wave, pulse, and
   filter programs shall be creatable from the Sound Editor.
5. **R44 — Wave structure editing:** Mouse-accessible controls shall insert, delete,
   retune, change control/delay bytes, and author `$7E` and `$7F` wave loop markers.
6. **R45 — Exact wave round-trip:** Graphical wave edits shall produce the exact paired
   wave-table bytes defined in section 4.
7. **R46 — Pulse block editing:** Mouse-accessible controls shall edit pulse start,
   slope/end, duration/unit, insertion, deletion, and loop target.
8. **R47 — Pulse wrap visibility:** Downward pulse ramps shall preserve and visibly
   show their modulo-`$1000` wrap count.
9. **R48 — Loop deletion contraction:** Deleting a block from a loop shall contract,
   never expand, the loop; removing the complete loop shall show End programme.
10. **R49 — Representability feedback:** If an endpoint is not exactly encodable, the
    editor shall show the resulting legal value and a clear clipping/quantisation cue.
11. **R50 — Keyjam channel:** The keyjam SID voice shall be selectable from 1-3 and
    shall default to voice 1 when the Sound Editor session opens.
12. **R51 — Filter block editing:** A logical filter block shall expose cutoff, slope,
    duration/unit, resonance, independent LP/BP/HP flags, and route mask.
13. **R52 — Exact filter round-trip:** Filter creation, adjustment, loop contraction,
    and deletion shall produce the exact CONFIG/SWEEP bytes in section 4.
14. **R53 — Filter routing audibility:** The same keyjam note shall produce measurably
    different reSID output when its selected voice is routed into versus out of an
    active filter; routing a different voice shall not filter the selected voice.
15. **R54 — reSID WYSIWYG:** Every completed edit shall silently rerender the current
    baseline when needed and display the actual reSID values without emitting preview
    audio outside an intentional keyjam.
16. **R55 — Three-note checkpoint audition:** Every mutation checkpoint shall keyjam
    C-4, G-3, and D-2 in that order and leave D-2 as the next edit's baseline.
17. **R56 — Stateful master regression:** One ordered master test shall exercise all
    checkpoints without reset and report the requirement and checkpoint on failure.
18. **R57 — Test task integration:** The master regression shall run under
    `mise run test`; R40-R72 shall have no skip or expected-failure marker.
19. **R58 — Filter response regions:** Each logical filter block shall use one absolute
    0..2047 cutoff axis: LP fills from cutoff to the bottom, BP draws a fixed one-third-
    height ribbon centred on cutoff and clamped to the band, and HP fills from the top to
    cutoff. Mode 00 is empty and combined flags draw the union. A single bright cutoff
    trace and one start/end handle retain the existing cutoff/slope/duration/offset-loop
    byte semantics; resonance must not change BP width.
20. **R59 — Discoverable equivalent controls:** Every contextual graph-row control and
    Filter LP/BP/HP/Rt control shall show its registry action and unique shortcut through
    CheeseCutter's existing Alt-H status-line help. Help shall expire normally without
    stationary-hover refresh, stay out of the left editor hint, and be suppressed behind
    menus/dialogs; shortcut and mouse routes shall remain behavior-equivalent.
21. **R60 — Axis-faithful programme resizing:** Dragging a Pulse or Filter right
    boundary shall choose the legal duration whose rendered boundary is nearest the
    pointer on the shared timeline (ties choose the shorter duration): Ticks permits
    1..128 ticks, Rows permits row-period multiples up to 128 ticks, and a row period
    above 128 falls back to 128 with a clamp cue; Fit, zoom, pan, endpoint
    recomputation, clipping feedback and one-gesture undo shall retain these semantics.
22. **R61 — Inward loop triangles:** Every authored Pulse or Filter loop shall show
    exactly one orange filled one-character-cell inward triangle pair (right-pointing
    at loop start and left-pointing at loop end), while a stopped multi-block programme
    shall show the right terminal grip; drawing, hit-testing, cursor and dragging shall
    share that geometry, either loop triangle shall edit the terminal jump, and slope
    dots plus the remaining duration boundary shall retain their existing priority.
    An off-view authored edge shall draw and hit nothing at the clamped plot rail.
23. **R62 — Bracket-free buttons:** Every on-canvas Sound Editor button or chip shall
    use a plain bracket-free label with one visible whitespace cell on each side in its
    hit/background region while preserving hover, pressed, active, disabled and
    release-off behaviour; LP/BP/HP/Route draw, debug and hit bounds shall be identical.
24. **R63 — Sound Editor menus:** In the Sound Editor the top menus shall be exactly
    File, Edit, View, Playback, Sound and Help; Sound shall contain New sound, Edit wave
    byte 1 and Edit wave byte 2 in that order from the shared action registry; classic-
    only or otherwise unusable commands shall be hidden or disabled through one enabled
    predicate shared by menus, keyboard and buttons, and ordinary menus shall return on exit.
25. **R64 — Logical command placement:** The graph control row shall keep a stable
    View group followed only by the selected Wave, Pulse, Filter SWEEP or Filter CONFIG
    action group in the canonical order in section 8, LP/BP/HP/Route shall stay beside
    Filter, and New/W1/W2 shall be available only from Sound and their shortcuts.
26. **R65 — Non-overlapping status help:** Help/status text shall clear and render only
    in the bounded area immediately left of the shared top-right SID-register column,
    clipped at that boundary, so display, timeout and long messages never alter
    or blink register glyphs or colours on rows 1..3; immediate menu/modal open, hover
    suppression and close refreshes shall preserve the same raw register cells.
27. **R66 — Layout-portable primaries:** Every Sound Editor command plus raw graph,
    octave and instrument operation shall have one unique semantic primary using only
    Ctrl/Shift with A-Z, 0-9 or PageUp/PageDown, reachable without AltGr, dead keys or
    an unmodified piano key on US/UK/DE/IT/ES/FI-SE/DK/NO layouts.
28. **R67 — Exact cross-platform dispatch:** Sound Editor primaries shall use no
    GUI/Super, Alt, Ctrl+Alt, Ctrl+Space or Ctrl+Arrow chord; an enabled primary fires
    exactly one Sound action, a disabled primary is consumed, AltGr/GUI variants fire
    none, raw modifiers match exactly, and leaving Sound Editor restores other contexts.
29. **R68 — Compact-keyboard completion:** Every operation shall be reachable without a
    keypad, Insert/Delete/Home/End cluster or layout punctuation; optional legacy
    navigation/keypad aliases shall follow the portable primary in generated help/docs.
30. **R69 — Row-aware Wave gestures:** A normal Wave pitch row shall drag vertically
    while preserving relative/absolute encoding; a `$01..$0F` delay shall drag
    horizontally and clamp to that range; target/end bytes shall not drag; bit painting
    shall preserve representation and remain idempotent. Effective `$E0..$FF` requests
    with no lossless W2 encoding shall show a cue and create no mutation, undo or rerender.
31. **R70 — Visible Wave row creation:** Every valid stopped or looped programme shall
    keep a trailing in-band `+` in a distinct top cell before its terminal triangle; it
    shall append before the terminal marker, support END-only programmes, hide graph
    creation UI for invalid or absent programmes, use `Sound > New sound` for replacement,
    disable safely at capacity, and undo once.
32. **R71 — Central non-modal Wave ownership:** Every Wave mutation route shall
    automatically copy-on-write when genuinely shared, repoint only the active sound,
    and combine fork plus edit into one undo transaction and one completed-edit rerender.
    Shared bytes shall change only while the explicit persistent `Linked edits` mode is
    visibly active. Multi-row bit paint shall apply initial and crossed rows idempotently
    with no drag-time rerender; capacity failure shall use status/help with no mutation.
33. **R72 — Wave END/LOOP triangles and extent:** Delay- and wave-speed-aware authored
    Wave timing shall position an 8×14 right triangle at loop start and left triangle at
    END/loop end; shared draw/hit geometry shall own only the exact top cell, off-view
    markers shall vanish, either grip shall retarget the simulated legal row owning an
    in-range pointer tick with one authorized undo, a drag beyond the authored span shall
    choose the nearest legal normal authored row, and short keyjam recordings or Fit shall
    not crop the authored Wave extent. Exact Pulse/Filter start and end triangles shall
    change only the terminal pointer with one undo. A fresh speed-0 END is frame 1 while
    Wave A remains frame 12 from its authored `$04` delay cadence, never a fixed tail constant.

## 4. Canonical byte oracles

All values are hexadecimal. Each interim dump and the classic table editor must match
these values exactly.

### 4.1 Instrument ADSR

1. First ADSR checkpoint: AD/SR = `88 88`.
2. Second ADSR checkpoint: AD/SR = `93 27`.

### 4.2 Wave checkpoint A

| Row | Wave 1 | Wave 2 |
|---|---:|---:|
| `W0+0` | `B0` | `81` |
| `W0+1` | `00` | `04` |
| `W0+2` | `02` | `41` |
| `W0+3` | `01` | `41` |
| `W0+4` | `00` | `41` |
| `W0+5` | `7E` | `00` |

### 4.3 Wave checkpoint B

| Row | Wave 1 | Wave 2 |
|---|---:|---:|
| `W0+0` | `C0` | `81` |
| `W0+1` | `00` | `02` |
| `W0+2` | `00` | `41` |
| `W0+3` | `00` | `0C` |
| `W0+4` | `0C` | `41` |
| `W0+5` | `00` | `0C` |
| `W0+6` | `7F` | `W0+2` |

The `$7F` target must be the absolute table row of the first `00/41` pair, not
the relative index `2` unless `W0` happens to be zero.

### 4.4 Pulse programme

With one row = 10 ticks, the initial three-block target is:

| Row | Byte 0 | Byte 1 | Byte 2 | Byte 3 | Meaning |
|---|---:|---:|---:|---:|---|
| `P0+0` | `27` | `66` | `00` | `00` | 40 ticks; rise from minimum toward maximum |
| `P0+1` | `CF` | `67` | `FF` | `00` | 80 ticks; descend through two modulo wraps |
| `P0+2` | `13` | `00` | `04` | `P0+1` | 20 ticks; fixed `$400`; loop to block 2 |

After changing only block 1 to four raw ticks:

| Row | Byte 0 | Byte 1 | Byte 2 | Byte 3 |
|---|---:|---:|---:|---:|
| `P0+0` | `03` | `FF` | `00` | `00` |
| `P0+1` | `CF` | `67` | `FF` | `00` |
| `P0+2` | `13` | `00` | `04` | `P0+1` |

The `$FF` slope is the legal clamp; the UI must not draw the old unattainable endpoint.

After deleting the second block, the former third block shifts and loops only itself:

| Row | Byte 0 | Byte 1 | Byte 2 | Byte 3 |
|---|---:|---:|---:|---:|
| `P0+0` | `03` | `FF` | `00` | `00` |
| `P0+1` | `13` | `00` | `04` | `P0+1` |

After deleting that remaining looped block, `P0+0` must be `03 FF 00 7F` and
the graph must show End programme.

Before all three blocks exist, the current last row must stop rather than fall through
into unused table data:

1. Block 1 alone: `P0+0 = 27 66 00 7F`.
2. Blocks 1-2: `P0+0 = 27 66 00 00`, `P0+1 = CF 67 FF 7F`.
3. Blocks 1-3 before looping: the first two byte-3 values are `00` and the third is
   `7F`; dragging the loop then changes only the third byte-3 to `P0+1`.

### 4.5 Filter programme

The initial three logical blocks are:

| Logical block | Row | Byte 0 | Byte 1 | Byte 2 | Byte 3 | Meaning |
|---|---|---:|---:|---:|---:|---|
| 1 CONFIG | `F0+0` | `90` | `31` | `20` | `00` | LP, resonance 3, mask 1, cutoff `$100` |
| 1 SWEEP | `F0+1` | `27` | `10` | `FF` | `00` | 40-tick rising sweep |
| 2 CONFIG | `F0+2` | `A0` | `80` | `FF` | `00` | BP, resonance 8, mask 0, inherited cutoff |
| 2 SWEEP | `F0+3` | `13` | `F8` | `FF` | `00` | 20-tick falling sweep |
| 3 CONFIG | `F0+4` | `C0` | `C7` | `FF` | `00` | HP, resonance C, mask 7, inherited cutoff |
| 3 SWEEP | `F0+5` | `09` | `04` | `FF` | `F0+2` | 10-tick rising sweep; loop to block 2 |

Route-mask edits must additionally exercise exact low-nibble values `00`, `01`, `02`,
`04`, and `07` without changing the resonance high nibble.

After changing logical block 1's SWEEP to four raw ticks, its row must be
`03 7F FF 00`; the slope clamp must be visible.

After deleting logical block 2, the exact compacted programme is:

| Logical block | Row | Byte 0 | Byte 1 | Byte 2 | Byte 3 |
|---|---|---:|---:|---:|---:|
| 1 CONFIG | `F0+0` | `90` | `31` | `20` | `00` |
| 1 SWEEP | `F0+1` | `03` | `7F` | `FF` | `00` |
| 3 CONFIG | `F0+2` | `C0` | `C7` | `FF` | `00` |
| 3 SWEEP | `F0+3` | `09` | `04` | `FF` | `F0+2` |

Deleting the remaining looped logical block must make `F0+1.b3 = 7F` and show
End programme.

Before all three logical blocks exist, the current last SWEEP row must stop:

1. Logical block 1 alone: CONFIG byte-3 is `00`; SWEEP byte-3 is `7F`.
2. Logical blocks 1-2: block 1 SWEEP byte-3 becomes `00`; block 2 SWEEP byte-3 is
   `7F`.
3. Logical blocks 1-3 before looping: block 2 SWEEP byte-3 becomes `00`; block 3
   SWEEP byte-3 is `7F`; dragging the loop then changes only block 3 SWEEP byte-3
   to `F0+2`.

## 5. Checkpoint assertion applied after every mutation

Each mutation checkpoint below must perform this complete sub-sequence before moving on:

1. Dump and compare the affected canonical bytes and pointers.
2. Assert the fixed-gate duration label states both its value and selected unit; when
   editing a pulse/filter block, assert that block's duration label as well.
3. Keyjam C-4, G-3, and D-2 in that order through the normal Sound Editor input path.
4. For each note, assert:
   - only the selected keyjam SID voice owns the new recording;
   - after any hard/soft-restart gate-low pre-roll, the contiguous gate-high duration
     is exactly 40 ticks, independent of physical keypress length;
   - recorded control, frequency, ADSR, pulse, cutoff, mode, resonance, and output
     come from reSID and agree with the displayed graph at sampled visible points;
   - the shared X-axis, tracker-row grid, and note-trigger origin remain aligned;
   - for drag mutations, no rerender occurs during the drag and exactly one occurs on
     mouse release; discrete button mutations rerender exactly once on completion.
5. After D-2, assert D-2 is the stored baseline.
6. Begin the next edit without another keyjam and assert its completed-gesture rerender
   uses D-2, changes the graph immediately, preserves the viewport, and emits no
   audible/remote note.
7. Record failures as `checkpoint N / requirement Rxx / expected / actual`.

### 5.1 Non-modal ownership usage sequence

Run these cases in order in one headless UI session, preserving state between numbered
steps except where a named deterministic fixture is loaded:

1. Load a new empty song and assert the current slot has absent/canonical sentinel
   Wave, Pulse and Filter state, zero live owners, and no `shared` or `used` label.
2. Enter Sound Editor and drag the empty Pulse band in one uninterrupted press/move/
   release gesture; assert no modal appears at any phase, the minimal programme is
   allocated, and the final value and duration correspond to the release position.
3. Undo once and assert the exact pre-gesture Pulse pointer, complete table bytes,
   EMPTY classification and undo depth are restored.
4. Repeat steps 2-3 on Filter, including canonical CONFIG+SWEEP allocation, the final
   cutoff/duration under the release point, modal absence and exact one-step undo.
5. Load the fixed-Pulse fixture, record its audible pulse width, begin a body drag and
   assert conversion starts from that same width, completes the original gesture, and
   undoes atomically without a modal.
6. Load two live sounds that genuinely share each non-EMPTY Wave, Pulse and Filter
   programme. For every programme kind, perform a representative drag in default mode;
   assert automatic copy-on-write changes only the active pointer/copy, leaves the other
   sound and original bytes exact, applies the release value, and opens no modal.
7. After each automatic fork, edit again and assert the private pointer is retained,
   no second allocation occurs, and no prompt appears.
8. Undo each first shared edit once and assert active pointer, allocated/free table
   extent, edited bytes, original bytes and the other sound all exactly match pre-edit.
9. Enable visible `Linked edits` mode for the current sound and perform two gestures
   for each programme kind; assert the mode remains visibly active, the shared pointer does not change, both
   referencing sounds observe the edits, and no default path can mutate those shared
   bytes while the mode is off.
10. Exercise every Wave mutation route (pitch, delay, control, exact byte, add, delete,
    loop and append) through the default-copy and linked-mode branches; exercise Pulse/
    Filter body, boundary, slope, add, delete and loop routes through the same branches.
11. Fill each destination table, attempt the corresponding automatic creation/fork,
    and assert a bounded non-modal message in the existing status/help area, zero byte/
    pointer/undo/rerender change, an intact graph and unchanged SID-register cells.

## 6. Ordered master usage sequence

1. Start the one stateful ccdriver server and load the clean fixture.
2. Assert PAL, speed 4, multiplier 2, row period 10 ticks, empty recording state,
   adequate table space, and the known isolated instrument.
3. Activate the Sound Editor through its user-facing shortcut.
4. Assert all six graph bands remain visible, default keyjam channel is voice 1, and
   the pre-keyjam baseline is C-4.
5. Select Rows and set fixed gate-high duration to 4 rows; assert the UI also resolves
   this to 40 ticks.
6. Prove keypress independence by rendering one C-4 released early and one held long;
   in both gate arrays, the first low tick after gate-on must occur exactly 40 ticks
   after the first gate-high tick (restart pre-roll is not part of the 40 ticks).
7. Create a new isolated sound in the current instrument slot; capture its private,
   nonzero `W0`, `P0`, and `F0` pointers and assert canonical stopped wave, pulse, and
   filter programs without changing any other instrument or existing program.
8. Drag the four ADSR handles to `88 88`; assert bytes, handles, one undo unit, and run
   the checkpoint assertion.
9. Create wave checkpoint A entirely with mouse-accessible graph controls; assert every
   pair in section 4.2 and run the checkpoint assertion.
10. Transform it into wave checkpoint B; assert insertion/deletion, every pair, and the
    absolute `$7F -> W0+2` loop target, then run the checkpoint assertion.
11. Drag ADSR to `93 27`; assert bytes and run the checkpoint assertion.
12. Select the preallocated pulse programme with the mouse; assert its canonical
    editable block and the current instrument's `P0` pointer.
13. Set pulse block 1 to 4 Rows, minimum start, and its approved rising slope; assert
    the sole-row stopped form `27 66 00 7F` and run the checkpoint assertion.
14. Add pulse block 2, set it to 8 Rows and the approved falling slope; assert
    block 1 now falls through, block 2 is `CF 67 FF 7F`, the recording contains two
    downward wraps, and run the checkpoint assertion.
15. Add pulse block 3, set it to 2 Rows at fixed `$400`; assert `13 00 04` and run the
    checkpoint assertion, with block 3 still stopped by `$7F`.
16. Drag the pulse loop target to block 2; assert byte-3 target `P0+1`, a clear loop
    region/grip, and run the checkpoint assertion.
17. Switch the selected duration to Ticks and shorten pulse block 1 to 4 Ticks; assert
    `03 FF 00 00`, visible clamp feedback, and run the checkpoint assertion.
18. Delete pulse block 2; assert the exact compacted rows, self-loop on the last block,
    no loop expansion, and run the checkpoint assertion.
19. Delete the remaining looped pulse block; assert `03 FF 00 7F` and End programme,
    then undo once and assert the prior two-row state is restored.
20. Select the preallocated filter programme with the mouse; assert canonical CONFIG+SWEEP block 1
    and the instrument's `F0` pointer.
21. Build filter logical block 1; assert `90 31 20 00 / 27 10 FF 7F`, LP-only state,
    and run the checkpoint assertion.
22. Add logical block 2; assert block 1 SWEEP now falls through and block 2 is
    `A0 80 FF 00 / 13 F8 FF 7F`, BP-only state, mask 0, then run the checkpoint.
23. Add logical block 3; assert block 2 SWEEP now falls through and block 3 is
    `C0 C7 FF 00 / 09 04 FF 7F`, HP-only state, mask 7, then run the checkpoint.
    Assert the three authored blocks expose LP/bottom, BP/middle and HP/top slope
    geometry through the deterministic lane oracle.
24. Drag the filter loop target to logical block 2; assert `F0+5.b3 = F0+2`, a clear
    loop region/grip, and run the checkpoint assertion.
25. Switch the first filter SWEEP duration to 4 Ticks; assert `03 7F FF 00`, visible
    clamp feedback, and run the checkpoint assertion.
26. Delete filter logical block 2 as one operation; assert both CONFIG and SWEEP were
    removed, the exact compacted programme, contracted self-loop, and checkpoint result.
27. Delete the remaining looped logical filter block; assert `F0+1.b3 = 7F` and End
    programme, then undo once and assert the prior four-row state is restored.
28. On keyjam channel 1, edit the surviving looped block's CONFIG mask and compare
    masks `00` and `01` with identical C-4 input in a stable window after that CONFIG
    has taken effect; only mask `01` may show the active filtered output signature.
29. Change keyjam channel to 2; compare masks `01` and `02`; only mask `02` may show
    the active filtered output signature.
30. Change keyjam channel to 3; compare masks `02` and `04`; only mask `04` may show
    the active filtered output signature.
31. Exercise mask `07` by auditioning the same note separately on all three keyjam
    channels; assert each is filtered and the CONFIG resonance high nibble remains C.
32. Return keyjam channel to 1, rerun the three-note checkpoint, and assert the final
    last-note baseline is D-2.
33. Exit to the classic editor and assert the complete instrument, wave, pulse, and
    filter byte state round-trips unchanged.
34. Exit ccdriver only after all ordered assertions have completed.

## 7. Master-test implementation constraints

1. Implement one named master test rather than independent tests that recreate partial
   state. Small helper assertions are allowed, but full reproduction must execute the
   complete ordered sequence.
2. Extend ccdriver only with user-equivalent actions or read-only semantic oracles.
3. Derive mouse targets from exposed UI geometry or stable labelled controls; do not
   hide table writes behind test-only mutation commands.
4. Keep the existing focused tests. The master test adds cross-feature and stateful
   coverage; it does not replace useful isolated regressions.
5. A checkpoint must fail immediately on a wrong interim value. A matching final table
   cannot conceal an earlier bad transition.
6. Undo assertions must verify both bytes and all shifted pointers/loop targets.
7. reSID output comparisons should use deterministic sample/trace signatures plus
   semantic register arrays, not subjective visual review alone.
8. The independent wave oracle must apply the player wave-speed and row-delay rules;
   bytes `02`, `04`, and `0C` must change recorded transition timing and the graph at
   exactly the same ticks. Treating every wave row as one tick is a failure.

## 8. Pass/fail gate

The master test passes only when all of the following are true:

1. Every ordered action is performed through the Sound Editor UI.
2. Every interim and final byte oracle matches exactly.
3. Every checkpoint completes the C-4, G-3, D-2 audition sequence.
4. Fixed gate-high duration is exactly 40 contiguous ticks after restart pre-roll at
   every note.
5. Rows and Ticks remain visibly distinct and convert predictably.
6. The displayed vivid traces match the actual reSID recordings.
7. Keyjam channel and filter mask combinations affect only the intended voice.
8. Loop deletion contracts correctly and produces End programme when fully removed.
9. The classic editor reads the same canonical bytes.
10. `mise run test` runs the focused suite and the stateful master with no R40-R72 skip,
    expected failure, or hidden retry.
11. Filter modes 00/LP/BP/HP/all produce empty/below/centred/above/union response
    silhouettes on one cutoff axis with one handle and unchanged exact filter bytes.
12. All 22 rendered/menu controls show registry-derived Alt-H status help with native timeout
    and foreground ownership, and their keyboard/mouse routes produce identical results.
13. Pulse and Filter END/LOOP triangles pass exact pixels, stopped, authored, offscreen,
    both-grip one-undo, dot-priority and boundary-resize usage checks.
14. LP/BP/HP/Route whitespace padding is painted, hittable and release-off safe through
    one shared draw/hit/debug geometry.
15. Wave loop retargeting maps in-range ticks to their owning authored row and maps
    far-left/far-right drags to the first/last legal normal row with exactly one undo.
16. Register-cell snapshots remain byte-identical through help replacement, menu/modal
    suppression, long status messages, timeout and close.
17. The frozen R66-R68 primary table passes the eight-layout and OS-reserved policy
    validators, binding uniqueness, AltGr/GUI negatives and exact raw-modifier checks;
    every naturally disabled binding is consumed with no table, pointer, view, audio or
    action mutation in representative initial, Wave-boundary, Filter CONFIG/SWEEP and
    real selected-table-capacity Add/New states.
18. All 22 named Sound actions plus 10 raw graph, octave and instrument operations
    complete through a compact-keyboard-only state-transition matrix.
19. Entering and leaving Sound Editor preserves global/sequencer dispatch, and generated
    KEYBOARD/help strings list the portable primary before any allowed legacy alias.
20. Wave pitch, delay, reserved-row and control-bit gestures pass the row-aware cursor,
    encoding, clamping, carry and idempotence matrix, including unrepresentable no-op
    help/undo/rerender and both lossless direct/encoded-low boundary crossings.
21. The in-band Wave `+` stays distinct and reachable for stopped and looped programmes
    and passes append, automatic ownership, END-only, invalid-placeholder absence,
    table-full and single-undo cases without hidden table mutation.
22. Every Wave mutation route passes the same non-modal ownership matrix, including
    automatic private copy, explicit visible linked edit, capacity no-op, atomic undo,
    multi-row paint idempotence, zero drag-time rerenders and one release-time rerender.
23. Wave A/B END/LOOP geometry passes exact delay/speed frames, 8×14 direction and
    top-cell priority; fresh END1 and authored WaveA END12 are derived without a fixed
    tail, Wave/Pulse/Filter tick ownership chooses the block under the pointer, shared
    triangle edits are atomic, off-view grips disappear, and Fit retains authored extent.
24. A new empty song reports zero live owners and no shared/used state; one direct Pulse
    or Filter drag creates and applies its release value without a modal or second gesture,
    fixed-Pulse conversion preserves its audible width, and one undo restores exact state.
25. Genuinely shared Wave/Pulse/Filter programmes copy-on-write on the first default
    mutation and never prompt; only visibly active persistent `Linked edits` mode changes
    shared bytes, and full-table failures use status/help with no mutation or undo entry.

## 9. Test-task and release-task isolation

1. This repository's default `mise.toml` contains only local task catalogs, so its
   `test` task has no GitHub or release-toolkit dependency.
2. Authenticated release tasks remain opt-in through
   `MISE_CONFIG_FILE=config/mise-release.toml mise run release:<task>`.
3. The parent workspace on the current developer machine has its own `../../mise.toml`
   which eagerly runs `gh auth token --user ventti`. That external ancestor config is
   outside this repository and is evaluated before project settings. Until it is made
   optional, validate this repository in isolation with
   `MISE_CEILING_PATHS="$(dirname "$PWD")" mise run test`.
4. A clean checkout without that external ancestor runs plain `mise run test` offline.
   The final R57 gate remains plain `mise run test`; the ceiling-path command is only
   evidence for this nested local workspace and must not hide a repository dependency.
