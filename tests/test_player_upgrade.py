"""Player upgrade gate: Export song and File > Upgrade player on an old-player song.

The optimized exports always assemble the bundled player, so a song with an
older player must be upgraded first. The fixture is made at run time: the
tracked master song with its song version set below the bundled revision.
"""
from __future__ import annotations

import shutil
import tempfile
import unittest
import zlib
from pathlib import Path

from tests.ccdriver_session import CCDriverSession

ROOT = Path(__file__).resolve().parents[1]
MASTER = ROOT / "tests" / "fixtures" / "sound_editor_master.ct"
VERSION_OFFSET = 65536   # first byte after the 64K image in the .ct payload
OLD_VERSION = 11


def make_old_song(path: Path) -> None:
    data = MASTER.read_bytes()
    payload = bytearray(zlib.decompress(data[3:]))
    payload[VERSION_OFFSET] = OLD_VERSION
    path.write_bytes(data[:3] + zlib.compress(bytes(payload)))


class PlayerUpgradeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.tmp = Path(tempfile.mkdtemp())
        cls.old = cls.tmp / "old-player.ct"
        make_old_song(cls.old)

    @classmethod
    def tearDownClass(cls) -> None:
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def session(self, song: Path) -> CCDriverSession:
        # The first key closes the startup About dialog.
        return CCDriverSession("key:ESC", f"load:{song}")

    def test_export_asks_and_no_cancels(self):
        with self.session(self.old) as s:
            self.assertIn("needsUpgrade=true", s.run("songver"))
            self.assertIn("action=export_song invoked=true", s.run("keyprobe:Shift-F10"))
            self.assertIn("Export needs the latest player. Upgrade now (Y/n)?",
                          s.run("screendump"))
            s.run("key:n")
            out = s.run("songver")
            self.assertIn(f"ver={OLD_VERSION} ", out)
            self.assertIn("modified=false", out)
            self.assertNotIn("Export song", s.run("screendump"))

    def test_export_yes_upgrades_then_opens_export(self):
        with self.session(self.old) as s:
            s.run("key:Shift-F10")
            s.run("key:y")
            out = s.run("songver")
            self.assertIn("ver=12 ", out)
            self.assertIn("needsUpgrade=false", out)
            self.assertIn("modified=true", out)
            self.assertIn("file=old-player.ct", out)
            screen = s.run("screendump")
            self.assertIn("Export song", screen)
            self.assertIn("Upgraded to the latest player.", screen)

    def test_current_song_exports_without_question(self):
        with self.session(MASTER) as s:
            s.run("key:Shift-F10")
            screen = s.run("screendump")
            self.assertIn("Export song", screen)
            self.assertNotIn("Upgrade now", screen)

    def test_menu_item_upgrades(self):
        with self.session(self.old) as s:
            # File menu, then the "Upgrade player..." row.
            s.run("click:3,0")
            self.assertIn("Upgrade player...", s.run("screendump"))
            s.run("click:8,8")
            self.assertIn("Upgrade to latest player (Y/n)?", s.run("screendump"))
            s.run("key:y")
            self.assertIn("ver=12 ", s.run("songver"))

    def test_menu_item_disabled_on_current_song(self):
        with self.session(MASTER) as s:
            s.run("click:3,0")
            s.run("click:8,8")
            self.assertNotIn("Upgrade to latest player", s.run("screendump"))
            self.assertIn("modified=false", s.run("songver"))


if __name__ == "__main__":
    unittest.main()
