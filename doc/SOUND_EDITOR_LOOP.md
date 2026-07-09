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

## Status: P1–P3 COMPLETE + independently verified. v2 LAYOUT (§7) committed (4f588d6). v3 (§8) committed (be8e371). v4 (§9) committed (f0aae3f). v5 (§10) filter-type colours + resonance-over-time + frequency band + F12 help committed (7b5255c) + fixed 8-row wave band (a09a81f). v6 (§11) RECORDING VIEW committed (caaa93c). v7 (§12) AUTO-FIT X-AXIS ZOOM — the shared X window is no longer a fixed VISIBLE_FRAMES=128; it auto-fits the note's full duration each draw (dynamic zoom) — implemented (read-only) — awaiting verify. P4–P6 (editing/write-back, mouse, docs polish) NOT started.
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
- (v4 GRAPH-SYNC + BIT-LANE WAVE + RESTART PRE-ROLL + PIXEL-PERFECT OUTPUT, §9
  2026-07-07) Still READ-ONLY. All four §9 fixes in `src/ui/soundedit.d` only.
  - **§9.1 one true shared X-axis.** `xForFrame(g,f)` is now THE single frame->pixel
    map for every band (folds in the pre-roll offset, accepts negative pre-roll
    frames). The ADSR band was the desync culprit: it now samples the envelope PER
    FRAME on that axis (SID ms tables -> frames for A/D/R; ramp to 1.0 over attackF,
    decay to sustain/15 over decayF, sustain hold for NOMINAL_GATE_FRAMES=46, then
    release over releaseF) instead of its old ms-proportional/stretch-to-fill X, so
    its knees line up in time with pulse/filter/wave/output. New TOTAL_FRAMES =
    RESTART_FRAMES + VISIBLE_FRAMES; every per-pixel band maps px->frame with the
    same constants.
  - **§9.5 output pixel-perfect again.** `drawOutputBand` restored to PER-PIXEL
    min/max (one column per horizontal pixel, not per frame — the classic
    oscilloscope approach) over the note region [trigger divider .. right edge].
    Live mix (`audio.audio.mixbuf`+`getbufsize()`) while `audio.player.isPlaying()`
    for a moving trace; `captureBuf` (visible = VISIBLE_FRAMES*captureFrameSamples,
    clamped to captureLen) for a held keyjam note. Continuous/non-blocky again and
    still frame-aligned (pixel<->frame is the shared mapping).
  - **§9.2 restart pre-roll + trigger divider.** RESTART_FRAMES=10 reserved at the
    LEFT (frames -10..0). A red note-trigger divider (`COL_TRIGGER`) is drawn at
    xForFrame(0) full-height across ALL bands. The ADSR band shades the pre-roll
    (dim gradient wash) and draws the restart ramp from col2 ($80 hard from full /
    $40 soft from mid / else 3-frame from low), decaying to 0 by the trigger, with a
    small `rst:hard|soft|3fr` label. Other bands start at frame 0 (pre-roll empty).
  - **§9.3 wave band -> 8 stacked control-bit lanes.** New `simWaveFrames(startRow)`
    flattens the wave program to one effective SID control byte per FRAME (follows
    $7F jump / $7E loop-prev like simPulse/simFilter; carries the last real control
    byte forward across delay/unchanged rows; records loopFrame). `drawWaveBand`
    now stacks 8 thin lanes b7 Noise(top)..b0 Gate(bottom), a filled coloured block
    per ON bit per frame (distinct colour + 3-char gutter label Noi/Pul/Saw/Tri/Tst/
    Rng/Snc/Gat), faint lane separators, loop-back marker kept. A combined-waveform
    frame lights >1 waveform lane. Band weights re-tuned to [1,1,0.9,0.9,2.0] so the
    wave band is tall enough for 8 lanes. (Old per-cell `drawWaveBand`/`waveformColor`
    removed; `simWave`/`WaveSim` kept — still used by the param column + raw strip.)
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver`
    → both binaries produced (ccutter 7435544, ccdriver 7446808).
  - Smoke (headless dummy SDL), tunes/vent-arkijuusto.ct, ENTER seq
    `load:... key:ESC key:Ctrl-e` (first ESC dismisses the splash), `key:+`×N to step:
    * se-v4-ins0A.png — ins0A "Basari+Bass" (AD05 SR CA Rst80 hard, Pul01 Flt01
      Wav1B): ADSR restart pre-roll + red trigger divider, pulse sweep, bit-lanes
      Noi(grey)->Pul(yellow) with Gat(green) held. Cross-checks the Instruments
      table row 0A `05 CA 80 41 01 01 00 1B`.
    * se-v4-play.png — ins07 "Lead", `play ff:6 scopefill:3 tick:2` (light scopefill
      w/ retry to dodge the pre-existing reSID-fp resampler segfault): PIXEL-PERFECT
      continuous Output trace from the live mix; one white playhead + red divider,
      each a single 407px full-height column, crossing every band aligned; ADSR knee
      + pulse ramp + wave bits all start at the divider. Wave $0F row10 = ctrl $61 =
      pulse+saw+gate → the **Pul(yellow) and Saw(green) lanes light on the SAME
      frame** (combined waveform, honest to HW) — see se-v4-combined-zoom.png.
    * se-v4-ins12.png — Restart `$00 3fr` (a DIFFERENT restart mode vs 0A/07 hard):
      pre-roll ramp shape differs; all bands update together.
    * se-v4-dialog.png — F12 help dialog over the editor renders clean, zero graph
      pixel bleed (z-order §8.1 still intact).
    * se-v4-cleanexit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic
      tracker fully restored, no lingering graph pixels/text.
  - Alignment CONFIRMED programmatically (PIL scan of se-v4-play.png): red divider at
    x=379 and white playhead at x=386 are each a single continuous 407px vertical run
    spanning the whole band stack; Output content begins at x=380 (the divider). The
    shared-axis mapping is structural (all bands call the one `xForFrame`).
  - Read-only CONFIRMED: `git status` shows only soundedit.d (code) changed; grep finds
    NO writes to song.instrumentTable/waveTable/pulseTable/filterTable.
  - Regenerated `make map` (module synopsis updated to v4); `make check-map` clean. No
    shortcut/CLI/flag added, so no KEYBOARD.md / man-page regen.
    NOT done: data editing / write-back / undo (P4+, still read-only).
- (v5 FILTER-TYPE COLOURS + RESONANCE-OVER-TIME + FREQUENCY BAND + CONTEXT F12 HELP,
  §10 2026-07-07) Still READ-ONLY. Files: `src/ui/soundedit.d` (all four features),
  `src/ui/help.d` (new HELPSOUNDEDITOR page). Regenerated doc/ARCHITECTURE.md.
  - **§10.1 filter coloured by TYPE per frame.** Extended `simFilter` (per §10.6) to
    carry per-frame mode/res/routing in `SweepSim.modeOf/resOf/routeOf`: a CONFIG row
    (b0&0x80) sets `mode=b0&0x70`, `res=b1>>4`, `routing=b1&0x0F`, cutoff=b2<<3 (if
    b2!=0xFF); a SWEEP row sweeps cutoff (n=b0&0x7F, delta=2*signed8(b1)) with mode/res/
    routing PERSISTING from the last config row. New `drawFilterBand` colours the cutoff
    fill+top-line PER FRAME via `filterModeColor(mode&0x70)`: 0x10 LP→red(2), 0x20 BP→
    green(5), 0x40 HP→lblu(14), 0x30 LP+BP→orange(8), 0x60 BP+HP→cyan(3), 0x50 LP+HP→
    purple(4), 0x70 all→gray(12), 0x00 none→empty column. Loop marker kept.
  - **§10.2 resonance over time.** In the filter band, res(0..15) is plotted as a thin
    bright YELLOW(7) step line (level segment per frame + risers on change), clearly
    above the cutoff fill; labelled "res" in the band gutter.
  - **§10.3 frequency/pitch band below ADSR.** New band order Output/ADSR/**Freq**/Pulse/
    Filter/Wave (Geo now `int[7] bandTopPx`, weights `[1,1,0.9,0.9,0.9,1.8]` re-apportioned
    for 6 bands at 1280x700; band indices bumped: pulse 2→3, filter 3→4, wave 4→5). The
    per-frame wave sim `simWaveFrames` now also records `transOf`/`absOf` from wave1: $80..
    $DF = absolute tuning (note=w1&0x7F, drawn cyan(3)), $00..$5F = relative transpose up
    (drawn lightgreen(13)). New `drawFreqBand` draws it as a step graph (auto-scaled,
    floor 12 semis) on the shared axis; playhead aligned.
  - **§10.4 context F12 help.** Added `ContextHelp HELPSOUNDEDITOR` in help.d mirroring
    HELPSEQUENCER (title "Sound Editor help" != HELPMAIN.title, lead line "Press F12
    again to see the global help." so dialogs.d:182 F12-again→global works); content =
    jam keys / KP octave / +/- instrument / Up-Down cursor / Ctrl-E exit / F1-F4 (Shift
    tracking). Added `override ContextHelp contextHelp() { return ui.help.HELPSOUNDEDITOR;
    }` to `SoundEditor` (+`import ui.help;`). Shortened the on-screen title line to
    " Sound Editor   (F12 help) ".
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` →
    exit 0, both binaries (ccutter 7453400, ccdriver 7448152).
  - Smoke (headless dummy SDL). ENTER seq: `load:tunes/<tune>.ct key:ESC key:Ctrl-e`
    (first ESC dismisses the splash), `key:+`×N to step instruments.
    * /tmp/se-v5-ins0A.png — vent-arkijuusto ins0A "Basari+Bass": all SIX bands incl. the
      new Freq band below ADSR; filter row $01=D0 F1 60 7F → LP+HP purple(4) fill + res
      overlay (verified: purple px at x380-385, trigger divider red at x379).
    * /tmp/se-v5-filter-modechange.png — abaddon-trouble ins04 "bsslap2" (Flt $01: 01:E0
      F1 50 00 / 02:00 00 FF 00 / 03:B0 F1 04 00 / 04:7F 06 FF 04): filter mode CHANGES
      over time — BP+HP cyan(3) for x380-392 then LP+BP orange(8) rising sweep x393-1243;
      yellow resonance line flat at y=337 (res=15). Column-scan CONFIRMED the two mode
      colours and their x-segments match the decode.
    * /tmp/se-v5-freq-arp.png — vent-arkijuusto ins03 "Snare" (Wave $07: C0/81 A5/81 DF/81
      C0/81 DF/81, all $80+ absolute): Freq band shows a multi-step ABSOLUTE-note staircase
      (cyan). ins0B "Lead2" (00→0C) shows a relative step (lightgreen). ~5 step transitions
      detected in the band.
    * /tmp/se-v5-f12-soundeditor.png — `key:F12` in the editor → "Sound Editor help 1/1"
      page (title, jam keys, octave, navigation, playback) — NOT the tracker global help.
    * /tmp/se-v5-f12-again-global.png — `key:F12` again → "Main help 1/4" (global). Flow OK.
    * /tmp/se-v5-switch-ins00.png → -ins03.png — `key:+`×3 switches instrument; all six
      bands + param column + raw strip update together.
    * /tmp/se-v5-play-playhead.png — vent-arkijuusto viewing ins04 "Flute", `play ff:4
      tick:2` then step to a sounding voice: one full-height WHITE playhead (400px run @
      x488) crosses all six bands aligned with the red trigger divider; live Output trace
      from the mix; "Live filter: Res F Route 1 Mode LPHP" annotates the shared SID filter.
    * /tmp/se-v5-exit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic tracker
      fully restored (Instruments/Wave/Pulse/Filter tables), no lingering graph pixels.
  - Read-only CONFIRMED: grep finds NO writes to song.instrumentTable/waveTable/pulseTable/
    filterTable/superTable in soundedit.d; git status shows only soundedit.d + help.d (code)
    and the regenerated ARCHITECTURE.md + the pre-existing §10 spec changed.
  - Regenerated `make docs` (man pages + KEYBOARD.md — unchanged, since no com.shortcuts
    registry entries were added; F12 help is wired via the window `contextHelp` override,
    not new registry shortcuts) and `make map` (soundedit synopsis + new ui.help dep edge).
    `make check-map` "fails" only because the regenerated map is uncommitted vs HEAD (the
    orchestrator commits) — the map is in sync with source (genmap is stable across reruns).
  - NOTE (headless, same as prior iterations): the Output band needs song playback (mix
    buffer) to show a trace; keyjam capture stays flat with the dummy audio driver.
    NOT done: data editing / write-back / undo (P4+, still read-only).
