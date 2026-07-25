"""Phase 5-A: raw reSID envelope truth contracts (test-first).

These tests intentionally require an 8-bit ``env`` channel separate from the
legacy synthetic floating-point ``amp`` channel.  They stay red until the SID
core, visualizer, driver oracles, and Sound Editor all carry that value.
"""

from __future__ import annotations

import re
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

from tests.test_sound_editor_master_usage import (
    _capture_fields,
    _instrument_bytes,
    _master_session,
)


def _hex_channel(output: str, label: str) -> list[int]:
    match = re.search(rf"^{re.escape(label)}:((?: [0-9A-F]{{2}})+)$", output, re.I | re.M)
    if match is None:
        raise AssertionError(f"missing 8-bit envelope oracle {label!r}\n{output}")
    return [int(value, 16) for value in match.group(1).split()]


def _set_param(session, row: int, current: int, target: int) -> None:
    """Edit one visible scalar using the same mouse/keyboard path as a user."""
    session.run(f"click:10,{row}")
    key = "RIGHT" if target > current else "LEFT"
    for _ in range(abs(target - current)):
        session.run(f"key:{key}")


def _set_adsr(session, ad: int, sr: int) -> None:
    raw = _instrument_bytes(session.run("insbytes"))
    current = (raw[0] >> 4, raw[0] & 0x0F, raw[1] >> 4, raw[1] & 0x0F)
    target = (ad >> 4, ad & 0x0F, sr >> 4, sr & 0x0F)
    for row, old, new in zip((7, 8, 9, 10), current, target):
        _set_param(session, row, old, new)
    changed = _instrument_bytes(session.run("insbytes"))
    if changed[:2] != [ad, sr]:
        raise AssertionError(f"UI ADSR edit landed at {changed[:2]}, wanted {[ad, sr]}")


def _set_gate_ticks(session, current: int, target: int) -> int:
    _set_param(session, 20, current, target)
    return target


def _record_note(session, key: str, voice: int = 0, ticks: int = 80):
    session.run(f"jamrender:{key},{ticks}")
    recording = session.run(f"recdump:{voice}")
    capture = _capture_fields(session.run("capturestate"))
    session.run(f"keyup:{key}")
    return (
        _hex_channel(recording, f"rec v{voice} env"),
        _hex_channel(recording, f"rec v{voice} ctrl"),
        capture,
    )


