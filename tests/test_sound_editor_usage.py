"""Headless usage tests for the Sound Editor requirements audit.

These tests drive the real UI through ccdriver.  Source-level checks are used
only for safety/documentation contracts that cannot be observed through the
dummy SDL device.  Requirement IDs match doc/SOUND_EDITOR_REQUIREMENTS_AUDIT.md.
"""

from __future__ import annotations

import os
import re
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DRIVER = ROOT / "ccdriver"
SONG = "tunes/vent-arkijuusto.ct"
ENTER = (f"load:{SONG}", "key:ESC", "key:Ctrl-e")

# Every deterministic requirement has an executable usage test below.
COVERAGE = {
    "test_classic_round_trip": {"R03", "R04"},
    "test_keyjam_real_sid_and_shortcuts": {"R05", "R10", "R11", "R12", "R30", "R31", "R32"},
    "test_layout_axis_and_tracker_period": {"R06", "R07", "R08", "R09", "R13"},
    "test_probe_selection_zoom_and_pan": {"R14", "R15"},
    "test_menu_masks_only_its_rectangle": {"R16"},
    "test_scalar_edit_and_single_undo": {"R17"},
    "test_filter_create_add_resize_slope_and_delete": {"R18", "R19", "R20", "R21", "R24", "R25", "R26", "R27"},
    "test_single_and_multi_block_join_ownership": {"R22", "R23"},
    "test_piecewise_resonance_and_undo": {"R28"},
    "test_released_keyjam_refreshes_after_edit": {"R29"},
    "test_wave_bit_default_cow_has_no_prompt": {"R33", "R36"},
    "test_wave_bit_undo": {"R37"},
    "test_pitch_program_structure": {"R34"},
    "test_stop_program": {"R35"},
    "test_table_safety_guards": {"R38"},
    "test_context_help_and_references": {"R39"},
}


# Instrumented (ASan) runs are several times slower; the sanitizer job scales
# every driver timeout via CCDRIVER_TIMEOUT_SCALE (default 1.0).
_TIMEOUT_SCALE = float(os.environ.get("CCDRIVER_TIMEOUT_SCALE", "1"))


def run_driver(*commands: str, timeout: int = 20) -> str:
    env = os.environ.copy()
    env.update(SDL_VIDEODRIVER="dummy", SDL_AUDIODRIVER="dummy")
    proc = subprocess.run(
        [str(DRIVER), *commands], cwd=ROOT, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout * _TIMEOUT_SCALE,
    )
    if proc.returncode:
        raise AssertionError(f"ccdriver exited {proc.returncode}\n{proc.stdout}")
    return proc.stdout


def occurrences(output: str, prefix: str) -> list[str]:
    return [line for line in output.splitlines() if line.startswith(prefix)]


def plot_x(tick: int, view_start: float = -2.0, view_end: float = 51.0) -> int:
    """Cell centre for a semantic timeline tick in the 117-cell graph."""
    return round(38.5 + (tick - view_start) / (view_end - view_start) * 117)


def first_filter_handle_geometry() -> tuple[int, int, int]:
    """Return the first added SWEEP's left/right edges and cutoff dot row."""
    out = run_driver(
        *ENTER, "click:39,22", "click:83,35",
        f"drag:{plot_x(2)},23,{plot_x(2) + 5},23", "filtershape",
    )
    match = re.search(r"filter step: row=3 .* x=(\d+)\.\.(\d+) .* y=\d+\.\.(\d+)", out)
    if match is None:
        raise AssertionError("missing first Filter handle geometry\n" + out)
    return tuple(map(int, match.groups()))


def non_dot_filter_boundary_row(edge_x: int) -> int:
    """Locate a horizontal part of that edge rather than assuming a fixed Y row."""
    commands = [
        *ENTER, "click:39,22", "click:83,35",
        f"drag:{plot_x(2)},23,{plot_x(2) + 5},23",
    ]
    for y in range(21, 25):
        commands.extend((f"hover:{edge_x},{y}", "soundstate"))
    states = occurrences(run_driver(*commands), "sound:")
    for y, state in zip(range(21, 25), states):
        if "cursor=1 " in state:
            return y
    raise AssertionError("Filter edge has no non-dot horizontal boundary row")


