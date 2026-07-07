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
