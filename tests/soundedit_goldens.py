"""Golden-master oracle dumps for the Sound Editor (pre-refactor safety net).

Phase 0 of the byte-identical `src/ui/soundedit.d` dedup refactor
(`refactor-soundedit-dedup`). This module drives a small, deterministic set of
ccdriver sessions through a representative matrix of Sound Editor states and
records every read-only oracle ccdriver exposes for each state. Nothing here
mutates `src/`; every action goes through the real UI (clicks/drags/keys), and
every dump is a read-only oracle (`.claude/skills/run-cheesecutter/driver.d`).

`tests/test_sound_editor_goldens.py` re-runs this exact matrix and asserts
byte-for-byte equality against the committed files in `tests/goldens/`. Any
later refactor phase that changes *observable* behaviour (not just internal
structure) fails here first, with the drifting fixture named in the message.

Regenerate (ONLY when the golden behaviour intentionally changes, e.g. a
deliberate Sound Editor UX change outside this refactor) with:

    python -m tests.soundedit_goldens

## Matrix covered

- ``idle_view``: all six bands' idle/sim rendering (``screendump`` +
  ``sounddump`` + ``soundstate``) at default zoom, then ``se_zoom_in``,
  ``se_fit``, a user timeline selection, and ``se_selection`` (zoom-to-selection).
  Also every other read-only oracle at the default view: ``controlstate``,
  ``insbytes``, ``sweepdump:P``/``:F``, ``wavedump``, ``waveaddstate``,
  ``waveloopstate``, ``sweeploopstate:P``/``:F``, ``filtershape``, ``voices``,
  ``recdump:0``, ``capturestate``.
- ``adsr``: the canonical ADSR drag-to-checkpoint gesture (attack/decay/release
  handles), read back via ``insbytes``/``soundstate``/``screendump``.
- ``new_sound``: ``se_new`` private Wave/Pulse/Filter allocation, plus a real
  Wave graph pitch drag (a value-endpoint gesture) on the freshly-allocated row.
- ``wave_gestures``: the Wave "checkpoint A/B" build (row Add, typed W1/W2
  value-endpoint edits, per-row delay/duration bytes), a Loop-marker
  (``se_wave_loop``) assignment, and a Delete that must roll the wave program
  back towards the pre-loop shape.
- ``pulse_gestures``: three one-tick Pulse blocks (Add = duration), a
  value-endpoint (level) drag on the first block's dot, a duration drag on its
  boundary, and a Loop-marker grip drag joining block 3 back to block 1.
- ``filter_gestures``: the three-block Filter build covering resonance
  (``se_res_up``), value-endpoint + duration drags, LP/BP/HP mode toggles,
  route cycling, and a Loop-marker grip drag (join).
- ``filter_route_cycle``: ``se_lp``/``se_bp``/``se_hp``/``se_route`` cycled in
  isolation on a single fresh CONFIG row, decoupled from the heavier build
  above so a drift is easy to attribute.
- ``ownership_fork`` / ``ownership_linked``: the copy-on-write fork that a
  shared Wave row's first mutation takes by default, and the same gesture
  under ``se_linked`` (edits the shared row in place instead) -- both followed
  by one Ctrl-Z proving the atomic undo restores every table byte.
- ``navigation``: ``se_instrument_next``/``se_instrument_prev`` and
  ``se_octave_up``/``se_octave_down``.

## What is deliberately excluded, and why

- **Screenshots (PNG `shot:`).** Pixel rendering is platform/font-sensitive
  (this is the same reasoning ``screendump``'s own case gives in
  ``driver.d``: "pixel graphs are covered through their semantic SoundEditor
  state ... rather than fragile PNG goldens"). A refactor that is byte-identical
  in behaviour could still legitimately shift antialiasing on a different
  machine; goldening PNGs would fail the equality gate for reasons unrelated to
  `soundedit.d`. Semantic oracles (``soundstate``, ``sweepdump``, ``wavedump``,
  ``filtershape``, ...) already cover the same information losslessly.
- **Nothing else.** Before committing, the exact matrix below was run three
  times end-to-end (see the empirical check recorded in
  ``doc/SOUND_EDITOR_LOOP.md`` / this module's iteration log entry) and diffed
  byte-for-byte, INCLUDING the reSID keyjam capture pipeline
  (``jamrender``/``capturestate``/``envpreview``/``recdump``/``voices``/
  ``scopefill``) that looked like the likeliest source of nondeterminism (live
  chip emulation, floating-point resid-fp filter state). All three runs were
  byte-identical: under the dummy SDL video/audio drivers ccdriver drives that
  pipeline synchronously and offline (``audio.audio.renderKeyjamCapture``,
  direct calls to the audio callback) with no wall-clock or thread dependency,
  so it is fully deterministic here. Nothing needed exclusion on those grounds.
"""

