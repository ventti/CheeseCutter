"""Sub-cell precision for the Sound Editor's continuous-value drags.

Mouse events reach the UI as character cells, but the graph bands are only ~5 cells
tall, so a value read off a cell centre could reach barely 5 positions no matter how
wide its range: ~745 of 4096 pulse widths apart, or 5 of 16 sustain levels. Each drag
now reads the exact mouse pixel row (com.fb.mousePixelY, published by main.mainloop
and by the driver's `dragpx`), matching the pixel its band draws the value at.

The pitch band's equivalent contract lives in test_sound_editor_wave_gestures.py.
"""

from __future__ import annotations

import re
import unittest

from tests.ccdriver_session import CCDriverSession
from tests.test_sound_editor_master_usage import (
    PULSE_GRAPH_ROW,
    PULSE_TOP_ROW,
    _instrument_bytes,
    _master_session,
    _plot_x_for_tick,
)
from tests.test_sound_editor_ownership_usage import _sweep_row

FONT_Y = 14  # com.fb.FONT_Y
CURSOR_VERTICAL = 2  # com.ui.soundedit CURSOR_VERTICAL: the ADSR sustain handle


def _cell_centre(cell_row: int) -> int:
    return cell_row * FONT_Y + FONT_Y // 2


def _sustain(session: CCDriverSession) -> int:
    return (_instrument_bytes(session.run("insbytes"))[1] >> 4) & 0x0F


def _find_sustain_handle(session: CCDriverSession) -> tuple[int, int]:
    """The sustain dot's current cell, located through its real hover cursor contract.

    Scanned narrowly: CURSOR_VERTICAL is also advertised by frequency-band pitch rows
    just below, and the dot moves vertically as the value changes.
    """
    for y in range(9, 16):
        for x in range(100, 116):
            session.run(f"hover:{x},{y}")
            match = re.search(r"cursor=(\d+)", session.run("soundstate"))
            if match is not None and int(match.group(1)) == CURSOR_VERTICAL:
                return x, y
    raise AssertionError("no visible ADSR sustain handle advertised CURSOR_VERTICAL")


PITCH_PROBE = re.compile(
    r"plot=(?P<plot_left>\d+)\.\.(?P<plot_right>\d+) "
    r"band=(?P<top>\d+)\.\.(?P<bottom>\d+) h=(?P<height>\d+) "
    r"scale=(?P<scale>\d+) latched=(?P<latched>-?\d+) row=(?P<row>-?\d+) "
    r"value=\$(?P<value>[0-9a-f]+) pitch=(?P<pitch>-?\d+) "
    r"drawnY=(?P<drawn_y>-?\d+) mouseY=(?P<mouse_y>-?\d+) "
    r"valueAtMouseY=(?P<value_at_mouse>-?\d+) delta=(?P<delta>-?\d+) "
    r"stepPx=(?P<step_px>[\d.]+) dragging=(?P<dragging>\w+)"
)


def _pitch_probe(session: CCDriverSession) -> dict[str, float]:
    """Parse the pitchprobe oracle: where the block is drawn vs where the cursor is."""
    out = session.run("pitchprobe")
    match = PITCH_PROBE.search(out)
    if match is None:
        raise AssertionError("pitchprobe did not report geometry\n" + out)
    fields = match.groupdict()
    probe: dict[str, float] = {"dragging": fields["dragging"] == "true"}
    probe["value"] = int(fields["value"], 16)
    probe["step_px"] = float(fields["step_px"])
    for key in (
        "plot_left", "plot_right", "top", "bottom", "height", "scale", "latched",
        "row", "pitch", "drawn_y", "mouse_y", "value_at_mouse", "delta",
    ):
        probe[key] = int(fields[key])
    return probe


