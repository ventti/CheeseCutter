# Visual Sound Editor — Design & Research

Status: **DRAFT / in progress** (feat/sound-editor)
An alternative, visual instrument/sound-editing screen that "sugarcoats" the
hex wave/pulse/filter tables behind pixel-accurate, realtime, mouse-and-keyboard
editable graphs — while writing back to the exact same `ct.base` data the classic
hex editor uses.

---

## 1. What makes a modern synth sound-editor UI intuitive

Surveying current soft-synths and chiptune instrument editors — Serum, Vital,
Ableton Operator/Wavetable, u-he Diva/Zebra, NI Massive, Logic ES2, Arturia
synths — and the chiptune-native editors that are the closest analog to SID —
**Furnace**, FamiTracker, SidWizard, GoatTracker, Renoise/SunVox instrument
editors — the recurring properties that make sound editing *feel* intuitive:

1. **Direct manipulation of the envelope as a curve.** ADSR is drawn as a
   polyline with a draggable handle per breakpoint (attack peak, decay→sustain
   knee, sustain level, release tail). You shape the sound by dragging its
   picture, not by typing four numbers. A playhead dot rides the curve during
   playback.
2. **Everything is realtime.** Change a value → hear it and see the graph/scope
   redraw the same frame. No "apply" step. Immediate audiovisual feedback is the
   single biggest driver of "intuitive".
3. **Live output waveform / oscilloscope.** The actual resulting waveform is
   always visible, so the ear/eye link is closed. Serum/Vital keep a scope on
   screen at all times.
4. **Time-varying parameters shown as timelines ("macros").** This is the
   chiptune-tracker insight (Furnace/FamiTracker): volume, arpeggio, pitch and
   duty are per-tick *sequences* drawn as bar-graph/step timelines with **loop**
   and **release** markers you drag. This maps 1:1 onto SID's wave/pulse/filter
   tables, which are literally per-frame programs.
5. **Consistent color language.** One hue per voice/module; the same color means
   the same thing everywhere. (We already have a semantic palette in
   `com.palette`.)
6. **Progressive disclosure.** A simple default face with the 6 things that
   matter; advanced/rare bits (test bit, ring/sync routing, combined waveforms)
   are reachable but not shouting.
7. **Snap + fine control.** Coarse drag snaps to musically useful steps; a
   modifier (Shift) gives fine/1-unit control. Keyboard arrows nudge; with a
   modifier, jump.
8. **Playability without leaving the screen.** Jam notes from the computer
   keyboard, change octave, switch the instrument under edit — all inline, so
   you audition while you sculpt.

Design takeaway for CheeseCutter: keep the tracker's keyboard-first speed, but
overlay a **graph-per-parameter** face that is (a) pixel-accurate, (b) redrawn
every frame from live SID registers, and (c) editable with both mouse and keys,
mapping edits straight back to the existing tables.

---

## 2. SID hardware limitations (the boundary the graphs must respect)

The MOS 6581/8580 SID (see `doc/sid_registers.txt`) constrains every visual to a
small, quantized space — the graphs must render the *real* discrete values, not
a flattering continuous fiction:

- **3 voices, one chip.** Editing an instrument = one voice's registers.
- **4 waveforms** — triangle, sawtooth, pulse, noise — selectable per frame and
  *combinable* (bits AND together); combined waveforms are model-dependent
  (6581 vs 8580 differ) and noise+other can silence/lock the oscillator. The
  waveform lane must show the raw control-register bits, not a idealized set.
- **Pulse width is 12-bit (0..4095)** — one shared PW per voice, only meaningful
  for the pulse waveform. Natural as a 0..4095 area/line graph over time.
- **ADSR is 4-bit each and non-linear.** Attack/decay/release map to fixed,
  wildly non-uniform time tables (2 ms … 8 s attack; 6 ms … 24 s decay/release).
  Sustain is a *level* 0..15, not a time. The envelope curve must use the real
  ms tables (already captured in the ADSR viz spec) so the drawn slope matches
  what you hear. The infamous **ADSR delay/retrigger bug** motivates hard-restart
  handling.
