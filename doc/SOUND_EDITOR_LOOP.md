# Sound Editor — loop memory

Survives context resets. Update every iteration.

## Goal
Build the visual Sound Editor per `doc/SOUND_EDITOR_DESIGN.md`, **phases P1–P3
only** (realtime read-only visualization). Stop for human review before editing
(P4–P6).

## Scope this run
- P1: new `SoundEditor` screen; enter/exit (slot-swap like startFp/stopFp);
  keyjam ON by default with the Toplevel routing guard; live output oscilloscope.
- P2: `com.fb` immediate-mode pixel overlay draw-list; ADSR envelope curve from
  the selected instrument (real ms tables); live playhead.
- P3: pulse / filter / wave+arp timelines drawn as pixel graphs w/ loop markers
  + playhead. Read-only.

## Stopping condition (per phase)
1. `cd ../CheeseCutter.soundeditor && make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` → exit 0, both binaries produced.
2. ccdriver: enter the Sound Editor screen, drive keyjam, screenshot shows the
   expected panels/graphs (verifier inspects the PNG).
3. No behavior regression to the normal editor (enter/exit clean).
Editing byte-parity is P4+ (out of scope this run) — DO NOT implement editing.

## Isolation
- Worktree: `../CheeseCutter.soundeditor`  Branch: `feat/sound-editor`
- Baseline: clean build green (ccutter + ccdriver), commit 9de0971.

## Tier / swarm
- Tier 2: dedicated implementer agent (`soundedit-implementer`) + separate
  verifier agent (`soundedit-verifier`). Grader stays separate from creator.

## Agent strategy
- Dedicated agents scaffolded in `.claude/agents/`.

## Status: P1–P3 COMPLETE + independently verified (each PASS). STOPPED for human review at the P1–P3 checkpoint (per user request). P4–P6 (keyboard editing/write-back, mouse editing, docs polish) NOT started.
Commits on feat/sound-editor: 85ccd8e (P1), e8a0f39 (P2), bee75eb (P3).

Tech-debt to address in P6 polish (non-blocking, from verifiers):
- soundedit.d duplicates the SID ms ADSR tables from audio.visualizer (private
  there) — expose a shared const to avoid drift.
- soundedit.d: COL_AXIS duplicates COL_LABEL value; amplitude clamping done 3
  ways (reuse clamp01).
- Pulse active-row playhead highlight is a wide region box; could be a slimmer
  cursor (correct, just cosmetic).
- Non-English man pages fall back to English for the new "Sound Editor" string —
  flag native review.