def _grab_a_pitch_block(session: CCDriverSession, probe: dict[str, float]) -> tuple[int, int]:
    """Press on a draggable pitch block, returning its cell column and pixel row.

    Scanned rather than computed: the plot's left edge is the restart pre-roll, which
    holds no authored row, and the band's first/last cell rows straddle its border.
    """
    first_plot_cell = int(probe["plot_left"]) // 8
    for cell_y in range(int(probe["top"]) // FONT_Y + 1, int(probe["bottom"]) // FONT_Y):
        pixel_y = cell_y * FONT_Y + FONT_Y // 2
        for cell_x in range(first_plot_cell, first_plot_cell + 14):
            session.run(f"presspx:{cell_x},{pixel_y}")
            if _pitch_probe(session)["dragging"]:
                return cell_x, pixel_y
            session.run(f"releasepx:{cell_x},{pixel_y}")
    raise AssertionError("no cell in the frequency band started a pitch drag")


class SoundEditorPitchTrackingTests(unittest.TestCase):
    """The dragged block must stay under the cursor -- the user-visible contract."""

    # 160x50 is the layout minimum; the real app autoscales to ~90% of the desktop, so
    # a 170x63 grid is what this project's reference display produces. Band height (and
    # therefore pixels per semitone) differs by ~3.6x between them.
    GEOMETRIES = (("minimum", ["screen:160x50"]), ("autoscale", ["wide", "screen:170x63"]))

    def _session(self, extra: list[str]) -> CCDriverSession:
        import shutil
        import tempfile
        from pathlib import Path

        from tests.test_sound_editor_master_usage import SOURCE_SONG

        self._tmp = tempfile.TemporaryDirectory(prefix="cc-pitch-")
        fixture = Path(self._tmp.name) / "sound-editor.ct"
        shutil.copyfile(SOURCE_SONG, fixture)
        return CCDriverSession(*extra, f"load:{fixture}", "key:ESC", "key:Ctrl-e")

    def test_dragged_block_follows_the_cursor(self) -> None:
        from tests.test_sound_editor_master_usage import (
            _new_isolated_wave,
            _set_selected_wave_row,
        )

        for name, extra in self.GEOMETRIES:
            with self.subTest(geometry=name):
                with self._session(extra) as session:
                    session.run("frames:2")
                    _new_isolated_wave(session)
                    _set_selected_wave_row(session, 0x30, 0x41)
                    probe = _pitch_probe(session)
                    cell_x, _ = _grab_a_pitch_block(session, probe)

                    top, bottom = int(probe["top"]), int(probe["bottom"])
                    step = max(1, int(probe["height"]) // 10)
                    # One semitone is the finest the value can express, so the block can
                    # only ever be within half a step of the cursor -- plus a pixel of
                    # integer rounding.
                    tolerance = probe["step_px"] / 2 + 1.5
                    for pixel_y in range(top + 2, bottom - 1, step):
                        session.run(f"movepx:{cell_x},{pixel_y}")
                        during = _pitch_probe(session)
                        self.assertLessEqual(
                            abs(during["delta"]),
                            tolerance,
                            f"{name}: block {during['delta']:+d}px from the cursor at "
                            f"mouseY={during['mouse_y']} (tolerance {tolerance:.1f})",
                        )

                    before = _pitch_probe(session)
                    session.run(f"releasepx:{cell_x},{bottom - 2}")
                    after = _pitch_probe(session)
                    # Releasing must not move the block: the axis may not re-fit as a
                    # result of the edit that was just made.
                    self.assertEqual(
                        after["drawn_y"],
                        before["drawn_y"],
                        f"{name}: block jumped {after['drawn_y'] - before['drawn_y']:+d}px "
                        f"on release (scale {before['scale']} -> {after['scale']})",
                    )


class SoundEditorDragPrecisionTests(unittest.TestCase):
    def test_pulse_level_drag_resolves_below_one_character_cell(self) -> None:
        with _master_session() as session:
            x = _plot_x_for_tick(session, 0)
            # First drag allocates the private pulse row this test then edits.
            session.run(f"drag:{x},{PULSE_GRAPH_ROW},{x},{PULSE_TOP_ROW}")
            pulse_ptr = _instrument_bytes(session.run("insbytes"))[5]
            self.assertNotEqual(pulse_ptr, 0, "expected a private pulse row to edit")

            def level_after(target_pixel_y: int) -> int:
                session.run(
                    f"dragpx:{x},{_cell_centre(PULSE_GRAPH_ROW)},{x},{target_pixel_y}"
                )
                return _sweep_row(session.run("sweepdump:P"), pulse_ptr)[2]

            span = range(PULSE_TOP_ROW * FONT_Y, (PULSE_GRAPH_ROW + 1) * FONT_Y)
            levels = {level_after(pixel_y) for pixel_y in span}
            cells_spanned = len({pixel_y // FONT_Y for pixel_y in span})

            self.assertGreater(
                len(levels),
                cells_spanned * 2,
                f"pulse level still quantized near cell granularity: {sorted(levels)}",
            )

    def test_adsr_sustain_drag_reaches_every_nibble(self) -> None:
        """All 16 sustain levels must be reachable by dragging the dot.

        Cell-granular input reached only 5 (0, 4, 8, 13, 15), which is why the master
        sequence used to fine-tune sustain with the arrow keys instead.
        """
        with _master_session() as session:
            session.run("frames:2")
            reached: set[int] = set()
            for target_pixel_y in range(9 * FONT_Y, 15 * FONT_Y, 3):
                handle_x, handle_y = _find_sustain_handle(session)
                session.run(
                    f"dragpx:{handle_x},{_cell_centre(handle_y)},"
                    f"{handle_x},{target_pixel_y}"
                )
                reached.add(_sustain(session))

            self.assertEqual(
                reached,
                set(range(16)),
                f"sustain levels unreachable by drag: {sorted(set(range(16)) - reached)}",
            )


if __name__ == "__main__":
    unittest.main()
