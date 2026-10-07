"""ADR 0010: the menu bar / dropdown / palette are the topmost layer.

Both passes that run late in a frame — the oscilloscope window and the playback
ADSR row tint — paint over cells an open dropdown occupies. The scope is the
sharper case: it is centred on screen and Window.drawFrame() blanks its whole
interior (src/ui/window.d:98), so a dropdown hanging down into it was erased
outright. These tests open a dropdown that genuinely reaches into the scope's
box and assert the menu text survives.
"""

from __future__ import annotations

import re
import unittest

from tests.ccdriver_session import CCDriverSession


SONG = "tunes/vent-arkijuusto.ct"

# Esc dismisses the startup splash; a second Esc focuses the menu bar. Four
# RIGHTs walk to Navigate — the longest menu, so its dropdown reaches furthest
# down the screen — and DOWN opens it.
OPEN_NAVIGATE = ("key:ESC", "key:RIGHT", "key:RIGHT", "key:RIGHT", "key:RIGHT", "key:DOWN")

# Last item of the Navigate menu: the deepest row of the tallest dropdown, and
# the one most likely to fall inside a centred overlay.
LAST_ITEM = "Go to instr wave"
SCOPE_TITLE = "Oscilloscope (combined)"


def _rows(dump: str) -> dict[int, str]:
    """screendump output -> {row index: text}."""
    out = {}
    for line in dump.splitlines():
        m = re.match(r"screen(\d+):(.*)", line)
        if m:
            out[int(m.group(1))] = m.group(2)
    return out


def _row_of(rows: dict[int, str], needle: str) -> int:
    for y, text in sorted(rows.items()):
        if needle in text:
            return y
    raise AssertionError(f"{needle!r} not on screen")


class MenuOverlayZOrderTests(unittest.TestCase):
    def test_foreground_focus_suspends_late_tracker_input_repaint(self):
        for overlay in ("menu", "palette"):
            with self.subTest(overlay=overlay), CCDriverSession(f"load:{SONG}", "key:ESC", "key:F6") as session:
                self.assertIn("inputframe: active=true", session.run("inputframe"))
                if overlay == "menu":
                    session.run("key:ESC")
                else:
                    session.run("key:Ctrl-p")
                    for char in "pla":
                        session.run(f"key:{char}")
                before = _rows(session.run("screendump"))
                for _ in range(20):
                    self.assertIn("inputframe: active=false", session.run("inputframe"))
                self.assertEqual(_rows(session.run("screendump")), before)
                session.run("key:ESC")
                self.assertIn("inputframe: active=true", session.run("inputframe"))

    def test_cached_menu_checkbox_updates_and_survives_reopen(self):
        with CCDriverSession("key:ESC", "key:ESC") as session:
            for _ in range(3):
                session.run("key:RIGHT")  # Playback
            rows = _rows(session.run("screendump"))
            row = _row_of(rows, "Voice 1")
            self.assertIn("[x]", rows[row])
            x = rows[row].index("Voice 1")
            session.run(f"hover:{x},{row}")
            session.run("key:SPACE")
            self.assertIn("[ ]", _rows(session.run("screendump"))[row])
            session.run("key:ESC")
            session.run("key:ESC")
            self.assertIn("[ ]", _rows(session.run("screendump"))[row])
            session.run("key:SPACE")
            self.assertIn("[x]", _rows(session.run("screendump"))[row])

    def test_menu_hover_preserves_sound_graphs_and_replaces_masks(self):
        from tests.test_overlay_lifetime import overlay_counts

        with CCDriverSession(f"load:{SONG}", "key:ESC", "key:Ctrl-e") as session:
            graph_ops, masks = overlay_counts(session)
            self.assertGreater(graph_ops, 0)
            self.assertEqual(masks, 0)
            session.run("press:3,0")  # File
            session.run("release:3,0")
            for x in (9, 15, 21, 3):  # switch menus using the lightweight path
                session.run(f"hover:{x},0")
                ops, masks = overlay_counts(session)
                self.assertEqual(ops - masks, graph_ops)
                self.assertEqual(masks, 1)
                if x == 3:
                    self.assertIn("Load song", session.run("screendump"))
            session.run("key:ESC")
            self.assertEqual(overlay_counts(session)[1], 0)

    def test_dropdown_survives_the_oscilloscope_it_hangs_into(self):
        session = CCDriverSession(f"load:{SONG}")
        try:
            session.run("key:ESC")            # dismiss the splash
            session.run("key:Shift-F12")      # scope on
            session.run("key:F1")             # play: the scope only draws while playing
            session.run("ff:10")
            # Where the scope sits, read before the menu covers its title row.
            scope_top = _row_of(_rows(session.run("screendump")), SCOPE_TITLE)

            for cmd in OPEN_NAVIGATE:
                session.run(cmd)
            session.run("ff:4")
            rows = _rows(session.run("screendump"))
            item_row = _row_of(rows, LAST_ITEM)
            # Guard against a vacuous pass: if a layout change ever stops the
            # dropdown from reaching the scope, this test proves nothing.
            self.assertGreater(
                item_row, scope_top,
                f"dropdown no longer overlaps the scope (item row {item_row}, "
                f"scope top {scope_top}) - the test needs a taller menu",
            )
        finally:
            session.close()

    def test_dropdown_survives_the_playback_row_tint(self):
        """The tint recolours track cells; it must not eat the dropdown's."""
        session = CCDriverSession(f"load:{SONG}")
        try:
            session.run("key:ESC")
            session.run("key:F1")
            session.run("ff:20")
            for cmd in OPEN_NAVIGATE:
                session.run(cmd)
            session.run("ff:10")
            session.run("tick:4")
            rows = _rows(session.run("screendump"))
            self.assertIn(LAST_ITEM, rows[_row_of(rows, LAST_ITEM)])
        finally:
            session.close()


if __name__ == "__main__":
    unittest.main()
