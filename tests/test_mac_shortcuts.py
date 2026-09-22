"""Mac-only registry bindings through the real keyboard translation/UI path."""
import sys
import unittest

from tests.ccdriver_session import CCDriverSession
from tests.test_sound_editor_master_usage import _master_session, _new_isolated_wave


@unittest.skipUnless(sys.platform == "darwin", "Mac build shortcuts")
class MacShortcutTests(unittest.TestCase):
    def test_command_bindings_survive_legacy_translation(self):
        with CCDriverSession("key:ESC", "key:F6") as session:
            for context in ("key:F6", "key:Ctrl-e"):
                session.run(context)
                for voice in range(1, 4):
                    result = session.run(f"keyprobe:Gui-{voice}")
                    self.assertIn(f"action=toggle_voice_{voice} invoked=true", result)
                self.assertIn("action=toggle_fullscreen invoked=true",
                              session.run("keyprobe:Ctrl-Gui-f"))

    def test_insert_aliases_match_legacy_edits_and_undo(self):
        cases = (
            ("F6", "Alt-RET", "INS", "note_insert_fixed", "seqdump:0"),
            ("F6", "Alt-Shift-RET", "Shift-INS", "note_insert_row", "seqdump:0"),
            ("F6", "Ctrl-RET", "Ctrl-INS", "note_expand", "seqdump:0"),
            ("F5", "Alt-RET", "INS", "trk_insert", "tracks"),
            ("F5", "Ctrl-RET", "Ctrl-INS", "trk_insert_end", "tracks"),
            ("F5", "Ctrl-Shift-RET", "Ctrl-Shift-INS", "trk_insert_all", "tracks"),
            ("Alt-5", "Alt-RET", "INS", "table_insert_row", "undostate"),
        )
        for focus, chord, legacy, action, oracle in cases:
            with self.subTest(chord=chord, focus=focus):
                snapshots = []
                for key in (chord, legacy):
                    with CCDriverSession("key:ESC", f"key:{focus}") as session:
                        def snapshot():
                            return session.run(oracle).split("checkpoint:")[0]
                        before = snapshot()
                        self.assertIn(f"action={action} invoked=true",
                                      session.run(f"keyprobe:{key}"))
                        snapshots.append(snapshot())
                        session.run("key:Ctrl-z")
                        if oracle != "undostate":
                            self.assertEqual(snapshot(), before)
                self.assertEqual(*snapshots)

    def test_return_and_sound_editor_insertion(self):
        with CCDriverSession("key:ESC", "key:F6") as session:
            self.assertIn("action=note_grab_instr invoked=true", session.run("keyprobe:RET"))
            self.assertIn("action=note_expand_quick invoked=true",
                          session.run("keyprobe:Shift-RET"))
        with _master_session() as session:
            _new_isolated_wave(session)
            before = session.run("sounddump").split("checkpoint:")[0]
            self.assertIn("action=se_add invoked=true", session.run("keyprobe:Alt-RET"))
            session.run("key:Ctrl-z")
            self.assertEqual(session.run("sounddump").split("checkpoint:")[0], before)