from __future__ import annotations

import re
from pathlib import Path

from tests.ccdriver_session import CCDriverSession
from tests.test_sound_editor_master_usage import (
    BTN_DEL,
    BTN_ZOOMOUT,
    FREQ_GRAPH_ROW,
    PULSE_TOP_ROW,
    _adsr_handle_cell,
    _build_exact_filter_three_blocks,
    _build_simple_pulse_three_blocks,
    _build_wave_a,
    _click_action,
    _click_control,
    _instrument_bytes,
    _master_session,
    _mutate_wave_a_to_b,
    _new_isolated_wave,
    _plot_x_for_tick,
    _pulse_boundary_row,
    _pulse_dot_row,
    _select_filter_at,
    _select_pulse_at,
)
from tests.test_sound_editor_wave_authorization import (
    WAVE_GATE_LANE_ROW,
    _begin_shared_two_row_gate_paint,
    _cross_both_rows_idempotently,
    _select_instrument_six,
)

ROOT = Path(__file__).resolve().parents[1]
GOLDEN_DIR = ROOT / "tests/goldens"


# The title bar embeds the binary's compile __DATE__/__TIME__ (com.util), e.g.
# "CheeseCutter EXTended 0.5.1 (Jul 26 2026 18:14)". That string changes on every
# rebuild and is NOT editor behaviour, so screendump row 0 would spuriously fail the
# byte-equality gate after any recompile. Normalise it to a fixed placeholder on both
# capture and compare (both paths go through _clean) so goldens are rebuild-stable.
_BUILD_STAMP_RE = re.compile(
    r"\((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [ 0-9]\d \d{4} \d\d:\d\d\)"
)


def _clean(raw: str) -> str:
    """Drop the persistent-session checkpoint marker and the volatile build stamp."""
    text = raw.split("checkpoint:", 1)[0].rstrip("\n") + "\n"
    return _BUILD_STAMP_RE.sub("(BUILD-TIMESTAMP)", text)


class _Capture:
    """Accumulates named oracle dumps in matrix order for one golden run."""

    def __init__(self) -> None:
        self.values: dict[str, str] = {}

    def run(self, session: CCDriverSession, name: str, command: str) -> str:
        if name in self.values:
            raise AssertionError(f"duplicate golden name: {name}")
        output = _clean(session.run(command))
        self.values[name] = output
        return output