def png_rgb(path: Path) -> tuple[int, int, bytes]:
    """Read the dependency-free filter-0 RGB PNGs written by com.fb."""
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AssertionError("not a PNG")
    pos, width, height, packed = 8, 0, 0, bytearray()
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        payload = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height = struct.unpack(">II", payload[:8])
        elif kind == b"IDAT":
            packed.extend(payload)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(bytes(packed))
    stride = width * 3
    rows = []
    for y in range(height):
        row = raw[y * (stride + 1):(y + 1) * (stride + 1)]
        if row[0] != 0:
            raise AssertionError("test PNG unexpectedly uses a filtered row")
        rows.append(row[1:])
    return width, height, b"".join(rows)


class SoundEditorUsageTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not DRIVER.exists():
            raise unittest.SkipTest("build ./ccdriver first")

    def test_requirement_manifest_is_complete(self) -> None:
        expected = {f"R{i:02d}" for i in range(3, 40)}
        covered = set().union(*COVERAGE.values())
        self.assertEqual(expected, covered)

    def test_classic_round_trip(self) -> None:
        out = run_driver(f"load:{SONG}", "key:ESC", "insbytes", "key:Ctrl-e",
                         "key:Ctrl-e", "insbytes")
        self.assertEqual(occurrences(out, "ins00:"),
                         ["ins00: 13 00 40 80 00 00 00 00"] * 2)

    def test_layout_axis_and_tracker_period(self) -> None:
        out = run_driver(*ENTER, "soundstate", "screendump", "mult:1", "frames:1", "soundstate")
        for label in ("Output", "ADSR", "Pitch", "Pulse", "Filter", "Noise", "Gate"):
            self.assertIn(label, out)
        states = occurrences(out, "sound:")
        initial = re.search(r"vis=(\d+) preroll=(\d+) view=([-\d.]+)\.\.([-\d.]+)", states[0])
        self.assertIsNotNone(initial)
        vis, preroll, view_start, view_end = initial.groups()
        self.assertEqual(float(view_start), -int(preroll))
        self.assertEqual(float(view_end), int(vis))
        self.assertRegex(states[1], r"tickUs=19950 stepTicks=5 ")
        self.assertIn(f"scale 0-{vis} Ticks", out)

    def test_probe_selection_zoom_and_pan(self) -> None:
        x9, x25 = plot_x(9), plot_x(25)
        out = run_driver(*ENTER, f"drag:{x9},8,{x25},8", "soundstate", "click:55,35",
                         "soundstate", f"hover:{x9},8", "screendump")
        states = occurrences(out, "sound:")
        self.assertRegex(states[0], r"selection=true:9\.\.25")
        self.assertRegex(states[1], r"view=9\.000\.\.25\.000 zoomed=true")
        self.assertIn("-- Probe (hover) --", out)
        self.assertRegex(out, r"frame \d+  ~\d+\.\d ms")

    def test_menu_masks_only_its_rectangle(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            base, menu = Path(td) / "base.png", Path(td) / "menu.png"
            run_driver(*ENTER, f"shot:{base}", "press:3,0", f"shot:{menu}")
            w0, h0, a = png_rgb(base)
            w1, h1, b = png_rgb(menu)
            self.assertEqual((w0, h0), (w1, h1))
            # The File menu occupies the upper-left.  The graph stack to its right
            # must remain rendered byte-for-byte instead of being globally cleared.
            equal = total = 0
            for y in range(60, 470):
                for x in range(400, 1200):
                    i = (y * w0 + x) * 3
                    total += 1
                    equal += a[i:i + 3] == b[i:i + 3]
            self.assertGreater(equal / total, 0.995)
            self.assertNotEqual(a, b, "opening the menu must still change its own rectangle")

    def test_scalar_edit_and_single_undo(self) -> None:
        out = run_driver(*ENTER, "insbytes", "key:RIGHT", "insbytes", "key:Ctrl-z", "insbytes")
        self.assertEqual(occurrences(out, "ins00:"), [
            "ins00: 13 00 40 80 00 00 00 00",
            "ins00: 23 00 40 80 00 00 00 00",
            "ins00: 13 00 40 80 00 00 00 00",
        ])

    def test_filter_create_add_resize_slope_and_delete(self) -> None:
        left_x, edge_x, dot_y = first_filter_handle_geometry()
        boundary_y = non_dot_filter_boundary_row(edge_x)
        out = run_driver(
            *ENTER, "click:39,22", "click:83,35",
            f"drag:{plot_x(2)},23,{plot_x(2) + 5},23", f"hover:{edge_x},{boundary_y}", "soundstate",
            f"hover:{edge_x},{dot_y}", "soundstate",
            f"drag:{edge_x},{dot_y},{edge_x},{dot_y - 1}", "sweepdump:F",
            "key:Ctrl-z", "sweepdump:F", "click:91,35", "sweepdump:F",
        )
        states = occurrences(out, "sound:")
        self.assertRegex(states[0], r"cursor=1 ")  # duration: left/right
        self.assertRegex(states[1], r"cursor=2 ")  # slope dot: up/down, higher priority
        dumps = occurrences(out, "00:7f00ff7f")
        self.assertIn("03:027fff7f", dumps[0])
        self.assertIn("03:0200ff7f", dumps[1])
        self.assertIn("03:00000000", dumps[2])

        controls = run_driver(
            *ENTER, "click:39,22", "key:Ctrl-Shift-b", "key:Ctrl-Shift-r",
            "click:83,35", f"drag:{plot_x(2)},23,{plot_x(2) + 5},23",
            f"drag:{left_x},{dot_y},{left_x},{dot_y + 1}", "sweepdump:F",
        )
        controlled = occurrences(controls, "00:7f00ff7f")[-1]
        self.assertIn("02:b002be00", controlled)  # BP added; route advanced 1 -> 2
        self.assertIn("03:0200677f", controlled)  # one-axis cutoff changed only b2

    def test_filter_response_png_silhouettes_use_one_cutoff_axis(self) -> None:
        """R58: independent framebuffer pixels show LP/BP/HP pass regions."""
        mode_clicks = {
            0x00: ("key:Ctrl-Shift-l",),
            0x10: (),
            0x20: ("key:Ctrl-Shift-l", "key:Ctrl-Shift-b"),
            0x40: ("key:Ctrl-Shift-l", "key:Ctrl-Shift-h"),
            0x70: ("key:Ctrl-Shift-b", "key:Ctrl-Shift-h"),
        }
        with tempfile.TemporaryDirectory() as td:
            for mode, clicks in mode_clicks.items():
                with self.subTest(mode=f"{mode:02X}"):
                    image = Path(td) / f"filter-{mode:02x}.png"
                    output = run_driver(
                        *ENTER, "click:39,22", "click:83,35", *clicks,
                        "filtershape", f"shot:{image}",
                    )
                    match = re.search(
                        rf"filter step: row=3 mode={mode} frames=\d+\.\.\d+ x=(\d+)\.\.(\d+) "
                        r"cutoff=(\d+)\.\.(\d+)", output,
                    )
                    self.assertIsNotNone(match, output)
                    x0, x1, cutoff0, _ = map(int, match.groups())
                    width, _, rgb = png_rgb(image)
                    top, bottom = 304, 347  # production bandBox from 1280x700 layout
                    span = bottom - top - 1
                    y = bottom - 1 - int(cutoff0 * span / 2047 + 0.5)
                    half = (bottom - top) // 6
                    expected: set[int] = set()
                    if mode & 0x10:
                        expected.update(range(y, bottom))
                    if mode & 0x20:
                        expected.update(range(max(top, y - half), min(bottom - 1, y + half) + 1))
                    if mode & 0x40:
                        expected.update(range(top, y + 1))
                    # The selected block's white outline is intentionally painted
                    # after the silhouette on the two outer rail pixels.
                    expected.discard(top)
                    expected.discard(bottom - 1)
                    px = ((x0 + x1) // 2) * 8 + 4
                    darkgray = b"\x49\x49\x49"
                    actual = {
                        py for py in range(top, bottom)
                        if rgb[(py * width + px) * 3:(py * width + px) * 3 + 3] == darkgray
                    }
                    self.assertEqual(actual, expected)

    def test_single_and_multi_block_join_ownership(self) -> None:
        # One selected block: its end dot changes that row only.  This is the
        # collision that previously lost to the duration boundary.
        _, edge_x, dot_y = first_filter_handle_geometry()
        out = run_driver(*ENTER, "click:39,22", "click:83,35",
                         f"drag:{plot_x(2)},23,{plot_x(2) + 5},23",
                         f"hover:{edge_x},{dot_y}", "soundstate",
                         f"drag:{edge_x},{dot_y},{edge_x},{dot_y - 1}", "sweepdump:F")
        self.assertRegex(occurrences(out, "sound:")[-1], r"cursor=2 ")
        dump = occurrences(out, "00:7f00ff7f")[-1]
        self.assertIn("03:027fff7f", dump)
        self.assertIn("02:9001be00", dump)
        # Two selected neighbouring Pulse blocks: their shared dot changes the
        # left slope and right start together, while leaving block 3 untouched.
        # Pulse has no instantaneous CONFIG rows between graphical blocks, so this
        # exercises join ownership without relying on obsolete Filter row layout.
        out = run_driver(
            *ENTER, "click:39,19", "click:83,35", "click:83,35",
            f"click:{plot_x(0)+1},19", f"shiftclick:{plot_x(1)+1},19",
            f"hover:{plot_x(1)},19", "soundstate",
            f"drag:{plot_x(1)},19,{plot_x(1)},18", "sweepdump:P",
        )
        self.assertRegex(occurrences(out, "sound:")[-1], r"cursor=2 ")
        joined = occurrences(out, "08:")[-1]
        self.assertIn("08:00ff7900", joined)
        self.assertIn("09:00008e00", joined)
        self.assertIn("0a:0000797f", joined)

    def test_piecewise_resonance_and_undo(self) -> None:
        from tests.test_sound_editor_master_usage import (
            BTN_ADD, BTN_RES_PLUS, _click_control, _instrument_bytes,
            _master_session, _new_isolated_wave, _select_filter_at, _sweep_row,
        )

        with _master_session() as session:
            _new_isolated_wave(session)
            f0 = _instrument_bytes(session.run("insbytes"))[4]
            _select_filter_at(session, 0)  # first CONFIG
            _click_control(session, BTN_ADD)  # append CONFIG+SWEEP logical block
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0)[1], 0x01)
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 2)[1], 0x01)

            _click_control(session, BTN_RES_PLUS)
            changed = session.run("sweepdump:F")
            self.assertEqual(_sweep_row(changed, f0)[1], 0x01)
            self.assertEqual(_sweep_row(changed, f0 + 2)[1], 0x11)

            session.run("key:Ctrl-z")
            restored = session.run("sweepdump:F")
            self.assertEqual(_sweep_row(restored, f0)[1], 0x01)
            self.assertEqual(_sweep_row(restored, f0 + 2)[1], 0x01)

    def test_keyjam_real_sid_and_shortcuts(self) -> None:
        controls = run_driver(*ENTER, "key:KP_MUL", "key:KP_PLUS", "screendump")
        self.assertIn("Octave 4", controls)
        self.assertRegex(controls, r"Sound Editor  -  01 ")

        idle = run_driver(*ENTER, "key:RIGHT", "voices", "state")
        self.assertNotIn("hasRec=true", idle)
        self.assertIn("playing=false", idle)

        out = run_driver(*ENTER, "jamrender:z,120", "frames:3", "voices", "soundstate",
                         "press:51,10", "move:60,10", "voices", "soundstate",
                         "release:60,10", "voices", "soundstate", "keyup:z", "key:F2", "state")
        self.assertRegex(out, r"voice0: ins=0 .*hasRec=true recLen=1\d\d")
        states = occurrences(out, "sound:")
        before = re.search(r"view=([^ ]+)", states[0]).group(1)
        during = re.search(r"view=([^ ]+)", states[1]).group(1)
        after = re.search(r"view=([^ ]+)", states[2]).group(1)
        self.assertEqual(before, during)
        self.assertEqual(before, after)
        lengths = [int(re.search(r"recLen=(\d+)", line).group(1))
                   for line in occurrences(out, "voice0:")]
        self.assertEqual(lengths[0], lengths[1], "dragging must keep the old recording")
        self.assertNotEqual(lengths[1], lengths[2], "mouse-up must replace the recording")
        self.assertIn("playing=true", out)

    def test_released_keyjam_refreshes_after_edit(self) -> None:
        # After releasing the audition note, editing Attack replaces the frozen
        # real-SID envelope without requiring another keyjam.
        out = run_driver(*ENTER, "jamrender:z,120", "frames:3", "keyup:z", "recdump:0",
                         "key:RIGHT", "frames:3", "recdump:0")
        amps = occurrences(out, "rec v0 amp:")
        self.assertEqual(2, len(amps))
        self.assertNotEqual(amps[0], amps[1])

    def test_wave_bit_default_cow_has_no_prompt(self) -> None:
        from tests.test_sound_editor_master_usage import (
            _full_sound_dump, _instrument_bytes, _master_session,
        )

        with _master_session() as session:
            for _ in range(6):
                session.run("key:KP_PLUS")
            before = _full_sound_dump(session.run("sounddump"))
            old_ptr = _instrument_bytes(session.run("insbytes"))[7]
            session.run("click:45,33")
            screen = session.run("screendump")
            self.assertNotIn("(y/n)", screen.lower())
            new_ptr = _instrument_bytes(session.run("insbytes"))[7]
            self.assertNotEqual(new_ptr, old_ptr)
            after = _full_sound_dump(session.run("sounddump"))
            self.assertEqual(after["wave"][old_ptr], before["wave"][old_ptr])
            shared_rows = [
                (before["wave"][old_ptr + i], before["wave"][old_ptr + i + 256])
                for i in range(2)
            ]
            private_rows = [
                (after["wave"][new_ptr + i], after["wave"][new_ptr + i + 256])
                for i in range(2)
            ]
            self.assertNotEqual(private_rows, shared_rows)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_wave_bit_undo(self) -> None:
        from tests.test_sound_editor_master_usage import (
            _full_sound_dump, _instrument_bytes, _master_session,
        )

        with _master_session() as session:
            for _ in range(6):
                session.run("key:KP_PLUS")
            session.run("key:Ctrl-Shift-e")
            before = _full_sound_dump(session.run("sounddump"))
            shared = _instrument_bytes(session.run("insbytes"))[7]
            session.run("click:45,33")
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[7], shared)
            self.assertNotEqual(_full_sound_dump(session.run("sounddump")), before)
            session.run("key:Ctrl-z")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

    def test_pitch_program_structure(self) -> None:
        # Build two private Wave rows using the visible controls: an absolute note
        # followed by a four-tick delay. The frequency graph advertises and applies
        # the meaningful axis for each row (pitch vertical, delay horizontal).
        from tests.test_sound_editor_master_usage import (
            BTN_ADD, _click_control, _master_session, _new_isolated_wave,
            _set_selected_wave_row, _wave_rows,
        )

        with _master_session() as session:
            w0 = _new_isolated_wave(session)
            _set_selected_wave_row(session, 0xB0, 0x81)
            _click_control(session, BTN_ADD)
            _set_selected_wave_row(session, 0x00, 0x04)
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 3),
                [(w0, 0xB0, 0x81), (w0 + 1, 0x00, 0x04), (w0 + 2, 0x7E, 0x00)],
            )

            vertical = horizontal = None
            for x in range(39, 156):
                session.run(f"hover:{x},15")
                state = session.run("soundstate")
                if vertical is None and "cursor=2 " in state:
                    vertical = x
                if horizontal is None and "cursor=1 " in state:
                    horizontal = x
            self.assertIsNotNone(vertical, "pitch row must advertise up/down")
            self.assertIsNotNone(horizontal, "delay row must advertise left/right")

            # A vertical drag rewrites the pitch keeping its absolute ($80..$DF) encoding
            # and leaving W2 alone. The exact magnitude depends on the band's vertical
            # scale and is asserted against the drawn block in
            # test_sound_editor_drag_precision.py, not pinned here.
            session.run(f"drag:{vertical},15,{vertical},16")
            pitched = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 3)
            dragged_pitch = pitched[0][1]
            self.assertIn(dragged_pitch, range(0x80, 0xE0))
            self.assertNotEqual(dragged_pitch, 0xB0, "the drag must have moved the pitch")
            self.assertEqual(pitched[0][2], 0x81)
            self.assertEqual(pitched[1][1:], (0x00, 0x04))

            # A horizontal (delay) drag must leave the pitch value alone.
            session.run(f"drag:{horizontal},15,{horizontal + 1},15")
            delayed = _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 3)
            self.assertEqual(delayed[0][1:], (dragged_pitch, 0x81))
            self.assertEqual(delayed[1][1:], (0x00, 0x05))

    def test_stop_program(self) -> None:
        out = run_driver(*ENTER, "click:39,22", "click:83,35", "click:40,22",
                         "click:99,35", "sweepdump:F")
        self.assertRegex(occurrences(out, "00:7f00ff7f")[-1], r"03:[0-9a-f]{6}7f")

    def test_table_safety_guards(self) -> None:
        source = (ROOT / "src/ui/soundedit.d").read_text()
        for guard in ("table full - cannot insert step", "sweepRowResizable", "b2 == 0xff", "b3 == 0x7f"):
            self.assertIn(guard, source)

    def test_r61_loop_indicators_use_shared_one_cell_inward_triangle_geometry(self) -> None:
        """R61: editable sweep loops use one shared draw/hit geometry."""
        source = (ROOT / "src/ui/soundedit.d").read_text()
        self.assertIn("struct SweepLoopGeometry", source)
        self.assertIn("drawFilledInwardTriangle", source)
        self.assertIn("sweepLoopGeometry", source)
        self.assertNotIn("sweepLoopGripX", source)
        self.assertRegex(source, r"FONT_X.*FONT_Y|FONT_Y.*FONT_X")

    def test_context_help_and_references(self) -> None:
        help_source = (ROOT / "src/ui/help.d").read_text()
        generator = (ROOT / "src/ui/shorthelp.d").read_text()
        keyboard = (ROOT / "doc/KEYBOARD.md").read_text()
        review = (ROOT / "doc/SOUND_EDITOR_USABILITY_REVIEW.md").read_text()
        self.assertIn("HELPSOUNDEDITOR", help_source)
        self.assertIn("Sound Editor", help_source)
        for reference in ("Ableton Wavetable", "Surge XT", "Pigments"):
            self.assertIn(reference, review)
        self.assertIn('CtxTitle(Ctx.soundEditor,', generator)
        self.assertIn("## Sound Editor", keyboard)
        section = keyboard.split("## Sound Editor", 1)[1].split("\n## ", 1)[0]
        self.assertEqual(section.count("| `"), 32)
        for action in ("Create a new private sound", "Set the wave loop target",
                       "Toggle Filter low-pass", "Cycle Filter channel route"):
            self.assertIn(action, section)
        for row in (
            "| `Ctrl-Shift-O` | Zoom out |", "| `Ctrl-Shift-I` | Zoom in |",
            "| `Ctrl-Shift-3` | Decrease Filter resonance |",
            "| `Ctrl-Shift-4` | Increase Filter resonance |",
        ):
            self.assertIn(row, section)


if __name__ == "__main__":
    unittest.main()
