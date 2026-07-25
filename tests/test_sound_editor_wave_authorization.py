"""R71: every Wave mutation uses one shared authorization/snapshot lifecycle."""

from __future__ import annotations

import re
import unittest

from tests.test_sound_editor_master_usage import (
    BTN_ADD,
    BTN_DEL,
    BTN_LOOP,
    FREQ_GRAPH_ROW,
    FREQ_GRAPH_SAFE_ROW,
    _click_control,
    _full_sound_dump,
    _instrument_bytes,
    _master_session,
    _plot_x_for_tick,
    _wave_rows,
)
from tests.test_sound_editor_wave_creation import _wave_add_state


WAVE_GATE_LANE_ROW = 33


def _select_instrument_six(session) -> None:
    for _ in range(6):
        session.run("key:KP_PLUS")
    if not session.run("insbytes").startswith("ins06:"):
        raise AssertionError("fixture did not select shared instrument 06")


def _select_shared_wave_row(session) -> int:
    ptr = _instrument_bytes(session.run("insbytes"))[7]
    session.run(f"click:{_plot_x_for_tick(session, 0)},{FREQ_GRAPH_SAFE_ROW}")
    return ptr


def _enter_exact_wave_byte(session, shortcut: str, value: int) -> None:
    session.run(f"key:{shortcut}")
    for digit in f"{value:02x}":
        session.run(f"key:{digit}")
    session.run("key:RET")


def _assert_non_modal(case: unittest.TestCase, session) -> None:
    screen = session.run("screendump")
    case.assertNotIn("(y/n)", screen.lower())
    case.assertNotIn("fork a private copy", screen.lower())


def _generation(session) -> tuple[int, int]:
    state = session.run("soundstate")
    match = re.search(r"captureLen=(\d+).* trigger=(\d+)", state)
    if match is None:
        raise AssertionError("missing capture/trigger generation\n" + state)
    return int(match.group(1)), int(match.group(2))


def _wave_owner_count(sound: dict[str, list[int]], pointer: int) -> int:
    return sum(sound["instruments"][instrument + 7 * 48] == pointer
               for instrument in range(48))


def _begin_shared_two_row_gate_paint(
    session, *, linked: bool = False, setup_fixture: bool = True,
) -> tuple[int, int, int]:
    if setup_fixture:
        _select_instrument_six(session)
        session.run("wavefixture:shared-two")
    if linked:
        session.run("key:Ctrl-Shift-e")
        if not re.search(r"ownership=linked\b", session.run("soundstate")):
            raise AssertionError("Linked edits did not activate")
    old_ptr = _select_shared_wave_row(session)
    session.run("jamrender:z,120")
    session.run("frames:2")
    # Recording-driven Fit can change graph geometry; hit it only after that settles.
    x0, x1 = (_plot_x_for_tick(session, frame) for frame in (0, 1))
    session.run(f"press:{x0},{WAVE_GATE_LANE_ROW}")
    return old_ptr, x0, x1


def _cross_both_rows_idempotently(session, x0: int, x1: int) -> None:
    session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")
    session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")
    session.run(f"move:{x0},{WAVE_GATE_LANE_ROW}")
    session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")