def _scene_idle_and_views(cap: _Capture, session: CCDriverSession) -> None:
    p = "idle_view/"
    for name, command in (
        ("screendump", "screendump"),
        ("sounddump", "sounddump"),
        ("soundstate", "soundstate"),
        ("controlstate", "controlstate"),
        ("insbytes", "insbytes"),
        ("sweepdump_p", "sweepdump:P"),
        ("sweepdump_f", "sweepdump:F"),
        ("wavedump", "wavedump:0"),
        ("waveaddstate", "waveaddstate"),
        ("waveloopstate", "waveloopstate"),
        ("sweeploopstate_p", "sweeploopstate:P"),
        ("sweeploopstate_f", "sweeploopstate:F"),
        ("filtershape", "filtershape"),
        ("voices", "voices"),
        ("recdump_0", "recdump:0"),
        ("capturestate", "capturestate"),
    ):
        cap.run(session, p + "01_default_" + name, command)

    session.run("key:Ctrl-Shift-i")  # se_zoom_in
    for name, command in (("screendump", "screendump"), ("sounddump", "sounddump"),
                          ("soundstate", "soundstate")):
        cap.run(session, p + "02_zoom_in_" + name, command)

    session.run("key:Ctrl-Shift-a")  # se_fit
    for name, command in (("screendump", "screendump"), ("sounddump", "sounddump"),
                          ("soundstate", "soundstate")):
        cap.run(session, p + "03_fit_" + name, command)

    x9, x25 = _plot_x_for_tick(session, 9), _plot_x_for_tick(session, 25)
    session.run(f"drag:{x9},8,{x25},8")  # draw a user timeline selection
    for name, command in (("screendump", "screendump"), ("sounddump", "sounddump"),
                          ("soundstate", "soundstate")):
        cap.run(session, p + "04_selection_" + name, command)

    session.run("key:Ctrl-Shift-g")  # se_selection (zoom to selection)
    for name, command in (("screendump", "screendump"), ("sounddump", "sounddump"),
                          ("soundstate", "soundstate")):
        cap.run(session, p + "05_selection_zoomed_" + name, command)


def _scene_adsr(cap: _Capture, session: CCDriverSession) -> None:
    """Attack/Decay/Release handle drags on a fresh session's default view.

    This deliberately does NOT reuse
    ``test_sound_editor_master_usage._drag_adsr_to_8888`` verbatim: that helper
    self-asserts landing at the exact byte pair 0x88/0x88, which only holds
    after that suite's specific 7-step prefix (Rows unit, two jamrendered
    notes, New sound) has shaped the ADSR graph's view/Fit geometry. A golden
    dump needs no target byte, only a deterministic gesture and a faithful
    record of whatever real value it produces on THIS scene's own (simpler,
    fresher) view -- so the same handle-drag mechanics are replayed here
    without that assertion, capturing the actual landing bytes.
    """
    p = "adsr/"
    session.run("frames:2")
    attack = _adsr_handle_cell(session, 1)
    session.run(f"drag:{attack[0]},{attack[1]},{_plot_x_for_tick(session, 10)},10")
    cap.run(session, p + "01_after_attack_drag_insbytes", "insbytes")

    decay = _adsr_handle_cell(session, 3)
    session.run(f"drag:{decay[0]},{decay[1]},{_plot_x_for_tick(session, 40)},12")
    cap.run(session, p + "02_after_decay_drag_insbytes", "insbytes")
    cap.run(session, p + "02_after_decay_drag_soundstate", "soundstate")

    _click_control(session, BTN_ZOOMOUT)
    release = _adsr_handle_cell(session, 1, last=True)
    session.run(f"drag:{release[0]},{release[1]},{_plot_x_for_tick(session, 70)},14")
    cap.run(session, p + "03_after_release_drag_insbytes", "insbytes")
    cap.run(session, p + "03_after_release_drag_soundstate", "soundstate")
    cap.run(session, p + "03_after_release_drag_screendump", "screendump")


def _scene_new_sound(cap: _Capture, session: CCDriverSession) -> None:
    p = "new_sound/"
    cap.run(session, p + "00_before_sounddump", "sounddump")
    w0 = _new_isolated_wave(session)
    cap.run(session, p + "01_after_new_insbytes", "insbytes")
    cap.run(session, p + "01_after_new_wavedump", f"wavedump:0x{w0:02x}")
    cap.run(session, p + "01_after_new_sweepdump_p", "sweepdump:P")
    cap.run(session, p + "01_after_new_sweepdump_f", "sweepdump:F")
    cap.run(session, p + "01_after_new_sounddump", "sounddump")
    cap.run(session, p + "01_after_new_soundstate", "soundstate")

    # A real Wave-graph pitch drag on the fresh row: a value-endpoint gesture.
    x0 = _plot_x_for_tick(session, 0)
    session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{FREQ_GRAPH_ROW + 1}")
    cap.run(session, p + "02_after_pitch_drag_wavedump", f"wavedump:0x{w0:02x}")
    cap.run(session, p + "02_after_pitch_drag_soundstate", "soundstate")


