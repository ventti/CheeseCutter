"""R72: delay-aware authored Wave END/LOOP triangles, hit geometry and extent."""

from __future__ import annotations

import re
import unittest

from tests.test_sound_editor_master_usage import (
    BTN_ADD,
    BTN_FIT,
    FREQ_GRAPH_ROW,
    FILTER_TOP_ROW,
    PULSE_TOP_ROW,
    _build_exact_filter_three_blocks,
    _click_control,
    _full_sound_dump,
    _instrument_bytes,
    _master_session,
    _new_isolated_wave,
    _plot_x_for_tick,
    _pulse_boundary_row,
    _pulse_loop_grip_x,
    _select_pulse_at,
    _sweep_row,
    _wave_rows,
)


def _wave_loop_state(session) -> dict[str, int | str]:
    out = session.run("waveloopstate")
    match = re.search(
        r"wave loop: looped=(\d+) stopped=(\d+) startVisible=(\d+) endVisible=(\d+) "
        r"startFrame=(-?\d+) endFrame=(-?\d+) start=(-?\d+)\.\.(-?\d+) "
        r"end=(-?\d+)\.\.(-?\d+) top=(-?\d+)\.\.(-?\d+) "
        r"startDir=([a-z-]+) endDir=([a-z-]+)", out,
    )
    if match is None:
        raise AssertionError("missing Wave loop geometry oracle\n" + out)
    values = list(map(int, match.groups()[:12]))
    keys = ("looped", "stopped", "startVisible", "endVisible", "startFrame",
            "endFrame", "startLeft", "startRight", "endLeft", "endRight", "top", "bottom")
    result: dict[str, int | str] = dict(zip(keys, values))
    result["startDir"], result["endDir"] = match.group(13), match.group(14)
    return result


def _sweep_loop_state(session, table: str) -> dict[str, int]:
    out = session.run(f"sweeploopstate:{table}")
    match = re.search(
        r"sweep loop: table=[PF] looped=(\d+) stopped=(\d+) "
        r"startVisible=(\d+) endVisible=(\d+) start=(-?\d+)\.\.(-?\d+) "
        r"end=(-?\d+)\.\.(-?\d+) top=(-?\d+)\.\.(-?\d+)", out,
    )
    if match is None:
        raise AssertionError("missing Sweep loop geometry oracle\n" + out)
    keys = ("looped", "stopped", "startVisible", "endVisible", "startLeft",
            "startRight", "endLeft", "endRight", "top", "bottom")
    return dict(zip(keys, map(int, match.groups())))


