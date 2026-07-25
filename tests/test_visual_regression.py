"""Layer-4 visual regression: tolerance-based screenshot checkpoints.

These are the deliberately-generous pixel guards described by the sdl2-ui-debug-qa
skill — a safety net for gross rendering regressions (blank frame, wrong layout,
palette breakage), NOT a pixel-exact golden diff.  The semantic ``screendump`` /
``soundstate`` oracles remain the primary correctness tests.

Baselines are committed under ``tests/baselines/``.  Regenerate them (after an
intentional visual change) with::

    CCUTTER_UPDATE_BASELINES=1 python3 -m unittest tests.test_visual_regression

On failure the actual frame + a red diff mask are written to ``tests/_artifacts/``.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from tests.visual_regression import capture_screenshot, compare_to_baseline

SONG = "tunes/vent-arkijuusto.ct"

# name -> ccdriver command sequence that reaches a settled, deterministic frame.
CHECKPOINTS = {
    "main_song_view": (f"load:{SONG}", "key:ESC", "ff:2"),
    "sound_editor_open": (f"load:{SONG}", "key:ESC", "key:Ctrl-e", "ff:2"),
}


class VisualRegressionTests(unittest.TestCase):
    def _check(self, name: str) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            shot = capture_screenshot(Path(tmp) / f"{name}.png", *CHECKPOINTS[name])
            ok, message = compare_to_baseline(name, shot)
            self.assertTrue(ok, message)

    def test_main_song_view(self) -> None:
        self._check("main_song_view")

    def test_sound_editor_open(self) -> None:
        self._check("sound_editor_open")


if __name__ == "__main__":
    unittest.main()
