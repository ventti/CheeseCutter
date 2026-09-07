"""Reproductions for the seven Sound Editor findings tracked in TODO."""

import re
import unittest

from tests.ccdriver_session import CCDriverSession
from tests.test_sound_editor_master_usage import (
    _master_session, _plot_x_for_tick, _instrument_bytes, _full_sound_dump,
    FREQ_GRAPH_SAFE_ROW, PULSE_GRAPH_ROW,
)


class SoundEditorPendingBugTests(unittest.TestCase):
    def test_prior_keyjam_mode_is_restored_during_playback(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled), CCDriverSession(
                    "load:tunes/vent-arkijuusto.ct", "key:ESC") as session:
                if enabled:
                    session.run("key:Ctrl-SPACE")
                session.run("key:F2")
                self.assertIn(f"keyjam={str(enabled).lower()}", session.run("sessionstate"))
                session.run("key:Ctrl-e")
                session.run("key:Ctrl-e")
                state = session.run("sessionstate")
                self.assertIn(f"keyjam={str(enabled).lower()}", state)
                self.assertIn(f"background={str(enabled).lower()}", state)
                self.assertIn("playing=true", state)

    def test_help_bottom_lines_survive_window_height_changes(self):
        for rows in (50, 74, 92):
            with self.subTest(rows=rows), CCDriverSession(
                    f"screen:160x{rows}", "key:ESC", "key:Ctrl-e",
                    "key:F12", "key:SPACE") as session:
                self.assertIn("Drag the loop grip", session.run("screendump"))
                session.run("key:SPACE")
                self.assertIn("Fit includes authored Wave timing", session.run("screendump"))

    def test_zero_pulse_pointer_does_not_borrow_another_program(self):
        with _master_session() as session:
            session.run("bugfixture:zero-pulse")
            loop = session.run("sweeploopstate:P")
            self.assertIn("looped=0 stopped=0", loop)
            self.assertIn("startVisible=0 endVisible=0", loop)

    def test_wave_row_zero_edit_forks_and_undo_restores_every_byte(self):
        with _master_session() as session:
            session.run("bugfixture:shared-zero-wave")
            before = _full_sound_dump(session.run("sounddump"))
            session.run(f"click:{_plot_x_for_tick(session, 0)},{FREQ_GRAPH_SAFE_ROW}")
            for command in ("key:Ctrl-Shift-1", "key:2", "key:0", "key:RET"):
                session.run(command)
            self.assertNotEqual(_instrument_bytes(session.run("insbytes"))[7], 0)
            self.assertIn("00:b0/41 01:7f/00", session.run("wavedump:0"))
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_insert_after_last_pulse_row_is_disabled_and_atomic(self):
        with _master_session() as session:
            session.run("bugfixture:tail-pulse")
            session.run(f"click:{_plot_x_for_tick(session, 0)},{PULSE_GRAPH_ROW}")
            before = _full_sound_dump(session.run("sounddump"))
            undo = session.run("undostate").splitlines()[0]
            # Both the primary binding and the Insert alias must be safe.
            for command in ("key:Ctrl-Shift-j", "key:INS"):
                session.run(command)
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before)
                self.assertEqual(session.run("undostate").splitlines()[0], undo)
            self.assertRegex(session.run("controlstate"), r"se_add@[^ ]+:off")

    def test_reentering_sound_editor_drops_keys_released_elsewhere(self):
        with _master_session() as session:
            session.run("key:z")
            self.assertIn("held=true", session.run("sessionstate"))
            for command in ("key:Ctrl-e", "keyup:z", "key:Ctrl-e"):
                session.run(command)
            self.assertIn("held=false", session.run("sessionstate"))
            before = int(re.search(r"trigger=(\d+)", session.run("soundstate"))[1])
            session.run("key:z")
            after = int(re.search(r"trigger=(\d+)", session.run("soundstate"))[1])
            self.assertGreater(after, before, "the next press must not be treated as autorepeat")

    def test_all_slow_adsr_handles_are_reachable_at_every_multiplier(self):
        for multiplier in (1, 2, 16):
            with self.subTest(multiplier=multiplier), _master_session() as session:
                session.run(f"mult:{multiplier}")
                session.run("bugfixture:slow-adsr")
                for _ in range(20):
                    session.run("key:Ctrl-Shift-o")
                self.assertIn("handles=[true, true, true, true]", session.run("sessionstate"))


if __name__ == "__main__":
    unittest.main()
