"""Fullscreen / window-size changes re-lay the UI out for the new grid.

A fullscreen toggle arrives as a window size change (async on macOS), which
ui.ui.fitToWindow turns into a grid that fills the window at 1:1 by rebuilding
the UI. `winsize:W,H` drives that same path headless: it resizes the dummy
window and calls fitToWindow, exactly as the SDL_WINDOWEVENT handler does.
"""

from __future__ import annotations

import re
import tempfile
import unittest
import zlib
from pathlib import Path

from tests.ccdriver_session import CCDriverSession


SONG = "tunes/vent-arkijuusto.ct"
MACBOOK_FULLSCREEN = "1512,982"      # 14" MacBook Pro screen in points
WINDOWED = "1280,700"                # the 160x50 minimum window


def _rows(dump: str) -> dict[int, str]:
    return {int(m.group(1)): m.group(2)
            for m in (re.match(r"screen(\d+):(.*)", line) for line in dump.splitlines()) if m}


def _seqpos(session: CCDriverSession) -> dict[str, str]:
    line = re.search(r"seqpos: (.*)", session.run("seqpos")).group(1)
    return dict(part.split("=") for part in line.split())


def _cursor_row(pos: dict[str, str]) -> tuple[int, int]:
    """(track, row in sequence) under the cursor: invariant under re-centring."""
    return int(pos["trk"]), int(pos["seq"]) + int(pos["pointer"])


class WindowFitTests(unittest.TestCase):
    def test_fullscreen_size_fills_the_screen_with_a_bigger_layout(self):
        with CCDriverSession(f"load:{SONG}", "key:ESC") as s:
            self.assertIn("winsize 189x70 cells", s.run(f"winsize:{MACBOOK_FULLSCREEN}"))
            rows = _rows(s.run("screendump"))
            self.assertEqual(len(rows), 70)
            self.assertEqual(len(rows[0]), 189)
            # Bars moved to the new bottom, the sequencer grew to 60 rows.
            self.assertIn("Filename:", rows[67])
            self.assertIn("Release:", rows[68])
            # 60 sequencer rows centred on the cursor (row 0): rows 0..1D show,
            # where the 40-row window layout stops at 13.
            labels = [t[:4].strip() for y, t in sorted(rows.items()) if 4 < y < 66]
            self.assertIn("1D", labels)

    def test_leaving_fullscreen_restores_the_window_layout(self):
        with CCDriverSession(f"load:{SONG}", "key:ESC") as s:
            before = s.run("screendump")
            s.run(f"winsize:{MACBOOK_FULLSCREEN}")
            self.assertIn("winsize 160x50 cells", s.run(f"winsize:{WINDOWED}"))
            after = s.run("screendump")
            self.assertEqual(len(_rows(after)), 50)
            self.assertEqual(_rows(before)[47], _rows(after)[47])   # Filename/Title bar

    def test_grid_is_clamped_to_the_layout_limits(self):
        with CCDriverSession(f"load:{SONG}", "key:ESC") as s:
            self.assertIn("winsize 160x50 cells", s.run("winsize:800,600"))
            self.assertIn("winsize 200x74 cells", s.run("winsize:3840,2160"))

    def test_cursor_stays_on_its_song_row(self):
        with CCDriverSession(f"load:{SONG}", "key:ESC", "key:F6") as s:
            for _ in range(5):
                s.run("key:DOWN")
            before = _cursor_row(_seqpos(s))
            s.run(f"winsize:{MACBOOK_FULLSCREEN}")
            self.assertEqual(_cursor_row(_seqpos(s)), before)
            s.run(f"winsize:{WINDOWED}")
            self.assertEqual(_cursor_row(_seqpos(s)), before)

    def test_undo_across_a_resize_restores_the_song(self):
        with tempfile.TemporaryDirectory() as tmp, \
                CCDriverSession(f"load:{SONG}", "key:ESC", "key:F6") as s:
            original, undone = Path(tmp) / "a.ct", Path(tmp) / "b.ct"
            s.run(f"save:{original}")
            s.run("key:q")                                    # enter a note
            self.assertIn("depth=1", s.run("undostate"))
            s.run(f"winsize:{MACBOOK_FULLSCREEN}")
            s.run("key:Ctrl-z")
            self.assertIn("depth=0", s.run("undostate"))
            s.run(f"save:{undone}")
            # Everything but the player's RAM ($19xx) and the SID registers,
            # which the auditioned note leaves changed with or without a resize.
            def song(p):
                data = bytearray(zlib.decompress(p.read_bytes()[3:]))
                data[0x1900:0x1a00] = bytes(0x100)
                data[0xd400:0xd500] = bytes(0x100)
                return bytes(data)
            self.assertEqual(song(original), song(undone))

    def test_menus_and_file_dialog_directories_survive(self):
        with CCDriverSession(f"load:{SONG}", "key:ESC") as s:
            s.run("key:Ctrl-Shift-F9")                        # .sid picker
            rows = _rows(s.run("screendump"))
            title = next(y for y, t in rows.items() if "Import CheeseCutter .sid" in t)
            target = next(y for y, t in sorted(rows.items())
                          if y > title + 1 and re.search(r"(?<![\w.])tests(?![\w.])", t))
            for _ in range(target - (title + 2)):
                s.run("key:DOWN")
            s.run("key:RETURN")                               # into tests/
            s.run("key:ESC")
            s.run(f"winsize:{MACBOOK_FULLSCREEN}")
            s.run("key:Ctrl-Shift-F9")
            # The picker reopens inside tests/ (the path itself is truncated).
            screen = "\n".join(_rows(s.run("screendump")).values())
            self.assertIn("fixtures", screen)
            self.assertIn("__pycache__", screen)
            s.run("key:ESC")
            s.run("key:ESC")                                  # menu bar still works
            self.assertIn("Import .sid...", s.run("screendump"))

    def test_sound_editor_stays_open(self):
        with CCDriverSession(f"load:{SONG}", "key:ESC", "key:Ctrl-e") as s:
            s.run(f"winsize:{MACBOOK_FULLSCREEN}")
            self.assertIn("Sound Editor  -  00", s.run("screendump"))


if __name__ == "__main__":
    unittest.main()