- **One filter, shared.** 11-bit cutoff, 4-bit resonance, per-voice routing bits,
  and LP/BP/HP mode bits (combinable → notch). Because it is global, the filter
  graph is conceptually song/voice-shared, not per-note.
- **Global volume is 4-bit** ($D418) and doubles as filter-mode + voice-3-off.
- **Ring mod & sync** couple adjacent voices (voice N modulated by N-1).
- **Write-only, frame-quantized.** Registers are written once per player tick
  (**PAL 50.125 Hz**, ~19.95 ms/frame). *Every* time-varying parameter is a
  staircase at frame resolution — the graphs are pixel-accurate horizontally in
  *frames/ticks*, and interpolation between frames would be a lie.

---

## 3. CheeseCutter player boundary conditions

The editor's job is to author the byte tables the C64 player interprets each
tick. Constraints from the player/data model (`ct.base`, `src/c64/player_v4.acme`,
`player_v5.md`, and the live-memory layout):

- **Tables are per-tick programs with jump/loop markers.** The wave, pulse and
  filter tables step one row per frame (or per instrument-defined speed), with
  end/jump bytes that loop or halt. A visual timeline must render these loop
  points and let you move them — they are the sustain/repeat of the sound.
- **Instrument = a small record + pointers into those tables** (AD, SR, wave/
  pulse/filter table start rows, hard-restart, vibrato, gate timing). The visual
  editor edits *both* the scalar instrument fields (→ envelope graph, vibrato)
  and the pointed-at table rows (→ the timelines).
- **Player features are versioned** (v4/v5: hi-fi vibrato, hard restart). The
  visual controls must degrade to whatever the active player supports and never
  emit bytes the player can't interpret.
- **Frame rate = graph x-resolution.** The player tick *is* the pixel step for
  every over-time graph; the realtime playhead is the player's current table
  index.
