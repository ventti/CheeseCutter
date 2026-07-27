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