- (v6 RECORDING VIEW — bands reflect the ACTUAL played audio, §11 2026-07-07) Still
  READ-ONLY (we record playback state; NO song-byte writes). Files: `src/audio/visualizer.d`
  (per-frame recording + getters), `src/ui/soundedit.d` (bands read the recording; sim =
  dimmed idle preview; loop replication + subtle loop lines; full-word bit-lane labels),
  `.claude/skills/run-cheesecutter/driver.d` (added read-only `voices` + `wavedump:<row>`
  oracles for verification). Regenerated `doc/ARCHITECTURE.md`.
  - **§11.1 per-frame recording in `audio.visualizer`.** New per-voice rolling log
    (`enum RECORD_FRAMES = 138` = the Sound Editor's TOTAL_FRAMES), appended once per player
    frame from the real `sidreg` in `updateSidRegisters()` (called every tick from
    `audio.callback`, so it works for keyjam on HW AND song playback / ccdriver `ff:`
    headless). Per frame per voice: control byte, 16-bit freq, 12-bit pulse, 11-bit cutoff,
    resonance, routing, mode(&0x70), and the visualizer's envelope amplitude 0..1. RESET on a
    gate 0->1 edge (own `recPrevGate[]`, independent of the envelope FSM's `voice.gateOn`);
    capped at RECORD_FRAMES (freezes trigger-aligned). Trailing module-level state + getters
    (`voiceHasRecording`, `getRecordingLength`, `getRecorded{Control,Freq,Pulse,Cutoff,
    Resonance,Routing,Mode,Amp}` returning slices) — no vtable-affecting base-class change.
    Reset in `resetVisualizer()`.
  - **§11.2 bands read the recording; sim = dimmed idle preview.** `chooseVoice(ins)` picks a
    voice sounding the viewed instrument (else one holding a recording of it); `useRec` gates
    every band. Recording path (vivid): Output = `captureBuf` pixel-perfect min/max (recording
    view — the live-mixbuf oscilloscope branch was REMOVED, so it's flat under headless song
    playback where no device fills the capture — documented); ADSR = recorded amp per frame
    (green step line, no restart pre-roll); Freq = recorded 16-bit freq on a log2(pitch) scale
    auto-fit to the window (cyan); Pulse = recorded 12-bit PW; Filter = recorded cutoff coloured
    per-frame by recorded mode (§10.1 map) + recorded resonance overlay (yellow); Wave = recorded
    control byte -> 8 bit-lanes. Idle fallback (no note yet): the existing table SIMULATION,
    drawn DIMMED (line+fill = palette 16 dark-navy) so it reads as a muted preview and sits
    BELOW the darkgray(11) loop lines. Playhead = the recording's record head (`recLen`), so it
    advances during a live note and freezes at the note end.
  - **§11.3 loop replication + subtle loop lines.** `simPulse`/`simFilter`/`simWaveFrames` no
    longer break at a revisited row — they REPLICATE the looped section across VISIBLE_FRAMES
    (record `loopFrame` + `loopPeriod` on first detection, then keep walking; a `steps` guard
    bounds jump-only cycles in the wave sim). `drawLoopLines()` draws a SUBTLE darkgray(11)
    vertical at loopFrame + k*period across each band, in BOTH the recording and sim paths;
    distinct from the bright red trigger divider (COL_TRIGGER=2) and white playhead
    (COL_HEAD=1). Period-1 single-row "holds" are skipped (not a repeating section), and a
    MIN_LOOP_PX=6 min spacing thins dense combs so fast loops stay subtle. (BUGFIX during
    dev: the min-spacing `lastX` seeded at `int.min` overflowed `x-lastX` and suppressed ALL
    loop lines — seeded to -1e6 instead.)
  - **§11.4 full-word bit-lane labels.** `BITLANE_LBL` = Noise/Pulse/Saw/Tri/Test/Ring/Sync/
    Gate (b7..b0); they fit the existing 8-char gutter (max word "Noise"/"Pulse" = 5). Lanes
    light from the actual recorded control byte (dimmed sim ctrl when idle). Fixed 8-row wave
    band + enter/exit/z-order/F12/F1-F3 all unchanged.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (touched the shared audio.visualizer module -> full clean build).
  - Smoke (headless dummy SDL), tunes/vent-arkijuusto.ct (mult=2). ENTER seq
    `load:... key:ESC key:Ctrl-e` (first ESC dismisses the splash), `key:+`xN to step; drive
    SONG PLAYBACK via `key:F2 ff:N tick:2` (ff: runs audio_frame() headless -> the per-frame
    recording populates). New driver `voices`/`wavedump` oracles confirmed the state:
    * /tmp/se-v6-1-idle-ins00.png — idle: all bands DIMMED navy sim (nothing played yet).
    * /tmp/se-v6-2-idle-loop-ins03.png — ins03 "Snare" idle: dimmed navy arp staircase +
      wave lanes REPLICATED across the full window; subtle darkgray loop lines every period
      (verified: wave $07 jumps 0C:7F/0A -> loops rows 0A,0B = period 2; PIL found 63 darkgray
      loop-line columns spaced ~13px in the Freq band).
    * /tmp/se-v6-3-play-ins04.png then -4-play-ins04-evolved.png — viewing ins04 "Flute" while
      voice2 sounds it: RECORDED bands (green ADSR envelope, cyan freq staircase, blue pulse
      sweep, purple LP+HP filter + yellow resonance, Tri+Gate lanes) that EVOLVE — the same
      voice's recording grew recLen 16 -> 72 between the two shots (bands extend right, more
      purple/cyan pixels), playhead riding the record head. NOT the idle sim.
    * /tmp/se-v6-5-switch-ins07.png — SWITCHED to ins07 "Lead" (voice1, recLen 20): different
      recorded envelope/freq/pulse, Pulse+Saw+Gate lanes; labels read the full words
      Noise/Pulse/Saw/Tri/Test/Ring/Sync/Gate.
    * /tmp/se-v6-6-exit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic tracker fully
      restored (Instruments/Wave/Pulse/Filter/Tracks tables), no lingering graph pixels. The
      restored Wave table cross-checks the recordings (ins04 row 0D=00/11 tri+gate; ins03
      07..0B then 0C:7F/0A).
  - Recorded-vs-sim CONFIRMED: idle shots are dominated by dim navy (palette 16) + darkgray;
    play shots drop the dim content and gain vivid mode-coloured filter (purple 141,59,151),
    cyan freq, blue pulse, green ADSR — and change with recLen over time. Loop lines confirmed
    as subtle darkgray verticals distinct from the red trigger + white playhead.
  - READ-ONLY CONFIRMED: grep finds NO writes to song.{instrumentTable/waveTable/pulseTable/
    filterTable/superTable/insLabels} in soundedit.d or visualizer.d.
  - Regenerated `make map` (visualizer synopsis updated to mention the recording; idempotent —
    `make check-map` "fails" only vs the uncommitted HEAD, orchestrator commits). No shortcut/
    CLI/flag/help-registry change -> no KEYBOARD.md / man-page regen needed.
  - NOTE (headless): the Output band needs a real audio device to fill `captureBuf`, so it is
    flat under headless song playback (documented in §11.5); the SID-STATE bands (ADSR/Freq/
    Pulse/Filter/Wave) DO populate from `ff:` because they read the per-frame recording.
    NOT done: data editing / write-back / undo (P4+, still read-only).
- (v7 AUTO-FIT X-AXIS ZOOM to the note's full duration, §12 2026-07-07) Still READ-ONLY.
  Files: `src/ui/soundedit.d` (dynamic window + scale label + all bands scaled),
  `src/audio/visualizer.d` (RECORD_FRAMES bumped 138 -> 1650 >= MAX_VIS; new
  `getRecordedAmpEnd(v,eps)` helper), `.claude/skills/run-cheesecutter/driver.d` (new
  read-only `insdump` oracle to pick fast-R vs slow-R instruments). Regenerated ARCHITECTURE.md.
  - **§12.1 dynamic `visFrames`** replaces the fixed `VISIBLE_FRAMES=128` post-trigger span.
    New `computeVisFrames(ins)` = MAX of (a) the ADSR-derived duration
    `attackFrames+decayFrames+NOMINAL_GATE_FRAMES+releaseFrames` (A/D/R from the SID ms tables
    at FRAME_MS) and (b) the actual recorded extent when the viewed voice has a live recording:
    `getRecordedAmpEnd(v,AMP_EPS)` returns one-past the last frame whose envelope amp>eps — if
    that's < the record head, silent frames follow so the note ENDED and its real end wins over
    the table; else (still sounding) `max(baseline, recLen)` grows the window. Clamped to
    `[MIN_VIS=24, MAX_VIS=1600]`. Computed ONCE per draw at the top of `update()` and threaded
    through as the `visFrames`/`totalFrames` members (never recomputed per band).
  - **§12.2 everything scales to the dynamic window.** `xForFrame` now maps
    `[-RESTART_FRAMES, visFrames]` across `plotWpx` (dynamic frames-per-pixel = zoom). EVERY band
    loop, both sims' MAXF caps (`simPulse/simFilter/simWaveFrames` replicate up to visFrames),
    the trigger divider, the playhead (record head clamped to visFrames) and the loop-lines use
    `visFrames`/`totalFrames`, so they stay aligned at any zoom. Unobtrusive scale label
    `scale 0-N f (~X.Xs)` printed at the top of the plot gutter (frames + seconds at FRAME_MS).
    RECORD_FRAMES raised to 1650 (>= MAX_VIS + pre-roll) so a long slow-release note records to
    its real end.
  - enter/exit, z-order chrome guard, F12 help, F1..F3, the fixed 8-row wave band, loop lines,
    and recording-vs-dimmed-sim behaviour all UNCHANGED.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (touched the shared audio.visualizer -> full clean build; ccutter 7512328,
    ccdriver relinked).
  - Smoke (headless dummy SDL), tunes/vent-arkijuusto.ct. New `insdump` oracle listed every
    instrument's SR/R nibble -> picked FAST **ins00 "HihatClosed"** (SR=00, R=0) vs SLOW
    **ins06 "Bgtr"** (SR=9B, R=B, a 2400 ms release).
    * /tmp/se-v7-fast-ins00.png — ENTER seq `load:... key:ESC key:Ctrl-e`: scale label reads
      **"scale 0-50 f (~1.0s)"** — ZOOMED IN (small span). (ins00 is percussive, sustain=0, so
      the dim idle envelope collapses early, but the axis IS fitted to the 50-frame ADSR total.)
    * /tmp/se-v7-slow-ins06.png — `key:+`x6 -> ins06: scale label **"scale 0-172 f (~3.4s)"** —
      ZOOMED OUT; the long release tail slopes across the ENTIRE plot width and ends near the
      right edge (no truncation). Release nibble = B, sustain = 9.
    * /tmp/se-v7-play-ins07.png — `key:F2 ff:24` then `key:+`x7 to view **ins07 "Lead"** while
      voice1 sounds it (recLen 116, still sounding): scale **"scale 0-116 f (~2.3s)"** (recording
      extent won). VIVID recorded bands — green ADSR envelope, cyan Freq staircase, blue Pulse
      sweep, purple LP+HP Filter + resonance, Pulse/Saw/Gate bit-lanes — with the WHITE playhead
      at the record head (right edge) and the red trigger divider at the left edge, all bands
      aligned at the new zoom.
    * /tmp/se-v7-exit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic tracker fully
      restored (Instruments/Wave/Pulse/Filter/Command/Tracks); the restored Instruments panel
      cross-checks the R nibbles (00:13/00, 06:04/9B, 07:67/B9).
  - SPAN-DIFFERS EVIDENCE (the core §12 check): ins00 R=0 -> 50 f (~1.0 s); ins06 R=B -> 172 f
    (~3.4 s) — a ~3.4x zoom difference driven purely by the release nibble; ins07 recording ->
    116 f (~2.3 s). Axis auto-fits each.
  - READ-ONLY CONFIRMED: grep finds NO writes to song.{instrumentTable/waveTable/pulseTable/
    filterTable/superTable/insLabels} in soundedit.d or visualizer.d; git status shows only code
    + the design doc + driver.d changed.
  - Ran `make map` — idempotent (no module's one-line synopsis first-sentence changed, so
    ARCHITECTURE.md is unchanged). No shortcut/CLI/flag/help-registry change -> no KEYBOARD.md /
    man-page regen needed.
    NOT done: data editing / write-back / undo (P4+, still read-only).
- (v9 MOUSE-HOVER PROBE + READOUT + LOOP-LINE SYNC, §14 2026-07-07) Still READ-ONLY. Files:
  `src/ui/window.d` (trailing `Window.hoverAt` no-op + `WindowSwitcher.hoverAt` forward),
  `src/ui/ui.d` (`UI.hoverAt` forwards to the active window when the Sound Editor is active),
  `src/ui/soundedit.d` (§14.1 probe + readout; §14.2 recording-derived loop detection),
  `.claude/skills/run-cheesecutter/driver.d` (new read-only `recdump:<voice>` oracle).
  - **§14.1 mouse-hover probe + numeric readout.** SDL plain mouse-motion (no button) already
    routes main.d -> `UI.hoverAt(x/FONT_X,y/FONT_Y)`; it now forwards to the active window and
    returns true (redraw) when `toplevel.soundEditorActive`, else keeps the menu-bar behaviour.
    `Window.hoverAt(scrx,scry)` is a TRAILING no-op virtual (vtable-safe); `WindowSwitcher`
    forwards to the active child. `SoundEditor.hoverAt` just records the hovered cell; `update()`
    maps it to a frame on the FRESH geometry (inverse of `xForFrame`, snapped + clamped to the
    note) and, only while the cursor is over the plot region, draws a DASHED white probe line
    (COL_PROBE=1) across all bands — distinct from the SOLID white playhead — plus a compact
    readout in the left param gutter: "frame N ~X.X ms" (N*FRAME_MS, labelled approximate), then
    Freq (raw + note via a reg->Hz->MIDI `noteName`) / Pulse / Filter cutoff+Res+Mode+Route /
    Ctrl byte + decoded bit words (Noise/Pulse/Saw/Tri/Test/Ring/Sync/Gate) / Env %. Values come
    from the RECORDING when a note has played (per-frame arrays) else the read-only sims; the ADSR
    Env is the INTERPOLATED continuous envelope (`adsrAmpAt`) on the sim path. Leaving the plot
    (or a dialog/menu via `chromeActive`) clears it (probe drawn last, after the early return).
  - **§14.2 loop lines sync with actual value repeats.** BUG: loop lines were drawn from the
    SIM's frame-0 `loopFrame`/`loopPeriod` in BOTH paths, so on the RECORDING path they drifted
    left of where the played values actually repeat (the recording includes the real gate-on/arp
    delay). FIX: new `loopFromRecording(v,n)` derives the loop DIRECTLY from the recorded per-frame
    array — the smallest period P>=2 for which the tail is exactly P-periodic and the earliest
    frame L where that begins (a constant one-cycle "hold" is rejected; needs >=2 full cycles).
    Wave/Pulse/Filter/Freq bands use it in the recording path (on control/pulse/cutoff/freq resp.);
    the idle-sim path keeps the sim `loopFrame`/`loopPeriod` (confirmed on the value-repeat frame,
    no off-by-one: the line at loopFrame sits where value[loopFrame]==value[loopFrame+period]).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7514344, ccdriver 7569944). Touched the widely-imported `Window` base
    (trailing virtual) -> full clean build, as required.
  - Smoke (headless dummy SDL), 160x50 screen; plot region cells x=39..156, band rows 7..36.
    * /tmp/.../se-v9-hover-A.png — vent ins03 idle, `hover:90,20` -> dashed white probe at frame 31
      + readout "frame 31 ~618.5 ms / Note abs 64 / Pulse $800 / Filter n/a / Ctrl $81 / Noi Gat /
      Env 18%" (sim path, interpolated envelope).
    * /tmp/.../se-v9-hover-B.png — `hover:120,25` -> probe MOVED to frame 55, readout now
      "frame 55 ~1097.2 ms ... Env 0%" (changed with the cursor).
    * /tmp/.../se-v9-hover-outside.png — `hover:90,20` then `hover:90,45` (below the stack) ->
      probe line AND readout CLEARED.
    * /tmp/.../se-v9-hover-rec-ins07.png — play (`key:F2 ff:24`), view ins07 (voice1 recording,
      recLen 116): RECORDING readout "frame 34 ~678.3 ms / Freq $0E82 A-3 / Pulse $230 /
      Cut $0300 Res F / Mode LPHP Rt1 / Ctrl $61 / Pul Saw Gat / Env 73%" — real reg values.
    * /tmp/.../se-v9-loop-rec-scarzix.png — scarzix ins03 "Chords" while playing (voice2 recLen 96,
      a period-18 6-note chord arp): loop lines coincident with the recorded arp repeat. PIL scan
      of the Freq band found loop-line columns x=340,388,435,482,530,577 == xForFrame(1,19,37,55,
      73,91); the `recdump:2` freq array through the same detection = LOOP L=1 P=18. So the lines
      sit EXACTLY on value[L]==value[L+P] — including the 1-frame gate-on offset the old sim
      frame-0 line missed (§14.2 fix confirmed).
    * /tmp/.../se-v9-loop-sim-ins03.png — vent ins03 idle (wave $07 = 2-frame arp): PIL scan found
      loop lines every 2 frames (x=441=xForFrame(3), 461,481,... period 2) coincident with the sim
      freq staircase repeat (value[f]==value[f+2]); no off-by-one.
    * /tmp/.../se-v9-f12-zorder.png — hover then `key:F12`: the Sound Editor help dialog renders
      clean over the editor, ZERO probe/graph pixel bleed (chromeActive suppresses the probe).
    * /tmp/.../se-v9-exit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic tracker fully
      restored (Instruments/Wave/Pulse/Filter/Command/Tracks), no lingering probe/graph pixels.
  - READ-ONLY CONFIRMED: grep finds NO writes to song.{instrumentTable/waveTable/pulseTable/
    filterTable/superTable/insLabels} in the changed files.
  - Ran `make map` — idempotent (ARCHITECTURE.md unchanged; no synopsis/dep-edge change). No
    shortcut/CLI/flag/help-registry change -> no KEYBOARD.md / man-page regen needed.
    NOT done: data editing / write-back / undo (P4+, still read-only).

- (v11 PHASE A — HEADLESS WAVEFORM CAPTURE, §16.4 2026-07-08) Still READ-ONLY. Makes the Output
  band's `captureBuf` fillable with NO audio device so the waveform is screenshottable headless
  (prior Output fixes were blind: the `ff:`/dummy-driver path never runs `sid_fillbuffer` + the
  capture-copy, so `captureBuf` stayed flat). NO Sound Editor axis/band/render code touched (that
  is Phase B/C). Files:
  - `src/audio/audio.d` — factored the capture-copy block (samples + gate bit + decay-to-silence
    stop) out of `audio_callback_2` into a shared `private void captureBlock(short*, int) nothrow`
    (callback behavior identical); added `void renderKeyjamCapture(int ticks)` — the offline
    capture path. With `SDL_LockAudio` held (mirrors `renderPcm`/`fastForward` device handling),
    it runs `ticks` iterations of the SAME per-tick loop the live callback uses:
    `sid_fillbuffer(mixbuf, callbackInterval, cyclesPerFrame)` -> `captureBlock` -> `audio_frame()`,
    filling BOTH `captureBuf` (Output) and the `rec*` visualizer arrays deterministically. No song
    writes.
  - `.claude/skills/run-cheesecutter/driver.d` — added `jamrender:<key>,<ticks>` (default 120):
    presses the keyjam piano key via the normal `press()`/keypress -> `playNote` path (arms the
    note + `captureStart`), then calls `audio.audio.renderKeyjamCapture(ticks)`; prints capLen/
    gateLen. Added its `--help` line. Read-only.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7531032, ccdriver 7571128).
  - VERIFIED headless (dummy SDL): `load:tunes/vent-arkijuusto.ct key:ESC key:Ctrl-e key:+ key:+
    key:+ key:+ jamrender:q,120 tick:2 shot:/tmp/se-phaseA.png` -> capLen=12479 gateLen=26; the
    Output band shows a NON-FLAT triangle envelope (ins 04 Flute, wave=tri): ramps from the
    trigger, peaks, decays. A second shot (`key:+ key:+ jamrender:e,200` -> /tmp/se-phaseA-2.png,
    capLen=15839 gateLen=33) shows a DIFFERENT Output shape (ins 02 Basari, note e): fast attack,
    longer sustained decay — confirms the waveform is real and varies with instrument/note.
    The whole point (SEE the waveform, not reason about it) is achieved.
  - NOT done: §16.2/16.3 shared-axis + pixel-accurate Output re-alignment (Phase B/C); editing (P4+).
