"""No-popup Sound Editor ownership regressions (headless user actions)."""

from __future__ import annotations

import re
import unittest

from tests.test_sound_editor_master_usage import (
    FILTER_BOTTOM_ROW,
    FILTER_TOP_ROW,
    PULSE_GRAPH_ROW,
    PULSE_TOP_ROW,
    _full_sound_dump,
    _instrument_bytes,
    _master_session,
    _plot_x_for_tick,
    _select_filter_at,
    _select_pulse_at,
    _sweep_row,
)
from tests.test_sound_editor_wave_loop_geometry import _cell_inside, _sweep_loop_state


def _assert_non_modal(case: unittest.TestCase, screen: str) -> None:
    lowered = screen.lower()
    case.assertNotIn("(y/n)", lowered)
    case.assertNotIn("fork a private copy", lowered)
    case.assertNotIn("create editable", lowered)


def _pointers(output: str, kind: str) -> list[int]:
    match = re.search(rf"^{kind} ptrs:((?: [0-9a-f]{{2}}){{48}})$", output, re.I | re.M)
    if match is None:
        raise AssertionError(f"missing {kind} pointer oracle\n{output}")
    return [int(value, 16) for value in match.group(1).split()]


def _select_instrument_six(session) -> None:
    for _ in range(6):
        session.run("key:KP_PLUS")
    if not session.run("insbytes").startswith("ins06:"):
        raise AssertionError("fixture did not select shared instrument 06")


def _stable(output: str) -> str:
    """Remove the persistent-session protocol marker from a read-only oracle."""
    return output.split("checkpoint:", 1)[0].rstrip()


def _undo_state(output: str) -> tuple[int, int, int]:
    match = re.search(r"undo: depth=(\d+) redo=(\d+) generation=(\d+)", output)
    if match is None:
        raise AssertionError("missing undo-depth oracle\n" + output)
    return tuple(map(int, match.groups()))