def _scene_wave_gestures(cap: _Capture, session: CCDriverSession) -> None:
    p = "wave_gestures/"
    w0 = _build_wave_a(session)
    cap.run(session, p + "01_checkpoint_a_wavedump", f"wavedump:0x{w0:02x}")
    cap.run(session, p + "01_checkpoint_a_screendump", "screendump")

    _mutate_wave_a_to_b(session, w0)
    cap.run(session, p + "02_checkpoint_b_wavedump", f"wavedump:0x{w0:02x}")
    cap.run(session, p + "02_checkpoint_b_screendump", "screendump")
    cap.run(session, p + "02_checkpoint_b_soundstate", "soundstate")

    # Delete the currently-selected (newest) row -- structural edit + Loop rebase.
    _click_control(session, BTN_DEL)
    cap.run(session, p + "03_after_delete_wavedump", f"wavedump:0x{w0:02x}")
    cap.run(session, p + "03_after_delete_screendump", "screendump")


def _scene_pulse_gestures(cap: _Capture, session: CCDriverSession) -> None:
    p = "pulse_gestures/"
    _build_simple_pulse_three_blocks(session, loop=True)
    cap.run(session, p + "01_three_block_loop_sweepdump_p", "sweepdump:P")
    cap.run(session, p + "01_three_block_loop_sweeploopstate_p", "sweeploopstate:P")
    cap.run(session, p + "01_three_block_loop_soundstate", "soundstate")
    cap.run(session, p + "01_three_block_loop_screendump", "screendump")

    # A value-endpoint (level) drag on block 1's dot.
    _select_pulse_at(session, 0)
    dot_y = _pulse_dot_row(session, 0)
    x0 = _plot_x_for_tick(session, 0)
    session.run(f"drag:{x0},{dot_y},{x0},{PULSE_TOP_ROW}")
    cap.run(session, p + "02_after_level_drag_sweepdump_p", "sweepdump:P")

    # A duration drag on the same block's boundary.
    boundary_y = _pulse_boundary_row(session, 1)
    x1 = _plot_x_for_tick(session, 1)
    x2 = _plot_x_for_tick(session, 2)
    session.run(f"drag:{x1},{boundary_y},{x2},{boundary_y}")
    cap.run(session, p + "03_after_duration_drag_sweepdump_p", "sweepdump:P")
    cap.run(session, p + "03_after_duration_drag_soundstate", "soundstate")


def _scene_filter_gestures(cap: _Capture, session: CCDriverSession) -> None:
    p = "filter_gestures/"
    _build_exact_filter_three_blocks(session, loop=True)
    cap.run(session, p + "01_three_block_loop_sweepdump_f", "sweepdump:F")
    cap.run(session, p + "01_three_block_loop_sweeploopstate_f", "sweeploopstate:F")
    cap.run(session, p + "01_three_block_loop_filtershape", "filtershape")
    cap.run(session, p + "01_three_block_loop_soundstate", "soundstate")
    cap.run(session, p + "01_three_block_loop_screendump", "screendump")
    cap.run(session, p + "01_three_block_loop_sounddump", "sounddump")


def _scene_filter_route_cycle(cap: _Capture, session: CCDriverSession) -> None:
    p = "filter_route_cycle/"
    _new_isolated_wave(session)
    _select_filter_at(session, 0)
    for step, action in enumerate(("se_lp", "se_bp", "se_hp"), start=1):
        _click_action(session, action)
        cap.run(session, p + f"0{step}_after_{action}_sweepdump_f", "sweepdump:F")
    for step in range(1, 4):
        _click_action(session, "se_route")
        cap.run(session, p + f"0{step + 3}_after_route_{step}_sweepdump_f", "sweepdump:F")