class SoundEditorWaveAuthorizationTests(unittest.TestCase):
    def test_shared_multirow_bit_paint_starts_default_fork_without_modal_or_redrag(self) -> None:
        with _master_session() as session:
            _select_instrument_six(session)
            session.run("wavefixture:shared-two")
            before = _full_sound_dump(session.run("sounddump"))
            old_ptr, x0, x1 = _begin_shared_two_row_gate_paint(session, setup_fixture=False)
            self.assertGreater(_wave_owner_count(before, old_ptr), 1)
            # The fixture is part of the baseline, but the press itself must already
            # have forked and applied the first row without waiting for Y/N.
            new_ptr = _instrument_bytes(session.run("insbytes"))[7]
            self.assertNotEqual(new_ptr, old_ptr)
            _assert_non_modal(self, session)
            generation = _generation(session)
            _cross_both_rows_idempotently(session, x0, x1)
            session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
            self.assertEqual(_generation(session)[1], generation[1] + 1)
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{old_ptr:02x}"), 2)],
                [(0xCF, 0x81), (0x00, 0x41)],
            )
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{new_ptr:02x}"), 2)],
                [(0xCF, 0x80), (0x00, 0x40)],
            )
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_shared_multirow_bit_paint_fork_is_one_gesture_snapshot_and_release_render(self) -> None:
        with _master_session() as session:
            _select_instrument_six(session)
            session.run("wavefixture:shared-two")
            before = _full_sound_dump(session.run("sounddump"))
            old_ptr, x0, x1 = _begin_shared_two_row_gate_paint(session, setup_fixture=False)
            self.assertGreater(_wave_owner_count(before, old_ptr), 1)
            generation = _generation(session)
            _cross_both_rows_idempotently(session, x0, x1)
            self.assertEqual(_generation(session), generation)
            session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
            after_generation = _generation(session)
            self.assertEqual(after_generation[1], generation[1] + 1)

            after = _full_sound_dump(session.run("sounddump"))
            new_ptr = after["instruments"][6 + 7 * 48]
            self.assertNotEqual(new_ptr, old_ptr)
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{old_ptr:02x}"), 2)],
                [(0xCF, 0x81), (0x00, 0x41)],
            )
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{new_ptr:02x}"), 2)],
                [(0xCF, 0x80), (0x00, 0x40)],
            )
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_shared_multirow_bit_paint_linked_is_one_gesture_snapshot_and_release_render(self) -> None:
        with _master_session() as session:
            _select_instrument_six(session)
            session.run("wavefixture:shared-two")
            before = _full_sound_dump(session.run("sounddump"))
            old_ptr, x0, x1 = _begin_shared_two_row_gate_paint(
                session, linked=True, setup_fixture=False,
            )
            self.assertGreater(_wave_owner_count(before, old_ptr), 1)
            generation = _generation(session)
            _assert_non_modal(self, session)
            self.assertEqual(_generation(session), generation)
            _cross_both_rows_idempotently(session, x0, x1)
            self.assertEqual(_generation(session), generation)
            session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
            after_generation = _generation(session)
            self.assertEqual(after_generation[1], generation[1] + 1)

            after = _full_sound_dump(session.run("sounddump"))
            self.assertEqual(after["instruments"][6 + 7 * 48], old_ptr)
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{old_ptr:02x}"), 2)],
                [(0xCF, 0x80), (0x00, 0x40)],
            )
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_every_shared_wave_mutation_entry_auto_forks_and_applies(self) -> None:
        def pitch(session):
            x = _plot_x_for_tick(session, 0)
            session.run(f"press:{x},{FREQ_GRAPH_ROW}")
            session.run(f"move:{x},{FREQ_GRAPH_ROW + 1}")
            session.run(f"release:{x},{FREQ_GRAPH_ROW + 1}")

        def delay(session):
            x = _plot_x_for_tick(session, 0)
            session.run(f"press:{x},{FREQ_GRAPH_ROW}")
            session.run(f"move:{x + 1},{FREQ_GRAPH_ROW}")
            session.run(f"release:{x + 1},{FREQ_GRAPH_ROW}")

        def bit_paint(session):
            session.run(f"click:{_plot_x_for_tick(session, 0)},33")

        def exact_w1(session):
            _enter_exact_wave_byte(session, "Ctrl-Shift-1", 0x20)

        def exact_w2(session):
            _enter_exact_wave_byte(session, "Ctrl-Shift-2", 0x41)

        def add(session):
            _click_control(session, BTN_ADD)

        def delete(session):
            _click_control(session, BTN_DEL)

        def loop(session):
            _click_control(session, BTN_LOOP)
            target = _instrument_bytes(session.run("insbytes"))[7] + 1
            for digit in f"{target:02x}":
                session.run(f"key:{digit}")
            session.run("key:RET")

        def trailing_create(session):
            state = _wave_add_state(session)
            session.run(f"click:{state['x']},{state['y']}")

        entries = {
            "pitch drag": pitch,
            "delay drag": delay,
            "control-bit paint": bit_paint,
            "exact W1": exact_w1,
            "exact W2": exact_w2,
            "Add": add,
            "Delete": delete,
            "Loop target": loop,
            "trailing creation": trailing_create,
        }
        for label, mutate in entries.items():
            with self.subTest(entry=label), _master_session() as session:
                _select_instrument_six(session)
                if label == "delay drag":
                    session.run("wavefixture:shared-delay")
                else:
                    session.run("wavefixture:shared-two")
                old_ptr = _select_shared_wave_row(session)
                before = _full_sound_dump(session.run("sounddump"))
                self.assertGreater(_wave_owner_count(before, old_ptr), 1, label)
                mutate(session)
                _assert_non_modal(self, session)
                after = _full_sound_dump(session.run("sounddump"))
                new_ptr = _instrument_bytes(session.run("insbytes"))[7]
                self.assertNotEqual(new_ptr, old_ptr, label)
                self.assertNotEqual(after, before, label)
                self.assertEqual(after["wave"][old_ptr], before["wave"][old_ptr], label)
                self.assertEqual(after["wave"][old_ptr + 256], before["wave"][old_ptr + 256], label)
                session.run("key:Ctrl-z")
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before, label)

    def test_exact_edit_default_fork_and_linked_mode_have_exact_atomic_outcomes(self) -> None:
        # Default: active pointer alone moves, the private copy receives the edit,
        # and one Ctrl-Z restores every table byte and pointer.
        with _master_session() as session:
            _select_instrument_six(session)
            session.run("wavefixture:shared-two")
            old_ptr = _select_shared_wave_row(session)
            before = _full_sound_dump(session.run("sounddump"))
            selected = re.search(r"\[row \$([0-9A-F]{2})\]", session.run("screendump"))
            self.assertIsNotNone(selected)
            selected_offset = int(selected.group(1), 16) - old_ptr
            sharers = [i for i in range(48) if before["instruments"][i + 7 * 48] == old_ptr]
            self.assertGreater(len(sharers), 1)
            _enter_exact_wave_byte(session, "Ctrl-Shift-1", 0x20)
            _assert_non_modal(self, session)
            after = _full_sound_dump(session.run("sounddump"))
            new_ptr = after["instruments"][6 + 7 * 48]
            self.assertNotEqual(new_ptr, old_ptr)
            for instrument in sharers:
                if instrument != 6:
                    self.assertEqual(after["instruments"][instrument + 7 * 48], old_ptr)
            self.assertEqual(after["wave"][new_ptr + selected_offset], 0x20)
            self.assertNotEqual(after["wave"][old_ptr + selected_offset], 0x20)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

        # Linked: pointer stays shared and the original row changes; one undo restores.
        with _master_session() as session:
            _select_instrument_six(session)
            session.run("wavefixture:shared-two")
            old_ptr = _select_shared_wave_row(session)
            before = _full_sound_dump(session.run("sounddump"))
            selected = re.search(r"\[row \$([0-9A-F]{2})\]", session.run("screendump"))
            self.assertIsNotNone(selected)
            selected_row = int(selected.group(1), 16)
            session.run("key:Ctrl-Shift-e")
            self.assertRegex(session.run("soundstate"), r"ownership=linked\b")
            _enter_exact_wave_byte(session, "Ctrl-Shift-1", 0x20)
            _assert_non_modal(self, session)
            after = _full_sound_dump(session.run("sounddump"))
            self.assertEqual(after["instruments"][6 + 7 * 48], old_ptr)
            self.assertEqual(after["wave"][selected_row], 0x20)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_authorized_drag_rerenders_once_on_release_never_during_motion(self) -> None:
        def generation(session) -> tuple[int, int]:
            state = session.run("soundstate")
            match = re.search(r"captureLen=(\d+).* trigger=(\d+)", state)
            if match is None:
                raise AssertionError("missing capture/trigger generation\n" + state)
            return int(match.group(1)), int(match.group(2))

        with _master_session() as session:
            _select_instrument_six(session)
            session.run("wavefixture:shared-two")
            _select_shared_wave_row(session)
            session.run("jamrender:z,120")
            session.run("frames:2")  # settle the recording-driven Fit before hit geometry
            before = generation(session)
            x = _plot_x_for_tick(session, 0)
            session.run(f"press:{x},{FREQ_GRAPH_ROW}")
            session.run(f"move:{x},{FREQ_GRAPH_ROW + 1}")
            self.assertEqual(generation(session), before)
            session.run(f"move:{x},{FREQ_GRAPH_ROW + 2}")
            self.assertEqual(generation(session), before)
            session.run(f"release:{x},{FREQ_GRAPH_ROW + 2}")
            after = generation(session)
            self.assertEqual(after[1], before[1] + 1)
            self.assertGreater(after[0], 0)

if __name__ == "__main__":
    unittest.main()