- (v11 PHASE B+C — REAL-TIME SHARED AXIS + CORRECT OUTPUT BAND, §16.2/§16.3 2026-07-08) Still
  READ-ONLY. Root cause: two conflated clocks. The recorded bands (recAmp/recFreq/..), the Output
  captureBuf and the playhead (recLen) are indexed per PLAYER TICK (runs `multiplier`x/screen
  frame), but FRAME_MS=19.95ms, the ADSR ms->frames conversion, the nominal gate and the "~X s"
  label assumed SCREEN frames. At multiplier==2 (vent-arkijuusto.ct) they desynced (label ~2x
  long; ADSR/restart geometry at half the recorded bands' scale). Files: `src/ui/soundedit.d`
  (axis unification), `src/audio/audio.d` (silence-stop gate).
  - **§16.2 one real-time axis.** Replaced the compile-time `FRAME_MS=19.95` with a per-draw
    `tickMs = SCREEN_FRAME_MS / multiplier` (multiplier from `audio.audio.multiplier`, clamped
    >=1), refreshed at the TOP of `update()` before any ms<->tick use. `tickMs` is the REAL
    duration of one axis index (one player tick), so EVERY ms<->tick conversion now agrees at any
    multiplier: `computeVisFrames` (ADSR ms tables /tickMs), `drawAdsrBand` + `adsrAmpAt` sim
    (aF/dF/rF = ms/tickMs), the scale label (`secs = visFrames*tickMs/1000`), and the probe
    readout (`ms = f*tickMs`). The fixed 46-tick `NOMINAL_GATE_FRAMES` became a real-time
    `NOMINAL_GATE_MS=918` converted to `nominalGateFrames = round(918/tickMs)` each draw, so the
    sim gate hold scales with the multiplier too. The recorded bands, playhead (recLen), sims
    (per-tick), trigger divider, restart marker, loop lines and hover probe were ALREADY per-tick,
    so they need no change — folding the ms-side onto the tick axis is the whole fix.
  - **§16.3 Output band pixel-accurate + time-aligned via the SHARED axis.** `drawOutputBand` now
    maps each horizontal pixel column x through the EXACT inverse of `xForFrame` to a tick range
    [t0,t1), then to samples [t0*spTick, t1*spTick) where `spTick = freq*(tickMs/1000)` = samples
    per tick (== captureFrameSamples, but derived from real time), drawing the min/max of that
    sample range (classic per-pixel oscilloscope). This is pixel-accurate AND lands the waveform
    at the SAME instant as the ADSR/Freq/Pulse/Filter/Wave bands + playhead/probe (all via the one
    axis). Peak auto-gain kept (raw level arbitrary). Begins at the trigger, runs forward, flat
    past the recording.
  - **§16.3 Output extent no longer cut short.** `src/audio/audio.d`: the decay-to-silence capture
    stop (`captureBlock`) fired during a quiet/slow ATTACK onset (the onset is near-silent, so the
    silence run tripped the stop once past the freq/4 minimum), cutting the waveform to ~13 frames.
    Added a `captureWasLoud` gate: the stop is only allowed AFTER a block >= SILENCE(200) has been
    seen (reset in `captureStart`, set in `captureBlock`). Slow-attack notes now record their full
    length; the captureCap hard bound still applies. Live-playback behaviour unchanged (a real note
    still stops at its release tail once it has been audible).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (touched shared audio.audio -> full clean build; ccutter 7531096, ccdriver 7571208).
  - VERIFIED headless (dummy SDL) at BOTH multipliers, tunes/vent-arkijuusto.ct, ins04 "Flute"
    (triangle, AD=FF slow 8000ms attack). ENTER seq `load:... key:ESC key:Ctrl-e key:+ key:+ key:+
    key:+`, then `mult:<n> jamrender:q,200 hover:100,20 tick:2 shot:...`:
    * /tmp/se-v11bc-mult2.png — Rate 2*50hz. Output = a DETAILED triangle waveform spanning the
      FULL window (no longer cut short: capLen=95995 = the whole 200-tick render), ramping up
      (slow attack). Scale label "scale 0-198 f (~2.0s)". Probe (frame 99) reads "~987.5 ms /
      Env 12%" — 99*9.975ms=987ms, and 987/8000=12.3% -> the ADSR envelope tracks the probe.
    * /tmp/se-v11bc-mult1.png — Rate 1*50hz. SAME 198 recorded ticks, but scale label reads
      "~4.0s" (200 ticks = 4.0s wall-clock at mult=1 vs 2.0s at mult=2 — real-time correct; the
      OLD code read ~4.0s at BOTH, i.e. 2x too long at mult=2). Probe (frame 99) reads
      "~1975.1 ms / Env 25%" (99*19.95=1975ms; 1975/8000=24.7%). The Output wedge is visibly
      thicker at the probe than mult=2 — amplitude envelope matches Env% at both multipliers.
    * /tmp/se-v11bc-zoom-crop.png — mult=1 short flute render (jamrender:m,20), Output band cropped
      + NEAREST-upscaled: a real TRIANGLE waveform with individual cycles resolved, amplitude
      ramping from the trigger — pixel-accurate, NOT blocky/aliased. Cyan restart marker + red
      trigger divider visible in the pre-roll; flat baseline before the note and past the recording.
    * /tmp/se-v11bc-exit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic tracker fully
      restored (Instruments/Wave/Pulse/Filter/Command/Tracks), no lingering graph pixels. ins04
      row cross-checks FF 33 09 80 .. 0D.
  - ALIGNMENT/SCALE EVIDENCE (core §16 check): at the SAME tick index (frame 99) the probe shows
    987ms/Env12% at mult=2 vs 1975ms/Env25% at mult=1 — both correct for their real time; the
    scale label shows 2.0s vs 4.0s for the same tick count; the Output amplitude, ADSR Env% and
    the probe all agree at both multipliers. Silence-stop fix: capLen went from being cut short to
    the full render (95995 samples at mult=2).
  - READ-ONLY CONFIRMED: grep finds NO writes to song.{instrumentTable/waveTable/pulseTable/
    filterTable/superTable/insLabels} in soundedit.d or audio.d; git status shows only those two
    code files changed.
  - Ran `make map` — idempotent (no module synopsis first-sentence changed; ARCHITECTURE.md
    unchanged). No shortcut/CLI/flag/help-registry change -> no KEYBOARD.md / man-page regen.
    NOT done: data editing / write-back / undo (P4+, still read-only).

- (v12a ZOOMABLE/PANNABLE VIEWPORT + TICK-SNAPPED SELECTION + ZOOM CONTROLS, §17.1/§17.2/§17.3
  2026-07-08) Still READ-ONLY. Builds on the v11 real-time shared tick axis. Files:
  `src/ui/soundedit.d` (viewport + selection + controls + mouse handlers), `src/ui/help.d`
  (F12 View/zoom section). The horizontal scrollbar (§17.4) is deliberately NOT built this
  phase — a blank row is reserved for it below the control row.
  - **§17.1 viewport model.** Added a view window `[viewStartTick, viewEndTick]` (doubles, in
    ticks) over the shared axis. `xForFrame` now maps `[viewStartTick,viewEndTick]` across
    `plotWpx` (was the whole note `[-RESTART_FRAMES, visFrames]`), clamped to the plot box; new
    `tickForPixel` is its exact inverse. Default = FIT = the whole note incl. the restart pre-roll
    (`fitViewport`); `clampViewport` keeps the user's zoom within `[-RESTART_FRAMES, visFrames]`
    with a MIN_VIEW_SPAN=4 floor. `userZoomed` preserves a user zoom across instrument/recording
    changes until Fit; otherwise every draw re-fits (auto-fit default kept). Because ALL bands/
    playhead/trigger/restart/loop-lines/probe/Output go through the ONE map, they follow zoom+pan
    automatically — refactored: Output band + ADSR sim + probe inversions now use `tickForPixel`;
    single-line markers (trigger/restart/playhead/selection edges/loop lines) are skipped when
    off-view via `frameInView` instead of clamping to a plot edge; every per-frame band loop is
    clipped to the visible integer-frame range (`visRange`, from `viewFrameLo/Hi`) so nothing
    piles up at the clamped edges when zoomed in.
  - **§17.2 tick-snapped selection.** Left-drag on the plot marks `[selStartTick,selEndTick]`,
    each edge SNAPPED to the integer tick grid (`snapPixelToTick` = lround(tickForPixel)) — the
    native per-tick rate (1/frame at 1x, 2/frame at 2x; the axis index IS the tick, so integer
    snapping matches the rate automatically). Drawn as a subtle translucent-looking wash (a sparse
    every-3px blue vertical hatch across the whole stack, BEFORE the bands so graphs stay legible)
    + brighter light-blue solid edges (AFTER the bands). Range shown in the control row readout
    ("sel A-B t (~ma-me ms, N t)"). Hover probe (no button) kept; button-held drag = selection
    (routed via new `clickedAt`/`draggedTo`/`releasedAt` overrides — pre-existing base virtuals,
    no vtable change). A plain click (press+release, no motion) or Backspace clears it.
  - **§17.3 zoom controls.** A subtle control-button row reserved above the (future) scrollbar row:
    `[-]` zoom out (x2 about centre), `[+]` zoom in (x0.5), `[Fit]` whole note, `[Sel]` zoom to the
    selection (no-op if none). Hit-tested in `clickedAt` like the menu bar (cells recomputed
    identically in the drawer + hit-test via `zoomButtons`). Non-keyjam keys bound (letters/digits
    are keyjam): Left/Right pan ~1/4 view, Home = Fit, End = zoom-to-selection, Backspace = clear
    selection. All documented in the F12 HELPSOUNDEDITOR page (new "View / zoom" section; still 1/1).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7536184, ccdriver 7592920).
  - VERIFIED by SEEING (headless dummy SDL), tunes/vent-arkijuusto.ct, ins04 "Flute" (triangle),
    ENTER seq `load:... key:ESC key:Ctrl-e key:+ key:+ key:+ key:+`, Output made visible with
    `mult:2 jamrender:q,200` (capLen=95995). Plot cells x=[39,156) y=[7,34); control row = cell
    row 35; buttons [-]@40, [+]@44, [Fit]@49, [Sel]@55.
    * /tmp/se-v12a-full.png — fit view: all 6 bands + control row "[-] [+] [Fit] [Sel]  view
      -10-198 t   (drag to select)", scale "0-198 f (~2.0s)".
    * /tmp/se-v12a-select.png — `drag:60,15,100,25` -> blue translucent hatch across the whole
      stack + light-blue edges; readout "sel 28-99 t  (~279-988 ms, 71 t)" (28*9.975=279,
      99*9.975=988). Graphs stay legible through the wash.
    * /tmp/se-v12a-sel-zoom.png — `click:55,35` ([Sel]) -> viewport zoomed to ticks 28-99; Output
      now resolves individual TRIANGLE cycles (more detail), Freq staircase spreads out, ALL bands
      aligned at the new zoom.
    * /tmp/se-v12a-zoomin.png / -zoomout.png / -fit.png — `click:44,35`([+]) narrows about centre
      (bigger cycles); `click:40,35`([-]) widens back; `click:49,35`([Fit]) restores view -10-198 t
      (full envelope; the sel hatch re-maps to ticks 28-99 — selection stored in ticks, survives
      zoom).
    * /tmp/se-v12a-key-panleft.png / -panright.png / -home.png — after [+][+] zoom: LEFT -> "view
      55-107 t", RIGHT RIGHT -> "view 81-133 t", HOME -> "view -10-198 t" (fit). All correct
      (pan step = 1/4 span).
    * /tmp/se-v12a-key-end.png / -bksp.png — drag-select then END -> viewport zoomed to sel 28-99
      (same as [Sel]); BACKSPACE -> hatch cleared, readout back to "view 28-99 t (drag to select)".
    * SNAPPING mult=1 vs mult=2 (/tmp/se-v12a-mult1-select.png): the SAME pixel drag snaps to the
      SAME integer ticks 28-99 at both, but ms differ correctly — mult=2 "~279-988 ms" (tickMs
      9.975, scale ~2.0s) vs mult=1 "~559-1975 ms" (tickMs 19.95, scale ~4.0s). Edges land on
      integer ticks (native grid) at both rates.
    * /tmp/se-v12a-hover.png — hover probe (no button) still works: dashed white line + readout
      "frame 64 ~638.4 ms / Freq $1168 C-4 / ... / Env 8%", coexisting with the control row.
    * /tmp/se-v12a-f12-help.png — F12 shows "Sound Editor help 1/1" WITH the new "View / zoom"
      section (drag/[-][+][Fit][Sel]/Left-Right/Home/End/Backspace); renders clean over the editor,
      ZERO graph-pixel bleed (z-order intact).
    * /tmp/se-v12a-cleanexit.png + -plainexit.png — `key:Ctrl-e` exits: "Sound Editor closed.",
      classic tracker fully restored (Instruments/Wave/Pulse/Filter/Command/Tracks), no lingering
      graph pixels. (KEYJAM indicator shows only after jamrender left a jam note armed; a plain
      enter/exit exit shows no KEYJAM — not a regression.)
  - READ-ONLY CONFIRMED: grep finds NO writes to song.{instrumentTable/waveTable/pulseTable/
    filterTable/superTable/insLabels} in soundedit.d or help.d; git status shows only those two
    code files (+ the pre-existing §17 design-doc edit) changed.
  - Ran `make map` (synopsis mentions the zoomable viewport; the map's truncated synopsis + dep
    edges are unchanged -> ARCHITECTURE.md idempotent) and `make docs` (man pages + KEYBOARD.md
    unchanged — the F12 help is a ContextHelp page, not a com.shortcuts registry entry, and no
    CLI flag was added).
  - NOT done this phase: §17.4 horizontal scrollbar (blank row reserved); data editing / write-back
    / undo (P4+, still read-only).

