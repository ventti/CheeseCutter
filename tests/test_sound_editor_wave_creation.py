"""R70: visible trailing Wave-row creation is a real in-band usage target."""

from __future__ import annotations

import re
import unittest

from tests.test_sound_editor_master_usage import (
    _full_sound_dump,
    _instrument_bytes,
    _master_session,
    _new_isolated_wave,
    _wave_rows,
)
from tests.test_sound_editor_wave_loop_geometry import _wave_loop_state


def _wave_add_state(session) -> dict[str, int | str]:
    out = session.run("waveaddstate")
    match = re.search(
        r"wave add: visible=(\d+) enabled=(\d+) frame=(-?\d+) "
        r"x=(-?\d+) y=(-?\d+) close=(-?\d+) reason=([a-z-]+)",
        out,
    )
    if match is None:
        raise AssertionError("missing trailing Wave creation oracle\n" + out)
    visible, enabled, frame, x, y, close = map(int, match.groups()[:6])
    return dict(
        visible=visible, enabled=enabled, frame=frame, x=x, y=y,
        close=close, reason=match.group(7),
    )


class SoundEditorWaveCreationTests(unittest.TestCase):
    def test_normal_program_target_is_visible_and_appends_exact_neutral_row(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            state = _wave_add_state(session)
            self.assertEqual((state["visible"], state["enabled"], state["close"],
                              state["reason"]), (1, 1, w0 + 1, "normal"))
            self.assertEqual(state["frame"], 1)  # one speed-0 row, no fixed END tail
            self.assertGreaterEqual(state["x"], 0)
            self.assertGreaterEqual(state["y"], 0)
            loop = _wave_loop_state(session)
            plus_left = int(state["x"]) * 8
            self.assertFalse(loop["endLeft"] <= plus_left < loop["endRight"])
            self.assertRegex(
                session.run(f"cellstate:{state['x']},{state['y']}"), r" ch=43 ",
            )  # visible '+'

            session.run(f"click:{state['x']},{state['y']}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 3),
                [(w0, 0x00, 0x00), (w0 + 1, 0x00, 0x00), (w0 + 2, 0x7E, 0x00)],
            )
            self.assertIn(f"[row ${w0 + 1:02X}]", session.run("screendump"))
            session.run("key:Ctrl-z")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2),
                [(w0, 0x00, 0x00), (w0 + 1, 0x7E, 0x00)],
            )

    def test_end_only_program_target_creates_first_value_row_before_end(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            session.run("wavefixture:end-only")
            state = _wave_add_state(session)
            self.assertEqual((state["visible"], state["enabled"], state["close"], state["reason"]),
                             (1, 1, w0, "end-only"))
            session.run(f"click:{state['x']},{state['y']}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2),
                [(w0, 0x00, 0x00), (w0 + 1, 0x7E, 0x00)],
            )
            self.assertIn(f"[row ${w0:02X}]", session.run("screendump"))

    def test_looped_program_target_is_distinct_from_both_triangles_and_reachable(self) -> None:
        with _master_session() as session:
            for _ in range(6):
                session.run("key:KP_PLUS")
            state = _wave_add_state(session)  # instrument 6 uses a shared loop
            loop = _wave_loop_state(session)
            before = _full_sound_dump(session.run("sounddump"))
            old_ptr = _instrument_bytes(session.run("insbytes"))[7]
            plus_left = int(state["x"]) * 8
            self.assertEqual((state["visible"], state["enabled"], loop["looped"]),
                             (1, 1, 1))
            self.assertFalse(loop["startLeft"] <= plus_left < loop["startRight"])
            self.assertFalse(loop["endLeft"] <= plus_left < loop["endRight"])
            session.run(f"click:{state['x']},{state['y']}")
            screen = session.run("screendump")
            self.assertNotIn("(y/n)", screen.lower())
            new_ptr = _instrument_bytes(session.run("insbytes"))[7]
            self.assertNotEqual(new_ptr, old_ptr)
            self.assertEqual(
                before["wave"][old_ptr],
                _full_sound_dump(session.run("sounddump"))["wave"][old_ptr],
            )
            # Instrument 6 uses Wave speed 4: each added row lasts five calls.
            self.assertEqual(_wave_add_state(session)["frame"], int(state["frame"]) + 5)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_absent_or_invalid_program_has_no_creation_placeholder(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            session.run("wavefixture:invalid")
            before = _full_sound_dump(session.run("sounddump"))
            state = _wave_add_state(session)
            self.assertEqual(
                (state["visible"], state["enabled"], state["reason"]),
                (0, 0, "invalid"),
            )
            screen = session.run("screendump")
            self.assertNotIn("Create Wave programme", screen)
            self.assertNotIn("Create private Wave programme", screen)
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_invalid_program_can_still_be_replaced_via_new_sound_action(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            session.run("wavefixture:invalid")
            old_active = _instrument_bytes(session.run("insbytes"))
            self.assertEqual(_wave_add_state(session)["visible"], 0)
            session.run("key:Ctrl-Shift-n")
            new_active = _instrument_bytes(session.run("insbytes"))
            self.assertNotEqual(new_active[7], old_active[7])
            wnew = new_active[7]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{wnew:02x}"), 2),
                [(wnew, 0x00, 0x00), (wnew + 1, 0x7E, 0x00)],
            )

    def test_capacity_target_is_visible_disabled_and_does_not_mutate(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            session.run("wavefixture:full")
            before = _full_sound_dump(session.run("sounddump"))
            state = _wave_add_state(session)
            self.assertEqual(
                (state["visible"], state["enabled"], state["reason"]),
                (1, 0, "full"),
            )
            session.run(f"click:{state['x']},{state['y']}")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_creation_target_does_not_steal_control_row_or_new_sound_menu_action(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            self.assertIn("se_add@", session.run("controlstate"))
            before = _instrument_bytes(session.run("insbytes"))
            session.run("key:Ctrl-Shift-n")
            self.assertNotEqual(_instrument_bytes(session.run("insbytes")), before)


if __name__ == "__main__":
    unittest.main()