## Iteration log
- (P0) Design doc + code map done; baseline build green. Next: P1.
- (P1) Skeleton + enter/exit + keyjam + live output scope DONE.
  - New module `src/ui/soundedit.d`: `class SoundEditor : Window`
    (`contextId = Ctx.soundEditor`). Draws framed chrome (title, selected
    instrument no/name from `song.insLabels`, current `state.octave`) and a live
    output oscilloscope by reusing `ui.oscilloscope.OscilloscopeWindow` (which
    calls `video.setScopeTrace/Envelope`). Owns its own `InputKeyjam`; also
    nudges octave via KP `/` `*`.
  - `com.shortcuts`: added `Ctx.soundEditor = "sound_editor"`.
  - `ui.toplevel`: full-screen slot-swap `startSoundEditor()/stopSoundEditor()/
    toggleSoundEditor()` mirroring `startFp()/stopFp()` — saves/restores the whole
    `windows[]` + active index. Entering forces keyjam ON
    (`state.keyjamStatus = true; ui.enableKeyjamMode(true)`); leaving restores the
    prior keyjam state + classic screen. Routing guard at the top of
    `keypress/keyrelease`: when `soundEditorActive`, keys go straight to the
    SoundEditor (its own keyjam + nav) instead of the global `inputKeyjam`.
  - `ui.keymap`: registered `toggle_sound_editor` on **Ctrl-E** (SDLK_e|KMOD_CTRL),
    Display category, menu label "Sound Editor". Resolves in `UI.keypress` before
    `toplevel.keypress`, so it toggles out even while the screen's keyjam is on;
    F1..F3 likewise still play the song.
  - `ui.ui.drawScope()`: bails early when `toplevel.soundEditorActive` so the
    end-of-frame pass doesn't clear the scope trace the SoundEditor sets.
  - `Makefile.objects.mk`: added `src/ui/soundedit.o`.
  - Regenerated generated docs: `make map` (ARCHITECTURE.md) + `make docs`
    (KEYBOARD.md + man pages; non-English man pages fall back to English help for
    the new string — flag for native review later).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter
    ccdriver` → exit 0, both binaries produced.
  - Smoke (headless, dummy SDL): ENTER seq (lowercase e — the driver maps a
    single-char key by ASCII, so `Ctrl-E` sends 'E'=69, not SDLK_e):
    `load:... key:ESC key:Ctrl-e ...` (ESC dismisses the startup splash first).
    Verified: enter shows the new screen (KEYJAM on, chrome, scope frame);
    `key:a` jams (SID V1 = 4c68/ctrl 81); `key:F2 scopefill:8` shows a live
    playback trace in the scope; `key:Ctrl-e` again exits cleanly to the classic
    editor. No crashes. Note: keyjam capture (`captureBuf`) stays flat headless
    for BOTH this scope and the classic oscilloscope — `scopefill` fills the
    playback `mixbuf` (drawPlayback path), so drive playback to see a trace.
  - NOT done (deferred to P2+): ADSR curve, pulse/filter/wave timelines, the
    `com.fb` overlay draw-list, any data editing. Next: P2.
- (P2) `com.fb` overlay draw-list + read-only ADSR envelope curve + live
  playhead DONE.
  - `com.fb`: added an immediate-mode overlay draw-list beside the single-slot
    scope trace. TRAILING no-op virtuals on base `Video` (`olClear`, `olLine`,
    `olVLine`, `olHLine`, `olRect`, `olFillRect`, `olPoint`; device-pixel coords +
    palette index) for vtable safety; `VideoStandard` stores the ops in a list and
    flushes them in `renderGrid()`'s tail right after `drawScopeTrace()` (so both
    `updateFrame()` and `saveScreenshot()` composite them). New `overlayActive`
    flag forces per-frame re-render exactly like `scopeActive`. Caller rebuilds the
    list each frame: `olClear()` then any ol* ops.
  - `ui.toplevel.stopSoundEditor()`: calls `video.olClear()` on exit so the
    editor's graphs don't linger over the classic editor (overlayActive would
    otherwise force stale re-renders). Verified clean exit (se-p2-exit.png).
  - `ui.soundedit`: `drawEnvelope(ins)` draws a framed **ADSR Envelope** panel for
    `state.activeInstrument` (`song.instrumentTable[ins]`=AD, `[ins+48]`=SR). A→D→
    S→R polyline via the overlay: fixed sustain-hold width, A/D/R widths shared in
    proportion to the real SID ms timing tables (duplicated from audio.visualizer /
    ADSR spec, since those copies are private), sustain level = sustain/15 on the
    Y axis. Labels the four nibbles + their ms as text. Live playhead: finds a
    voice whose `getVoiceInstrument()==ins` with `getVoiceBrightness()>0.01`, rides
    the curve at that brightness (amplitude cursor); phase (attack/decay/sustain/
    release) disambiguated by gate bit (`audio.audio.sidreg`) + brightness
    direction (`prevBright[3]`). Drawn as a dim vertical stem + a bright dot.
    Also handles `+`/`-` inline (via `UI.activateInstrument`) so the instrument
    under view switches without leaving the screen.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter
    ccdriver` → exit 0, both binaries produced.
  - Smoke (headless dummy SDL): `load:tunes/scarzix-visualbrothers.ct key:ESC
    key:Ctrl-e` enters. `tick:2 shot` → ADSR curve for ins00. `key:+ key:+ key:+
    tick:2 shot` → ins03 "Chords" curve changes dramatically (long attack ramp,
    near-instant decay cliff, sustain plateau at 5/15, long release) — verified
    against the real bytes (ins03 AD=D0 SR=5C). `play scopefill:8 tick:1 shot` →
    playhead dot rides ins03's attack ramp (voice 2 plays ins03, brightness ~0.2).
    Screenshots: /tmp/se-p2-{default,ins3,playhead,exit}.png.
  - NOTE: headless **keyjam** produces a degenerate envelope (jammed voice's SID
    AD/SR read 00, brightness stays 0) — the same P1 limitation that keeps the
    keyjam capture flat headless (no real audio device to run the note). The
    playhead is therefore demonstrated via song playback, which drives the exact
    same `getVoiceBrightness` path; on real hardware keyjam feeds it identically.
  - Regenerated `make map` (ARCHITECTURE.md) after updating the module synopsis.
    No shortcut/flag added (the in-screen `+`/`-` is internal keypress handling,
    not a com.shortcuts registration), so no KEYBOARD.md / man-page regen needed.
  - NOT done (deferred to P3+): pulse/filter/wave+arp timelines, any editing.
    Next: P3.
