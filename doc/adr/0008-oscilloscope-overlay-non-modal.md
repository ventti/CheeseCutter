# 0008 — Oscilloscope overlay is a non-modal, text-cell window over the combined mix

**Status:** Accepted

## Context

We wanted a toggleable oscilloscope (`Shift-F12`) that shows the synthesized
audio waveform live, "same look and feel" as the Help / Export / Render dialogs,
usable while playing a song **and** while keyjamming.

Three facts about the engine shaped the design:

- **Only the combined signal is available cheaply.** reSID's
  `sid->clock(delta_t, buf, n)` (via `sid_fillbuffer` in
  `src/audio/resid/residctrl.cpp`) emits a single mixed mono stream. There is no
  per-voice PCM buffer; `Voice::output()` is only an instantaneous pre-filter
  sample, not a sample-rate stream. The mixed output is already captured in
  `audio.audio.mixbuf` (the buffer that feeds the sound card). So a *combined*
  scope is a free tap; per-voice scopes would need extra SID instances or edits
  to the vendored reSID clock loop. The feature was scoped to combined-only.
- **The existing overlays are modal.** Help/Export/Render are `Window`s shown via
  `UI.activateDialog`, which calls `enableKeyjamMode(false)` and routes *all* keys
  to the dialog. A scope built that way would disable keyjam and swallow the
  transport keys — the opposite of the requirement.
- **`mixbuf` is filled during both `Status.Play` and `Status.Keyjam`**
  (`isPlaying()` covers both), and under the `--vice`/`--ultimate` remote
  backends `audio_callback_2` still runs `sid_fillbuffer` (it mutes only the
  output *stream*, not `mixbuf`). So one `mixbuf` tap covers playback, keyjam and
  remote playback alike.

## Decision

Add a **non-modal** overlay, not a dialog:

- New `OscilloscopeWindow : Window` (`src/ui/oscilloscope.d`) whose `update()`
  draws a framed, titled window (reusing `Window.drawFrame`, so it matches the
  other overlays) and renders `mixbuf` into the character-cell `Screen` grid: a
  dim horizontal zero axis, then one full-block trace column per interior column,
  amplitude mapped about the midline with a fixed gain, vertical runs filled
  between adjacent samples for a continuous trace. When not playing it draws a
  flat line (the buffer holds stale samples otherwise).
- `UI` owns the window plus a `scopeVisible` flag; `Shift-F12`
  (`toggle_oscilloscope`, registered in `ui.keymap`, so it also gets a menu entry,
  F12-help line and `doc/KEYBOARD.md` row from the single registry) flips it.
- The overlay is drawn **last** each frame from `UI.timerEvent` / `UI.update`
  (`drawScope`), so it sits on top of everything repainted that tick and animates
  live. It is **suppressed while any real dialog is open** (`dialog !is null`) so
  the modal dialogs stay visually authoritative.

## Consequences

- Keyjam and playback keys keep working with the scope open — the whole reason it
  is not a dialog. The trade-off is that, unlike the modal dialogs, it does not
  own input or a close key of its own; `Shift-F12` toggles it and it hides itself
  behind any dialog you open.
- Rendering in the text grid (not pixels) keeps it inside the existing render
  path and the retro look, at the cost of coarse vertical/temporal resolution.
- Only the combined waveform is shown. Per-voice scopes remain possible later but
  would require the extra-SID-instance or reSID-tap work deliberately deferred
  here.
- Because `mixbuf` is filled only by the SDL audio callback (which never fires
  under `SDL_AUDIODRIVER=dummy`), headless driver shots need the `scopefill`
  command added to `ccdriver` (it runs the real `audio_callback_2` path) to show
  a waveform; otherwise the overlay correctly draws a flat line.
- The legacy `Oscilloscope` class in `src/com/fb.d` (an SDL1-surface relic behind
  the dead `VisMode.Oscilloscope`, whose `VideoStandard.drawVisualizer` is a
  stub) is left untouched and unrelated to this overlay.