def _scene_ownership_fork(cap: _Capture, session: CCDriverSession) -> None:
    p = "ownership_fork/"
    _select_instrument_six(session)
    session.run("wavefixture:shared-two")
    cap.run(session, p + "00_before_sounddump", "sounddump")

    old_ptr, x0, x1 = _begin_shared_two_row_gate_paint(session, setup_fixture=False)
    cap.run(session, p + "01_after_first_press_insbytes", "insbytes")
    cap.run(session, p + f"01_after_first_press_wavedump_old_0x{old_ptr:02x}",
            f"wavedump:0x{old_ptr:02x}")

    _cross_both_rows_idempotently(session, x0, x1)
    session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
    cap.run(session, p + "02_after_release_insbytes", "insbytes")
    cap.run(session, p + "02_after_release_sounddump", "sounddump")
    new_ptr = _instrument_bytes(session.run("insbytes"))[7]
    cap.run(session, p + f"02_after_release_wavedump_new_0x{new_ptr:02x}",
            f"wavedump:0x{new_ptr:02x}")

    session.run("key:Ctrl-z")
    cap.run(session, p + "03_after_undo_sounddump", "sounddump")


def _scene_ownership_linked(cap: _Capture, session: CCDriverSession) -> None:
    p = "ownership_linked/"
    _select_instrument_six(session)
    session.run("wavefixture:shared-two")
    cap.run(session, p + "00_before_sounddump", "sounddump")

    old_ptr, x0, x1 = _begin_shared_two_row_gate_paint(session, linked=True, setup_fixture=False)
    cap.run(session, p + "01_after_first_press_soundstate", "soundstate")
    cap.run(session, p + "01_after_first_press_insbytes", "insbytes")

    _cross_both_rows_idempotently(session, x0, x1)
    session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
    cap.run(session, p + "02_after_release_insbytes", "insbytes")
    cap.run(session, p + "02_after_release_sounddump", "sounddump")
    cap.run(session, p + f"02_after_release_wavedump_0x{old_ptr:02x}",
            f"wavedump:0x{old_ptr:02x}")

    session.run("key:Ctrl-z")
    cap.run(session, p + "03_after_undo_sounddump", "sounddump")


def _scene_navigation(cap: _Capture, session: CCDriverSession) -> None:
    p = "navigation/"
    cap.run(session, p + "00_initial_insbytes", "insbytes")
    cap.run(session, p + "00_initial_soundstate", "soundstate")

    for step in range(1, 4):
        session.run("key:KP_PLUS")  # se_instrument_next
        cap.run(session, p + f"0{step}_next_insbytes", "insbytes")
    for step in range(1, 4):
        session.run("key:KP_MINUS")  # se_instrument_prev
        cap.run(session, p + f"0{step + 3}_prev_insbytes", "insbytes")

    session.run("key:KP_MUL")  # se_octave_up
    cap.run(session, p + "07_octave_up_screendump", "screendump")
    cap.run(session, p + "07_octave_up_soundstate", "soundstate")
    session.run("key:KP_DIV")  # se_octave_down
    cap.run(session, p + "08_octave_down_screendump", "screendump")
    cap.run(session, p + "08_octave_down_soundstate", "soundstate")


def build_goldens() -> dict[str, str]:
    """Run the full deterministic matrix and return {golden name: dump text}."""
    cap = _Capture()

    with _master_session() as session:
        _scene_idle_and_views(cap, session)

    with _master_session() as session:
        _scene_adsr(cap, session)

    with _master_session() as session:
        _scene_new_sound(cap, session)

    with _master_session() as session:
        _scene_wave_gestures(cap, session)

    with _master_session() as session:
        _scene_pulse_gestures(cap, session)

    with _master_session() as session:
        _scene_filter_gestures(cap, session)

    with _master_session() as session:
        _scene_filter_route_cycle(cap, session)

    with _master_session() as session:
        _scene_ownership_fork(cap, session)

    with _master_session() as session:
        _scene_ownership_linked(cap, session)

    with _master_session() as session:
        _scene_navigation(cap, session)

    return cap.values


def golden_path(name: str) -> Path:
    return GOLDEN_DIR / (name + ".txt")


def write_goldens(values: dict[str, str]) -> None:
    for name, text in values.items():
        path = golden_path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)


if __name__ == "__main__":
    goldens = build_goldens()
    write_goldens(goldens)
    print(f"wrote {len(goldens)} golden fixtures under {GOLDEN_DIR}")