- **Round-trip fidelity is mandatory.** The visual editor is a *view* over the
  canonical `ct.base` bytes. Any edit must produce byte-identical results to
  doing it in the hex editor (undo via the existing `Undoable` stack), so the two
  editors stay perfectly interchangeable ("sugarcoat", don't replace).

---

## 4. Proposed screen (overview)

A new full-screen **Sound Editor** mode, toggled from the main editor, showing
for the currently-selected instrument:

- **ADSR envelope graph** — draggable A/D/S/R, live playhead, ↔ AD/SR nibbles.
- **Waveform lane** — per-tick waveform + gate/test/ring/sync, ↔ wave table.
- **Pulse-width graph over time** (0..4095 area), ↔ pulse table.
- **Filter graph over time** — cutoff + resonance + routing + mode, ↔ filter table.
- **Pitch/arp lane** — relative/absolute note offsets + vibrato, ↔ wave table arp col.
- **Live output oscilloscope** (reuse `ui.oscilloscope`) — the resulting waveform.
- **Realtime playhead** across all time-based graphs = the player's table index.
- **Keyjam on by default**; change octave & current instrument inline; F1..F3
  (with modifiers) still drive song playback.

Concrete data mapping, module layout, framebuffer/pixel drawing primitives, and
the phased implementation plan are filled in below from the code survey.

---

## 5. Code mapping (what we reuse, what we add)

### 5.1 Data model (`src/ct/base.d`) — the bytes we sugarcoat
- **Instrument** = 8 column-major bytes: `song.instrumentTable[no + col*48]`.
  `col 0`=AD (hi=attack, lo=decay), `1`=SR (hi=sustain, lo=release), `2`=restart/
  arp (`$00`/`$40`/`$80` = 3-frame/soft/hard restart; low nibble = gate-on/arp
  delay), `3`=hard-restart waveform, `4`=filter pointer, `5`=pulse pointer,
  `6`=hard-restart SR, `7`=wave pointer.
- **Wave table** `WaveTable` (2 cols × 256): `wave1`=transpose/arp note, `wave2`=
  waveform/control byte per tick. Markers `$7E` loop-prev, `$7F` jump-to-row.
- **Pulse / filter** `SweepTable` (4 cols × 64): byte0 duration/dir, byte1 add/
  frame, byte2 init value, byte3 jump (`$00` next / `$7F` stop / `≤$3F` jump).
- **Command/arp** `superTable` (3 parallel 64-byte cols: cmd, param-hi, param-lo).
- Accessors: `wavetablePointer/pulsetablePointer/filtertablePointer(insno)`,
  `speed/setSpeed`, `WaveTable.insertRow/deleteRow` (fixes `$7F` targets + arp
  pointers), `SweepTable.seekProgram`.

### 5.2 Reused mechanisms
- **Screen switch (full-screen)**: slot-swap into `Toplevel.windows[]` exactly as
  `startFp()/stopFp()` swap `fplay`↔`sequencer` (`toplevel.d:488-509`);
  `WindowSwitcher.activateWindow` pushes the window's `contextId` into the
  shortcut manager automatically.
- **Keyjam**: `InputKeyjam` (`input.d:874`) piano map
  `"1!azsxdcvgbhnjmq2w3er5t6y7ui9o0p"`, `→ audio.player.playNote(Element)`
  (`player.d:81`). Octave = `state.octave` (KP `/`,`*`), instrument =
  `state.activeInstrument` (`+`/`-`, `UI.activateInstrument`).
- **Song play F1..F3**: registered in the shortcut registry (`keymap.d:156-194`)
  and resolved in `UI.keypress` **before** `toplevel.keypress`, so they keep
  working inside the Sound Editor with no extra work. Modifier variants
  (Shift-F1/2/3 = follow) already exist.
- **Live data for graphs (no locks, `__gshared`)**:
  `audio.audio.sidreg[0..0x19]` (25 SID regs), `audio.audio.mixbuf` +
  `getbufsize()` (output PCM), `audio.audio.captureBuf/captureGate/captureLen/
  captureFrameSamples` (per-keyjam-note recording), and `audio.visualizer.*`
  getters (`getVoiceBrightness`, `getVoiceInstrument`, envelope state). The
  playhead = the player's live wave/pulse/filter table row (read from player mem
  via the visualizer, or re-derived).
- **Output scope**: reuse the sample→pixel math from `ui.oscilloscope`
  (`offOf`, `FULLSCALE`, `PLAY_SPAN`).

### 5.3 New enabling primitive — `com.fb` overlay draw-list
The only pixel facility today is the single-slot `setScopeTrace/Envelope`
polyline (`fb.d:115-121,208-268`). The Sound Editor needs *several* independent
pixel graphs on screen at once, so we add a small **immediate-mode overlay** to
`Video`/`VideoStandard`, flushed on top of the text grid in `renderGrid()` and
cleared each frame (mirroring how `scopeActive` forces a per-frame re-render):
`olClear()`, `olLine`, `olVLine`, `olHLine`, `olRect` (outline), `olFillRect`,
`olPoint` — all device-pixel coords + palette color index. New **trailing**
virtuals (base no-ops) + a draw-list field; always `make clean` build (no dep
tracking, so vtable order matters — keep additions trailing).

### 5.4 New module — `src/ui/soundedit.d` : `class SoundEditor : Window`
- Own `contextId = Ctx.soundEditor` (new `Ctx` value + shortcut registrations).
- `update()`: draw the text-cell chrome (labels, values, frames via
  `Window.drawFrame`) plus the pixel graphs via the `com.fb` overlay, every
  frame, from live data.