- (v12b HORIZONTAL SCROLLBAR, §17.4 2026-07-08) Still READ-ONLY. Builds on the v12a viewport.
  Files: `src/ui/soundedit.d` (scrollbar draw + pan/page mouse handling), `src/ui/help.d`
  (one F12 line). Fills the blank row v12a reserved below the `[-][+][Fit][Sel]` control row.
  - **§17.4 scrollbar on the reserved row.** Drawn on `g.scrollRow` (= `rawTopRow-1`, one row
    below `controlRow`), spanning the SAME cells the plot bands span (`plotX0px/FONT_X` ..
    `+plotWpx/FONT_X`). The TRACK = the whole Fit range `[-RESTART_FRAMES, visFrames]`; the THUMB
    = the current viewport `[viewStartTick, viewEndTick]` as a fraction of that. Both are the
    full-block glyph (197 — the only fully-solid cell in font.psf, found by scanning glyph bit
    counts); the COLOUR distinguishes them — dim darkgray track (11) under, brighter lightgray
    thumb (15) over. At Fit the thumb fills the track (all lightgray); zoomed in it's a shorter
    lightgray run with darkgray track on either side. All TEXT cells (`screen.setChar`), so it
    composites like the rest of the chrome; drawn in `update()` right after `drawZoomControls`,
    and only in the non-`chromeActive` path (drawTextChrome wipes the row each frame, so it's
    blank under a dialog/menu — matches the control row).
  - **Interaction, hit-tested by ROW.** `clickedAt`: a left-press on `g.scrollRow` grabs the thumb
    if it lands within the thumb cells (records `scrollGrabOffset` = tick-on-full-axis under the
    press minus `viewStartTick`), else PAGES by one viewport width toward the click
    (`panBy(±span)`). A scroll-row press sets `clickWasButton` so its paired release neither
    finalises nor clears a selection. `draggedTo`: while `scrollDragging`, sets
    `viewStart = scrollTickForCell(x) - scrollGrabOffset`, keeps the span, `clampViewport()` — a
    pan that keeps the thumb under the grab point. `releasedAt` ends the drag. A press on the
    scroll row NEVER starts a plot selection and a plot drag never pans the scrollbar (rows are
    disjoint), satisfying the §17.4 hit-test-by-row rule. Reuses v12a `panBy`/`clampViewport`/
    `MIN_VIEW_SPAN`, so the scrollbar shares the exact viewport clamping/min-span.
  - **F12 help:** added one line under the "View / zoom" section — "Scrollbar...............Drag
    the thumb to pan; click the track to page". Still ONE page (1/1).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7536728, ccdriver 7593448).
  - VERIFIED by SEEING (headless dummy SDL), tunes/vent-arkijuusto.ct, ins04 "Flute" (triangle),
    ENTER seq `load:... key:ESC key:Ctrl-e key:+ key:+ key:+ key:+ mult:2 jamrender:q,200`
    (capLen=95995). Scroll row = cell row 36; track = plot cells 39..155 (x 312..1247).
    * /tmp/se-v12b-1-fit.png — Fit: the thumb FILLS the track (a single lightgray run, 936px =
      all 117 cells; PIL: light run x312..1247, no darkgray). Readout "view -10-198 t".
    * /tmp/se-v12b-2-zoomin.png — `click:44,35`x2 ([+][+]): thumb now SHORTER than the track,
      cells 83..111 (232px) with darkgray track filling 39..82 + 112..155. Readout "view 68-120
      t"; Output resolves wider individual triangle cycles (pixel-accurate).
    * /tmp/se-v12b-3-pan.png — `drag:97,36,55,36` (grab thumb, drag left along the scroll row):
      thumb SLID to cells 41..69 (width kept 29); readout PANNED "view 68-120 t" -> "view -7-45
      t"; the red trigger divider + restart marker + Freq staircase + Tri/Gate lanes all shifted
      into view together (bands + waveform + playhead follow the pan). Output waveform starts
      partway (silent pre-roll left of the trigger).
    * /tmp/se-v12b-4-page.png — `click:145,36` (track, right of the thumb): PAGED right by one
      view width; thumb moved 41..69 -> 70..98; readout "view -7-45 t" -> "view 45-97 t".
    * /tmp/se-v12b-5-f12.png — `key:F12`: "Sound Editor help 1/1" WITH the new "Scrollbar ... Drag
      the thumb to pan; click the track to page" line under View / zoom; renders clean over the
      editor, ZERO graph-pixel bleed (z-order intact).
    * /tmp/se-v12b-6-exit.png — `key:Ctrl-e` exits: "Sound Editor closed.", classic tracker fully
      restored (Instruments/Wave/Pulse/Filter/Command/Tracks), no lingering scrollbar/graph pixels.
  - READ-ONLY CONFIRMED: grep finds NO writes to song.{instrumentTable/waveTable/pulseTable/
    filterTable/superTable/insLabels} in soundedit.d or help.d (all song.* refs are reads into
    locals / sims); git status shows only those two code files changed.
  - Ran `make map` + `make docs` — both idempotent (no synopsis/dep-edge change; F12 help is a
    ContextHelp page, not a com.shortcuts registry entry or CLI flag, so KEYBOARD.md/man pages/
    ARCHITECTURE.md are unchanged).
  - NOT done: §17.5 remaining polish / data editing / write-back / undo (P4+, still read-only).