class SoundEditorNoPopupOwnershipTests(unittest.TestCase):
    def test_blank_sentinel_programs_are_visibly_empty_not_shared(self) -> None:
        with _master_session() as session:
            screen = session.run("screendump")
            self.assertIn("Wave: EMPTY", screen)
            self.assertIn("Pulse: EMPTY", screen)
            self.assertIn("Filter: EMPTY", screen)
            self.assertNotIn("shared", screen.lower())

    def test_empty_pulse_first_drag_creates_and_applies_without_redrag(self) -> None:
        with _master_session() as session:
            before = _full_sound_dump(session.run("sounddump"))
            x = _plot_x_for_tick(session, 0)
            session.run(f"drag:{x},{PULSE_GRAPH_ROW},{x},{PULSE_TOP_ROW}")
            _assert_non_modal(self, session.run("screendump"))

            ins = _instrument_bytes(session.run("insbytes"))
            self.assertNotEqual(ins[5], 0, "first drag must allocate a private Pulse row")
            created = _sweep_row(session.run("sweepdump:P"), ins[5])
            self.assertNotEqual(created[2], 0x00,
                                "the same first drag must apply its final level")

            first = _full_sound_dump(session.run("sounddump"))
            session.run(f"drag:{x},{PULSE_TOP_ROW},{x},{PULSE_GRAPH_ROW}")
            _assert_non_modal(self, session.run("screendump"))
            self.assertNotEqual(_full_sound_dump(session.run("sounddump")), first)

            session.run("key:Ctrl-z")
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before,
                             "create+gesture undo must restore pointer and bytes atomically")

    def test_empty_filter_first_drag_creates_and_applies_without_redrag(self) -> None:
        with _master_session() as session:
            before = _full_sound_dump(session.run("sounddump"))
            x = _plot_x_for_tick(session, 0)
            session.run(f"drag:{x},{FILTER_BOTTOM_ROW},{x},{FILTER_TOP_ROW}")
            _assert_non_modal(self, session.run("screendump"))

            ins = _instrument_bytes(session.run("insbytes"))
            self.assertNotEqual(ins[4], 0, "first drag must allocate Filter CONFIG+SWEEP")
            config = _sweep_row(session.run("sweepdump:F"), ins[4])
            self.assertTrue(config[0] & 0x80)
            self.assertNotEqual(config[2], 0x00,
                                "the same first drag must apply its final cutoff")

            first = _full_sound_dump(session.run("sounddump"))
            session.run(f"drag:{x},{FILTER_TOP_ROW},{x},{FILTER_BOTTOM_ROW}")
            _assert_non_modal(self, session.run("screendump"))
            self.assertNotEqual(_full_sound_dump(session.run("sounddump")), first)

            session.run("key:Ctrl-z")
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_shared_wave_first_mutation_auto_forks_applies_and_undoes(self) -> None:
        with _master_session() as session:
            _select_instrument_six(session)
            before = _full_sound_dump(session.run("sounddump"))
            old_pointer = _instrument_bytes(session.run("insbytes"))[7]
            self.assertGreater(
                sum(before["instruments"][instrument + 7 * 48] == old_pointer
                    for instrument in range(48)),
                1,
            )
            old_program = session.run(f"wavedump:0x{old_pointer:02x}")

            session.run("click:45,33")
            _assert_non_modal(self, session.run("screendump"))
            new_pointer = _instrument_bytes(session.run("insbytes"))[7]
            self.assertNotEqual(new_pointer, old_pointer)
            self.assertEqual(session.run(f"wavedump:0x{old_pointer:02x}").split("checkpoint")[0],
                             old_program.split("checkpoint")[0])

            once = _full_sound_dump(session.run("sounddump"))
            session.run("click:45,33")
            _assert_non_modal(self, session.run("screendump"))
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[7], new_pointer)
            self.assertNotEqual(_full_sound_dump(session.run("sounddump")), once)

            session.run("key:Ctrl-z")
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_shared_pulse_and_filter_first_drag_auto_fork_atomically(self) -> None:
        for table, pointer_index, y0, y1 in (
            ("P", 5, PULSE_GRAPH_ROW, PULSE_TOP_ROW),
            ("F", 4, FILTER_BOTTOM_ROW, FILTER_TOP_ROW),
        ):
            with self.subTest(table=table), _master_session() as session:
                _select_instrument_six(session)
                before = _full_sound_dump(session.run("sounddump"))
                ptrs_before = _pointers(session.run(f"sweepdump:{table}"),
                                        "puls" if table == "P" else "filt")
                shared = ptrs_before[6]
                self.assertGreater(sum(pointer == shared for pointer in ptrs_before), 1)
                original_row = _sweep_row(session.run(f"sweepdump:{table}"), shared)

                x = _plot_x_for_tick(session, 0)
                if table == "F":
                    session.run("click:31,23")  # visible LP chip mutation
                else:
                    session.run(f"drag:{x},{y0},{x},{y1}")
                _assert_non_modal(self, session.run("screendump"))
                ptrs_after = _pointers(session.run(f"sweepdump:{table}"),
                                       "puls" if table == "P" else "filt")
                self.assertNotEqual(ptrs_after[6], shared)
                self.assertEqual(ptrs_after[:6] + ptrs_after[7:],
                                 ptrs_before[:6] + ptrs_before[7:])
                self.assertEqual(_sweep_row(session.run(f"sweepdump:{table}"), shared),
                                 original_row)

                if table == "F":
                    session.run("click:34,23")  # second private BP-chip mutation
                else:
                    session.run(f"drag:{x},{y1},{x},{y0}")
                _assert_non_modal(self, session.run("screendump"))
                self.assertEqual(_pointers(session.run(f"sweepdump:{table}"),
                                           "puls" if table == "P" else "filt")[6],
                                 ptrs_after[6])

                session.run("key:Ctrl-z")
                session.run("key:Ctrl-z")
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_explicit_linked_mode_mutates_shared_programs_without_forking(self) -> None:
        """Ctrl-Shift-E is the only opt-in path for intentional linked edits."""
        for table in ("W", "P", "F"):
            with self.subTest(table=table), _master_session() as session:
                _select_instrument_six(session)
                self.assertRegex(session.run("soundstate"), r"ownership=fork\b")
                session.run("key:Ctrl-Shift-e")
                self.assertRegex(session.run("soundstate"), r"ownership=linked\b")
                self.assertIn("Linked edits", session.run("screendump"))

                before = _full_sound_dump(session.run("sounddump"))
                ins = _instrument_bytes(session.run("insbytes"))
                pointer_index = {"W": 7, "P": 5, "F": 4}[table]
                shared = ins[pointer_index]
                x = _plot_x_for_tick(session, 0)
                if table == "W":
                    session.run("click:45,33")
                elif table == "P":
                    session.run(f"drag:{x},{PULSE_GRAPH_ROW},{x},{PULSE_TOP_ROW}")
                else:
                    session.run("click:31,23")
                _assert_non_modal(self, session.run("screendump"))
                self.assertEqual(_instrument_bytes(session.run("insbytes"))[pointer_index],
                                 shared)
                once = _full_sound_dump(session.run("sounddump"))
                self.assertNotEqual(once, before)

                # A second linked edit stays linked and remains prompt-free.
                if table == "W":
                    session.run("click:45,33")
                elif table == "P":
                    session.run(f"drag:{x},{PULSE_TOP_ROW},{x},{PULSE_GRAPH_ROW}")
                else:
                    session.run("click:34,23")
                _assert_non_modal(self, session.run("screendump"))
                self.assertEqual(_instrument_bytes(session.run("insbytes"))[pointer_index],
                                 shared)

                session.run("key:Ctrl-z")
                session.run("key:Ctrl-z")
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_table_full_auto_fork_is_non_modal_and_byte_atomic(self) -> None:
        for table, label in (("W", "Wave"), ("P", "Pulse"), ("F", "Filter")):
            with self.subTest(table=table), _master_session() as session:
                _select_instrument_six(session)
                fixture = session.run(f"ownershipfixture:full-{table}")
                self.assertNotIn("unknown cmd", fixture.lower(),
                                 f"ccdriver needs ownershipfixture:full-{table}")
                before = _full_sound_dump(session.run("sounddump"))
                x = _plot_x_for_tick(session, 0)
                if table == "W":
                    session.run("click:45,33")
                elif table == "P":
                    session.run(f"drag:{x},{PULSE_GRAPH_ROW},{x},{PULSE_TOP_ROW}")
                else:
                    session.run("click:31,23")
                screen = session.run("screendump")
                _assert_non_modal(self, screen)
                self.assertIn(f"{label} table full".lower(), screen.lower())
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before,
                                 "failed fork must not change pointer or any table byte")

    def test_fixed_pulse_first_drag_preserves_width_then_continues_and_undoes_once(self) -> None:
        with _master_session() as session:
            session.run("ownershipfixture:fixed-P-84")
            before = _full_sound_dump(session.run("sounddump"))
            undo_before = _undo_state(session.run("undostate"))
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[5], 0x84)

            x = _plot_x_for_tick(session, 0)
            session.run(f"press:{x},{PULSE_GRAPH_ROW}")
            created_pointer = _instrument_bytes(session.run("insbytes"))[5]
            self.assertLess(created_pointer, 0x40)
            # $84 is a direct $400 pulse width; its nibble-swapped init byte is $04.
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), created_pointer)[2], 0x04)

            session.run(f"move:{x},{PULSE_TOP_ROW}")
            session.run(f"release:{x},{PULSE_TOP_ROW}")
            _assert_non_modal(self, session.run("screendump"))
            self.assertNotEqual(
                _sweep_row(session.run("sweepdump:P"), created_pointer)[2], 0x04,
                "the creating press and following motion must be one continuing gesture",
            )
            undo_after = _undo_state(session.run("undostate"))
            self.assertEqual(undo_after[0], undo_before[0] + 1)
            self.assertEqual(undo_after[2], undo_before[2] + 1)

            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)
            self.assertEqual(_undo_state(session.run("undostate"))[0], undo_before[0])

    def test_table_full_failure_preserves_undo_rerender_register_graph_and_controls(self) -> None:
        for table, label in (("W", "Wave"), ("P", "Pulse"), ("F", "Filter")):
            with self.subTest(table=table), _master_session() as session:
                _select_instrument_six(session)
                session.run(f"ownershipfixture:full-{table}")
                x = _plot_x_for_tick(session, 0)
                if table == "P":
                    _select_pulse_at(session, 0)

                bytes_before = _full_sound_dump(session.run("sounddump"))
                undo_before = _stable(session.run("undostate"))
                sound_before = _stable(session.run("soundstate"))
                regs_before = _stable(session.run("regstate"))
                controls_before = _stable(session.run("controlstate"))
                graph_before = _stable(session.run(
                    "wavepreview:16" if table == "W" else f"sweeploopstate:{table}"
                ))

                if table == "W":
                    session.run("click:45,33")
                elif table == "P":
                    session.run(f"drag:{x},{PULSE_GRAPH_ROW},{x},{PULSE_TOP_ROW}")
                else:
                    session.run("click:31,23")

                screen = session.run("screendump")
                self.assertIn(f"{label} table full".lower(), screen.lower())
                _assert_non_modal(self, screen)
                self.assertEqual(_full_sound_dump(session.run("sounddump")), bytes_before)
                self.assertEqual(_stable(session.run("undostate")), undo_before)
                self.assertEqual(_stable(session.run("soundstate")), sound_before)
                self.assertEqual(_stable(session.run("regstate")), regs_before)
                self.assertEqual(_stable(session.run("controlstate")), controls_before)
                self.assertEqual(
                    _stable(session.run(
                        "wavepreview:16" if table == "W" else f"sweeploopstate:{table}"
                    )),
                    graph_before,
                )

    def test_pulse_filter_structural_edits_follow_default_cow_and_linked_matrix(self) -> None:
        for table in ("P", "F"):
            for linked in (False, True):
                for operation in ("add", "delete", "loop"):
                    with self.subTest(table=table, linked=linked, operation=operation), \
                            _master_session() as session:
                        _select_instrument_six(session)
                        if table == "F":
                            session.run("ownershipfixture:shared-F-struct")
                        if linked:
                            session.run("key:Ctrl-Shift-e")

                        if operation != "loop":
                            if table == "P":
                                _select_pulse_at(session, 0)
                            else:
                                _select_filter_at(session, 1)
                        shape = _sweep_loop_state(session, table) if operation == "loop" else None
                        if shape is not None:
                            self.assertEqual((shape["looped"], shape["startVisible"]), (1, 1))

                        kind = "puls" if table == "P" else "filt"
                        pointer_index = 5 if table == "P" else 4
                        before = _full_sound_dump(session.run("sounddump"))
                        pointers_before = _pointers(session.run(f"sweepdump:{table}"), kind)
                        old_pointer = pointers_before[6]
                        undo_before = _undo_state(session.run("undostate"))

                        if operation == "add":
                            session.run("key:Ctrl-Shift-j")
                        elif operation == "delete":
                            session.run("key:Ctrl-Shift-d")
                        else:
                            assert shape is not None
                            target_tick = 100 if table == "P" else 6
                            y = shape["top"] // 14
                            session.run(
                                f"drag:{_cell_inside(shape['startLeft'], shape['startRight'])},"
                                f"{y},{_plot_x_for_tick(session, target_tick)},{y}"
                            )

                        _assert_non_modal(self, session.run("screendump"))
                        after = _full_sound_dump(session.run("sounddump"))
                        new_pointer = _instrument_bytes(session.run("insbytes"))[pointer_index]
                        if linked:
                            self.assertEqual(new_pointer, old_pointer)
                            self.assertNotEqual(after, before)
                        else:
                            self.assertNotEqual(new_pointer, old_pointer)
                            self.assertEqual(
                                _pointers(session.run(f"sweepdump:{table}"), kind)[:6]
                                + _pointers(session.run(f"sweepdump:{table}"), kind)[7:],
                                pointers_before[:6] + pointers_before[7:],
                            )
                            table_key = "pulse" if table == "P" else "filter"
                            width = 8 if table == "P" else 16
                            start = old_pointer * 4
                            self.assertEqual(
                                after[table_key][start:start + width],
                                before[table_key][start:start + width],
                            )
                        self.assertEqual(_undo_state(session.run("undostate"))[0],
                                         undo_before[0] + 1)
                        session.run("key:Ctrl-z")
                        self.assertEqual(_full_sound_dump(session.run("sounddump")), before)


if __name__ == "__main__":
    unittest.main()