def _read_png_rgb(path: Path) -> tuple[int, int, list[bytearray]]:
    """Minimal stdlib PNG reader for ccdriver's non-interlaced RGB screenshots."""
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssertionError(f"not a PNG: {path}")
    pos, packed = 8, bytearray()
    width = height = color_type = 0
    while pos < len(data):
        size = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + size]
        pos += size + 12
        if kind == b"IHDR":
            width, height, depth, color_type, _, _, interlace = struct.unpack(
                ">IIBBBBB", payload
            )
            if depth != 8 or color_type != 2 or interlace != 0:
                raise AssertionError("ccdriver screenshot must be 8-bit RGB/non-interlaced")
        elif kind == b"IDAT":
            packed.extend(payload)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(packed)
    stride, bpp = width * 3, 3
    rows: list[bytearray] = []
    previous = bytearray(stride)
    offset = 0
    for _ in range(height):
        filter_type = raw[offset]
        offset += 1
        current = bytearray(raw[offset:offset + stride])
        offset += stride
        for index in range(stride):
            left = current[index - bpp] if index >= bpp else 0
            above = previous[index]
            upper_left = previous[index - bpp] if index >= bpp else 0
            if filter_type == 1:
                current[index] = (current[index] + left) & 0xFF
            elif filter_type == 2:
                current[index] = (current[index] + above) & 0xFF
            elif filter_type == 3:
                current[index] = (current[index] + (left + above) // 2) & 0xFF
            elif filter_type == 4:
                estimate = left + above - upper_left
                distances = (
                    abs(estimate - left), abs(estimate - above), abs(estimate - upper_left)
                )
                predictor = (left, above, upper_left)[distances.index(min(distances))]
                current[index] = (current[index] + predictor) & 0xFF
            elif filter_type != 0:
                raise AssertionError(f"unsupported PNG filter {filter_type}")
        rows.append(current)
        previous = current
    return width, height, rows


def _pixel_is(rows: list[bytearray], x: int, y: int, rgb: tuple[int, int, int]) -> bool:
    if y < 0 or y >= len(rows) or x < 0 or x * 3 + 2 >= len(rows[y]):
        return False
    return tuple(rows[y][x * 3:x * 3 + 3]) == rgb


def _capture_line(output: str) -> str:
    match = re.search(r"^capture:.*$", output, re.M)
    if match is None:
        raise AssertionError("missing capture line\n" + output)
    return match.group(0)


def _env_preview(output: str, *, expected_note: int | None = None) -> tuple[int, list[int]]:
    meta = re.search(
        r"env preview: source=resid-estimate note=(\d+) pcm=0 remote=0 render=(\d+)",
        output,
    )
    if meta is None:
        raise AssertionError("missing silent reSID preview metadata\n" + output)
    note, generation = map(int, meta.groups())
    if expected_note is not None and note != expected_note:
        raise AssertionError(
            f"silent preview used note {note}, expected {expected_note}\n{output}"
        )
    return generation, _hex_channel(output, "env preview env")


class SoundEditorResidEnvelopeContractTests(unittest.TestCase):
    def test_recdump_exposes_raw_env_separately_from_synthetic_amp(self) -> None:
        with _master_session() as session:
            session.run("jamrender:q,12")
            recording = session.run("recdump:0")
            env = _hex_channel(recording, "rec v0 env")
            self.assertIn("rec v0 amp:", recording)
            self.assertTrue(env)
            self.assertTrue(all(0 <= value <= 0xFF for value in env))

    def test_adsr_gate_and_note_matrix_is_trigger_aligned(self) -> None:
        """Every requested AD/SR, gate, and note exposes a valid raw ENV trace."""
        for ad, sr in ((0x88, 0x88), (0x93, 0x27)):
            # Verify the silent, history-free estimate for all requested gates.
            with self.subTest(adsr=f"{ad:02X}{sr:02X}"), _master_session() as session:
                _set_adsr(session, ad, sr)
                current_gate = 50
                for gate_ticks in (1, 4, 40):
                    current_gate = _set_gate_ticks(session, current_gate, gate_ticks)
                    generation, offline = _env_preview(
                        session.run("envpreview:64"), expected_note=48
                    )
                    repeated_generation, repeated = _env_preview(
                        session.run("envpreview:64"), expected_note=48
                    )
                    self.assertEqual((repeated_generation, repeated),
                                     (generation, offline))
                    self.assertEqual(len(offline), 64)
                    if gate_ticks in (1, 4):
                        self.assertEqual(offline[:gate_ticks],
                                         sorted(offline[:gate_ticks]))
                        self.assertLess(max(offline[:gate_ticks]), 0xFF)
                        self.assertEqual(offline[-1], 0)
                    else:
                        sustain = (sr >> 4) * 0x11
                        self.assertGreater(max(offline[:gate_ticks]), 0xF0)
                        self.assertIn(sustain, offline[30:gate_ticks])
                        self.assertLess(offline[gate_ticks], sustain)

            # SID envelopes have rate-counter history. Give each pitch the same fresh
            # history so this comparison isolates pitch rather than retrigger history.
            for gate_ticks in (1, 4, 40):
                for key, note in (("q", 48), ("b", 43), ("x", 26)):
                    with self.subTest(adsr=f"{ad:02X}{sr:02X}", gate=gate_ticks,
                                      note=note), _master_session() as note_session:
                        _set_adsr(note_session, ad, sr)
                        _set_gate_ticks(note_session, 50, gate_ticks)
                        if note == 26:
                            note_session.run("key:KP_DIV")
                        env, ctrl, capture = _record_note(note_session, key)
                        self.assertEqual(capture["gateHigh"], gate_ticks)
                        self.assertEqual(capture["voice"], 1)
                        self.assertEqual(sum(value & 1 for value in ctrl), gate_ticks)
                        self.assertTrue(env)
                        self.assertEqual(len(env), len(ctrl))
                        self.assertTrue(all(0 <= value <= 0xFF for value in env))
                        # The live player is stateful and starts each key command at its
                        # actual CPU phase.  Do not compare separately launched sessions
                        # sample-for-sample; backend parity below runs an identical command
                        # sequence and is the deterministic pitch-independence oracle.
                        self.assertGreater(max(env[:gate_ticks]), 0)

    def test_silent_default_c4_preview_uses_resid_without_side_effects(self) -> None:
        """Before keyjam, the C-4 preview is same-core data but emits no sound/note."""
        with _master_session() as session:
            before_capture = _capture_line(session.run("capturestate"))
            before_state = session.run("soundstate")
            preview = session.run("envpreview:64")
            self.assertRegex(
                preview,
                r"env preview: source=resid-estimate note=48 pcm=0 remote=0 render=\d+",
            )
            generation, env = _env_preview(preview, expected_note=48)
            repeated_generation, repeated_env = _env_preview(
                session.run("envpreview:64"), expected_note=48
            )
            self.assertEqual((repeated_generation, repeated_env), (generation, env))
            self.assertGreater(len(env), 1)
            self.assertTrue(any(env))
            after_capture = _capture_line(session.run("capturestate"))
            after_state = session.run("soundstate")
            self.assertEqual(after_capture, before_capture)
            self.assertRegex(before_state, r"trigger=0 preview=0/48")
            self.assertRegex(after_state, r"trigger=0 preview=0/48")
            self.assertRegex(session.run("recdump:0"), r"(?m)^rec v0 env:$")

            # The isolated preview cannot inherit the live player's CPU-cycle phase.
            # It must nevertheless closely track and converge with the later raw C-4.
            session.run("jamrender:q,80")
            live = _hex_channel(session.run("recdump:0"), "rec v0 env")
            session.run("keyup:q")
            self.assertGreaterEqual(len(live), len(env))
            active = [
                abs(actual - estimated)
                for actual, estimated in zip(live, env)
                if actual or estimated
            ]
            self.assertTrue(active)
            # The isolated core cannot know the live player's CPU instruction phase.
            # Bound that uncertainty to 5% of the 8-bit counter, then require the
            # estimate to converge and share the exact zero tail.
            self.assertLessEqual(max(active), 13)
            midpoint = max(1, len(active) // 2)
            self.assertLessEqual(sum(active[midpoint:]), sum(active[:midpoint]))
            self.assertEqual(live[len(active):len(active) + 1], [0])
            self.assertEqual(env[len(active):len(active) + 1], [0])

    def test_pre_keyjam_mouse_move_is_silent_and_release_renders_once(self) -> None:
        with _master_session() as session:
            session.run("frames:2")
            generation0, env0 = _env_preview(
                session.run("envpreview:64"), expected_note=48
            )
            capture0 = _capture_line(session.run("capturestate"))
            state0 = session.run("soundstate")
            self.assertRegex(state0, r"trigger=0 preview=0/48")

            # Default instrument's attack handle advertises horizontal motion here.
            session.run("hover:44,11")
            self.assertRegex(session.run("soundstate"), r"cursor=1 ")
            session.run("press:44,11")
            session.run("move:50,11")
            generation_during, env_during = _env_preview(
                session.run("envpreview:64"), expected_note=48
            )
            self.assertEqual((generation_during, env_during), (generation0, env0))
            self.assertEqual(_capture_line(session.run("capturestate")), capture0)
            self.assertRegex(session.run("soundstate"), r"trigger=0 preview=0/48")

            session.run("release:50,11")
            generation_after, env_after = _env_preview(
                session.run("envpreview:64"), expected_note=48
            )
            self.assertEqual(generation_after, generation0 + 1)
            self.assertNotEqual(env_after, env0)
            self.assertEqual(_capture_line(session.run("capturestate")), capture0)
            self.assertRegex(session.run("soundstate"), r"trigger=0 preview=0/48")

    def test_four_rows_follow_song_speed_and_multiplier(self) -> None:
        """Row duration is speed calls times the calls-per-frame multiplier."""
        for speed in (4, 5, 6):
            with self.subTest(speed=speed), _master_session() as session:
                # Fixture speed is 5. Use the visible tracker speed hotspot while the
                # Sound Editor is closed, then reopen it; no test-only song mutation.
                session.run("key:Ctrl-e")
                button = 1 if speed > 5 else 3
                for _ in range(abs(speed - 5)):
                    session.run(f"click:31,46,{button}")
                session.run("key:Ctrl-e")
                session.run("frames:2")

                session.run("click:10,21")
                session.run("key:RIGHT")  # Ticks -> Rows (50 ticks -> 5 rows)
                chrome = session.run("screendump")
                current_rows_match = re.search(r"Gate high\s+(\d+) Rows", chrome)
                self.assertIsNotNone(current_rows_match)
                _set_param(session, 20, int(current_rows_match.group(1)), 4)
                for multiplier in (1, 2, 4):
                    with self.subTest(speed=speed, multiplier=multiplier):
                        session.run(f"mult:{multiplier}")
                        session.run("frames:2")
                        state = session.run("soundstate")
                        expected_step = speed * multiplier
                        self.assertRegex(state, rf"stepTicks={expected_step}\b")
                        _, ctrl, capture = _record_note(
                            session, "q", ticks=expected_step * 4 + 24
                        )
                        self.assertEqual(capture["gateHigh"], expected_step * 4)
                        self.assertEqual(sum(value & 1 for value in ctrl), expected_step * 4)

    def test_resid_and_resid_fp_match_envelope_and_onset(self) -> None:
        """Both compiled SID engines expose the same raw counter timeline."""
        results: dict[str, list[tuple[list[int], dict[str, int | str]]]] = {}
        offline_results: dict[str, list[int]] = {}
        for backend in ("resid", "resid-fp"):
            with _master_session() as session:
                selected = session.run(f"backend:{backend}")
                self.assertIn(f"backend: {backend}", selected)
                _set_adsr(session, 0x93, 0x27)
                _set_gate_ticks(session, 50, 40)
                _, offline_results[backend] = _env_preview(
                    session.run("envpreview:64"), expected_note=48
                )
                traces = []
                for key in ("q", "b"):
                    env, _, capture = _record_note(session, key)
                    traces.append((env, capture))
                session.run("key:KP_DIV")
                env, _, capture = _record_note(session, "x")
                traces.append((env, capture))
                results[backend] = traces
        self.assertEqual(offline_results["resid"], offline_results["resid-fp"])
        for note_index, note in enumerate(("C-4", "G-3", "D-2")):
            with self.subTest(note=note):
                standard = results["resid"][note_index]
                fp = results["resid-fp"][note_index]
                self.assertEqual(standard[0], fp[0])
                for field in ("gateOn", "gateOff", "gateHigh", "onsetSample",
                              "frameSamples"):
                    self.assertEqual(standard[1][field], fp[1][field])

    def test_release_can_begin_during_attack_and_decay(self) -> None:
        """Gate-off continues from the true current counter, without a phase jump."""
        cases = ((0x88, 0x88, 1, "attack"), (0x88, 0x88, 12, "decay"),
                 (0x93, 0x27, 4, "attack"), (0x93, 0x27, 27, "decay"))
        for ad, sr, gate_ticks, phase in cases:
            with self.subTest(adsr=f"{ad:02X}{sr:02X}", phase=phase), _master_session() as session:
                _set_adsr(session, ad, sr)
                _set_gate_ticks(session, 50, gate_ticks)
                env, ctrl, _ = _record_note(session, "q")
                gate_off = next(i for i, value in enumerate(ctrl) if not (value & 1))
                self.assertEqual(gate_off, gate_ticks)
                before = env[:gate_off]
                if phase == "attack":
                    self.assertLess(max(before), 0xFF)
                    self.assertEqual(max(before), before[-1])
                else:
                    peak_at = before.index(max(before))
                    self.assertLess(peak_at, gate_off - 1)
                    self.assertLess(before[-1], max(before))
                    self.assertGreater(before[-1], (sr >> 4) * 0x11)
                # First released sample must continue locally, not reset to 0/255.
                self.assertLess(abs(env[gate_off] - env[gate_off - 1]), 0x40)

    def test_selected_keyjam_voice_owns_the_raw_envelope(self) -> None:
        for voice in range(3):
            with self.subTest(voice=voice + 1), _master_session() as session:
                _set_adsr(session, 0x88, 0x88)
                _set_gate_ticks(session, 50, 4)
                _set_param(session, 19, 0, voice)
                env, ctrl, capture = _record_note(session, "q", voice)
                self.assertEqual(capture["voice"], voice + 1)
                self.assertEqual(sum(value & 1 for value in ctrl), 4)
                self.assertTrue(any(env))

    def test_png_adsr_curve_hits_raw_env_at_true_tick_geometry(self) -> None:
        """Independent PNG pixels, not a graph value-array, verify WYSIWYG."""
        with _master_session() as session, tempfile.TemporaryDirectory() as tmp:
            _set_adsr(session, 0x88, 0x88)
            _set_gate_ticks(session, 50, 40)
            session.run("jamrender:q,55")
            session.run("frames:2")
            state = session.run("soundstate")
            self.assertIn("recording=true", state)
            env = _hex_channel(session.run("recdump:0"), "rec v0 env")
            image_path = Path(tmp) / "adsr.png"
            session.run(f"shot:{image_path}")
            width, height, rows = _read_png_rgb(image_path)
            self.assertEqual((width, height), (1280, 700))

            view = re.search(r"view=(-?[0-9.]+)\.\.(-?[0-9.]+)", state)
            assert view is not None
            view_start, view_end = map(float, view.groups())
            font_x, font_y = width // 160, height // 50
            plot_x0, plot_width = 39 * font_x, 117 * font_x
            stack_top, stack_bottom = 7 * font_y, 34 * font_y
            wave_top = stack_bottom - 9 * font_y
            span = wave_top - stack_top
            band1 = stack_top + round(span * 1.0 / 4.7)
            band2 = stack_top + round(span * 2.0 / 4.7)
            top, bottom = band1 + 2, band2 - 3
            graph_height = bottom - top
            green = (0xA9, 0xFE, 0x9F)

            hits = 0
            midpoint_hits = 0
            checked = 0
            for tick, value in enumerate(env[: min(len(env), 40)]):
                x = plot_x0 + round((tick - view_start) / (view_end - view_start) * plot_width)
                y = bottom - round(value / 255 * graph_height)
                checked += 1
                if any(
                    _pixel_is(rows, x + dx, y + dy, green)
                    for dx in range(-2, 3) for dy in range(-2, 3)
                ):
                    hits += 1
                if tick + 1 < len(env):
                    mid_x = plot_x0 + round(
                        (tick + 0.5 - view_start) / (view_end - view_start) * plot_width
                    )
                    mid_value = (value + env[tick + 1]) / 2
                    mid_y = bottom - round(mid_value / 255 * graph_height)
                    if any(
                        _pixel_is(rows, mid_x + dx, mid_y + dy, green)
                        for dx in range(-2, 3) for dy in range(-2, 3)
                    ):
                        midpoint_hits += 1
            self.assertGreaterEqual(hits, checked * 3 // 4,
                                    f"only {hits}/{checked} raw ENV points hit the PNG curve")
            self.assertGreaterEqual(
                midpoint_hits, (checked - 1) * 3 // 4,
                f"only {midpoint_hits}/{checked - 1} interpolated midpoints hit the curve",
            )


if __name__ == "__main__":
    unittest.main()