- **Panels**: (1) ADSR envelope curve (real ms tables), (2) waveform lane
  (per-tick waveform + gate/test/ring/sync), (3) pulse-width-over-time area,
  (4) filter cutoff-over-time + resonance/routing/mode, (5) pitch/arp lane +
  vibrato, (6) live output oscilloscope. Realtime playhead across the time
  panels = the player's current table index.
- **Input**: piano keys → own `InputKeyjam` (keyjam on by default); non-note
  keys (arrows/Tab/Enter/Ins/Del/PgUp-Dn/mouse) → panel navigation + editing.
  Edits write straight into the same `ct.base` byte slices and snapshot the
  `Undoable` stack, identical bytes to the hex editor.
- **Routing fix**: `Toplevel.keypress/keyrelease` currently send *all* keys to
  `inputKeyjam` when `keyjamStatus` (toplevel.d:328,344). Add a guard so that
  when the active window is the Sound Editor, keys go to it (it does its own
  keyjam), giving simultaneous jam + edit.

### 5.5 Wiring & docs
- `ui.ui`: add `Ctx.soundEditor`; construct + hold the `SoundEditor`; a toggle
  entering/leaving the screen (slot swap) that also forces keyjam on.
- `ui.keymap`: register the toggle shortcut + the in-screen editing shortcuts;
  regenerate man pages / `KEYBOARD.md` via `make docs`.
- `README.md`, `guide/README.md`: document the new screen + shortcut (same-change
  doc rule). `make map` after adding the module (header synopsis).

## 6. Implementation plan (phased, each phase builds clean + verifies via ccdriver)

- **P1 — Skeleton + enter/exit + keyjam + live output scope.** New module &
  `Ctx`; toggle in/out (slot swap); keyjam-on-by-default with the routing guard;
  render panel chrome + a live output oscilloscope. *Verify*: enter screen,
  screenshot, jam a note, screenshot shows the trace.
- **P2 — `com.fb` overlay + ADSR envelope graph (realtime, read-only).** Add the
  overlay draw-list; draw the ADSR curve from the selected instrument using the
  ms timing tables; live playhead dot. *Verify*: screenshot the curve for a
  couple of instruments; playhead moves during a jam.
- **P3 — Pulse, filter, wave/arp timelines (realtime, read-only).** Draw the
  three table programs as pixel graphs with loop markers + playhead. *Verify*:
  screenshots match the hex-table contents.
- **P4 — Keyboard editing → write-back + undo.** Move handles/values with
  arrows+modifiers on every panel; write the exact bytes; hook `Undoable`.
  *Verify*: edit in Sound Editor, switch to hex editor, bytes match; undo works.
- **P5 — Mouse editing.** Drag handles / draw into timelines / click loop
  markers. *Verify*: driver click/drag → expected bytes.
- **P6 — Polish + docs.** Octave/instrument HUD, color language, `make docs`,
  README/guide, ADR for the design decision.

---

## 7. Layout redesign v2 (2026-07-07 — user feedback)

Supersedes the P3 panel arrangement (§5.4 panel list stays valid; only the
on-screen layout changes). Still **read-only** this pass (left panel displays +
has a cursor but does not write; write-back is P4).

### 7.1 Requirements (verbatim intent)
1. **No separate keyjam background.** The Sound Editor must use the *same*
   background as non-keyjam mode — drop the whole-screen dark-blue keyjam tint.
   Notes still play (keyjam functionally on); only the cosmetic tint goes.
2. **Time-aligned stacked graphs, shared X-axis.** The keyjam/output waveform,
   ADSR, Pulse and Filter graphs are drawn *on top of each other* as horizontal
   bands with the **same left edge, same width, same X scale**, so a single
   vertical **playhead** crosses all of them at the same instant.
3. **Parameter editing UI on the LEFT** of the graphs (a vertical column).
4. **Raw table data** for the instrument along the **bottom**.

