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

## Status: P1–P3 COMPLETE + independently verified. v2 LAYOUT (§7) committed (4f588d6). v3 (§8) separate-view/Z-order + restart conditions implemented (read-only) — awaiting verify. P4–P6 (editing/write-back, mouse, docs polish) NOT started.
Commits on feat/sound-editor: 85ccd8e (P1), e8a0f39 (P2), bee75eb (P3), 41a8e65 (checkpoint). v2 relayout uncommitted (loop orchestrator commits).

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
- (v2 LAYOUT REDESIGN, §7 2026-07-07) Full relayout of `src/ui/soundedit.d`
  (still READ-ONLY). Reused the P2/P3 sims + com.fb overlay; only the on-screen
  arrangement + the shared time base changed.
  - **No keyjam tint** (§7.4): `ui.toplevel.startSoundEditor()` now forces
    `com.fb.keyjamBackground=false` right after `enableKeyjamMode(true)` and
    `refresh()`es; `SoundEditor.update()` also re-asserts it false every frame.
    Note routing/playing unchanged (keyjamStatus stays true; the toplevel guard
    still routes note keys to the editor's own InputKeyjam). Exit restores the
    caller's prior keyjam state (and thus tint) via `enableKeyjamMode(prevKeyjamStatus)`.
    Verified: enter shows the normal dark bg (not blue); exit fully restores the
    classic editor and drops the KEYJAM indicator (se-v2-exit.png).
  - **Stacked frame-aligned bands** (§7.2): one shared X axis = frames-since-note-on
    (VISIBLE_FRAMES=128, FRAME_MS=19.95). Five bands top→bottom sharing the same
    pixel `plotX0px`/`plotWpx`: Output (min/max per frame from `captureBuf`), ADSR
    (SID ms tables → frames, nominal gate-hold so A/D/S/R all show), Pulse + Filter
    (`simPulse`/`simFilter` per-frame val on the frame axis, loop marker vLine),
    and a thin Wave/arp lane (one waveform-colored step per frame + gate/sync/ring
    ticks + active-row cell highlight + $7E/$7F loop marker). Band geometry computed
    from `area` each frame (weights [1,1,1,1,0.55]).
  - **Single full-height playhead** across every band at the sounding voice's
    `frameSinceTrigger` (own per-voice counter reset on the SID gate 0→1 edge,
    voice chosen by `findVoiceFor(ins)`). Drawn as one white vLine spanning the
    whole stack.
  - **Left parameter column** (§7.3): 11 display-only rows (A/D/S/R with nibble
    text-bars; waveform mnemonic; wave/pulse/filter pointers; HardRst mnemonic;
    HR wave/SR) + a cursor moved with Up/Down (**no byte writes** — arrows only
    move the cursor). `+/-` still switch instrument, KP `/`,`*` still nudge octave.
  - **Bottom raw-data strip** (§7.3): the instrument's 8 bytes + the wave/pulse/
    filter rows it points into as read-only hex, plus the live (shared) filter
    Res/Route/Mode. Cross-checked against the classic Instruments table
    (ins04 Flute = FF 33 09 80 00 00 00 0D; ins0A = 05 CA 80 41 01 01 00 1B).
  - Dropped the standalone `OscilloscopeWindow` (output is now a band drawn via the
    overlay), so `ui.soundedit` no longer imports `ui.oscilloscope`.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver`
    → exit 0, both binaries.
  - Smoke (headless dummy SDL), tune tunes/vent-arkijuusto.ct, ENTER seq
    `load:... key:ESC key:Ctrl-e`:
    * se-v2-layout-1-enter.png — normal bg, left param col (>Attack cursor), 5
      stacked left-aligned bands, bottom raw strip.
    * se-v2-layout-2-cursor.png — `key:DOWN`×6 moves the cursor to >Pulse ptr.
    * se-v2-layout-3-instr.png — `key:+`×10 → ins0A "Basari+Bass"; params, all
      bands and raw data change together.
    * se-v2-layout-4-playhead.png — viewing ins04 "Flute", `play scopefill:8
      tick:16`: one white full-height playhead crosses all five bands at frame ~16
      (auto-detected: 407 px vertical white run at x=370). Playhead advances right
      with more ticks (x319→341→370 for tick 2/8/16).
    * se-v2-exit.png — `key:Ctrl-e` exits cleanly; classic editor restored, no tint.
  - Regenerated `make map` (ARCHITECTURE.md: soundedit synopsis + dropped
    ui.oscilloscope dep). No shortcut/CLI/flag added (Up/Down + `+/-` are internal
    keypress handling, not com.shortcuts entries), so no KEYBOARD.md / man-page regen.
  - KNOWN PRE-EXISTING FLAKY CRASH (not from this change): heavy `scopefill`
    (headless audio-callback fill) intermittently segfaults in reSID-fp
    `SIDFP::clock_resample_interpolate` on the SDL audio thread. It reproduces in
    the CLASSIC editor too (no Sound Editor, no keyjam) — e.g. `key:ESC play ff:0
    scopefill:12 tick:2` — so it is unrelated to soundedit.d. Screenshots were
    captured with retry-on-crash. Worth a separate bug for the reSID-fp resampler.
  - Headless-capture note: the playhead's `frameSinceTrigger` advances per UI
    `tick` (not per player frame), so headless it sits near the left unless extra
    ticks are driven; on real hardware update()≈50 fps ≈ player rate so it tracks.
    NOT done: data editing / write-back / undo (P4+, still read-only).
- (v3 SEPARATE-VIEW + Z-ORDER + RESTART CONDITIONS, §8 2026-07-07) Still READ-ONLY.
  - **§8.1 Z-order — yield the pixel overlay to higher-Z chrome.** The com.fb
    overlay is a post-composite pixel layer drawn on top of ALL text cells (menu
    bar, dropdowns, palette, dialogs), so its graphs bled over pop-ups. Fix:
    `SoundEditor.update()` now calls a new `chromeActive()` guard first — when
    `mainui.dialogActive` (new trailing `@property bool UI.dialogActive` exposing
    the private `dialog` field), or `mainui.menubar.active`, or
    `mainui.palette.active` — it does `video.olClear()` and RETURNS, emitting no
    graph pixels that frame. The chrome (drawMenu / dialog.update, both text) then
    renders unobstructed; the editor's own text cells stay beneath it exactly like
    the classic editor. Added imports `com.session : mainui`, `ui.menubar`,
    `ui.palette` to soundedit.d.
  - **§8.1 confine pixels below the menu bar:** verified no change needed — the
    band stack starts at `stackTopRow = area.y + 3` (area.y=zone1y=4 → row 7,
    pixel Y=98), far below the row-0 menu bar (px 0..13). All graph pixels (bands +
    the full-height playhead spanning stackTopPx..stackBotPx) live below it.
  - **§8.2 clean view switch:** `ui.toplevel.startSoundEditor()` now `screen.clrscr()`s
    BEFORE the window swap so no tracker cells peek through the editor's non-solid
    content region; `stopSoundEditor()` now `screen.clrscr()`s after `video.olClear()`
    and before restoring `windows` (activateWindow→refresh repaints the tracker
    clean) so no Sound-Editor text/pixels linger. Both directions verified
    pixel-clean (enter and re-enter PNGs are byte-identical; exit fully restores the
    tracker).
  - **§8.2 restart conditions in the param column + raw strip:** left param row 8
    relabelled `HardRst`→`Restart`, value now `$40 soft g0` (mode from bits 6-7:
    hard/soft/3fr + gate-on/arp-delay low nibble); rows 9/10 `HR wave $80` / `HR SR
    $00` (cols 3/6). The bottom raw strip already prints `Rst %02X  HRw %02X ...
    HRsr %02X` (cols 2/3/6 hex) — verified present.
  - Files: `src/ui/soundedit.d` (chromeActive guard + early-return; Restart row
    relabel/gate-on; new imports), `src/ui/ui.d` (trailing `dialogActive`
    accessor), `src/ui/toplevel.d` (clrscr on enter+exit).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver`
    → exit 0, both binaries (ccutter 7434984, ccdriver 7446232).
  - Smoke (headless dummy SDL), tune tunes/vent-arkijuusto.ct, ENTER seq
    `load:... key:ESC key:Ctrl-e` (first ESC dismisses the startup splash):
    * se-v3fix-enter.png — non-blue bg, menu bar intact, param col incl.
      `Restart $40 soft g0 / HR wave $80 / HR SR $00`, raw strip
      `Rst 40 HRw 80 ... HRsr 00`, five stacked bands.
    * se-v3fix-menu.png — `key:ESC` inside the editor opens the File dropdown
      (Esc resolves in `UI.keypress` above the toplevel routing guard). Dropdown
      fully visible, ZERO graph pixels over it (ADSR curve + pulse fill suppressed).
    * se-v3fix-dialog.png — `key:F12` (help_dialog, Ctx.global) opens the modal
      help dialog over the editor, clean, no graph pixels over it.
    * se-v3fix-exit.png — `key:Ctrl-e` exits; classic tracker fully restored, no
      lingering graph pixels/text ("Sound Editor closed.").
    * se-v3fix-reenter.png — `key:Ctrl-e` re-enters; byte-identical to enter PNG,
      no tracker cells showing through.
  - Regenerated `make map` (ARCHITECTURE.md dep edges: soundedit.d → ui.menubar,
    ui.palette). No shortcut/CLI/flag added, so no KEYBOARD.md / man-page regen.
    NOT done: data editing / write-back / undo (P4+, still read-only).