- (v13 SEMANTIC COLOURS EVERYWHERE + BUTTON BG + DOTTED SCROLLBAR, §18 2026-07-08) Still
  READ-ONLY. Mechanical colour refactor: the Sound Editor now goes through the semantic palette
  (com.palette) like the rest of ccutter — no magic colour indices. UI chrome -> `Role.*` (via
  `idx()`), graph colours -> named `BaseColor.*` (tier-1 configurable).
  - `src/com/palette.d`: 7 new roles after `soundeditSelection` — `soundeditValue`(yellow),
    `soundeditButtonBg`(darkgray), `soundeditButtonLabel`(white), `soundeditScrollTrack`(darkgray),
    `soundeditScrollThumb`(gray), `soundeditSelEdge`(lightblue), `soundeditDim`(darkgray). Added to
    the `Role` enum, `defaultRoleBase`, and the `roleByName` JSON map (key == role name). Existing
    defaults untouched, so the classic editor renders identically.
  - `src/ui/soundedit.d`:
    * import now pulls `BaseColor` too.
    * Replaced the whole `enum int COL_*` block: Role-backed chrome became `@property int` getters
      (COL_TITLE/HEAD=cursor, COL_LABEL=text [was darkgray -> now readable light], COL_VALUE=
      soundeditValue, COL_CTRL=text, COL_CTRL_LBL=soundeditButtonLabel, NEW COL_CTRL_BG=
      soundeditButtonBg, COL_SCROLL_TRACK/THUMB, COL_SEL_WASH=soundeditSelection, COL_SEL_EDGE=
      soundeditSelEdge, COL_DIM/DIMFILL=soundeditDim); graph colours stay compile-time enums using
      named `BaseColor.*` (COL_SEP/AXIS=darkgray, CURVE/TRACE/FREQ_REL=lightgreen, LOOP=orange,
      LOOPLINE=gray, PULSE_FILL=blue, PULSE_LINE=lightblue, FILT_LINE/RSTCURVE=lightred, TRIGGER=
      red, RESTART/FREQ_ABS=cyan, RSTFILL=brown, RES=yellow). Dropped unused COL_FILT_FILL. Added
      GLYPH_DOTS=176 (CP437 light-shade) next to GLYPH_BLOCK=197.
    * `filterModeColor` returns named BaseColor.* per filter mode (was numeric).
    * `BITLANE_COL` = named BaseColor.* array (lightgreen/lightblue/orange/purple/cyan/green/
      yellow/lightgray).
    * `drawZoomControls`: buttons now drawn with `COL_CTRL_BG` background (was bg 0), so
      `[-][+][Fit][Sel]` read as buttons; info readout still COL_CTRL on bg 0.
    * `drawScrollbar`: track glyph changed BLOCK->GLYPH_DOTS in COL_SCROLL_TRACK (dotted darkgray);
      thumb stays solid GLYPH_BLOCK in COL_SCROLL_THUMB (mid-gray).
    * NOTE: `COL_PROBE = 1` (hover-probe, line ~1377) is a separate local enum OUTSIDE the spec's
      COL_* block; left unchanged per "apply exactly" — it is the one remaining bare FG index
      (semantically == Role.cursor/white). Flagged for the verifier.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7555272, ccdriver 7598232).
  - VERIFIED by SEEING (headless dummy SDL), tunes/vent-arkijuusto.ct, ins05 "Arppi":
    * /tmp/se-v13.png — spec ENTER seq (`key:ESC key:Ctrl-e key:+*5 mult:1 jamrender:q,60
      drag:70,15,110,25`): (a) param labels Octave/Attack/Decay/... and band labels Output/ADSR/
      Freq/Pulse/Filter-res + "scale 0-58 f" + raw-data labels are LIGHT/readable (not darkgray);
      (b) values (yellow) readable; (c) `[-] [+] [Fit] [Sel]` sit on a visible darkgray background;
      (d) scrollbar present (thumb fills track at this near-fit zoom); (e) graph colours correct —
      envelope/ADSR green, output trace green, selection blue wash, bit-lanes coloured (Gate
      lightgreen, Pulse yellow, Saw green, Tri cyan, etc.).
    * /tmp/se-v13-sel.png (+ crop /tmp/se-v13-sel-scroll.png) — `drag:70,15,110,25 key:END`
      (zoom-to-selection shrinks the viewport): scrollbar TRACK now clearly a row of sparse
      darkgray DOTS (glyph 176) on both sides of a solid MID-GRAY thumb. Glyph 176 renders fine as
      sparse dots — no need to fall back to 177.
    * /tmp/se-v13-classic.png — `key:ESC tick:2` classic tracker: frames/text/instrument list/
      Wave/Pulse/Filter/Command/Tracks all render with normal colours; the new palette roles did
      NOT disturb the classic editor (they only ADD roles; existing defaults unchanged).
  - READ-ONLY CONFIRMED: no writes to song.* table slices in soundedit.d (only local buffers +
    `screen.data` framebuffer). NO MAGIC COLOUR INDICES in the refactored surfaces: all colour
    args are Role/BaseColor-backed constants or variables; remaining bare integers are bg `0`
    (black backdrop, conventional) and glyph codes (197/176), plus the flagged COL_PROBE=1.
  - Files touched: `src/com/palette.d` (7 roles), `src/ui/soundedit.d` (COL_* block + filterMode/
    BITLANE + button bg + dotted scrollbar), `doc/SOUND_EDITOR_LOOP.md` (this entry).
  - Ran neither `make map`/`make docs` change — no synopsis/dep-edge/CLI-flag/shortcut change (the
    palette JSON roles are documented in doc/palette.json schema, not the generated man pages).
  - NOT done: data editing / write-back / undo (P4+, still read-only). Did not commit/grade.