### 7.2 The shared X-axis = frames (PAL ticks) from note-on
All bands use one common horizontal unit: **frames since the note triggered**
(the player tick; ~19.95 ms PAL). This is the honest common time base and makes
the stack physically meaningful:
- **Output/keyjam waveform** — `captureBuf` stores `captureFrameSamples` samples
  per frame, so sample index → frame is exact; draw min/max per column mapped to
  the frame axis (reuse `ui.oscilloscope` capture path). Headless the capture is
  flat (no audio device) — layout/alignment still fully verifiable.
- **ADSR** — convert the SID ms tables to frames; draw A→D→(sustain hold)→R
  across the frame axis. Use a fixed visible window (e.g. ~128 frames ≈ 2.5 s)
  and a nominal gate-hold so sustain/release are visible.
- **Pulse / Filter** — step the `SweepTable` program one row per frame (respect
  instrument speed + jump/loop); plot value per frame on the same axis. Loop
  back-edge drawn as a marker at its X.
- **Wave/arp lane** — also per-frame; keep it as a thin band at the bottom of the
  stack (still shares X), or fold into the raw-data strip. Prefer a thin band so
  the playhead stays meaningful across it.
- **Playhead** — one full-height vertical line at `currentFrameSinceTrigger`
  (from the live player: active table row / a frame counter), spanning every band.

### 7.3 Screen regions (compact 1280×700 / ccdriver layout)
```
+-- params (left col) --+-- stacked graphs (shared X = frames from note-on) --+
| Attack   [#]          | Output  ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~ |
| Decay    [#]          | ADSR    /\________                                  |
| Sustain  [#]          | Pulse   .:iI#####                                   |
| Release  [#]          | Filter  ####iI:.                                    |
| Waveform [pul]        | Wave/arp [t][s][p] (thin lane)                      |
| Pulse ptr[..] Filt[..]| ^ single playhead | crosses all bands at cur frame  |
| HardRst/Vib/...       |                                                     |
+-----------------------+-----------------------------------------------------+
+-- raw table data for this instrument (bottom) -----------------------------+
| Instr: AD SR .. | Wave: rows | Pulse: rows | Filter: rows  (hex, read-only) |
+----------------------------------------------------------------------------+
```
- **Left param column**: labelled rows for the instrument's editable params
  (AD, SR nibbles; waveform; pulse/filter pointers; hard-restart; vibrato/arp;
  gate timing) shown as simple visual values (bars/mnemonics), with a movable
  **cursor** (↑/↓ select a row) — **display-only** this pass; arrows just move
  the cursor, no byte writes.
- **Graph stack**: bands share `X0`/`width`; each band a fixed pixel height;
  labels at each band's left inside the graph area or in the param gutter.
- **Bottom raw data**: the hex bytes the instrument uses (its 8 instrument bytes
  + the wave/pulse/filter table rows it points into) as read-only hex — the
  "escape hatch" tying the picture back to the real bytes.

### 7.4 Keyjam-tint fix
`com.fb.keyjamBackground` (`fb.d:56`, applied `fb.d:511`) is the whole-screen
tint, set by `UI.enableKeyjamMode` (`ui.d:802`). In the Sound Editor keep note
routing/playing (the toplevel guard already routes keys to the editor's own
`InputKeyjam` when `soundEditorActive`; `playNote` doesn't depend on the tint),
but ensure `keyjamBackground` stays **false** while the screen is active (don't
set it on enter; restore prior value on exit). The menu KEYJAM indicator may stay
(only the background tint was objected to).

### 7.5 Verify (read-only redesign)
Clean build; enter the screen → screenshot shows: normal (non-blue) background;
the four+ graphs stacked and left-aligned to a common X with one playhead; the
left param column present with a cursor; raw hex table data along the bottom.
Switch instrument → graphs + params + raw data all change together. Drive song
playback → the single playhead moves across all bands in lockstep. No writes to
song bytes (still read-only).