- (P3) Per-tick pulse / filter / wave-arp TABLE TIMELINES (read-only) DONE.
  - `audio.visualizer`: added trailing read-only getters `getActiveWaveRow(v)`,
    `getActivePulseRow(v)`, `getActiveChordRow(v)`, `getActiveFilterRow()` exposing
    the player's live table rows the visualizer already tracks (`activeWaveRows`
    etc. read from player memory in `updateSidRegisters`). Used to place the
    timeline playheads. No vtable concern (module functions).
  - `ui.soundedit`: reorganized the layout into a top band (ADSR curve top-left,
    output scope top-right, rows 8-18) + three full-width stacked timelines below
    (Pulse rows 20-27, Filter 28-35, Wave/Arp 36-43). The scope's Rectangle moved
    to the top-right in the ctor; ADSR panel shrank to the top-left.
  - Three read-only per-frame SIMULATORS mirroring `src/c64/player_v4.acme` (cross-
    checked against the hex tables via the classic editor):
    * `simPulse(startRow)` — pulstab 4 bytes/row: b0 dur|dir (bit7 subtract, low7
      frames+1), b1 add magnitude (PW +=/-= b1 per frame, 12-bit wrap), b2 init PW
      (nibbles swapped `((b2&0xF)<<8)|(b2&0xF0)`, $FF keep), b3 jump ($00 next /
      $7F stop / <=$3F row). Start row = `instrumentTable[ins+5*48]`; >=$80 = direct
      fixed pulse (no program, labelled). Emits per-frame PW 0..4095 + source row.
    * `simFilter(startRow)` — filttab: sweep row (b0 bit7 clear) dur=b0 frames,
      11-bit cutoff delta = 2*signed(b1), init cutoff = b2<<3 ($FF keep); config
      row (b0 bit7 set) sets mode (b0&0x70) + $d417 res/routing (instantaneous).
      Start = `instrumentTable[ins+4*48]` (0 = no program). Cutoff 0..2047 global.
    * `simWave(startRow)` — walks wave rows: wave1 $7F = jump (target in wave2),
      $7E = loop-prev/end; $80..$DF absolute note, $00..$5F relative transpose;
      wave2 = SID control byte / delay override / unchanged. Start =
      `instrumentTable[ins+7*48]`.
  - Drawing via the `com.fb` overlay: `drawSweepGraph` renders pulse/filter as an
    area+top-line graph with the loop-back frame marked (orange vLine) and the
    active table row's frame span outlined (white playhead box). The wave lane
    draws one colored block per step (waveform color: tri cyan / saw green / pulse
    yellow / noise grey / unchanged dim), gate/sync/ring tick marks along the top,
    a relative/absolute note step line, the $7E/$7F loop marker, and outlines the
    active wave-row cell as the playhead. Filter panel also annotates LIVE
    resonance/routing/mode from `audio.audio.sidreg[$17..$18]` (filter is shared).
  - All READ-ONLY: no writes to song byte tables, no editing/undo (that's P4+).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter
    ccdriver` → exit 0, both binaries produced.
  - Smoke (headless dummy SDL): ENTER seq `load:tunes/vent-arkijuusto.ct key:ESC
    key:Ctrl-e` then `key:+` to step instruments. Best all-three instrument:
    **ins0A "Basari+Bass"** (filt=01, puls=01, wave=1B → pulse sweep that loops +
    filter program + a 3-step wave lane). Also ins06, ins12 "Arpeggio2" (6-step
    arp lane), ins07 "Lead". Playhead demo via song playback (`play scopefill:N
    tick:2 ff:N`): **ins07 "Lead"** plays and shows all playheads moving at once —
    ADSR dot on the curve, the pulse-timeline row-highlight box, and the wave-lane
    cell highlight — across se-p3-play{1,2,3}.png. The filter's live annotation
    reads "ResF Route:1 Mode:LPHP (shared)" during playback, matching filter table
    row $01 = `D0 F1 60 7F` in the hex editor (config row: LP+HP, res F, route 1).
    Screenshots: /tmp/se-p3-{ins00,ins06,ins07,ins10,ins12,ins16,play1,play2,play3,
    exit}.png. Clean exit verified (se-p3-exit.png: classic editor fully restored).
  - Regenerated `make map` (ARCHITECTURE.md) after the module synopsis change. No
    shortcut/flag/CLI added, so no KEYBOARD.md / man-page regen needed.
  - NOTE (headless keyjam limitation, same as P1/P2): jammed notes produce no
    brightness headless, so playheads are demonstrated via song playback (the same
    getVoice*/getActive*Row path real hardware feeds identically).
  - NOT done: data editing / write-back / undo (P4+). P1-P3 read-only viz complete
    — STOP for human review before editing.