- (P4a ENVELOPE + SCALAR EDITING, §19.5 2026-07-09) FIRST editing pass — no longer read-only.
  The per-instrument SCALAR bytes are now editable in the Sound Editor, both numerically in the
  left column AND by dragging the ADSR curve; nothing shared, BYTE-IDENTICAL to the classic
  InsTable (same `instrumentTable[ins + col*48]` writes). P4b/c (pulse/filter/wave PROGRAM
  editing) intentionally NOT done — pointer rows stay display-only.
  - Editable: Attack (AD hi), Decay (AD lo), Sustain (SR hi), Release (SR lo); Restart TYPE
    (col2 bits 6-7, cycle hard/soft/3fr preserving bits 0-5); Gate delay (col2 low nibble, now
    its OWN param row); HR wave (col3 byte); HR SR (col6 byte).
  - `src/ui/soundedit.d`:
    * `class SoundEditor : Window, Undoable` — implements com.session `Undoable`:
      snapshotInstruments() does `insertUndo(this, {tableData:[song.instrumentTable.dup]})`;
      `undo(v){ song.instrumentTable[] = v.tableData[0]; }`;
      `createRedoState(){ r.tableData=[song.instrumentTable.dup]; }`. ONE insertUndo per gesture
      (per keypress; once at ADSR drag's first tick). Global Ctrl-Z/Y (Ctx.global, keymap.d)
      dispatch to us for free.
    * PARAM_ROWS 11->12: added named ROW_* enum + a new "Gate dly" row after "Restart" (so
      Left/Right edits the gate nibble directly and Shift-Left/Right can always pan — a clean,
      consistent scheme). Editable rows show a `<value >` marker; a hint line "L/R edit
      Shift+L/R pan" sits under the param block.
    * Left-column keys: Up/Down select; Left/Right decrement/increment the SELECTED editable
      row (nibbles clamp 0..15, Restart cycles the type, HR bytes clamp 0..255); on a
      non-editable (pointer) row OR with Shift held, Left/Right PAN the viewport instead
      (view-pan moved OFF bare Left/Right). Letters/digits still keyjam.
    * ADSR-curve drag: adsrHandlePositions() computes the 4 A/D/S/R handle centres from the
      bytes (attack peak, decay->sustain knee, sustain-level grab, release tail);
      drawAdsrHandles() draws square markers (grabbed one lights red); adsrHandleAt() hit-tests
      within ADSR_HIT_PX=9. clickedAt grabs the nearest handle (before the plot drag-select),
      draggedTo maps mouse->nearest SID nibble via the ms tables (X for A/D/R, Y for S) and
      rewrites the byte each tick, releasedAt re-triggers. One undo snapshot at the first drag
      tick; a plain click with no drag writes nothing.
    * retriggerIfSounding(): after a keypress commit / drag release, if a keyjam note is held it
      re-triggers via inputKeyjam so the new envelope is audible at once (never per drag tick).
  - `src/ui/input.d`: InputKeyjam gains `noteHeld()` (heldKeys non-empty) and `retrigger()`
    (re-`playNote(element)` with the active instrument) — the only new surface, trailing.
  - `src/ui/help.d`: HELPSOUNDEDITOR (F12) gains an "Editing the sound" section (Left/Right per
    row, ADSR drag, Ctrl-Z/Y) and moves pan onto Shift-Left/Right. Static ContextHelp, so no
    man-page / KEYBOARD.md / ARCHITECTURE.md drift (make docs + make check-map both clean).
  - `.claude/skills/run-cheesecutter/driver.d`: added a test-only `insbytes` oracle — dumps the
    active instrument's 8 raw bytes from the live instrumentTable (the byte-parity oracle).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries.
  - VERIFIED by driving ccdriver (tunes/vent-arkijuusto.ct, ins00 HihatClosed, headless dummy):
    * keyboard: each editable row's Left/Right lands the exact expected byte — Attack 13->73,
      Decay 13->15, Sustain ->50, Release ->57, Restart cycle 40->00 (soft->3fr, low nibble
      kept), Gate ->06, HR wave 80->82, HR SR ->09; Shift-Right on a row makes no byte change
      (pans). Screens /tmp/se-p4a-enter.png, /tmp/se-p4a-attack.png (attack ramp lengthens).
    * byte-parity: after editing to AD=75 SR=57, Ctrl-E to the classic editor shows Instruments
      row `00:75 57 40 80 ...` — identical (/tmp/se-p4a-classic.png).
    * undo: Ctrl-Z 13->23->33 then 33->23->13; Ctrl-R redo ->23.
    * ADSR drag: attack handle 13->a3 (drag right), sustain handle 00->d0 (drag up), decay
      handle 13->19 (drag right). Screens /tmp/se-p4a-drag-attack.png, -drag-sustain.png.
    * re-trigger: with a note held ('q'), a keypress edit and a handle drag both fire playNote
      without crashing (/tmp/se-p4a-retrigger.png).
  - Classic editor intact: enter/exit clean ("Sound Editor closed."), tables render normally.
  - NOT done: P4b/c program editing, P4d polish. Did not commit/grade (loop orchestrator/verifier).
- (v-est WHITE-DOTTED ADSR ESTIMATE overlaid on the recording, §19 2026-07-09) Files:
  `src/ui/soundedit.d` ONLY (drawing + one nominal constant; read-only re: song data —
  no byte-editing logic touched). Verifier grades separately; not committed.
  - **§19.1 sustain = 50 axis units.** `nominalGateFrames` is no longer derived from
    `NOMINAL_GATE_MS/tickMs` (was ~46-92 depending on multiplier) — it's a fixed **50**
    ("frames" as shown on the scale label). One assignment change keeps the estimate
    curve, the ADSR drag handles (`adsrHandlePositions`/`adsrDragUpdate`), the hover
    `adsrAmpAt` Env% helper, and `computeVisFrames`'s idle window-fit all consistent at
    50. `NOMINAL_GATE_MS` left defined but unused; the member initialiser + comment updated.
  - **§19.2 exponential estimate matching the recording's shape.** New module-level
    `expEnvLevel(float frac) nothrow` mirrors the visualizer's e^-5 decay/release curve.
    BOTH `amp()` closures (the `drawAdsrBand` per-pixel estimate and the `adsrAmpAt` hover
    helper) now use it: decay `= sLvl + (1-sLvl)*expEnvLevel((f-aF)/dF)`, release
    `= clamp01(sLvl*expEnvLevel((f-gateEnd)/rF))`. Attack stays linear; sustain hold
    unchanged. Estimate curve, hover Env%, and the recording now agree in SHAPE.
  - **§19.3 always draw the estimate as WHITE DOTTED; keep the recorded curve.** New
    `COL_ESTIMATE = BaseColor.white`. In `drawAdsrBand`: the `useRec` branch still draws
    the solid green recorded polyline (`COL_CURVE`) but no longer `return`s — it falls
    through, and the estimate per-pixel loop ALWAYS runs, drawing the AD/SR-derived curve
    as a white dotted line (`if((x & 2) == 0) video.olPoint(x, y, COL_ESTIMATE)`, still
    skipping pre-roll `f<0` columns) instead of the old dim solid polyline. So: idle ->
    white-dotted estimate only; after a keyjam note -> solid green recording + white-dotted
    estimate overlaid, the estimate updating live as A/D/S/R are edited. Restart pre-roll
    drawing kept.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` ->
    exit 0, both binaries (ccutter 7556072, ccdriver 7615640).
  - Smoke (headless dummy SDL), tunes/vent-arkijuusto.ct, ENTER seq `load:... key:ESC key:Ctrl-e`:
    * /tmp/se-est-1-idle.png — ins00 "HihatClosed" (AD13 SR00, sustain 0): white-dotted
      estimate = attack ramp then exponential decay to 0 (no plateau since S=0).
    * /tmp/se-est-2-idle-full.png — `key:+`x6 -> ins06 "Bgtr" (AD04 SR9B): white-dotted
      estimate shows fast attack, exponential decay to sustain ~9/15, ~50-unit sustain
      plateau, then exponential release tail. Scale "0-302 f".
    * /tmp/se-est-3-edited.png — `key:Right`x6 on Attack (AD 04->64, filename shows `*`):
      the white-dotted estimate grew a visible attack RAMP at the left — changed live.
    * /tmp/se-est-4-overlay.png — after `jamrender:q,80` on ins06 (voice0 hasRec=true
      recLen=78): the ADSR band shows BOTH the solid GREEN recorded curve (held at the
      sustain level) AND the white-dotted estimate (decay+release) overlaid.
    * /tmp/se-est-5-overlay-edited.png — then edit Sustain to F (`Down`x2 `Right`x8,
      SR->FB): the white-dotted estimate's plateau jumped to full height + longer release
      tail — the estimate moves with the edit while the green recording is still drawn.
  - READ-ONLY CONFIRMED: `git diff --stat 1eeb37f -- src/` = soundedit.d only (+41/-22);
    grep of the diff finds NO new `song.{instrumentTable/waveTable/pulseTable/filterTable/
    superTable/insLabels}[...] =` writes.
  - No shortcut/CLI/flag/help-registry change -> no KEYBOARD.md / man-page / ARCHITECTURE.md
    regen needed (module synopsis first-sentence unchanged). Did not commit/grade.

- (P4b-1 PULSE/FILTER PROGRAM LEVEL EDITING + SHARED-PROGRAM WARN/FORK, §20.1/§20.2/§20.4
  2026-07-09) Second editing pass. The pulse (col5) and filter (col4) SweepTable programs
  are now editable from their graph bands by dragging a step's LEVEL (init byte b2), with
  the §19.6 shared-program warn/fork. Writes song data (pulse/filterTable b2 + instrument
  pointer byte on fork). Add/delete-step + loop-drag are P4b-2 (NOT done). Files:
  `src/ui/soundedit.d` (drag + fork infra + multi-table undo), `src/ui/help.d` (F12 line),
  `.claude/skills/run-cheesecutter/driver.d` (read-only `sweepdump:P|F` oracle).
  - **§20.1 drag a step's LEVEL.** A vertical grab inside the Pulse band (index 3) or Filter
    band (index 4) plot region begins a "sweep level drag". `sweepBandAt` hit-tests the band
    AFTER the ADSR handles / scrollbar / zoom buttons and before the plot drag-select (so all
    those keep working; selection is only preempted inside the two sweep bands). `sweepRowAtPress`
    maps the press X -> frame (tickForPixel) -> the active SweepTable row via `simPulse/simFilter`'s
    `rowOf[frame]`. `draggedTo` maps mouse Y -> value on the band's exact pixel scale (inverse of
    the drawer's `y = botPx - v*h/maxVal`) and rewrites that row's b2: PULSE inverts simPulse's
    encoding `b2 = ((pw>>8)&0x0f) | (pw & 0xf0)` (pw 0..4095, steps of 16); FILTER `b2 = cutoff>>3`
    (cutoff 0..2047). Band redraws live from the byte (WYSIWYG).
  - **§20.2 shared-program warn/fork at PRESS.** `sweepProgramRows` walks the b3 jump chain
    (same traversal as the sims). `sweepProgramShared` = the instrument's program shares any row
    with another instrument's program (walk all 48 pointer bytes + chains). If shared and undecided
    this session, `clickedAt` pops a `ConfirmationDialog` ("This pulse/filter program is shared.
    Fork a private copy (y/n)?") and does NOT start the drag (modal takes over; the user drags
    again after choosing). Y -> `forkSweepProgram`: `seekTableEnd`-allocate (`song.tPulse/tFilter.
    seekTableEnd()`), copy the program's rows ascending (preserves b3==0 fall-through adjacency),
    relocate internal b3 jump targets to the new base, repoint ONLY this instrument's col5/col4
    byte; capacity guard `base+count > 0x3f` aborts with a statusline msg (no corruption). N ->
    edit in place (classic; changes all sharers), remembered per program (`sweepEditShared[table]
    [startRow]`) so it doesn't re-prompt. Non-shared programs edit directly.
  - **§20.3 undo.** Level drag: ONE `snapshotAllTables(false)` at the first drag tick (all 6
    tables in the classic `tableIterator` order). Fork: `snapshotAllTables(true)` (+ insLabels).
    `undo`/`createRedoState` extended: length==1 = the P4a instrument-only snapshot, length>1 =
    all-tables restore via `tableIterator` (mirrors the classic HexTable all-tables undo). Ctrl-Z
    reverts the whole gesture. Retrigger a held keyjam note after the gesture (release / fork).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7558296, ccdriver 7637208). Did NOT touch a base class (soundedit.d,
    help.d, driver.d only) but clean-built anyway.
  - VERIFIED by DRIVING + SEEING (headless dummy SDL), tunes/vent-arkijuusto.ct. Band cell rows:
    Pulse = 18-21, Filter = 22-24. New `sweepdump:P|F` oracle reads song.pulse/filterTable + every
    instrument's pointer (byte-parity + no-clobber oracle).
    * NON-SHARED PULSE (ins07, pul ptr $06 = rows {06,07}, not shared): drags at press y=20 to
      release y=18/19/20/21 land row07 b2 = 8e/79/54/00 (monotonic top->bottom); EVERY other byte
      + the pulse pointer unchanged. Two drags at x=70 vs x=120 hit rows 06 vs 07 (per-frame row
      pick). /tmp/se-p4b1-pulse-edit.png (band curve moved; raw strip 06:40 10 8E 07 / 07:B0 10 00 06).
    * BYTE-PARITY vs classic: after the pulse edit, Ctrl-E to the classic editor shows the classic
      Pulse table 06:40 10 8E 07 / 07:B0 10 00 06 -- identical (same song.pulseTable slice).
      /tmp/se-p4b1-exit.png ("Sound Editor closed.", tracker fully restored).
    * SHARED PULSE (ins0A pul ptr $01 = rows {01,02}, shared with ins06+ins16): drag -> fork prompt
      /tmp/se-p4b1-probe.png. Y=fork -> ins0A repoints $01->$08, rows 08/09 = relocated copy
      (jumps 02->09, 01->08), original rows 01/02 + ins06/ins16 pointers UNCHANGED, the edit (b2=79)
      lands only in the private row 09 (/tmp/se-p4b1-fork-yes.png). N=edit shared -> ptr stays $01,
      shared row02 b2 ff->8e, no fork (/tmp/se-p4b1-editshared-no.png) -> ins06/ins16 see it.
    * FILTER (ins0A flt ptr $01 = row {01} config, shared): fork -> ptr $01->$02, row01 unchanged,
      row02 = copy with b2 60->be (/tmp/se-p4b1-filter-fork.png); No -> row01 b2 60->be shared.
    * UNDO: level edit Ctrl-Z reverts row07 b2 8e->ff. Fork+edit = TWO gestures: Ctrl-Z #1 reverts
      the level edit (ptr stays $08), Ctrl-Z #2 reverts the fork (ptr $08->$01, rows 08/09 zeroed).
    * RETRIGGER: with note 'q' held, a pulse drag edits + retriggers without crashing
      (/tmp/se-p4b1-retrig.png). P4a scalar edit + undo still works (13->33->23).
    * F12 help renders (now 1/2, no crash) with the new "Drag in Pulse/Filter" line
      (/tmp/se-p4b1-f12.png).
  - SCOPE CONFIRMED: `git diff --stat 1f0f7ae -- src/ ...driver.d` = soundedit.d (+251) / help.d /
    driver.d only; the only song.* table writes in soundedit.d are instrumentTable (scalars + the
    fork pointer), pulseTable/filterTable [row*4+2] (b2 level), and insLabels (undo restore) --
    NO wave/super/chord writes.
  - Ran `make map` -> ARCHITECTURE.md regen ADDS soundedit's new dep edges (ct.base, ui.dialogs);
    no synopsis change. No com.shortcuts/CLI/flag change -> no KEYBOARD.md / man-page regen needed
    (the drag is internal mouse handling; F12 is a ContextHelp page). Did not commit/grade.
  - NOT done: P4b-2 (add/delete step + loop-marker drag), P4b-3 (filter res/mode), wave editing (P4c).

- (P4b-2 ADD/DELETE STEP + DRAGGABLE LOOP MARKER, §20.1/§20.2/§20.4 P4b-2 2026-07-09)
  Third editing pass. The pulse (col5) + filter (col4) SweepTable PROGRAMS can now have
  steps added/removed and their loop-back point dragged, from the graph bands. Reuses ALL
  the P4b-1 fork infra (`sweepProgramShared`/`promptSweepFork`/`forkSweepProgram`/
  `sweepEditShared`) + multi-table undo (`snapshotAllTables`). Writes song data (pulse/
  filter tables + the pointers/commands the ct.purge row-ops fix globally + the fork
  pointer/insLabels). Files: `src/ui/soundedit.d` (select/Ins/Del/loop-drag + helpers),
  `src/ui/help.d` (3 F12 lines). Regenerated `doc/ARCHITECTURE.md` (new soundedit->ct.purge
  dep edge). No driver change — reused the existing read-only `sweepdump:P|F` + `insbytes`
  oracles.
  - **§20 P4b-2(1) select a step.** A plain CLICK (press+release, no motion) inside the
    Pulse (band 3) or Filter (band 4) plot region selects the SweepTable row active at that
    frame (`sweepRowAtPress` -> the sim's `rowOf`). New members `selectedSweepTable
    (0 pulse / 1 filter / -1 none)` + `selectedSweepRow`; `drawSweepSelection` draws a bright
    WHITE outline (`olRect`, `COL_STEPSEL`) around the step's first contiguous frame span on
    the band. Selecting in one band clears the other (single var); switching instrument
    (`+/-`) clears it (`clearSweepSelection`, the row index is table-local). Selection is
    set at PRESS (non-mutating), so a plain click never pops a modal. A vertical DRAG in the
    band is still the P4b-1 LEVEL edit; the shared-program fork prompt moved from press to
    the FIRST DRAG-MOTION tick (so click-to-select and drag-to-edit coexist cleanly — the
    net shared/fork/edit behaviour + undo is unchanged from P4b-1, just triggered on motion).
  - **§20 P4b-2(2) add/delete a step (Ins/Del).** With a step selected, `SDLK_INSERT` inserts
    a row AFTER it and `SDLK_DELETE` removes it, via `ct.purge.pulse/filterInsertRow` /
    `...DeleteRow` (the classic row-ops that shift the table AND fix every instrument pointer
    + sequence command GLOBALLY). Ins/Del aren't com.shortcuts entries (registry Ins/Del are
    C.noteColumn/C.trackColumn, not active for Ctx.soundEditor), so they fall through to the
    editor's own `keypress`. `sweepRowOp` runs the §20.2 shared check first: shared+undecided
    -> `ConfirmationDialog` whose callback forks (`forkSweepProgram`, which now remaps
    `selectedSweepRow` into the private copy) or sets edit-shared, THEN performs the row-op —
    one Ins/Del press does it all. `doSweepRowOp` snapshots ALL tables + insLabels
    (`snapshotAllTables(true)`) before mutating. INSERT default: the new row copies the
    selected step's shape (b0/b1/b2) and INHERITS its (post-shift) jump b3, and the selected
    row now falls through (b3=0) into it — so the program stays valid (terminal/loop still
    resolves) and grows in place; selection -> the new row. DELETE: selection -> an adjacent
    program row (prev if still in the program, else the shifted row, else program start).
    Table-full guard: `sweepTableFull` refuses an Ins that would push a used row 0x3f off the
    end (statusline msg, no corruption). No selection -> statusline "Select a ... step first".
  - **§20 P4b-2(3) draggable loop marker.** `sweepLoopHandleAt` hit-tests the subtle loop
    line(s) (drawn at `loopFrame + k*period`) or, for a STOPPING program, a new grabbable end
    marker (`drawSweepEndMarker` draws a darkgray vLine at the program's stop frame) — checked
    BEFORE the level-drag so grabbing the loop line neither pans nor edits levels. Dragging
    (`sweepLoopDragUpdate`) maps the cursor frame -> its SweepTable row and sets the loop-
    CLOSING row's b3 (`sweepCloseRow` = the row whose b3 stops or jumps back) to that row —
    moving the loop-back point, or CONVERTING a $7f stop into a loop. Shared check + fork on
    the first drag tick (same as the level drag); one `snapshotAllTables(false)` per gesture;
    retrigger a held note on release.
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0,
    both binaries (ccutter 7576152, ccdriver 7638520).
  - VERIFIED by DRIVING + SEEING (headless dummy SDL), tunes/vent-arkijuusto.ct. Pulse band
    cell rows 18-21, Filter 22-24, plot cells x 39..155.
    * SELECT: `click:50,20` on ins07 -> the Pulse step gets a bright white outline
      (/tmp/se-p4b2-8...); sweepdump shows NO byte change (selection is non-mutating). Filter
      select `click:45,23` on ins0A -> white outline in the Filter band (/tmp/se-p4b2-13...).
    * INSERT (non-shared, ins07 pul $06 rows {06,07}): `click:50,20 key:INS` -> program grows
      to {06,07,08}: 06:40101000 (falls to 07) / 07:40101008 (new, copy of 06, b3->08) /
      08:b010ff06 (old 07 shifted, still loops to 06). All pointers valid (sweepdump).
      Exit to classic: the classic Pulse table shows the SAME rows byte-for-byte and Wave/
      Chord/Command tables intact (/tmp/se-p4b2-15...). DELETE `click:120,20 key:DEL` ->
      row07 removed, row06 b3 07->06 (self-loop), pointers intact.
    * SHARED (ins0A pul $01, shared w/ ins06+ins10): Ins -> "shared, fork? (y/n)" prompt
      (/tmp/se-p4b2-5..., zero graph bleed). Y=fork -> ins0A $01->$08, private copy rows
      08/09/0A with the inserted step, original rows 01/02 + ins06/ins10 ptrs UNCHANGED
      (/tmp/se-p4b2-6...). N=edit shared -> ptr stays $01, the row inserted into the shared
      {01,02,03}, EVERY instrument pointer >=02 re-fixed globally by the purge op (ins07
      06->07, ins09 05->06, ...) so all other programs still play (/tmp/se-p4b2-7...).
      Filter fork on ins0A $01->$02 likewise isolates (/tmp/se-p4b2-14...).
    * LOOP DRAG: ins07 grab the frame-114 loop line (cell 124) drag left -> loop-closing
      row07 b3 06->07 (only b3 changed; /tmp/se-p4b2-9...). STOP->LOOP: ins0D (pul $03, single
      row03=7f00907f STOP, non-shared) grab the end marker (cell 93) drag left -> row03 b3
      7f->03 (a self-loop; /tmp/se-p4b2-12...). Nothing else touched either time.
    * UNDO/REDO: Ins Ctrl-Z reverts to {06,07}; Ctrl-Y redoes to {06,07,08}. Loop-drag Ctrl-Z
      reverts row07 b3 07->06. Stop->loop Ctrl-Z reverts row03 b3 03->7f. Fork+Ins = two
      gestures (two Ctrl-Z: the level/row-op then the fork).
    * REGRESSION: P4b-1 level drag still edits b2 (ins07 row06 10->8e, b3 untouched); P4a
      scalar edit (ins00 AD 13->33) + undo/redo intact; F12 "Sound Editor help 1/2" renders
      clean over the editor with the new Click/Insert-Delete/loop-line lines (/tmp/se-p4b2-16).
      Enter/exit clean ("Sound Editor closed.", classic tracker fully restored).
  - SCOPE CONFIRMED: `git diff --stat 1e6e105 -- src/` = soundedit.d (+310/-15) + help.d only.
    The only table writes are pulse/filterTable (b2 level, b3 loop, seeded Ins rows), the
    ct.purge row-ops (pulse/filterTable + instrument pointers + seq commands — the globally-
    managed fixups), instrumentTable (scalars + fork pointer), insLabels (undo). NO wave/
    super/chord writes; classic tables intact.
  - Ran `make map` (ARCHITECTURE.md gains the soundedit->ct.purge dep edge; no synopsis change).
    No com.shortcuts/CLI/flag change -> no KEYBOARD.md / man-page regen (Ins/Del + loop drag
    are internal keypress/mouse handling; F12 is a ContextHelp page). Did not commit/grade.
  - NOT done: P4b-3 (filter resonance + mode editing), wave editing (P4c).

- (P4b-3 FILTER RESONANCE + MODE EDITING, §10.1/§10.2/§20.1/§20.4 P4b-3 2026-07-09) Fourth
  editing pass, the LAST P4b piece. The filter (col4) SweepTable program's per-frame RESONANCE
  and MODE (LP/BP/HP combos) are now editable from the Filter band, reusing ALL the P4b-1/2 fork
  infra (`sweepProgramShared`/`sweepDecided`/`promptSweepFork`/`forkSweepProgram`/`sweepEditShared`)
  + multi-table undo (`snapshotAllTables`) + retrigger. Writes ONLY filterTable b0 (mode nibble) /
  b1 (res hi nibble) + the reused fork pointer/rows + undo insLabels. Files: `src/ui/soundedit.d`
  (res drag + mode chip + config-row tracking), `src/ui/help.d` (2 F12 lines). No driver change
  (reused the read-only `sweepdump:P|F` oracle + the existing `drag`/`click` primitives).
  - **§10.2/§20.1 resonance drag.** `simFilter` now also emits `SweepSim.cfgRowOf[]` = the CONFIG
    row (last `b0&0x80` row at/before each frame) governing that frame's mode/res. `filterResHandleAt`
    hit-tests the DRAWN resonance line (ry = botPx - res*h/15) within RES_HIT_PX=6 of the click,
    at a column the filter program actually emits (`f` in `resOf` range) -> returns the governing
    config row. Checked in `clickedAt` BEFORE `sweepBandAt`/the P4b-1 cutoff-level drag (a res
    line sitting at the filter band's TOP edge falls in a cell the cell-top band split calls the
    Pulse band, so gating on it dropped max-res grabs -- the independent proximity test fixes that).
    `sweepResDragUpdate` maps mouse Y -> res 0..15 (inverse of the drawer) and writes the config
    row's b1 HIGH nibble, PRESERVING the low nibble (routing). Res drag state:
    `sweepResDragging`/`sweepResRow`/`sweepResMoved` (independent of the level-drag vars).
  - **§10.1/§20.1 mode chip.** A clickable `[MODE]` chip in the Filter band's left gutter (row 2,
    below "res"), drawn by `drawFilterModeChip` showing the first config row's `filterModeName` in
    its §10.1 `filterModeColor`. `filterModeChipAt` hit-tests the gutter row; checked in `clickedAt`
    BEFORE step-selection so clicking the chip cycles rather than selecting a step. `cycleFilterMode`
    -> `doCycleFilterMode` advances `b0`'s 0x70 bits through `FILTER_MODE_CYCLE =
    [0x10,0x20,0x40,0x30,0x60,0x50,0x70]` (LP->BP->HP->LP+BP->BP+HP->LP+HP->all->LP), preserving the
    0x80 config flag + low nibble. During playback the recorded-mode fill recolours per §10.1
    (idle preview stays dim navy by the v6 recording-view design; the chip is the idle mode indicator).
  - **§20.2/§20.3 shared + undo.** Both edits run the shared check on the first mutating tick (res
    drag: first drag motion, like the level drag; mode chip: at click) -> shared+undecided pops the
    fork/edit-shared ConfirmationDialog. Res drag aborts on the prompt (user re-drags after choosing);
    the mode chip's dialog callback forks/edits-shared THEN cycles (fork+cycle = two undo gestures,
    matching P4b-1). `filterFirstConfigRow` is re-derived after a fork so the cycle/res lands in the
    private copy. Non-shared/decided edits `snapshotAllTables(false)` + write directly. No config row
    in the program -> res drag is a no-op (hit-test returns -1), mode chip shows a statusline hint.
    Retrigger a held keyjam note on release (res) / after the write (mode).
  - Build: `make -f Makefile.mac clean && make -f Makefile.mac -j4 ccutter ccdriver` -> exit 0, both
    binaries (ccutter 7577560, ccdriver 7639912).
  - VERIFIED by DRIVING + SEEING (headless dummy SDL), tunes/abaddon-trouble.ct (has filter config
    rows). Filter band rows ~21-25; res line at frame0 ~cell 43; mode chip at cell row 23. Instruments:
    ins03 flt $05 = row05 `C0 F1 60 7F` (HP res15, NON-shared); ins00/ins04 share flt $01 (first
    config row01 `E0 F1 50 00` = BP+HP).
    * RES DRAG (ins03, non-shared): `drag:43,21,43,24` -> row05 b1 `F1`->`11` (res 15->1, routing low
      nibble preserved; b0/b2/b3 untouched); only that byte + only that row changed (sweepdump:F); raw
      strip `05:C0 11 60 7F`. /tmp/se-p4b3-1-resdrag.png.
    * MODE CHIP (ins03, non-shared): 7 clicks cycle b0 `C0`->`B0`->`E0`->`D0`->`F0`->`90`->`A0`->`C0`
      (HP->LP+BP->BP+HP->LP+HP->all->LP->BP->HP), 0x80 flag + b1/b2/b3 preserved. Chip recolours
      lightblue([HP])->red([LP]) per §10.1 (/tmp/se-p4b3-2-modechip-LP.png). During playback the
      RECORDED filter fill is RED for the edited LP mode (/tmp/se-p4b3-7-play-LPfill.png).
    * CLASSIC PARITY: edit ins03 (mode+res) -> Ctrl-E to classic -> the classic Filter table shows
      `05: B0 61 60 7F` byte-for-byte (/tmp/se-p4b3-4b-classic.png; "Sound Editor closed.", tracker
      fully restored).
    * SHARED (ins04 flt $01, shared w/ ins00): mode chip click -> "filter program is shared, fork
      (y/n)?" prompt, zero graph bleed (/tmp/se-p4b3-3b-forkprompt.png). Y=fork -> ins04 $01->$06,
      forked row06 config cycled `E0`->`D0`, original rows 01-05 + ins00 ptr $01 UNCHANGED
      (/tmp/se-p4b3-3c-fork-yes.png). N=edit shared -> ptr stays $01, row01 `E0`->`D0` in place (ins00
      sees it), no fork. Shared RES drag -> fork -> re-drag lands res only in forked row06 `E0 11 50 00`,
      original row01 b1 stays F1 -> fork isolates.
    * UNDO: res drag Ctrl-Z reverts row05 b1 `11`->`f1`; mode cycle Ctrl-Z reverts row05 b0 `b0`->`c0`.
    * REGRESSION: P4b-1 pulse level drag still edits pulse b2 (ins04 row06 `01`->`8e`) and leaves
      filterTable UNTOUCHED (the res-check reordering doesn't hijack pulse edits); P4b-2 pulse
      select+Insert grows the program with the global purge pointer fixups (ins10 pul `08`->`09`);
      keyjam ('a' -> KEYJAM + SID regs); F12 "Sound Editor help 1/2" + page 2/2 render with the new
      "Drag the Filter res line" / "Click the Filter [mode] chip" lines (/tmp/se-p4b3-6b-f12-page2.png).
  - SCOPE CONFIRMED: `git diff --stat 5ea33a3 -- src/` = soundedit.d (+204) + help.d (+2) only. The
    only NEW table writes are `filterTable[cfg*4]` (mode b0) + `filterTable[sweepResRow*4+1]` (res b1);
    everything else (fork rows/pointer, undo insLabels, P4b-1/2 pulse/filter b2/b3, ct.purge row-ops)
    is reused. NO wave/super/chord writes; classic tables intact.
  - Ran `make map` -> ARCHITECTURE.md unchanged (idempotent; no new module dep or synopsis change).
    No com.shortcuts/CLI/flag change -> no KEYBOARD.md / man-page regen (res drag + mode chip are
    internal mouse handling; F12 is a ContextHelp page). Did not commit/grade (loop orchestrator/verifier).
  - NOT done: wave/arp editing (P4c), P4d polish. P4b (pulse+filter program editing) is now COMPLETE.
