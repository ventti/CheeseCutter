"""Focused executable contract for row-aware wavetable mouse gestures (R69)."""

from __future__ import annotations

import re
import unittest

from tests.test_sound_editor_master_usage import (
    BTN_ADD,
    FILTER_TOP_ROW,
    FREQ_GRAPH_ROW,
    _click_control,
    _full_sound_dump,
    _master_session,
    _new_isolated_wave,
    _plot_x_for_tick,
    _preview_values,
    _set_selected_wave_row,
    _wave_rows,
)


WAVE_GATE_LANE_ROW = 33
WAVE_TRI_LANE_ROW = WAVE_GATE_LANE_ROW - 4
WAVE_SAW_LANE_ROW = WAVE_GATE_LANE_ROW - 5


def _generation(session) -> tuple[int, int]:
    state = session.run("soundstate")
    match = re.search(r"captureLen=(\d+).* trigger=(\d+)", state)
    if match is None:
        raise AssertionError("missing capture/trigger generation\n" + state)
    return int(match.group(1)), int(match.group(2))


def _effective_wave_control(session) -> int:
    return _preview_values(session.run("wavepreview:1"), "ctrl")[0]


class SoundEditorWaveGestureTests(unittest.TestCase):
    def test_unrepresentable_direct_control_paint_is_a_true_no_op(self) -> None:
        # $C0 + Saw would need raw $E0, but $E0 decodes as effective $00; $D0 + Saw
        # would need reserved raw $F0.  Neither request may silently change meaning.
        for raw, desired in ((0xC0, 0xE0), (0xD0, 0xF0)):
            with self.subTest(raw=f"{raw:02X}", desired=f"{desired:02X}"), _master_session() as session:
                w0 = _new_isolated_wave(session)
                _set_selected_wave_row(session, 0x0C, raw)
                before = _full_sound_dump(session.run("sounddump"))
                self.assertEqual(_effective_wave_control(session), raw)

                session.run("jamrender:z,120")
                session.run("frames:2")
                generation = _generation(session)
                x0 = _plot_x_for_tick(session, 0)
                session.run(f"click:{x0},{WAVE_SAW_LANE_ROW}")

                self.assertEqual(_full_sound_dump(session.run("sounddump")), before)
                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                    (0x0C, raw),
                )
                self.assertEqual(_effective_wave_control(session), raw)
                self.assertEqual(_generation(session), generation)
                help_text = session.run("screendump").lower()
                self.assertIn("cannot", help_text)
                self.assertIn("represent", help_text)

                # The rejected gesture must not consume an undo entry: one undo reaches
                # the preceding exact-W2 edit instead of popping an identical snapshot.
                session.run("key:Ctrl-z")
                self.assertNotEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][2],
                    raw,
                )

    def test_direct_and_encoded_low_control_cross_the_e0_boundary_losslessly(self) -> None:
        for raw, expected_raw, expected_effective in (
            (0x10, 0xE0, 0x00),  # clear Triangle from direct $10
            (0xE0, 0x10, 0x10),  # set Triangle from encoded effective $00
        ):
            with self.subTest(raw=f"{raw:02X}"), _master_session() as session:
                w0 = _new_isolated_wave(session)
                _set_selected_wave_row(session, 0x0C, raw)
                x0 = _plot_x_for_tick(session, 0)
                session.run(f"click:{x0},{WAVE_TRI_LANE_ROW}")

                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                    (0x0C, expected_raw),
                )
                self.assertEqual(_effective_wave_control(session), expected_effective)
                session.run("key:Ctrl-z")
                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                    (0x0C, raw),
                )

    def test_relative_absolute_and_carry_rows_use_pitch_only_vertical_drag(self) -> None:
        # The dragged-to value follows the frequency band's auto-fit vertical scale
        # (max(12, largest value in the program)), which is what the band is drawn
        # against -- so one cell down from row 15 is a different number of semitones
        # for a program that peaks at 32 than for one that peaks at 48. These
        # expectations previously assumed a fixed 0..$5F axis that the drawing side
        # never used, which is why a dragged block did not follow the cursor; see
        # yForPitch/pitchForY in src/ui/soundedit.d.
        for w1, w2, expected_w1 in (
            (0x20, 0x41, 0x0E),  # relative pitch keeps the $00..$5F encoding class
            (0xB0, 0x81, 0x95),  # absolute pitch keeps the $80..$DF encoding class
            (0x20, 0x00, 0x0E),  # Carry stays Carry; only W1 is changed
        ):
            with self.subTest(row=f"{w1:02X}/{w2:02X}"), _master_session() as session:
                w0 = _new_isolated_wave(session)
                _set_selected_wave_row(session, w1, w2)
                x0 = _plot_x_for_tick(session, 0)
                session.run(f"hover:{x0},{FREQ_GRAPH_ROW}")
                self.assertRegex(session.run("soundstate"), r"cursor=2 ")
                session.run(
                    f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{FREQ_GRAPH_ROW + 1}"
                )
                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                    (expected_w1, w2),
                )
                session.run("key:Ctrl-z")
                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                    (w1, w2),
                )

    def test_pitch_drag_value_tracks_the_bands_auto_fit_scale(self) -> None:
        """A dragged pitch block must land where the cursor is.

        The frequency band is drawn on an auto-fitted axis (0..max(12, peak value)),
        so the value a given cursor height means depends on that scale. The drag
        hit-test once used a fixed 0..$5F axis instead, which wrote roughly $5F/scale
        (~8x at the one-octave floor) too much: the block jumped far above the cursor
        and, because the axis then re-fitted to the new peak, every other block moved
        too. Pin the property that broke rather than the arithmetic: at one fixed
        cursor height, programs with different scales must yield values in the same
        ratio as their scales, and the bottom of the band must always mean zero.
        """
        drag_row = FREQ_GRAPH_ROW + 1
        values: dict[int, int] = {}
        for peak in (0x0C, 0x18, 0x30):  # 12 (the floor), 24, 48 semitones
            with self.subTest(peak=f"{peak:02X}"), _master_session() as session:
                w0 = _new_isolated_wave(session)
                _set_selected_wave_row(session, peak, 0x41)
                x0 = _plot_x_for_tick(session, 0)

                session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{drag_row}")
                values[peak] = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1]

                # The very bottom of the band is 0 on every scale.
                _set_selected_wave_row(session, peak, 0x41)
                session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{FILTER_TOP_ROW - 1}")
                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1],
                    0x00,
                    "the band floor must mean zero semitones on every scale",
                )

        # Same cursor height, scales 12:24:48 -> values must rise in step. The old
        # fixed-axis hit-test produced the SAME value for all three.
        self.assertLess(values[0x0C], values[0x18])
        self.assertLess(values[0x18], values[0x30])
        for smaller, larger in ((0x0C, 0x18), (0x18, 0x30)):
            self.assertAlmostEqual(
                values[larger] / values[smaller],
                larger / smaller,
                delta=0.35,  # integer semitone quantization on a ~5-row-tall band
                msg=f"value ratio must follow the scale ratio: {values}",
            )

    def test_pitch_drag_resolves_below_one_character_cell(self) -> None:
        """Pitch must be draggable at pixel resolution, not cell resolution.

        Mouse events reach the UI as character cells, and the frequency band is under
        five cells tall -- so reconstructing a cell centre caps the whole 0..$5F range
        at ~5 reachable values, ~20 semitones apart. The drag reads the exact pixel row
        (com.fb.mousePixelY) instead; `dragpx` publishes it the way main.mainloop does.
        """
        font_y = 14  # com.fb.FONT_Y
        rows = range(FREQ_GRAPH_ROW * font_y, (FREQ_GRAPH_ROW + 3) * font_y)
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            x0 = _plot_x_for_tick(session, 0)
            seen: list[int] = []
            for pixel_y in rows:
                _set_selected_wave_row(session, 0x30, 0x41)  # peak $30 -> scale 48
                session.run(
                    f"dragpx:{x0},{FREQ_GRAPH_ROW * font_y + font_y // 2},{x0},{pixel_y}"
                )
                seen.append(_wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1])

            cells_spanned = len({y // font_y for y in rows})
            self.assertGreater(
                len(set(seen)),
                cells_spanned,
                f"pitch still quantized to character cells: {seen}",
            )
            # Moving the cursor down must never raise the pitch.
            for earlier, later in zip(seen, seen[1:]):
                self.assertGreaterEqual(earlier, later, f"non-monotonic drag: {seen}")

    def test_delay_w2_is_horizontal_clamped_and_never_crosses_encoding_class(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            _set_selected_wave_row(session, 0x0C, 0x04)
            x0 = _plot_x_for_tick(session, 0)
            session.run(f"hover:{x0},{FREQ_GRAPH_ROW}")
            self.assertRegex(session.run("soundstate"), r"cursor=1 ")

            session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0 + 1},{FREQ_GRAPH_ROW}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                (0x0C, 0x05),
            )
            session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0 - 100},{FREQ_GRAPH_ROW}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                (0x0C, 0x01),
            )
            session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0 + 100},{FREQ_GRAPH_ROW}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                (0x0C, 0x0F),
            )

    def test_carry_bit_paint_materializes_encoded_control_and_undo_restores_carry(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            _set_selected_wave_row(session, 0x0C, 0x00)
            x0 = _plot_x_for_tick(session, 0)
            session.run(f"click:{x0},{WAVE_GATE_LANE_ROW}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                (0x0C, 0xE1),
            )
            session.run("key:Ctrl-z")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                (0x0C, 0x00),
            )

    def test_reserved_w1_is_not_drag_editable_and_exact_dialog_remains_fallback(self) -> None:
        for reserved in (0x60, 0x7D, 0xE0, 0xFF):
            with self.subTest(w1=f"{reserved:02X}"), _master_session() as session:
                w0 = _new_isolated_wave(session)
                _set_selected_wave_row(session, reserved, 0x41)
                x0 = _plot_x_for_tick(session, 0)

                session.run(f"hover:{x0},{FREQ_GRAPH_ROW}")
                self.assertRegex(session.run("soundstate"), r"cursor=0 ")
                self.assertIn("reserved; exact", session.run("screendump"))
                session.run(
                    f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{FREQ_GRAPH_ROW + 1}"
                )
                self.assertEqual(
                    _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                    (reserved, 0x41),
                )

    def test_reserved_w2_is_not_drag_editable(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            _set_selected_wave_row(session, 0x0C, 0xF0)
            x0 = _plot_x_for_tick(session, 0)
            session.run(f"hover:{x0},{FREQ_GRAPH_ROW}")
            self.assertRegex(session.run("soundstate"), r"cursor=0 ")
            session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{FREQ_GRAPH_ROW + 1}")
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1:],
                (0x0C, 0xF0),
            )

    def test_direct_control_drag_paints_all_rows_once_and_undoes_as_one_gesture(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            _set_selected_wave_row(session, 0x0C, 0x40)
            _click_control(session, BTN_ADD)
            _set_selected_wave_row(session, 0x0C, 0x40)
            x0, x1 = (_plot_x_for_tick(session, frame) for frame in (0, 1))

            session.run(f"press:{x0},{WAVE_GATE_LANE_ROW}")
            session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")
            session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")
            session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2)],
                [(0x0C, 0x41), (0x0C, 0x41)],
            )
            session.run("key:Ctrl-z")
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2)],
                [(0x0C, 0x40), (0x0C, 0x40)],
            )

    def test_encoded_control_drag_preserves_e_encoding_and_is_idempotent(self) -> None:
        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            _set_selected_wave_row(session, 0x0C, 0xE0)
            _click_control(session, BTN_ADD)
            _set_selected_wave_row(session, 0x0C, 0xE0)
            x0, x1 = (_plot_x_for_tick(session, frame) for frame in (0, 1))

            session.run(f"press:{x0},{WAVE_GATE_LANE_ROW}")
            session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")
            session.run(f"move:{x0},{WAVE_GATE_LANE_ROW}")
            session.run(f"move:{x1},{WAVE_GATE_LANE_ROW}")
            session.run(f"release:{x1},{WAVE_GATE_LANE_ROW}")
            self.assertEqual(
                [row[1:] for row in _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2)],
                [(0x0C, 0xE1), (0x0C, 0xE1)],
            )


if __name__ == "__main__":
    unittest.main()