def _cell_inside(left: int, right: int) -> int:
    """Character-cell input whose centre is inside production's exact pixel bounds."""
    for cell in range(left // 8 - 1, right // 8 + 2):
        if left <= cell * 8 + 4 < right:
            return cell
    raise AssertionError(f"no input cell centre inside {left}..{right}")


class SoundEditorWaveLoopGeometryTests(unittest.TestCase):
    def test_fresh_one_row_stopped_wave_end_is_exactly_one_tick(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            shape = _wave_loop_state(session)
            self.assertEqual((shape["stopped"], shape["endFrame"]), (1, 1))
            session.run("key:Ctrl-Shift-0")
            self.assertGreaterEqual(float(re.search(
                r"view=-?[0-9.]+\.\.(-?[0-9.]+)", session.run("soundstate")
            ).group(1)), 1.0)

    def test_wave_a_end_is_delay_aware_exact_left_pointing_character_triangle(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            session.run("wavefixture:timing-a")
            shape = _wave_loop_state(session)
            self.assertEqual((shape["looped"], shape["stopped"]), (0, 1))
            self.assertEqual((shape["startVisible"], shape["endVisible"]), (0, 1))
            self.assertEqual(shape["endFrame"], 12)
            self.assertEqual(shape["endRight"] - shape["endLeft"], 8)
            self.assertEqual(shape["bottom"] - shape["top"], 14)
            self.assertEqual(shape["endDir"], "left")

    def test_wave_b_loop_pair_is_delay_and_speed_aware_with_exact_orientation(self) -> None:
        for fixture, expected in (("timing-b", (4, 32)), ("timing-b1", (5, 35))):
            with self.subTest(fixture=fixture), _master_session() as session:
                _new_isolated_wave(session)
                session.run(f"wavefixture:{fixture}")
                shape = _wave_loop_state(session)
                self.assertEqual((shape["looped"], shape["stopped"]), (1, 0))
                self.assertEqual((shape["startFrame"], shape["endFrame"]), expected)
                self.assertEqual((shape["startDir"], shape["endDir"]), ("right", "left"))
                self.assertEqual(shape["startRight"] - shape["startLeft"], 8)
                self.assertEqual(shape["endRight"] - shape["endLeft"], 8)
                self.assertEqual(shape["bottom"] - shape["top"], 14)

    def test_stopped_end_and_both_loop_triangles_retarget_legal_rows_with_one_undo(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            session.run("wavefixture:timing-a")
            before = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 6)
            shape = _wave_loop_state(session)
            y = shape["top"] // 14
            session.run(
                f"drag:{shape['endLeft'] // 8},{y},{_plot_x_for_tick(session, 0)},{y}"
            )
            changed = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 6)
            self.assertEqual(changed[-1], (w0 + 5, 0x7F, w0))
            session.run("key:Ctrl-z")
            self.assertEqual(_wave_rows(session.run(f"wavedump:0x{w0:02x}"), 6), before)

        for grip in ("start", "end"):
            with self.subTest(grip=grip), _master_session() as session:
                w0 = _new_isolated_wave(session)
                session.run("wavefixture:timing-b")
                before = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 7)
                shape = _wave_loop_state(session)
                x = shape[f"{grip}Left"] // 8
                y = shape["top"] // 14
                session.run(f"drag:{x},{y},{_plot_x_for_tick(session, 0)},{y}")
                changed = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 7)
                self.assertEqual(changed[-1], (w0 + 6, 0x7F, w0))
                session.run("key:Ctrl-z")
                self.assertEqual(_wave_rows(session.run(f"wavedump:0x{w0:02x}"), 7), before)

    def test_wave_loop_retarget_uses_the_block_owning_pointer_tick(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            session.run("wavefixture:timing-b")
            shape = _wave_loop_state(session)
            y = int(shape["top"]) // 14
            session.run(
                f"drag:{int(shape['endLeft']) // 8},{y},"
                f"{_plot_x_for_tick(session, 15)},{y}"
            )
            # Tick 15 is inside the long W0+2 delay block even though W0+3's
            # start is geometrically closer. Ownership, not nearest start, wins.
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 7)[-1],
                (w0 + 6, 0x7F, w0 + 2),
            )

    def test_pulse_and_filter_loop_retarget_keep_the_same_pointer_ownership_rule(self) -> None:
        with self.subTest(table="Pulse"), _master_session() as session:
            _new_isolated_wave(session)
            p0 = _instrument_bytes(session.run("insbytes"))[5]
            _select_pulse_at(session, 0)
            edge_y = _pulse_boundary_row(session, 1)
            session.run(
                f"drag:{_plot_x_for_tick(session, 1)},{edge_y},"
                f"{_plot_x_for_tick(session, 20)},{edge_y}"
            )
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_FIT)
            session.run(f"click:{_plot_x_for_tick(session, 10)},7")
            # First use the existing END grip to establish a loop to block 2.
            shape = _sweep_loop_state(session, "P")
            session.run(
                f"drag:{_cell_inside(shape['endLeft'], shape['endRight'])},"
                f"{shape['top'] // 14},{_plot_x_for_tick(session, 20)},"
                f"{shape['top'] // 14}"
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0 + 2)[3], p0 + 1)

            # The exact LEFT triangle now retargets to the long block owning tick 15.
            shape = _sweep_loop_state(session, "P")
            before = _full_sound_dump(session.run("sounddump"))
            session.run(
                f"drag:{_cell_inside(shape['startLeft'], shape['startRight'])},"
                f"{shape['top'] // 14},{_plot_x_for_tick(session, 15)},"
                f"{shape['top'] // 14}"
            )
            after = _full_sound_dump(session.run("sounddump"))
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0 + 2)[3], p0)
            self.assertEqual(
                [i for i, pair in enumerate(zip(before["pulse"], after["pulse"]))
                 if pair[0] != pair[1]],
                [(p0 + 2) * 4 + 3],
            )
            for key in ("instruments", "wave", "filter"):
                self.assertEqual(after[key], before[key])
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

            # Retain the equivalent right/end-triangle ownership and undo check.
            shape = _sweep_loop_state(session, "P")
            session.run(
                f"drag:{_cell_inside(shape['endLeft'], shape['endRight'])},"
                f"{shape['top'] // 14},{_plot_x_for_tick(session, 15)},"
                f"{shape['top'] // 14}"
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0 + 2)[3], p0)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

        with self.subTest(table="Filter"), _master_session() as session:
            f0, _, _ = _build_exact_filter_three_blocks(session)
            # Tick 15 belongs to block 1's emitted SWEEP row F0+1.
            session.run(f"click:{_plot_x_for_tick(session, 20)},7")
            shape = _sweep_loop_state(session, "F")
            before = _full_sound_dump(session.run("sounddump"))
            session.run(
                f"drag:{_cell_inside(shape['startLeft'], shape['startRight'])},"
                f"{shape['top'] // 14},"
                f"{_plot_x_for_tick(session, 15)},{shape['top'] // 14}"
            )
            after = _full_sound_dump(session.run("sounddump"))
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 5)[3], f0 + 1)
            self.assertEqual(
                [i for i, pair in enumerate(zip(before["filter"], after["filter"]))
                 if pair[0] != pair[1]],
                [(f0 + 5) * 4 + 3],
            )
            for key in ("instruments", "wave", "pulse"):
                self.assertEqual(after[key], before[key])
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

            # Retain right/end-triangle parity using the same shared geometry.
            shape = _sweep_loop_state(session, "F")
            session.run(
                f"drag:{_cell_inside(shape['endLeft'], shape['endRight'])},"
                f"{shape['top'] // 14},{_plot_x_for_tick(session, 15)},"
                f"{shape['top'] // 14}"
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 5)[3], f0 + 1)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_wave_loop_retarget_outside_timeline_uses_nearest_legal_normal_row(self) -> None:
        # §22 position decides the loop TYPE for an off-timeline drag: off the LEFT edge
        # lands on the first authored row (a $7F jump); off the RIGHT edge lands on the
        # last authored row, which is "loop to previous" ($7E, marker 0x7E / target 0).
        for target_x, side in ((-100, "left"), (300, "right")):
            with self.subTest(side=side), _master_session() as session:
                w0 = _new_isolated_wave(session)
                session.run("wavefixture:timing-b")
                before = _full_sound_dump(session.run("sounddump"))
                shape = _wave_loop_state(session)
                y = int(shape["top"]) // 14
                session.run(
                    f"drag:{_cell_inside(int(shape['endLeft']), int(shape['endRight']))},"
                    f"{y},{target_x},{y}"
                )
                after = _full_sound_dump(session.run("sounddump"))
                marker = after["wave"][w0 + 6]
                target = after["wave"][w0 + 6 + 256]
                if side == "left":
                    self.assertEqual(marker, 0x7F)
                    self.assertEqual(target, w0)          # first authored row
                    changed = [w0 + 6 + 256]
                else:
                    self.assertEqual(marker, 0x7E)        # loop to previous (last row)
                    self.assertEqual(target, 0)
                    changed = [w0 + 6, w0 + 6 + 256]
                self.assertEqual(
                    [i for i, pair in enumerate(zip(before["wave"], after["wave"]))
                     if pair[0] != pair[1]],
                    changed,
                )
                for key in ("instruments", "pulse", "filter"):
                    self.assertEqual(after[key], before[key])
                session.run("key:Ctrl-z")
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_shared_wave_triangle_default_fork_and_linked_are_atomic_and_rerender_once(self) -> None:
        def generation(session) -> tuple[int, int]:
            state = session.run("soundstate")
            match = re.search(r"captureLen=(\d+).* trigger=(\d+)", state)
            self.assertIsNotNone(match)
            return tuple(map(int, match.groups()))

        for linked in (False, True):
            with self.subTest(linked=linked), _master_session() as session:
                for _ in range(6):
                    session.run("key:KP_PLUS")
                session.run("wavefixture:shared-two")
                old_ptr = _instrument_bytes(session.run("insbytes"))[7]
                before = _full_sound_dump(session.run("sounddump"))
                if linked:
                    session.run("key:Ctrl-Shift-e")
                    self.assertRegex(session.run("soundstate"), r"ownership=linked\b")
                session.run("jamrender:z,4")
                session.run("frames:2")
                before_generation = generation(session)
                shape = _wave_loop_state(session)
                y = int(shape["top"]) // 14
                session.run(f"press:{int(shape['endLeft']) // 8},{y}")
                session.run(f"move:{_plot_x_for_tick(session, 3)},{y}")
                self.assertEqual(generation(session), before_generation)
                during = _full_sound_dump(session.run("sounddump"))
                new_ptr = _instrument_bytes(session.run("insbytes"))[7]
                self.assertNotIn("(y/n)", session.run("screendump").lower())
                self.assertEqual(generation(session), before_generation)
                if linked:
                    self.assertEqual(new_ptr, old_ptr)
                else:
                    self.assertNotEqual(new_ptr, old_ptr)
                    self.assertEqual(during["wave"][old_ptr + 2 + 256], old_ptr)
                # §22 tick 3 lands on the last authored row => "loop to previous" ($7E)
                self.assertEqual(during["wave"][new_ptr + 2], 0x7E)
                self.assertEqual(during["wave"][new_ptr + 2 + 256], 0)
                session.run(f"release:{_plot_x_for_tick(session, 3)},{y}")
                after_generation = generation(session)
                self.assertEqual(after_generation[1], before_generation[1] + 1)
                self.assertGreater(after_generation[0], 0)
                session.run("key:Ctrl-z")
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_triangle_top_cell_has_priority_but_below_keeps_row_gesture_and_offscreen_has_no_rail(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            session.run("wavefixture:timing-b")
            shape = _wave_loop_state(session)
            x = shape["startLeft"] // 8
            top_row = shape["top"] // 14
            session.run(f"hover:{x},{top_row}")
            self.assertRegex(session.run("soundstate"), r"cursor=1 ")
            session.run(f"hover:{x},{FREQ_GRAPH_ROW + 1}")
            self.assertRegex(session.run("soundstate"), r"cursor=[12] ")
            for _ in range(8):
                session.run("key:Ctrl-Shift-i")
            for _ in range(20):
                session.run("key:Shift-RIGHT")
            offscreen = _wave_loop_state(session)
            self.assertEqual((offscreen["startVisible"], offscreen["endVisible"]), (0, 0))

    def test_long_authored_wave_extent_survives_short_keyjam_and_fit(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            session.run("wavefixture:timing-b")
            session.run("jamrender:z,4")
            session.run("frames:2")
            session.run("key:Ctrl-Shift-0")  # Fit
            state = session.run("soundstate")
            view = re.search(r"view=[^.]*(?:\.[0-9]+)?\.\.(-?[0-9.]+)", state)
            if view is None:
                view = re.search(r"view=-?[0-9.]+\.\.(-?[0-9.]+)", state)
            self.assertIsNotNone(view)
            self.assertGreaterEqual(float(view.group(1)), 32.0)


if __name__ == "__main__":
    unittest.main()
