"""Stateful Sound Editor master usage regression.

The master executes R40-R59 in one editor process using user actions and read-only
oracles; focused tests retain smaller failure diagnostics for each feature.
"""

from __future__ import annotations

from contextlib import contextmanager
import math
import re
import shutil
import tempfile
import unittest
from pathlib import Path

from tests.ccdriver_session import CCDriverSession, DRIVER, ROOT


SOURCE_SONG = ROOT / "tests/fixtures/sound_editor_master.ct"
PLAN = ROOT / "doc/SOUND_EDITOR_MASTER_TEST_PLAN.md"

# Stable labelled control row from the frozen Phase-2 interaction contract.
BTN_ADD = 67
BTN_DEL = 74
BTN_STOP = 80
BTN_TYPE = 87
BTN_CARRY = 94
BTN_FIT = 50
BTN_ZOOMOUT = 40
BTN_NEW = 100
BTN_PREV = 106
BTN_NEXT = 113
BTN_W1 = 120
BTN_W2 = 125
BTN_LOOP = 130
BTN_RES_MINUS = 138
BTN_RES_PLUS = 145
CONTROL_ROW = 35
PLOT_X0 = 39
PLOT_WIDTH = 117
FREQ_GRAPH_ROW = 15
# Use the next Wave-band row when selecting a row at an X position that may contain
# top-strip chrome (`+` or END/LOOP). Direct pitch/delay drags still test row 15.
FREQ_GRAPH_SAFE_ROW = 16
PULSE_TOP_ROW = 18
PULSE_BOUNDARY_ROW = 19
PULSE_GRAPH_ROW = 20
FILTER_TOP_ROW = 21
FILTER_GRAPH_ROW = 22
FILTER_BOTTOM_ROW = 24


@contextmanager
def _master_session():
    """Give every master/focused sequence its own disposable song file."""
    with tempfile.TemporaryDirectory(prefix="cc-sound-editor-") as tmp:
        fixture = Path(tmp) / "sound-editor-master.ct"
        shutil.copyfile(SOURCE_SONG, fixture)
        with CCDriverSession(f"load:{fixture}", "key:ESC", "key:Ctrl-e") as session:
            yield session


def _click_control(session: CCDriverSession, x: int) -> None:
    action_by_legacy_x = {
        BTN_ZOOMOUT: "se_zoom_out", BTN_FIT: "se_fit", BTN_ADD: "se_add",
        BTN_DEL: "se_delete", BTN_STOP: "se_stop", BTN_TYPE: "se_type",
        BTN_CARRY: "se_carry",
        BTN_PREV: "se_wave_prev", BTN_NEXT: "se_wave_next", BTN_LOOP: "se_wave_loop",
        BTN_RES_MINUS: "se_res_down", BTN_RES_PLUS: "se_res_up",
    }
    menu_shortcut = {BTN_NEW: "Ctrl-Shift-n", BTN_W1: "Ctrl-Shift-1", BTN_W2: "Ctrl-Shift-2"}
    if x in menu_shortcut:
        session.run(f"key:{menu_shortcut[x]}")
        return
    action = action_by_legacy_x.get(x)
    if action is None:
        session.run(f"click:{x},{CONTROL_ROW}")
        return
    state = session.run("controlstate")
    match = re.search(rf"{action}@(\d+)\.\.(\d+),(\d+):on", state)
    if match is None:
        raise AssertionError(f"visible enabled control {action} not found\n{state}")
    x0, x1, row = map(int, match.groups())
    session.run(f"click:{(x0 + x1 - 1) // 2},{row}")


def _control_states(session: CCDriverSession) -> list[tuple[str, bool]]:
    """Read the production control layout in its visible left-to-right order."""
    return [
        (action, enabled == "on")
        for action, enabled in re.findall(
            r"(se_[a-z0-9_]+)@-?\d+\.\.-?\d+,-?\d+:(on|off)",
            session.run("controlstate"),
        )
    ]


def _control_action_ids(session: CCDriverSession) -> list[str]:
    return [action for action, _ in _control_states(session)]


def _control_bounds(session: CCDriverSession, action: str) -> tuple[int, int, int, bool]:
    match = re.search(
        rf"{re.escape(action)}@(\d+)\.\.(\d+),(\d+):(on|off)",
        session.run("controlstate"),
    )
    if match is None:
        raise AssertionError(f"visible control {action} not found")
    x0, x1, row = map(int, match.groups()[:3])
    return x0, x1, row, match.group(4) == "on"


def _click_action(session: CCDriverSession, action: str, *, cell: str = "middle") -> None:
    x0, x1, row, enabled = _control_bounds(session, action)
    if not enabled:
        raise AssertionError(f"visible control {action} is disabled")
    x = x0 if cell == "left" else x1 - 1 if cell == "right" else (x0 + x1 - 1) // 2
    session.run(f"click:{x},{row}")


def _enter_hex_byte(session: CCDriverSession, button_x: int, value: int) -> None:
    """Click a labelled graph control and enter one byte in its real QueryDialog."""
    _click_control(session, button_x)
    for digit in f"{value & 0xff:02x}":
        session.run(f"key:{digit}")
    session.run("key:RET")


def _set_selected_wave_row(session: CCDriverSession, w1: int, w2: int) -> None:
    _enter_hex_byte(session, BTN_W1, w1)
    _enter_hex_byte(session, BTN_W2, w2)


def _plot_x_for_tick(session: CCDriverSession, tick: int) -> int:
    state = session.run("soundstate")
    match = re.search(r"view=(-?[0-9.]+)\.\.(-?[0-9.]+)", state)
    if match is None:
        raise AssertionError("missing viewport oracle\n" + state)
    start, end = map(float, match.groups())
    x = round(PLOT_X0 - 0.5 + (tick - start) / (end - start) * PLOT_WIDTH)
    return min(PLOT_X0 + PLOT_WIDTH - 1, max(PLOT_X0, x))


def _nearest_legal_duration_at_pointer(
    session: CCDriverSession, pointer_cell_x: int, *, rows: bool, anchor_tick: int = 0
) -> tuple[int, int]:
    """Independent R60 oracle: legal width and its rendered boundary pixel."""
    state = session.run("soundstate")
    view = re.search(r"view=(-?[0-9.]+)\.\.(-?[0-9.]+)", state)
    step = re.search(r"stepTicks=(\d+)", state)
    if view is None or step is None:
        raise AssertionError("missing duration-axis oracle\n" + state)
    start, end = map(float, view.groups())
    period = int(step.group(1))
    legal = list(range(1, 129))
    if rows:
        legal = list(range(period, 129, period)) if period <= 128 else [128]
    pointer_px = pointer_cell_x * 8 + 4

    def rendered_px(width: int) -> int:
        edge_tick = anchor_tick + width
        raw = PLOT_X0 * 8 + (edge_tick - start) / (end - start) * (PLOT_WIDTH * 8)
        return math.floor(raw + 0.5)

    # (distance, width) implements the canonical shorter-duration tie break.
    width = min(legal, key=lambda candidate: (abs(rendered_px(candidate) - pointer_px), candidate))
    return width, rendered_px(width)


def _pointer_cell_for_duration(
    session: CCDriverSession, target: int, *, anchor_tick: int = 0
) -> int:
    """Find a real character-cell pointer whose nearest legal edge is target ticks."""
    candidates: list[int] = []
    for _ in range(9):
        candidates = [
            x for x in range(PLOT_X0, PLOT_X0 + PLOT_WIDTH)
            if _nearest_legal_duration_at_pointer(
                session, x, rows=False, anchor_tick=anchor_tick
            )[0] == target
        ]
        if candidates:
            break
        # Headless usage input addresses character centres, unlike the real mouse's
        # pixel positions. Zoom until this exact short transient has a reachable cell,
        # then pan it back into view because zoom is centred on the whole programme.
        session.run("key:Ctrl-Shift-i")
        edge_tick = anchor_tick + target
        for _ in range(20):
            match = re.search(r"view=(-?[0-9.]+)\.\.(-?[0-9.]+)", session.run("soundstate"))
            if match is None:
                raise AssertionError("missing viewport while finding duration pointer")
            start, end = map(float, match.groups())
            if start <= edge_tick <= end:
                break
            session.run("key:Shift-LEFT" if edge_tick < start else "key:Shift-RIGHT")
    if not candidates:
        raise AssertionError(f"duration {target} has no reachable pointer cell after zoom")
    rendered = _nearest_legal_duration_at_pointer(
        session, candidates[0], rows=False, anchor_tick=anchor_tick
    )[1]
    return min(candidates, key=lambda x: abs((x * 8 + 4) - rendered))


def _select_wave_row_on_frequency_graph(
    session: CCDriverSession, frame: int, row: int
) -> None:
    """Select through the visible graph, and prove focus before opening hex input."""
    session.run(f"click:{_plot_x_for_tick(session, frame)},{FREQ_GRAPH_SAFE_ROW}")
    selected = session.run("screendump")
    if f"[row ${row:02X}]" not in selected:
        raise AssertionError(
            f"frequency graph did not visibly select wave row ${row:02X}\n" + selected
        )


def _instrument_bytes(output: str) -> list[int]:
    match = re.search(r"ins[0-9a-f]{2}:((?: [0-9a-f]{2}){8})", output, re.I)
    if match is None:
        raise AssertionError("missing instrument byte oracle\n" + output)
    return [int(x, 16) for x in match.group(1).split()]


def _wave_rows(output: str, count: int) -> list[tuple[int, int, int]]:
    match = re.search(r"wave rows from [0-9A-F]{2}:([^\n]+)", output, re.I)
    if match is None:
        raise AssertionError("missing wave row oracle\n" + output)
    rows = [
        (int(address, 16), int(w1, 16), int(w2, 16))
        for address, w1, w2 in re.findall(
            r"([0-9a-f]{2}):([0-9a-f]{2})/([0-9a-f]{2})", match.group(1), re.I
        )
    ]
    return rows[:count]


def _sweep_row(output: str, row: int) -> tuple[int, int, int, int]:
    match = re.search(rf"(?:^| )({row:02x}):([0-9a-f]{{8}})(?: |$)", output, re.I | re.M)
    if match is None:
        raise AssertionError(f"missing sweep row ${row:02X}\n" + output)
    raw = match.group(2)
    return tuple(int(raw[i:i + 2], 16) for i in range(0, 8, 2))


def _sweep_rows(
    session: CCDriverSession, table: str, first: int, count: int
) -> list[tuple[int, int, int, int]]:
    dump = session.run(f"sweepdump:{table}")
    return [_sweep_row(dump, first + offset) for offset in range(count)]


def _cursor_at(session: CCDriverSession, x: int, y: int) -> int:
    session.run(f"hover:{x},{y}")
    match = re.search(r"cursor=(\d+)", session.run("soundstate"))
    if match is None:
        raise AssertionError("missing cursor oracle")
    return int(match.group(1))


def _select_rows_duration(session: CCDriverSession, rows: int = 4) -> None:
    """Use the visible parameter rows; the fixture starts at 50 raw ticks."""
    session.run("click:10,21")
    session.run("key:RIGHT")
    for _ in range(5 - rows):
        session.run("click:10,20")
        session.run("key:LEFT")


def _select_pulse_at(session: CCDriverSession, tick: int) -> None:
    session.run(f"click:{_plot_x_for_tick(session, tick)},{PULSE_GRAPH_ROW}")


def _pulse_boundary_row(session: CCDriverSession, tick: int) -> int:
    """Find the resize part of an edge without stealing its higher-priority dot."""
    x = _plot_x_for_tick(session, tick)
    # Prefer the lower boundary cells: the top cell can contain the explicit
    # END/LOOP grip, which intentionally owns that small strip.
    for row in reversed(range(PULSE_TOP_ROW, PULSE_GRAPH_ROW + 1)):
        if _cursor_at(session, x, row) == 1:
            return row
    raise AssertionError(
        f"pulse boundary at tick {tick} has no horizontal grab area\n"
        + session.run("soundstate") + "\n" + session.run("screendump")
    )


def _pulse_dot_row(session: CCDriverSession, tick: int) -> int:
    x = _plot_x_for_tick(session, tick)
    for row in range(PULSE_TOP_ROW, PULSE_GRAPH_ROW + 1):
        if _cursor_at(session, x, row) == 2:
            return row
    raise AssertionError(f"pulse endpoint at tick {tick} has no vertical grab area")


def _pulse_signed_slope(row: tuple[int, int, int, int]) -> int:
    return -row[1] if row[0] & 0x80 else row[1]


def _fine_adjust_pulse_slope(
    session: CCDriverSession, row: int, target: int
) -> None:
    """Fine-adjust after a mouse gesture through the documented graph shortcut."""
    current = _pulse_signed_slope(_sweep_row(session.run("sweepdump:P"), row))
    key = "Ctrl-Shift-8" if target > current else "Ctrl-Shift-7"
    for _ in range(abs(target - current)):
        session.run(f"key:{key}")
    actual = _pulse_signed_slope(_sweep_row(session.run("sweepdump:P"), row))
    if actual != target:
        raise AssertionError(f"pulse slope fine adjustment landed at {actual}, wanted {target}")


def _fine_adjust_pulse_start_byte(
    session: CCDriverSession, row: int, target: int
) -> None:
    """Cycle the selected start handle in its real $10 pulse-width quantum."""
    def decoded(byte: int) -> int:
        return ((byte & 0x0F) << 8) | (byte & 0xF0)

    current = _sweep_row(session.run("sweepdump:P"), row)[2]
    key = "Ctrl-Shift-5" if decoded(target) < decoded(current) else "Ctrl-Shift-6"
    for _ in range(257):
        current = _sweep_row(session.run("sweepdump:P"), row)[2]
        if current == target:
            return
        session.run(f"key:{key}")
    raise AssertionError(f"pulse start byte never reached ${target:02X}")


def _select_filter_at(session: CCDriverSession, tick: int) -> None:
    # Select through the cutoff body, not the resonance overlay (which correctly
    # selects its governing CONFIG row).
    session.run(f"click:{_plot_x_for_tick(session, tick)},{FILTER_BOTTOM_ROW}")


def _filter_boundary_row(session: CCDriverSession, tick: int) -> int:
    x = _plot_x_for_tick(session, tick)
    # The explicit END/LOOP grip owns the top strip once multiple blocks exist.
    for row in reversed(range(FILTER_TOP_ROW, FILTER_BOTTOM_ROW + 1)):
        if _cursor_at(session, x, row) == 1:
            return row
    raise AssertionError(f"filter boundary at tick {tick} has no horizontal grab area")


def _filter_duration_edge(session: CCDriverSession, row: int) -> tuple[int, int]:
    """Production-rendered right edge and its non-dot horizontal grab row."""
    shape = next(item for item in _filter_shapes(session.run("filtershape")) if item[0] == row)
    edge_x = shape[3]
    for y in reversed(range(FILTER_TOP_ROW, FILTER_BOTTOM_ROW + 1)):
        if _cursor_at(session, edge_x, y) == 1:
            return edge_x, y
    raise AssertionError(f"filter row {row} has no horizontal duration edge")


def _filter_loop_grip_x(session: CCDriverSession, tick: int) -> int:
    """Find the explicit top-strip grip left of a Filter END/LOOP boundary."""
    boundary_x = _plot_x_for_tick(session, tick)
    for x in range(boundary_x - 1, boundary_x - 4, -1):
        if _cursor_at(session, x, FILTER_TOP_ROW) == 1:
            return x
    raise AssertionError(f"filter END/LOOP at tick {tick} has no offset grip")


def _pulse_loop_grip_x(session: CCDriverSession, tick: int) -> int:
    """Find the explicit top-strip grip left of a Pulse END/LOOP boundary."""
    boundary_x = _plot_x_for_tick(session, tick)
    for x in range(boundary_x - 1, boundary_x - 4, -1):
        if _cursor_at(session, x, PULSE_TOP_ROW) == 1:
            return x
    if _cursor_at(session, boundary_x, PULSE_TOP_ROW) == 1:
        return boundary_x
    raise AssertionError(f"pulse END/LOOP at tick {tick} has no grip")


def _orange_components(path: Path, top_row: int, bottom_row: int) -> list[set[tuple[int, int]]]:
    """Connected authored-loop pixels inside one graph band."""
    from tests.test_sound_editor_usage import png_rgb

    width, _, rgb = png_rgb(path)
    orange = bytes((0x8D, 0x50, 0x29))
    points = set()
    for y in range(top_row * 14, (bottom_row + 1) * 14):
        for x in range(PLOT_X0 * 8, (PLOT_X0 + PLOT_WIDTH) * 8):
            offset = (y * width + x) * 3
            if rgb[offset:offset + 3] == orange:
                points.add((x, y))
    components = []
    while points:
        pending = [points.pop()]
        component = set(pending)
        while pending:
            x, y = pending.pop()
            for neighbour in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                if neighbour in points:
                    points.remove(neighbour)
                    component.add(neighbour)
                    pending.append(neighbour)
        components.append(component)
    return sorted(components, key=lambda component: min(x for x, _ in component))


def _filter_dot_row(session: CCDriverSession, tick: int) -> int:
    x = _plot_x_for_tick(session, tick)
    for row in range(FILTER_TOP_ROW, FILTER_BOTTOM_ROW + 1):
        if _cursor_at(session, x, row) == 2:
            return row
    raise AssertionError(f"filter handle at tick {tick} has no vertical grab area")


def _filter_signed_slope(row: tuple[int, int, int, int]) -> int:
    return row[1] if row[1] < 0x80 else row[1] - 0x100


def _fine_adjust_filter_slope(
    session: CCDriverSession, row: int, target: int
) -> None:
    current = _filter_signed_slope(_sweep_row(session.run("sweepdump:F"), row))
    key = "Ctrl-Shift-8" if target > current else "Ctrl-Shift-7"
    for _ in range(abs(target - current)):
        session.run(f"key:{key}")
    actual = _filter_signed_slope(_sweep_row(session.run("sweepdump:F"), row))
    if actual != target:
        raise AssertionError(f"filter slope fine adjustment landed at {actual}, wanted {target}")


def _full_sound_dump(output: str) -> dict[str, bytes]:
    result: dict[str, bytes] = {}
    for name in ("instruments", "wave", "pulse", "filter"):
        match = re.search(rf"all {name}:([0-9a-f]+)", output, re.I)
        if match is None:
            raise AssertionError(f"missing all-{name} oracle\n" + output)
        result[name] = bytes.fromhex(match.group(1))
    return result


def _assert_only_active_sound_changed(
    case: unittest.TestCase,
    before: dict[str, bytes],
    after: dict[str, bytes],
    w0: int,
    p0: int,
    f0: int,
) -> None:
    """Mask only instrument 0 and its canonical newly allocated program rows."""
    for index, (old, new) in enumerate(zip(before["instruments"], after["instruments"])):
        if index % 48 != 0:
            case.assertEqual(new, old, f"other instrument byte changed at {index}")

    allowed_wave = set(range(w0, w0 + 7)) | set(range(w0 + 256, w0 + 7 + 256))
    for index, (old, new) in enumerate(zip(before["wave"], after["wave"])):
        if index not in allowed_wave:
            case.assertEqual(new, old, f"unrelated wave byte changed at {index}")

    allowed_pulse = set(range(p0 * 4, p0 * 4 + 4))
    for index, (old, new) in enumerate(zip(before["pulse"], after["pulse"])):
        if index not in allowed_pulse:
            case.assertEqual(new, old, f"unrelated pulse byte changed at {index}")

    allowed_filter = set(range(f0 * 4, f0 * 4 + 8))
    for index, (old, new) in enumerate(zip(before["filter"], after["filter"])):
        if index not in allowed_filter:
            case.assertEqual(new, old, f"unrelated filter byte changed at {index}")


def _preview_values(output: str, field: str) -> list[int]:
    match = re.search(rf"wave preview {field}:((?: [0-9A-F]{{2}})+)", output)
    if match is None:
        raise AssertionError(f"missing wave preview {field} oracle\n" + output)
    return [int(x, 16) for x in match.group(1).split()]


def _ui_preview_values(output: str, field: str) -> list[int]:
    match = re.search(rf"ui preview {field}:((?: [0-9A-F]{{2}})+)", output)
    if match is None:
        raise AssertionError(f"missing UI preview {field} oracle\n" + output)
    return [int(x, 16) for x in match.group(1).split()]


def _capture_fields(output: str) -> dict[str, int | str]:
    match = re.search(
        r"capture: samples=(\d+) hash=([0-9a-f]+) peak=(\d+) sumAbs=(\d+) "
        r"gates=(\d+) gateOn=(-?\d+) gateOff=(-?\d+) gateHigh=(\d+) "
        r"onsetSample=(-?\d+) frameSamples=(\d+) instr=(\d+) voice=(\d+)",
        output, re.I,
    )
    if match is None:
        raise AssertionError("missing capture signature\n" + output)
    names = ("samples", "hash", "peak", "sumAbs", "gates", "gateOn", "gateOff",
             "gateHigh", "onsetSample", "frameSamples", "instr", "voice")
    values: list[int | str] = [int(v) if i != 1 else v.lower()
                                for i, v in enumerate(match.groups())]
    return dict(zip(names, values))


def _recorded_hex_values(
    output: str, voice: int, field: str, base: int = 16
) -> list[int]:
    match = re.search(rf"rec v{voice} {field}:((?: [0-9A-F]+)+)", output, re.I)
    if match is None:
        raise AssertionError(f"missing recorded {field} for voice {voice}\n" + output)
    return [int(value, base) for value in match.group(1).split()]


def _filter_shapes(output: str) -> list[tuple[int, int, int, int, int, int, int, int, int]]:
    return [
        tuple(map(int, (row, mode, x0, x1, c0, c1, y0, y1, handles)))
        for row, mode, _f0, _f1, x0, x1, c0, c1, y0, y1, handles in re.findall(
            r"filter step: row=(\d+) mode=(\d+) frames=(\d+)\.\.(\d+) x=(\d+)\.\.(\d+) "
            r"cutoff=(\d+)\.\.(\d+) y=(\d+)\.\.(\d+) handles=(\d+)",
            output, re.I,
        )
    ]


def _filter_shape_frames(output: str, row: int) -> tuple[int, int]:
    match = re.search(
        rf"filter step: row={row} mode=\d+ frames=(\d+)\.\.(\d+)", output, re.I
    )
    if match is None:
        raise AssertionError(f"missing rendered frame span for filter row {row}\n{output}")
    return tuple(map(int, match.groups()))


def _filter_shape_formula(output: str) -> tuple[int, ...]:
    match = re.search(
        r"filter shape: mode=(\d+) cutoff=(\d+) axis=(\d+)\.\.(\d+) y=(\d+) "
        r"lp=(\d+):(\d+)\.\.(\d+) bp=(\d+):(\d+)\.\.(\d+) "
        r"hp=(\d+):(\d+)\.\.(\d+)", output,
    )
    if match is None:
        raise AssertionError("missing filter response-shape oracle\n" + output)
    return tuple(map(int, match.groups()))


def _screen_row(output: str, row: int) -> str:
    match = re.search(rf"^screen{row:02d}:(.*)$", output, re.M)
    if match is None:
        raise AssertionError(f"missing screen row {row}\n" + output)
    return match.group(1).rstrip()


def _set_filter_route(
    session: CCDriverSession, row: int, target: int
) -> None:
    current = _sweep_row(session.run("sweepdump:F"), row)[1] & 0x0F
    for _ in range((target - current) & 0x0F):
        _click_action(session, "se_route")
    actual = _sweep_row(session.run("sweepdump:F"), row)[1] & 0x0F
    if actual != target:
        raise AssertionError(f"filter route landed at {actual:X}, wanted {target:X}")


def _set_filter_mode(
    session: CCDriverSession, row: int, target: int
) -> None:
    current = _sweep_row(session.run("sweepdump:F"), row)[0] & 0x70
    for bit, action in ((0x10, "se_lp"), (0x20, "se_bp"), (0x40, "se_hp")):
        if bool(current & bit) != bool(target & bit):
            _click_action(session, action)
    actual = _sweep_row(session.run("sweepdump:F"), row)[0] & 0x70
    if actual != target:
        raise AssertionError(f"filter mode landed at {actual:02X}, wanted {target:02X}")


def _new_isolated_wave(session: CCDriverSession) -> int:
    _click_control(session, BTN_NEW)
    ins = _instrument_bytes(session.run("insbytes"))
    f0, p0, w0 = ins[4], ins[5], ins[7]
    if 0 in (w0, p0, f0):
        raise AssertionError("New must allocate non-zero private wave/pulse/filter pointers")
    return w0


def _adsr_handle_cell(session: CCDriverSession, cursor: int, *, last: bool = False) -> tuple[int, int]:
    """Locate a visible ADSR dot through its real hover cursor contract."""
    hits: list[tuple[int, int]] = []
    for y in range(7, 15):
        for x in range(PLOT_X0, PLOT_X0 + PLOT_WIDTH):
            session.run(f"hover:{x},{y}")
            match = re.search(r"cursor=(\d+)", session.run("soundstate"))
            if match is not None and int(match.group(1)) == cursor:
                hits.append((x, y))
    if not hits:
        raise AssertionError(f"no visible ADSR handle advertised cursor {cursor}")
    return max(hits) if last else min(hits)


def _drag_adsr_to_8888(session: CCDriverSession) -> None:
    """Perform the canonical 88/88 checkpoint through the graph handles."""
    session.run("frames:2")
    attack = _adsr_handle_cell(session, 1)
    session.run(f"drag:{attack[0]},{attack[1]},{_plot_x_for_tick(session, 10)},10")
    decay = _adsr_handle_cell(session, 3)
    session.run(f"drag:{decay[0]},{decay[1]},{_plot_x_for_tick(session, 40)},12")
    _click_control(session, BTN_ZOOMOUT)
    release = _adsr_handle_cell(session, 1, last=True)
    session.run(f"drag:{release[0]},{release[1]},{_plot_x_for_tick(session, 70)},14")
    if _instrument_bytes(session.run("insbytes"))[:2] != [0x88, 0x88]:
        raise AssertionError("mouse ADSR checkpoint did not land at 88 88")


def _drag_adsr_to_9327(session: CCDriverSession) -> None:
    """Readjust A/D/R by handles, then use visible sustain fine adjustment."""
    attack = _adsr_handle_cell(session, 1)
    session.run(f"drag:{attack[0]},{attack[1]},{_plot_x_for_tick(session, 25)},10")
    decay = _adsr_handle_cell(session, 3)
    session.run(f"drag:{decay[0]},{decay[1]},{_plot_x_for_tick(session, 32)},14")
    release = _adsr_handle_cell(session, 1, last=True)
    session.run(f"drag:{release[0]},{release[1]},{_plot_x_for_tick(session, 64)},14")
    # This helper drags in character cells, which reaches only 5 of the 16 sustain
    # levels (0, 4, 8, 13, 15) -- so it finishes with the selected-parameter keys for
    # the exact nibble. A real mouse resolves to the pixel and reaches every level;
    # see test_sound_editor_drag_precision.py.
    session.run("click:10,9")
    session.run("key:RIGHT")
    session.run("key:RIGHT")
    actual = _instrument_bytes(session.run("insbytes"))[:2]
    if actual != [0x93, 0x27]:
        raise AssertionError(
            f"ADSR checkpoint did not land at 93 27: got {actual[0]:02X} {actual[1]:02X}"
        )


def _master_three_note_checkpoint(
    case: unittest.TestCase, session: CCDriverSession, label: str
) -> None:
    """Audition C-4, G-3, D-2 without resetting the persistent master session."""
    chrome = session.run("screendump")
    if "Octave 2" in chrome:
        session.run("key:KP_MUL")
    case.assertIn("Octave 3", session.run("screendump"), label)
    for key, note in (("q", 48), ("b", 43)):
        session.run(f"jamrender:{key},80")
        capture = _capture_fields(session.run("capturestate"))
        case.assertEqual(capture["gateHigh"], 40, label)
        case.assertEqual(capture["voice"], 1, label)
        recording = session.run("recdump:0")
        case.assertTrue(_recorded_hex_values(recording, 0, "env"), label)
        session.run(f"keyup:{key}")
        case.assertRegex(session.run("soundstate"), rf"preview=0/{note}")
    session.run("key:KP_DIV")
    session.run("jamrender:x,80")
    capture = _capture_fields(session.run("capturestate"))
    case.assertEqual(capture["gateHigh"], 40, label)
    case.assertEqual(capture["voice"], 1, label)
    case.assertTrue(_recorded_hex_values(session.run("recdump:0"), 0, "env"), label)
    session.run("keyup:x")
    case.assertRegex(session.run("soundstate"), r"preview=0/26")


def _build_wave_a(session: CCDriverSession) -> int:
    w0 = _new_isolated_wave(session)
    _set_selected_wave_row(session, 0xB0, 0x81)
    for w1, w2 in ((0x00, 0x04), (0x02, 0x41), (0x01, 0x41), (0x00, 0x41)):
        _click_control(session, BTN_ADD)
        _set_selected_wave_row(session, w1, w2)
    return w0


def _mutate_wave_a_to_b(session: CCDriverSession, w0: int) -> None:
    # Delays make rows 0..4 visible at frames 0,5,6,7,8. Select every existing
    # row through the frequency graph and prove the raw strip changed focus before
    # opening either typed-hex dialog.
    _select_wave_row_on_frequency_graph(session, 0, w0 + 0)
    _set_selected_wave_row(session, 0xC0, 0x81)
    for frame, offset, w1, w2 in (
        (5, 1, 0x00, 0x02),
        (4, 2, 0x00, 0x41),
        (5, 3, 0x00, 0x0C),
        (18, 4, 0x0C, 0x41),
    ):
        _select_wave_row_on_frequency_graph(session, frame, w0 + offset)
        _set_selected_wave_row(session, w1, w2)
    _click_control(session, BTN_ADD)
    _set_selected_wave_row(session, 0x00, 0x0C)
    _enter_hex_byte(session, BTN_LOOP, w0 + 2)


def _build_exact_filter_three_blocks(
    session: CCDriverSession, *, loop: bool = True,
) -> tuple[int, int, int]:
    """Reach plan 4.5's six exact rows using only visible Sound Editor actions."""
    w0 = _new_isolated_wave(session)
    ins = _instrument_bytes(session.run("insbytes"))
    f0, p0 = ins[4], ins[5]
    _select_rows_duration(session)

    _select_filter_at(session, 0)
    res_y = _filter_dot_row(session, 0)
    session.run(
        f"drag:{_plot_x_for_tick(session, 0)},{res_y},"
        f"{_plot_x_for_tick(session, 0) + 1},{FILTER_BOTTOM_ROW}"
    )
    _click_control(session, BTN_RES_PLUS)
    _click_control(session, BTN_RES_PLUS)
    for _ in range(0x20):
        session.run("key:Ctrl-Shift-6")
    _select_filter_at(session, 1)
    y = _filter_boundary_row(session, 2)
    session.run(
        f"drag:{_plot_x_for_tick(session, 2)},{y},"
        f"{_plot_x_for_tick(session, 41)},{y}"
    )
    dot_y = _filter_dot_row(session, 41)
    session.run(
        f"drag:{_plot_x_for_tick(session, 41)},{dot_y},"
        f"{_plot_x_for_tick(session, 41)},{FILTER_TOP_ROW}"
    )
    _fine_adjust_filter_slope(session, f0 + 1, 0x10)

    _click_control(session, BTN_ADD)
    _click_control(session, BTN_FIT)
    _click_control(session, BTN_ZOOMOUT)
    _select_filter_at(session, 41)
    _click_action(session, "se_lp")
    _click_action(session, "se_bp")
    for _ in range(5):
        _click_control(session, BTN_RES_PLUS)
    _set_filter_route(session, f0 + 2, 0x00)
    _select_filter_at(session, 42)
    y = _filter_boundary_row(session, 43)
    session.run(
        f"drag:{_plot_x_for_tick(session, 43)},{y},"
        f"{_plot_x_for_tick(session, 62)},{y}"
    )
    dot_y = _filter_dot_row(session, 62)
    session.run(
        f"drag:{_plot_x_for_tick(session, 62)},{dot_y},"
        f"{_plot_x_for_tick(session, 62)},{FILTER_BOTTOM_ROW}"
    )
    _fine_adjust_filter_slope(session, f0 + 3, -8)

    _click_control(session, BTN_ADD)
    _click_control(session, BTN_FIT)
    _click_control(session, BTN_ZOOMOUT)
    _select_filter_at(session, 62)
    _click_action(session, "se_bp")
    _click_action(session, "se_hp")
    for _ in range(4):
        _click_control(session, BTN_RES_PLUS)
    _set_filter_route(session, f0 + 4, 0x07)
    _select_filter_at(session, 64)
    y = _filter_boundary_row(session, 64)
    session.run(
        f"drag:{_plot_x_for_tick(session, 64)},{y},"
        f"{_plot_x_for_tick(session, 73)},{y}"
    )
    dot_y = _filter_dot_row(session, 73)
    session.run(
        f"drag:{_plot_x_for_tick(session, 73)},{dot_y},"
        f"{_plot_x_for_tick(session, 73)},{FILTER_TOP_ROW}"
    )
    _fine_adjust_filter_slope(session, f0 + 5, 4)
    if loop:
        grip_x = _filter_loop_grip_x(session, 73)
        session.run(
            f"drag:{grip_x},{FILTER_TOP_ROW},"
            f"{_plot_x_for_tick(session, 41)},{FILTER_TOP_ROW}"
        )
    return f0, p0, w0


def _build_simple_pulse_three_blocks(
    session: CCDriverSession, *, loop: bool = True,
) -> int:
    """Three one-tick Pulse blocks, optionally looping block 3 to block 2."""
    _new_isolated_wave(session)
    p0 = _instrument_bytes(session.run("insbytes"))[5]
    _select_pulse_at(session, 0)
    _click_control(session, BTN_ADD)
    _click_control(session, BTN_ADD)
    _click_control(session, BTN_FIT)
    _select_pulse_at(session, 0)  # keep the terminal dot away from the END grip
    if loop:
        grip_x = _pulse_loop_grip_x(session, 3)
        session.run(
            f"drag:{grip_x},{PULSE_TOP_ROW},"
            f"{_plot_x_for_tick(session, 1)},{PULSE_TOP_ROW}"
        )
    return p0


class SoundEditorMasterFoundationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not DRIVER.exists():
            raise unittest.SkipTest("build ./ccdriver first")

    def test_persistent_checkpoint_and_recording_oracles(self) -> None:
        """Commands observe one continuing UI session without replay or reload."""
        with _master_session() as session:
            self.assertIn("serve: ready", session.startup_output)
            initial = session.run("insbytes")
            self.assertIn("ins00: 13 00 40 80 00 00 00 00", initial)
            state = session.run("soundstate")
            self.assertRegex(state, r"sound: tickUs=9975 stepTicks=10 .*preview=0/48")
            capture = session.run("capturestate")
            self.assertRegex(
                capture,
                r"capture: samples=0 hash=811c9dc5 .*gates=0 gateOn=-1 gateOff=-1 .*voice=1",
            )
            recording = session.run("recdump:0")
            for field in ("ctrl", "freq", "pulse", "amp", "cutoff", "mode", "resonance", "route"):
                self.assertIn(f"rec v0 {field}:", recording)
            final = session.run("insbytes")
            self.assertIn("ins00: 13 00 40 80 00 00 00 00", final)
            markers = re.findall(r"checkpoint: session-(\d{4})", initial + state + capture + recording + final)
            self.assertEqual(markers, ["0001", "0002", "0003", "0004", "0005"])

    def test_phase1_duration_gate_baseline_and_keyjam_channel(self) -> None:
        """R40-R42/R50 through one continuing user-level editor session."""
        with _master_session() as session:
            initial = session.run("soundstate")
            self.assertRegex(initial, r"stepTicks=10 .*preview=0/48")  # default C-4

            # Duration unit -> Rows, then legacy 50 ticks (5 rows) -> requested 4 rows.
            session.run("click:10,21")
            session.run("key:RIGHT")
            session.run("click:10,20")
            session.run("key:LEFT")
            chrome = session.run("screendump")
            self.assertIn("Gate high 4 Rows = 40 Ticks", chrome)
            self.assertIn("Duration unit  Rows", chrome)

            # Release after five rendered ticks: the configured clock still owns key-off.
            session.run("jamrender:q,5")
            session.run("keyup:q")
            session.run("scopefill:20")
            early = session.run("capturestate")
            self.assertRegex(early, r"gateOn=3 gateOff=43 gateHigh=40 .*voice=1")

            # Keep the next key physically held past the boundary and route it to voice 2.
            session.run("click:10,19")
            session.run("key:RIGHT")
            session.run("jamrender:b,80")
            held = session.run("capturestate")
            self.assertRegex(held, r"gateOn=3 gateOff=43 gateHigh=40 .*voice=2")
            voices = session.run("voices")
            self.assertRegex(voices, r"voice1: ins=0 .*hasRec=true")
            session.run("keyup:b")

            # D-2 is x at base octave 2; a completed edit silently reuses that note.
            session.run("key:KP_DIV")
            session.run("jamrender:x,80")
            session.run("keyup:x")
            played = session.run("soundstate")
            self.assertRegex(played, r"preview=0/26")
            played_trigger = int(re.search(r"trigger=(\d+)", played).group(1))
            session.run("click:10,7")
            session.run("key:RIGHT")
            session.run("frames:2")
            rerendered = session.run("soundstate")
            self.assertRegex(rerendered, r"preview=0/26")
            self.assertEqual(
                int(re.search(r"trigger=(\d+)", rerendered).group(1)),
                played_trigger + 1,
            )

    def test_phase1_one_to_four_tick_gates_are_exact(self) -> None:
        """The fixed gate clock must not round short holds up to its key-off pipeline."""
        with _master_session() as session:
            # Gate high is already in Ticks; reduce the default 50 to one.
            session.run("click:10,20")
            for _ in range(49):
                session.run("key:LEFT")

            for ticks, key in ((1, "z"), (2, "x"), (3, "c"), (4, "v")):
                if ticks > 1:
                    session.run("key:RIGHT")
                session.run(f"jamrender:{key},12")
                capture = session.run("capturestate")
                session.run(f"keyup:{key}")
                match = re.search(
                    r"gateOn=(-?\d+) gateOff=(-?\d+) gateHigh=(\d+)", capture
                )
                with self.subTest(ticks=ticks):
                    self.assertIsNotNone(match)
                    gate_on, gate_off, gate_high = map(int, match.groups())
                    self.assertEqual(gate_high, ticks)
                    self.assertEqual(gate_off - gate_on, ticks)

    def test_phase1_adsr_release_uses_the_configured_gate_end(self) -> None:
        """The raw reSID estimate releases from the configured gate end."""
        with _master_session() as session:
            # One-tick gate with full sustain and the fixture's short release.
            session.run("click:10,20")
            for _ in range(49):
                session.run("key:LEFT")
            session.run("click:10,9")
            for _ in range(15):
                session.run("key:RIGHT")

            # The former hand-written curve expected zero at graph tick 2.  Raw
            # reSID has a real rate-counter pipeline: with this fixture it holds
            # FF briefly, then releases to 01 and 00.  Assert that deterministic
            # timeline instead of reviving the synthetic approximation.
            preview = session.run("envpreview:16")
            match = re.search(
                r"^env preview env:((?: [0-9A-F]{2})+)$", preview, re.I | re.M
            )
            self.assertIsNotNone(match)
            env = [int(value, 16) for value in match.group(1).split()]
            self.assertEqual(env[:6], [0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x00])

    def test_phase1_last_note_baseline_survives_instrument_switches(self) -> None:
        """Changing instruments keeps pitch while rebinding the preview instrument."""
        with _master_session() as session:
            session.run("key:KP_DIV")
            session.run("jamrender:x,12")  # D-2 in the master sequence
            session.run("keyup:x")
            self.assertRegex(session.run("soundstate"), r"preview=0/26")

            session.run("key:KP_PLUS")
            self.assertRegex(session.run("soundstate"), r"preview=1/26")
            session.run("key:KP_MINUS")
            self.assertRegex(session.run("soundstate"), r"preview=0/26")

    def test_phase1_each_editor_opening_resets_keyjam_to_voice_one(self) -> None:
        """Keyjam channel is session chrome, not persistent editor state."""
        with _master_session() as session:
            session.run("click:10,19")
            session.run("key:RIGHT")
            self.assertIn("Keyjam Ch 2", session.run("screendump"))

            session.run("key:Ctrl-e")
            session.run("key:Ctrl-e")
            reopened = session.run("screendump")
            self.assertIn("Keyjam Ch 1", reopened)

    def test_phase1_fixed_gate_expiry_sends_remote_keyoff(self) -> None:
        """Static fallback for the remote path, which has no headless SID backend."""
        source = (ROOT / "src/audio/player.d").read_text()
        start = source.index("private void issueFixedKeyoff()")
        end = source.index("\nvoid init()", start)
        expiry = source[start:end]
        self.assertIn("NOTE_KEYOFF", expiry)
        self.assertIn("audio.remote.cmdKeyjam", expiry)

    def test_phase1_note_on_and_gate_arm_are_one_ordered_transaction(self) -> None:
        """Static concurrency contract for a race the single-threaded driver cannot create."""
        source = (ROOT / "src/audio/player.d").read_text()

        start = source.index("void armFixedKeyjamGate(")
        end = source.index("\nint fixedKeyjamGateRemaining", start)
        publication = source[start:end]
        self.assertLess(publication.index("fixedGateVoice ="),
                        publication.index("fixedGateTicksRemaining ="))
        self.assertLess(publication.index("fixedGateInstrument ="),
                        publication.index("fixedGateTicksRemaining ="))

        start = source.index("void playNoteOnVoiceWithFixedGate(")
        end = source.index("\nvoid init()", start)
        transaction = source[start:end]
        self.assertIn("SDL_LockAudio();", transaction)
        self.assertIn("scope(exit) SDL_UnlockAudio();", transaction)
        self.assertLess(transaction.index("playNoteImpl("),
                        transaction.index("armFixedKeyjamGate("))

    def test_phase2_new_action_allocates_an_isolated_stopped_wave(self) -> None:
        """R43: [New] allocates private editable W/P/F programmes."""
        with _master_session() as session:
            before = _instrument_bytes(session.run("insbytes"))
            w0 = _new_isolated_wave(session)
            ins = _instrument_bytes(session.run("insbytes"))
            f0, p0 = ins[4], ins[5]
            self.assertNotEqual(w0, before[7])
            self.assertNotEqual(p0, before[5])
            self.assertNotEqual(f0, before[4])
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2),
                [(w0, 0x00, 0x00), (w0 + 1, 0x7E, 0x00)],
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0),
                             (0x00, 0x00, 0x00, 0x7F))
            filter_dump = session.run("sweepdump:F")
            self.assertEqual(_sweep_row(filter_dump, f0), (0x90, 0x01, 0x00, 0x00))
            self.assertEqual(_sweep_row(filter_dump, f0 + 1),
                             (0x00, 0x00, 0xFF, 0x7F))
            chrome = session.run("screendump")
            self.assertRegex(chrome, rf"END \${w0 + 1:02X}")

    def test_phase2_wave_checkpoint_a_and_a_to_b_use_normal_ui_actions(self) -> None:
        """R44/R45: labelled mouse controls produce both canonical byte checkpoints."""
        with _master_session() as session:
            before = _full_sound_dump(session.run("sounddump"))
            w0 = _build_wave_a(session)

            # The graph itself is an editor, not just a row picker: note rows drag
            # vertically, delay rows horizontally. Restore exact values through the
            # visible W1/W2 fine-entry controls before asserting checkpoint A.
            x0 = _plot_x_for_tick(session, 0)
            session.run(f"hover:{x0},{FREQ_GRAPH_ROW}")
            self.assertRegex(session.run("soundstate"), r"cursor=2 ")
            session.run(f"drag:{x0},{FREQ_GRAPH_ROW},{x0},{FREQ_GRAPH_ROW + 1}")
            self.assertNotEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 1)[0][1], 0xB0
            )
            _set_selected_wave_row(session, 0xB0, 0x81)

            x5 = _plot_x_for_tick(session, 5)
            session.run(f"hover:{x5},{FREQ_GRAPH_SAFE_ROW}")
            self.assertRegex(session.run("soundstate"), r"cursor=1 ")
            session.run(
                f"drag:{x5},{FREQ_GRAPH_SAFE_ROW},{x5 + 1},{FREQ_GRAPH_SAFE_ROW}"
            )
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2)[1][2], 0x05
            )
            _set_selected_wave_row(session, 0x00, 0x04)

            expected_a = [
                (w0 + 0, 0xB0, 0x81),
                (w0 + 1, 0x00, 0x04),
                (w0 + 2, 0x02, 0x41),
                (w0 + 3, 0x01, 0x41),
                (w0 + 4, 0x00, 0x41),
                (w0 + 5, 0x7E, 0x00),
            ]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(expected_a)),
                expected_a,
            )
            self.assertRegex(session.run("screendump"), rf"END \${w0 + 5:02X}")

            _mutate_wave_a_to_b(session, w0)
            expected_b = [
                (w0 + 0, 0xC0, 0x81),
                (w0 + 1, 0x00, 0x02),
                (w0 + 2, 0x00, 0x41),
                (w0 + 3, 0x00, 0x0C),
                (w0 + 4, 0x0C, 0x41),
                (w0 + 5, 0x00, 0x0C),
                (w0 + 6, 0x7F, w0 + 2),
            ]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(expected_b)),
                expected_b,
            )
            self.assertRegex(
                session.run("screendump"), rf"LOOP \${w0 + 6:02X}->\${w0 + 2:02X}"
            )
            ins = _instrument_bytes(session.run("insbytes"))
            _assert_only_active_sound_changed(
                self, before, _full_sound_dump(session.run("sounddump")),
                w0, ins[5], ins[4],
            )

    def test_phase2_wave_insert_delete_rebases_absolute_loop_target(self) -> None:
        """R44: structural edits preserve the loop's logical target and undo the shift."""
        with _master_session() as session:
            w0 = _build_wave_a(session)
            _mutate_wave_a_to_b(session, w0)

            # B leaves W0+5 selected. Move to W0+1, then insert immediately before
            # the old W0+2 loop target. The absolute target must shift with that row.
            for _ in range(4):
                _click_control(session, BTN_PREV)
            _click_control(session, BTN_ADD)
            inserted = [
                (w0 + 0, 0xC0, 0x81),
                (w0 + 1, 0x00, 0x02),
                (w0 + 2, 0x00, 0x00),
                (w0 + 3, 0x00, 0x41),
                (w0 + 4, 0x00, 0x0C),
                (w0 + 5, 0x0C, 0x41),
                (w0 + 6, 0x00, 0x0C),
                (w0 + 7, 0x7F, w0 + 3),
            ]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(inserted)), inserted
            )
            self.assertRegex(
                session.run("screendump"), rf"LOOP \${w0 + 7:02X}->\${w0 + 3:02X}"
            )

            # Add selects the inserted row; deleting it must restore checkpoint B,
            # including the absolute loop target, rather than leaving a stale address.
            _click_control(session, BTN_DEL)
            restored = [
                (w0 + 0, 0xC0, 0x81),
                (w0 + 1, 0x00, 0x02),
                (w0 + 2, 0x00, 0x41),
                (w0 + 3, 0x00, 0x0C),
                (w0 + 4, 0x0C, 0x41),
                (w0 + 5, 0x00, 0x0C),
                (w0 + 6, 0x7F, w0 + 2),
            ]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(restored)), restored
            )
            self.assertRegex(
                session.run("screendump"), rf"LOOP \${w0 + 6:02X}->\${w0 + 2:02X}"
            )

    def test_phase2_wave_preview_obeys_delay_and_loop_semantics(self) -> None:
        """R45: delays hold prior rows and B loops to the absolute W0+2 target."""
        with _master_session() as session:
            w0 = _build_wave_a(session)
            preview_a = session.run("wavepreview:12")
            ui_a = session.run("uipreview:12")
            self.assertEqual(
                _preview_values(preview_a, "rows"),
                [w0] * 5 + [w0 + 1, w0 + 2, w0 + 3] + [w0 + 4] * 4,
            )
            self.assertEqual(
                _preview_values(preview_a, "w1"),
                [0xB0] * 5 + [0x00, 0x02, 0x01] + [0x00] * 4,
            )
            self.assertEqual(
                _preview_values(preview_a, "ctrl"), [0x81] * 6 + [0x41] * 6
            )
            for field in ("rows", "ctrl"):
                self.assertEqual(
                    _ui_preview_values(ui_a, field), _preview_values(preview_a, field)
                )
            self.assertEqual(
                _ui_preview_values(ui_a, "w1"),
                [0x30] * 5 + [0x00, 0x02, 0x01] + [0x00] * 4,
            )

            _mutate_wave_a_to_b(session, w0)
            preview_b = session.run("wavepreview:36")
            ui_b = session.run("uipreview:36")
            expected_rows = (
                [w0] * 3
                + [w0 + 1]
                + [w0 + 2] * 13
                + [w0 + 3]
                + [w0 + 4] * 13
                + [w0 + 5]
                + [w0 + 2] * 4
            )
            self.assertEqual(_preview_values(preview_b, "rows"), expected_rows)
            self.assertEqual(
                _preview_values(preview_b, "ctrl"), [0x81] * 4 + [0x41] * 32
            )
            for field in ("rows", "ctrl"):
                self.assertEqual(
                    _ui_preview_values(ui_b, field), _preview_values(preview_b, field)
                )
            self.assertEqual(
                _ui_preview_values(ui_b, "w1"),
                [0x40] * 3 + [0x00] * 14 + [0x00] + [0x0C] * 13 + [0x00] * 5,
            )

    def test_phase2_nonzero_wave_speed_combines_with_row_delays(self) -> None:
        """R45: default wave speed applies except where the next row overrides it."""
        with _master_session() as session:
            w0 = _build_wave_a(session)
            # Arpeggio speed is the restart byte's low nibble. This is a normal
            # parameter-row UI edit after New has established speed zero.
            session.run("click:10,16")
            session.run("key:RIGHT")
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[2], 0x41)

            independent = session.run("wavepreview:16")
            ui = session.run("uipreview:16")
            expected_rows = [w0] * 5 + [w0 + 1] * 2 + [w0 + 2] * 2 \
                + [w0 + 3] * 2 + [w0 + 4] * 5
            self.assertEqual(_preview_values(independent, "rows"), expected_rows)
            self.assertEqual(_preview_values(independent, "ctrl"),
                             [0x81] * 7 + [0x41] * 9)
            for field in ("rows", "ctrl"):
                self.assertEqual(
                    _ui_preview_values(ui, field), _preview_values(independent, field)
                )

    def test_phase3_pulse_boundary_and_dot_hit_priority(self) -> None:
        """R46: an edge is horizontal everywhere except its higher-priority dot."""
        with _master_session() as session:
            _new_isolated_wave(session)
            p0 = _instrument_bytes(session.run("insbytes"))[5]
            _select_rows_duration(session)
            _select_pulse_at(session, 0)
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0),
                             (0x00, 0x00, 0x00, 0x7F))

            edge = _plot_x_for_tick(session, 1)
            self.assertEqual(_cursor_at(session, edge, PULSE_TOP_ROW), 1)
            self.assertEqual(_cursor_at(session, edge, PULSE_BOUNDARY_ROW), 1)
            self.assertEqual(_cursor_at(session, edge, PULSE_GRAPH_ROW), 2)

    def test_phase3_pulse_rows_then_raw_ticks_recomputes_and_clamps_slope(self) -> None:
        """R46/R47: reproduce plan 4.4's first block and its raw-tick resize."""
        with _master_session() as session:
            _new_isolated_wave(session)
            p0 = _instrument_bytes(session.run("insbytes"))[5]
            _select_rows_duration(session)
            _select_pulse_at(session, 0)

            # Rows mode: resize from one tick to four 10-tick tracker rows using
            # the vertical boundary, then raise the end dot from min to max.
            boundary_row = _pulse_boundary_row(session, 1)
            session.run(
                f"drag:{_plot_x_for_tick(session, 1)},{boundary_row},"
                f"{_plot_x_for_tick(session, 40)},{boundary_row}"
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0),
                             (0x27, 0x00, 0x00, 0x7F))
            # The parameter pane clips the final letters on the 160-column
            # headless surface; assert the complete semantic prefix it exposes.
            self.assertIn(f"Pulse ${p0:02X}: 40 Ticks (4 Ro",
                          session.run("screendump"))
            session.run(
                f"drag:{_plot_x_for_tick(session, 40)},{PULSE_GRAPH_ROW},"
                f"{_plot_x_for_tick(session, 40)},{PULSE_TOP_ROW}"
            )
            self.assertEqual(
                _sweep_row(session.run("sweepdump:P"), p0),
                (0x27, 0x66, 0x00, 0x7F),
                "a full-height 40-tick mouse ramp must encode plan checkpoint 4.4",
            )

            # Ticks mode: the same right edge now means an exact raw duration.
            # The endpoint is held at its displayed value, so the requested slope
            # exceeds the table range and must visibly clamp to $FF.
            session.run("click:10,21")
            session.run("key:LEFT")
            _select_pulse_at(session, 0)
            target_x = _pointer_cell_for_duration(session, 4)
            boundary_row = _pulse_boundary_row(session, 40)
            edge_x = _plot_x_for_tick(session, 40)
            session.run(
                f"drag:{edge_x},{boundary_row},{target_x},{boundary_row}"
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0),
                             (0x03, 0xFF, 0x00, 0x7F))
            chrome = session.run("screendump")
            self.assertIn(f"Pulse ${p0:02X}: 4 Ticks", chrome)
            self.assertRegex(chrome.lower(), r"clamp|limit")

    def test_r60_duration_edges_follow_timeline_pointer_at_every_view_scale(self) -> None:
        """R60: Pulse/Filter resizing has timeline velocity in Ticks and Rows."""
        view_names = ("fit", "zoom", "zoom-pan")
        for table in ("P", "F"):
            for rows in (False, True):
                for view_name in view_names:
                    with self.subTest(table=table, rows=rows, view=view_name):
                        with _master_session() as session:
                            if table == "P":
                                _new_isolated_wave(session)
                                ins = _instrument_bytes(session.run("insbytes"))
                                row, anchor_tick, initial_width = ins[5], 0, 1
                                if rows:
                                    _select_rows_duration(session)
                                selection_end = 45 if rows else 30
                            else:
                                f0, _, _ = _build_exact_filter_three_blocks(session)
                                row, initial_width = f0 + 1, 40
                                anchor_tick = _filter_shape_frames(
                                    session.run("filtershape"), row
                                )[0]
                                # The builder intentionally authors in Rows mode.
                                if not rows:
                                    session.run("click:10,21")
                                    session.run("key:LEFT")
                                selection_end = 80 if rows else 60

                            if view_name != "fit":
                                session.run(
                                    f"drag:{_plot_x_for_tick(session, 0)},5,"
                                    f"{_plot_x_for_tick(session, selection_end)},5"
                                )
                                session.run("key:END")
                                if view_name == "zoom-pan":
                                    session.run("key:Shift-LEFT" if table == "P" else "key:Shift-RIGHT")

                            if table == "P":
                                _select_pulse_at(session, 0)
                                start_tick = 1
                                boundary_y = _pulse_boundary_row(session, start_tick)
                                start_x = _plot_x_for_tick(session, start_tick)
                            else:
                                # After a right pan the off-screen CONFIG marker clamps
                                # to the plot edge; select safely inside this SWEEP.
                                _select_filter_at(session, 35 if view_name == "zoom-pan" else 5)
                                shape = next(
                                    item for item in _filter_shapes(session.run("filtershape"))
                                    if item[0] == row
                                )
                                start_x = shape[3]
                                boundary_y = next(
                                    y for y in reversed(range(FILTER_TOP_ROW, FILTER_BOTTOM_ROW + 1))
                                    if _cursor_at(session, start_x, y) == 1
                                )

                            target_width = (40 if table == "P" else 60) if rows else 17
                            pointer_x = _plot_x_for_tick(session, anchor_tick + target_width)
                            expected_width, expected_edge_px = _nearest_legal_duration_at_pointer(
                                session, pointer_x, rows=rows, anchor_tick=anchor_tick
                            )
                            session.run(
                                f"drag:{start_x},{boundary_y},{pointer_x},{boundary_y}"
                            )
                            actual = _sweep_row(session.run(f"sweepdump:{table}"), row)
                            actual_width = (actual[0] & 0x7F) + 1
                            self.assertEqual(
                                actual_width, expected_width,
                                "duration must use the timeline under the pointer, not cells moved",
                            )

                            # The stored width is also the box's rendered right edge.
                            actual_edge_x = _plot_x_for_tick(session, anchor_tick + actual_width)
                            expected_edge_x = expected_edge_px // 8
                            self.assertLessEqual(
                                abs(actual_edge_x - pointer_x),
                                abs(expected_edge_x - pointer_x) + 1,
                            )

                            session.run("key:Ctrl-z")
                            restored = _sweep_row(session.run(f"sweepdump:{table}"), row)
                            self.assertEqual((restored[0] & 0x7F) + 1, initial_width)

    def test_r61_filter_loop_is_exactly_one_inward_one_cell_triangle_pair(self) -> None:
        """R61: the authored loop span has one ▶/◀ pair, not repeated grips."""
        from tests.test_sound_editor_usage import png_rgb

        with tempfile.TemporaryDirectory(prefix="cc-loop-triangles-") as tmp:
            image = Path(tmp) / "loop.png"
            with _master_session() as session:
                _build_exact_filter_three_blocks(session)
                session.run("key:Ctrl-e")
                session.run("key:Ctrl-e")
                session.run(f"shot:{image}")
            width, _, rgb = png_rgb(image)
            orange = bytes((0x8D, 0x50, 0x29))
            points = set()
            for y in range(FILTER_TOP_ROW * 14, (FILTER_BOTTOM_ROW + 1) * 14):
                for x in range(PLOT_X0 * 8, (PLOT_X0 + PLOT_WIDTH) * 8):
                    offset = (y * width + x) * 3
                    if rgb[offset:offset + 3] == orange:
                        points.add((x, y))

            components = []
            while points:
                pending = [points.pop()]
                component = set(pending)
                while pending:
                    x, y = pending.pop()
                    for neighbour in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)):
                        if neighbour in points:
                            points.remove(neighbour)
                            component.add(neighbour)
                            pending.append(neighbour)
                components.append(component)
            components.sort(key=lambda component: min(x for x, _ in component))
            self.assertEqual(len(components), 2, "one authored loop must draw one pair")
            for component in components:
                xs = [x for x, _ in component]
                ys = [y for _, y in component]
                self.assertEqual(max(xs) - min(xs) + 1, 8)
                self.assertEqual(max(ys) - min(ys) + 1, 14)
            start_columns = {x: sum(px == x for px, _ in components[0]) for x, _ in components[0]}
            end_columns = {x: sum(px == x for px, _ in components[1]) for x, _ in components[1]}
            self.assertGreater(start_columns[min(start_columns)], start_columns[max(start_columns)])
            self.assertLess(end_columns[min(end_columns)], end_columns[max(end_columns)])

    def test_r61_pulse_and_filter_stopped_end_then_offscreen_loop_has_no_rail_grip(self) -> None:
        """R61: real END/LOOP chrome never clamps an off-view handle to a rail."""
        with tempfile.TemporaryDirectory(prefix="cc-loop-visibility-") as tmp:
            for table in ("P", "F"):
                with self.subTest(table=table), _master_session() as session:
                    if table == "P":
                        close = _build_simple_pulse_three_blocks(session, loop=False) + 2
                        top, bottom, end_tick, loop_tick = (
                            PULSE_TOP_ROW, PULSE_GRAPH_ROW, 3, 1
                        )
                        dump = "P"
                        grip = _pulse_loop_grip_x(session, end_tick)
                    else:
                        f0, _, _ = _build_exact_filter_three_blocks(session, loop=False)
                        close = f0 + 5
                        top, bottom, end_tick, loop_tick = (
                            FILTER_TOP_ROW, FILTER_BOTTOM_ROW, 73, 41
                        )
                        dump = "F"
                        grip = _filter_loop_grip_x(session, end_tick)

                    stopped = Path(tmp) / f"{table}-stopped.png"
                    session.run(f"shot:{stopped}")
                    self.assertEqual(len(_orange_components(stopped, top, bottom)), 1)
                    self.assertEqual(_cursor_at(session, grip, top), 1)
                    self.assertEqual(_sweep_row(session.run(f"sweepdump:{dump}"), close)[3],
                                     0x7F)

                    session.run(
                        f"drag:{grip},{top},{_plot_x_for_tick(session, loop_tick)},{top}"
                    )
                    loop_target = _sweep_row(session.run(f"sweepdump:{dump}"), close)[3]
                    self.assertNotEqual(loop_target, 0x7F)
                    authored = Path(tmp) / f"{table}-loop.png"
                    session.run(f"shot:{authored}")
                    self.assertEqual(len(_orange_components(authored, top, bottom)), 2)

                    # Zoom to an interval that excludes both authored edges.
                    a, b = ((10, 20) if table == "P" else (0, 20))
                    session.run(
                        f"drag:{_plot_x_for_tick(session, a)},7,"
                        f"{_plot_x_for_tick(session, b)},7"
                    )
                    session.run("key:END")
                    offscreen = Path(tmp) / f"{table}-offscreen.png"
                    session.run(f"shot:{offscreen}")
                    self.assertEqual(_orange_components(offscreen, top, bottom), [],
                                     "offscreen triangles must not clamp to plot rails")
                    session.run(f"drag:{PLOT_X0},{top},{PLOT_X0 + 5},{top}")
                    self.assertEqual(
                        _sweep_row(session.run(f"sweepdump:{dump}"), close)[3], loop_target,
                        "the empty rail must not remain an invisible loop hit target",
                    )

    def test_r61_both_authored_triangles_edit_terminal_and_undo_once(self) -> None:
        """R61: left and right triangles are equivalent real drag handles."""
        cases = (
            ("P", _build_simple_pulse_three_blocks, PULSE_TOP_ROW, 1, 3, 0, 2),
            ("F", _build_exact_filter_three_blocks, FILTER_TOP_ROW, 41, 73, 1, 64),
        )
        for table, builder, top, start_tick, end_tick, start_target, end_target in cases:
            with self.subTest(table=table), _master_session() as session:
                built = builder(session)
                first = built if isinstance(built, int) else built[0]
                close = first + (2 if table == "P" else 5)
                original = _sweep_row(session.run(f"sweepdump:{table}"), close)[3]
                targets = ((start_tick, start_target, False),
                           (end_tick, end_target, True))
                for triangle_tick, target_tick, end_triangle in targets:
                    # Plain Output-band click clears the selected slope-dot priority.
                    session.run(f"click:{_plot_x_for_tick(session, 20)},7")
                    grip = (_pulse_loop_grip_x(session, triangle_tick)
                            if table == "P" and end_triangle
                            else _filter_loop_grip_x(session, triangle_tick)
                            if table == "F" and end_triangle
                            else _plot_x_for_tick(session, triangle_tick))
                    session.run(
                        f"drag:{grip},{top},{_plot_x_for_tick(session, target_tick)},{top}"
                    )
                    changed = _sweep_row(session.run(f"sweepdump:{table}"), close)[3]
                    self.assertNotEqual(changed, original)
                    session.run("key:Ctrl-z")
                    self.assertEqual(
                        _sweep_row(session.run(f"sweepdump:{table}"), close)[3], original,
                        "one Undo must restore the terminal jump after either grip",
                    )

    def test_r61_pulse_and_filter_dot_priority_and_other_edge_resize(self) -> None:
        """R61: a co-located dot edits slope; another boundary position edits duration."""
        for table in ("P", "F"):
            with self.subTest(table=table), _master_session() as session:
                _new_isolated_wave(session)
                first = _instrument_bytes(session.run("insbytes"))[5 if table == "P" else 4]
                _select_rows_duration(session)
                if table == "P":
                    _select_pulse_at(session, 0)
                    edge_tick, top, bottom = 1, PULSE_TOP_ROW, PULSE_GRAPH_ROW
                    dot_y = _pulse_dot_row(session, edge_tick)
                    boundary_y = _pulse_boundary_row(session, edge_tick)
                    row = first
                    target_tick = 10
                else:
                    _select_filter_at(session, 1)
                    row = first + 1
                    initial_edge = _filter_shape_frames(
                        session.run("filtershape"), row
                    )[1]
                    setup_boundary = _filter_boundary_row(session, initial_edge)
                    session.run(
                        f"drag:{_plot_x_for_tick(session, initial_edge)},{setup_boundary},"
                        f"{_plot_x_for_tick(session, initial_edge + 9)},{setup_boundary}"
                    )
                    _fine_adjust_filter_slope(session, row, 1)
                    _, edge_tick = _filter_shape_frames(
                        session.run("filtershape"), row
                    )
                    top, bottom = FILTER_TOP_ROW, FILTER_BOTTOM_ROW
                    dot_y = _filter_dot_row(session, edge_tick)
                    boundary_y = _filter_boundary_row(session, edge_tick)
                    target_tick = edge_tick + 10

                before = _sweep_row(session.run(f"sweepdump:{table}"), row)
                edge_x = _plot_x_for_tick(session, edge_tick)
                self.assertEqual(_cursor_at(session, edge_x, dot_y), 2)
                session.run(f"drag:{edge_x},{dot_y},{edge_x},{top}")
                after_dot = _sweep_row(session.run(f"sweepdump:{table}"), row)
                self.assertEqual(after_dot[0], before[0])
                self.assertNotEqual(after_dot[1], before[1])
                session.run("key:Ctrl-z")

                self.assertEqual(_cursor_at(session, edge_x, boundary_y), 1)
                session.run(
                    f"drag:{edge_x},{boundary_y},"
                    f"{_plot_x_for_tick(session, target_tick)},{boundary_y}"
                )
                after_edge = _sweep_row(session.run(f"sweepdump:{table}"), row)
                self.assertNotEqual(after_edge[0], before[0])
                self.assertEqual(after_edge[2], before[2])
                session.run("key:Ctrl-z")
                self.assertEqual(_sweep_row(session.run(f"sweepdump:{table}"), row), before)

    def test_r62_r64_context_menu_and_bracketless_graph_control_layout(self) -> None:
        """R62-R64: Sound context owns non-graph commands; graph row stays contextual."""
        with _master_session() as session:
            screen = session.run("screendump")
            top = _screen_row(screen, 0)
            self.assertRegex(top, r"File\s+Edit\s+View\s+Playback\s+Sound\s+Help")
            self.assertNotIn("Navigate", top)
            controls = _screen_row(screen, CONTROL_ROW)
            self.assertNotIn("[", controls)
            self.assertNotIn("]", controls)
            self.assertRegex(controls, r"\s-\s+\s\+\s+\sFit\s+\sSelection\s")
            self.assertNotIn("New", controls)
            self.assertNotIn("W1", controls)
            self.assertNotIn("W2", controls)

    def test_r63_r64_exact_sound_menu_and_contextual_control_groups(self) -> None:
        """R63-R64: exact menu ownership and one selected graph group at a time."""
        view = ["se_zoom_out", "se_zoom_in", "se_fit", "se_selection", "se_linked"]
        local_filter = ["se_lp", "se_bp", "se_hp", "se_route"]
        with _master_session() as session:
            self.assertEqual(_control_action_ids(session), view + local_filter)
            self.assertEqual(
                dict(_control_states(session)),
                {
                    "se_zoom_out": True, "se_zoom_in": True, "se_fit": True,
                    "se_selection": False, "se_linked": True,
                    "se_lp": False, "se_bp": False,
                    "se_hp": False, "se_route": False,
                },
            )

            # The context menu has exactly the three non-graph Sound actions.
            session.run("click:31,0")
            dropdown = session.run("screendump")
            self.assertIn("New sound", _screen_row(dropdown, 2))
            self.assertIn("Ctrl-Shift-N", _screen_row(dropdown, 2))
            self.assertIn("Edit wave byte 1...  Ctrl-Shift-1", _screen_row(dropdown, 3))
            self.assertIn("Edit wave byte 2...  Ctrl-Shift-2", _screen_row(dropdown, 4))
            self.assertNotIn("Navigate", _screen_row(dropdown, 0))
            session.run("key:ESC")

            _new_isolated_wave(session)
            self.assertEqual(
                _control_action_ids(session),
                view + ["se_add", "se_delete", "se_wave_prev", "se_wave_next",
                        "se_wave_loop"] + local_filter,
            )

            _select_pulse_at(session, 0)
            self.assertEqual(
                _control_action_ids(session),
                view + ["se_add", "se_delete", "se_stop", "se_carry"] + local_filter,
            )

            # Tick zero owns the instantaneous CONFIG marker; the following tick
            # owns its paired SWEEP.  Both are selected by real graph clicks.
            _select_filter_at(session, 1)
            self.assertEqual(
                _control_action_ids(session),
                view + ["se_add", "se_delete", "se_stop", "se_type", "se_carry"]
                + local_filter,
            )
            _select_filter_at(session, 0)
            self.assertEqual(
                _control_action_ids(session),
                view + ["se_add", "se_delete", "se_stop", "se_type",
                        "se_res_down", "se_res_up"] + local_filter,
            )

    def test_r62_r64_padding_menu_equivalence_and_context_restoration(self) -> None:
        """R62-R64: padded hit areas, shared actions, suppression, and restoration."""
        with _master_session() as session:
            x0, x1, row, enabled = _control_bounds(session, "se_zoom_out")
            self.assertTrue(enabled)
            self.assertGreaterEqual(x1 - x0, 3)  # whitespace + glyph + whitespace
            for x in (x0, x1 - 1):
                cell = session.run(f"cellstate:{x},{row}")
                self.assertRegex(cell, r"ch=32 ")
                self.assertNotRegex(cell, r"bg=0 ")
            self.assertNotIn("[", _screen_row(session.run("screendump"), row))
            self.assertNotIn("]", _screen_row(session.run("screendump"), row))

            original = re.search(r"view=([^ ]+)", session.run("soundstate")).group(1)
            session.run(f"press:{x0},{row}")
            session.run(f"release:{x1 + 3},{row}")
            self.assertEqual(
                re.search(r"view=([^ ]+)", session.run("soundstate")).group(1), original,
                "release outside must disarm instead of firing",
            )
            session.run(f"click:{x0},{row}")
            self.assertNotEqual(
                re.search(r"view=([^ ]+)", session.run("soundstate")).group(1), original,
                "left whitespace padding must be part of the hit target",
            )

            for action, expected in (("se_new", True), ("se_wave_1", False),
                                     ("se_wave_2", False)):
                state = session.run(f"shortcutstate:{action}")
                self.assertIn(f"enabled={'true' if expected else 'false'}", state)
            for action in ("toggle_filter_track", "toggle_oscilloscope",
                           "scope_zoom_in", "scope_zoom_out", "toggle_keyjam"):
                self.assertIn("enabled=false", session.run(f"shortcutstate:{action}"))

            session.run("key:Ctrl-e")
            restored = _screen_row(session.run("screendump"), 0)
            self.assertIn("Navigate", restored)
            self.assertNotIn("Sound", restored)

        # Menu and shortcut dispatch share the same callback/state transition.
        with _master_session() as menu, _master_session() as shortcut:
            menu.run("click:31,0")
            menu.run("click:34,2")
            shortcut.run("key:Ctrl-Shift-n")
            self.assertEqual(
                _full_sound_dump(menu.run("sounddump")),
                _full_sound_dump(shortcut.run("sounddump")),
            )
            for action in ("se_new", "se_wave_1", "se_wave_2"):
                self.assertIn("enabled=true", menu.run(f"shortcutstate:{action}"))

            for menu_row, key, prompt in (
                (3, "Ctrl-Shift-1", "Wave 1: $"),
                (4, "Ctrl-Shift-2", "Wave 2: $"),
            ):
                menu.run("click:31,0")
                menu.run(f"click:34,{menu_row}")
                shortcut.run(f"key:{key}")
                self.assertIn(prompt, menu.run("screendump"))
                self.assertIn(prompt, shortcut.run("screendump"))
                menu.run("key:ESC")
                shortcut.run("key:ESC")

    def test_r62_filter_gutter_padding_is_painted_hittable_and_release_safe(self) -> None:
        """R62: LP/BP/HP/Route share exact padded draw, hit and release geometry."""
        with _master_session() as session:
            _new_isolated_wave(session)
            f0 = _instrument_bytes(session.run("insbytes"))[4]
            for action, width in (("se_lp", 4), ("se_bp", 4), ("se_hp", 4),
                                  ("se_route", 8)):
                with self.subTest(action=action):
                    x0, x1, row, enabled = _control_bounds(session, action)
                    self.assertTrue(enabled)
                    self.assertEqual(x1 - x0, width)
                    cells = []
                    for x in (x0, x1 - 1):
                        cell = session.run(f"cellstate:{x},{row}")
                        match = re.search(r"ch=(\d+) fg=(\d+) bg=(\d+)", cell)
                        self.assertIsNotNone(match)
                        self.assertEqual(int(match.group(1)), 32)
                        cells.append((int(match.group(2)), int(match.group(3))))
                    self.assertEqual(cells[0], cells[1],
                                     "both padding cells must be painted")

                    before = _sweep_row(session.run("sweepdump:F"), f0)
                    session.run(f"press:{x1 - 1},{row}")
                    self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0), before,
                                     "press only arms the action")
                    session.run(f"release:{x1 + 2},{row}")
                    self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0), before,
                                     "release outside cancels")
                    session.run(f"click:{x1 - 1},{row}")
                    self.assertNotEqual(_sweep_row(session.run("sweepdump:F"), f0), before,
                                        "right whitespace padding must fire the action")
                    session.run("key:Ctrl-z")
                    self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0), before)

    def test_r65_hover_help_never_changes_top_right_register_cells(self) -> None:
        """R65: help display, replacement, and timeout leave SID registers byte-stable."""
        with _master_session() as session:
            session.run("key:q")
            session.run("tick:5")
            before = session.run("regstate").split("checkpoint", 1)[0]
            self.assertIn("00000f56", before)  # rendered 'V' glyph cell is present

            for action in ("se_zoom_out", "se_fit", "se_selection"):
                x0, x1, row, _ = _control_bounds(session, action)
                session.run(f"hover:{(x0 + x1 - 1) // 2},{row}")
                self.assertEqual(session.run("regstate").split("checkpoint", 1)[0], before)

            # A context menu suppresses underlying hover help without repainting the
            # adjacent register rectangle.
            session.run("click:31,0")
            self.assertIn("New sound", session.run("screendump"))
            self.assertEqual(session.run("regstate").split("checkpoint", 1)[0], before)
            x0, x1, row, _ = _control_bounds(session, "se_zoom_out")
            session.run(f"hover:{(x0 + x1 - 1) // 2},{row}")
            self.assertEqual(session.run("regstate").split("checkpoint", 1)[0], before)
            session.run("key:ESC")
            self.assertEqual(session.run("regstate").split("checkpoint", 1)[0], before)

            # A modal query likewise suppresses help from the graph behind it.  New
            # sound establishes an editable Wave row; compare against the fresh raw
            # register snapshot because that command may legitimately retrigger q.
            session.run("key:Ctrl-Shift-n")
            modal_before = session.run("regstate").split("checkpoint", 1)[0]
            session.run("key:Ctrl-Shift-1")
            self.assertIn("Wave 1: $", session.run("screendump"))
            self.assertEqual(
                session.run("regstate").split("checkpoint", 1)[0], modal_before
            )
            session.run(f"hover:{(x0 + x1 - 1) // 2},{row}")
            self.assertEqual(
                session.run("regstate").split("checkpoint", 1)[0], modal_before
            )
            session.run("key:ESC")
            self.assertEqual(
                session.run("regstate").split("checkpoint", 1)[0], modal_before
            )

            session.run("status:" + "X" * 240)
            self.assertEqual(
                session.run("regstate").split("checkpoint", 1)[0], modal_before
            )

            session.run("tick:90")
            self.assertEqual(
                session.run("regstate").split("checkpoint", 1)[0], modal_before
            )
            # The help/status region ends immediately before the register rectangle.
            self.assertRegex(session.run("cellstate:117,2"), r"x=117 y=2 ch=32 ")
            self.assertRegex(session.run("cellstate:118,2"), r"x=118 y=2 ch=86 ")
            session.run("keyup:q")

    def test_phase3_exact_three_block_loop_contracts_to_self_then_end(self) -> None:
        """R46-R49: execute plan 4.4's exact dependent pulse-table sequence."""
        with _master_session() as session:
            _new_isolated_wave(session)
            p0 = _instrument_bytes(session.run("insbytes"))[5]
            filter_before = _full_sound_dump(session.run("sounddump"))["filter"]
            _select_rows_duration(session)
            _select_pulse_at(session, 0)

            # Block 1: four rows, minimum to maximum.
            y = _pulse_boundary_row(session, 1)
            session.run(
                f"drag:{_plot_x_for_tick(session, 1)},{y},"
                f"{_plot_x_for_tick(session, 40)},{y}"
            )
            dot_y = _pulse_dot_row(session, 40)
            session.run(
                f"drag:{_plot_x_for_tick(session, 40)},{dot_y},"
                f"{_plot_x_for_tick(session, 40)},{PULSE_TOP_ROW}"
            )
            self.assertEqual(_sweep_rows(session, "P", p0, 1),
                             [(0x27, 0x66, 0x00, 0x7F)])

            # Block 2: eight rows, inherited start, negative $67 slope. The
            # coarse mouse gesture establishes direction; documented graph-key
            # fine adjustment reaches the exact canonical quantized value.
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_CARRY)
            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)
            y = _pulse_boundary_row(session, 80)
            session.run(
                f"drag:{_plot_x_for_tick(session, 80)},{y},"
                f"{_plot_x_for_tick(session, 120)},{y}"
            )
            dot_y = _pulse_dot_row(session, 120)
            session.run(
                f"drag:{_plot_x_for_tick(session, 120)},{dot_y},"
                f"{_plot_x_for_tick(session, 120)},{PULSE_GRAPH_ROW}"
            )
            _fine_adjust_pulse_slope(session, p0 + 1, -0x67)
            self.assertEqual(
                _sweep_rows(session, "P", p0, 2),
                [(0x27, 0x66, 0x00, 0x00), (0xCF, 0x67, 0xFF, 0x7F)],
            )
            with self.subTest(checkpoint="two-wrap visibility"):
                self.assertIn(
                    "Wraps -2", session.run("screendump"),
                    "the selected descending block must visibly disclose both wraps",
                )

            # Block 3: two rows at fixed $400, initially stopping.
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)
            y = _pulse_boundary_row(session, 200)
            session.run(
                f"drag:{_plot_x_for_tick(session, 200)},{y},"
                f"{_plot_x_for_tick(session, 140)},{y}"
            )
            session.run(
                f"drag:{_plot_x_for_tick(session, 130)},{PULSE_GRAPH_ROW},"
                f"{_plot_x_for_tick(session, 130)},{PULSE_BOUNDARY_ROW}"
            )
            _fine_adjust_pulse_start_byte(session, p0 + 2, 0x04)
            _fine_adjust_pulse_slope(session, p0 + 2, 0)
            self.assertEqual(
                _sweep_rows(session, "P", p0, 3),
                [
                    (0x27, 0x66, 0x00, 0x00),
                    (0xCF, 0x67, 0xFF, 0x00),
                    (0x13, 0x00, 0x04, 0x7F),
                ],
            )

            # Drag the orange top-strip terminator onto block 2.
            session.run(
                f"drag:{_plot_x_for_tick(session, 140)},{PULSE_TOP_ROW},"
                f"{_plot_x_for_tick(session, 41)},{PULSE_TOP_ROW}"
            )
            self.assertEqual(
                _sweep_rows(session, "P", p0, 3)[-1],
                (0x13, 0x00, 0x04, p0 + 1),
                "the loop grip must visibly target block 2",
            )
            self.assertRegex(
                session.run("screendump"),
                rf"Pulse \${p0:02X} LOOP \${p0 + 2:02X}->\${p0 + 1:02X}:",
            )

            # Resize block 1 in raw Ticks. Preserve its displayed endpoint and
            # expose the legal $FF clamp without changing either later block.
            session.run("click:10,21")
            session.run("key:LEFT")
            _click_control(session, BTN_FIT)
            _select_pulse_at(session, 1)
            target_x = _pointer_cell_for_duration(session, 4)
            y = _pulse_boundary_row(session, 40)
            edge_x = _plot_x_for_tick(session, 40)
            session.run(
                f"drag:{edge_x},{y},{target_x},{y}"
            )
            self.assertEqual(
                _sweep_rows(session, "P", p0, 3),
                [
                    (0x03, 0xFF, 0x00, 0x00),
                    (0xCF, 0x67, 0xFF, 0x00),
                    (0x13, 0x00, 0x04, p0 + 1),
                ],
            )

            # Removing block 2 contracts the loop to the surviving old block 3;
            # removing that complete loop converts the predecessor to END.
            _select_pulse_at(session, 10)
            _click_control(session, BTN_DEL)
            self.assertEqual(
                _sweep_rows(session, "P", p0, 2),
                [(0x03, 0xFF, 0x00, 0x00), (0x13, 0x00, 0x04, p0 + 1)],
            )
            self.assertRegex(
                session.run("screendump"),
                rf"Pulse \${p0:02X} LOOP \${p0 + 1:02X}->\${p0 + 1:02X}:",
            )
            _select_pulse_at(session, 10)
            _click_control(session, BTN_DEL)
            self.assertEqual(_sweep_rows(session, "P", p0, 1),
                             [(0x03, 0xFF, 0x00, 0x7F)])
            self.assertRegex(
                session.run("screendump"), rf"Pulse \${p0:02X} END \${p0:02X}:"
            )
            self.assertEqual(
                _full_sound_dump(session.run("sounddump"))["filter"], filter_before,
                "pulse editing must not alter any filter-table byte",
            )

            # Each delete is one undoable structural edit, including its marker.
            session.run("key:Ctrl-z")
            self.assertEqual(
                _sweep_rows(session, "P", p0, 2),
                [(0x03, 0xFF, 0x00, 0x00), (0x13, 0x00, 0x04, p0 + 1)],
            )
            self.assertRegex(
                session.run("screendump"),
                rf"Pulse \${p0:02X} LOOP \${p0 + 1:02X}->\${p0 + 1:02X}:",
            )
            session.run("key:Ctrl-z")
            self.assertEqual(
                _sweep_rows(session, "P", p0, 3),
                [
                    (0x03, 0xFF, 0x00, 0x00),
                    (0xCF, 0x67, 0xFF, 0x00),
                    (0x13, 0x00, 0x04, p0 + 1),
                ],
            )
            self.assertRegex(
                session.run("screendump"),
                rf"Pulse \${p0:02X} LOOP \${p0 + 2:02X}->\${p0 + 1:02X}:",
            )
            self.assertEqual(
                _full_sound_dump(session.run("sounddump"))["filter"], filter_before,
            )

    def test_phase4_exact_filter_program_and_resid_usage_sequence(self) -> None:
        """R51-R55: stateful filter authoring/audition sequence from plan 4.5."""
        with _master_session() as session:
            _new_isolated_wave(session)
            ins = _instrument_bytes(session.run("insbytes"))
            f0, p0, w0 = ins[4], ins[5], ins[7]
            before = _full_sound_dump(session.run("sounddump"))
            _select_rows_duration(session)

            self.assertEqual(
                _sweep_rows(session, "F", f0, 2),
                [(0x90, 0x01, 0x00, 0x00), (0x00, 0x00, 0xFF, 0x7F)],
            )

            # Logical block 1 CONFIG: the graph resonance handle must be able to
            # land on every nibble, including 3, while preserving route mask 1.
            _select_filter_at(session, 0)
            self.assertRegex(session.run("screendump"),
							 rf"screen22:\s+Filter \${f0:02X} CFG")
            res_y = _filter_dot_row(session, 0)
            self.assertEqual(_cursor_at(session, _plot_x_for_tick(session, 0), res_y), 2)
            session.run(
                f"drag:{_plot_x_for_tick(session, 0)},{res_y},"
                f"{_plot_x_for_tick(session, 0) + 1},{FILTER_BOTTOM_ROW}"
            )
            self.assertEqual(
                _sweep_row(session.run("sweepdump:F"), f0)[1], 0x11,
                "coarse graph drag establishes resonance 1 without changing route 1",
            )
            controls = session.run("screendump")
            self.assertRegex(_screen_row(controls, CONTROL_ROW), r"\sRes-\s+\sRes\+\s")
            _click_control(session, BTN_RES_PLUS)
            _click_control(session, BTN_RES_PLUS)
            self.assertEqual(
                _sweep_row(session.run("sweepdump:F"), f0)[:2], (0x90, 0x31),
                "two visible Res+ clicks must reach resonance 3 and preserve route 1",
            )
            self.assertIn("Res 3", session.run("screendump"))

            # Cutoff $100 is byte $20. Use the selected graph handle's documented
            # fine step after a mouse selection so no test-only table write is hidden.
            for _ in range(0x20):
                session.run("key:Ctrl-Shift-6")

            # Logical block 1 SWEEP: four rows and rising signed slope $10.
            _select_filter_at(session, 1)
            self.assertRegex(session.run("screendump"),
                             rf"screen22:\s+Filter \${f0 + 1:02X}:")
            boundary_y = _filter_boundary_row(session, 2)
            self.assertEqual(
                _cursor_at(session, _plot_x_for_tick(session, 2), boundary_y), 1
            )
            session.run(
                f"drag:{_plot_x_for_tick(session, 2)},{boundary_y},"
                f"{_plot_x_for_tick(session, 41)},{boundary_y}"
            )
            dot_y = _filter_dot_row(session, 41)
            self.assertEqual(
                _cursor_at(session, _plot_x_for_tick(session, 41), dot_y), 2
            )
            session.run(
                f"drag:{_plot_x_for_tick(session, 41)},{dot_y},"
                f"{_plot_x_for_tick(session, 41)},{FILTER_TOP_ROW}"
            )
            _fine_adjust_filter_slope(session, f0 + 1, 0x10)
            self.assertEqual(
                _sweep_rows(session, "F", f0, 2),
                [(0x90, 0x31, 0x20, 0x00), (0x27, 0x10, 0xFF, 0x7F)],
            )
            self.assertRegex(
				session.run("screendump"), rf"Filter \${f0:02X} END \${f0 + 1:02X}:"
            )

            # One Add on a selected filter SWEEP is one logical-block operation:
            # it appends both a carry-cutoff CONFIG and a stopped neutral SWEEP.
            _click_control(session, BTN_ADD)
            added = _sweep_rows(session, "F", f0, 4)
            self.assertEqual(added[0][:3], (0x90, 0x31, 0x20))
            self.assertEqual(added[0][3], 0x00)
            self.assertEqual(added[1], (0x27, 0x10, 0xFF, 0x00))
            self.assertTrue(added[2][0] & 0x80,
                            "one Add must append the next logical CONFIG row")
            self.assertEqual(added[2][2:], (0xFF, 0x00))
            self.assertFalse(added[3][0] & 0x80,
                             "one Add must append the logical SWEEP row as well")
            self.assertEqual(added[3][3], 0x7F)

            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)

            # Logical block 2 CONFIG is visible and mouse-selected at frame 41.
            _select_filter_at(session, 41)
            self.assertRegex(session.run("screendump"),
                             rf"screen22:\s+Filter \${f0 + 2:02X} CFG")
            # LP off, BP on; resonance 3 -> 8; route 1 cycles through to 0.
            _click_action(session, "se_lp")
            _click_action(session, "se_bp")
            for _ in range(5):
                _click_control(session, BTN_RES_PLUS)
            for _ in range(15):
                _click_action(session, "se_route")
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 2),
                             (0xA0, 0x80, 0xFF, 0x00))
            config_chrome = session.run("screendump")
            self.assertIn(f"Filter ${f0 + 2:02X} CFG M20 Res 8", config_chrome)
            self.assertIn("Mode BP Rt0", config_chrome)

            # Logical block 2 SWEEP: two Rows, falling signed slope -8.
            _select_filter_at(session, 42)
            self.assertRegex(session.run("screendump"),
                             rf"screen22:\s+Filter \${f0 + 3:02X}:")
            boundary_y = _filter_boundary_row(session, 43)
            self.assertEqual(
                _cursor_at(session, _plot_x_for_tick(session, 43), boundary_y), 1
            )
            session.run(
                f"drag:{_plot_x_for_tick(session, 43)},{boundary_y},"
                f"{_plot_x_for_tick(session, 62)},{boundary_y}"
            )
            dot_y = _filter_dot_row(session, 62)
            self.assertEqual(
                _cursor_at(session, _plot_x_for_tick(session, 62), dot_y), 2
            )
            session.run(
                f"drag:{_plot_x_for_tick(session, 62)},{dot_y},"
                f"{_plot_x_for_tick(session, 62)},{FILTER_BOTTOM_ROW}"
            )
            _fine_adjust_filter_slope(session, f0 + 3, -8)
            self.assertEqual(
                _sweep_rows(session, "F", f0, 4),
                [
                    (0x90, 0x31, 0x20, 0x00),
                    (0x27, 0x10, 0xFF, 0x00),
                    (0xA0, 0x80, 0xFF, 0x00),
                    (0x13, 0xF8, 0xFF, 0x7F),
                ],
            )

            # One Add appends logical block 3 atomically as CONFIG+SWEEP.
            _click_control(session, BTN_ADD)
            added = _sweep_rows(session, "F", f0, 6)
            self.assertEqual(added[3][3], 0x00)
            self.assertTrue(added[4][0] & 0x80)
            self.assertEqual(added[4][2:], (0xFF, 0x00))
            self.assertFalse(added[5][0] & 0x80)
            self.assertEqual(added[5][3], 0x7F)

            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)

            # Logical block 3 CONFIG: HP only, resonance C, route all voices.
            _select_filter_at(session, 62)
            self.assertRegex(session.run("screendump"),
                             rf"screen22:\s+Filter \${f0 + 4:02X} CFG")
            _click_action(session, "se_bp")  # BP off
            _click_action(session, "se_hp")  # HP on
            for _ in range(4):
                _click_control(session, BTN_RES_PLUS)
            for _ in range(7):
                _click_action(session, "se_route")
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 4),
                             (0xC0, 0xC7, 0xFF, 0x00))
            config_chrome = session.run("screendump")
            self.assertIn(f"Filter ${f0 + 4:02X} CFG M40 Res C", config_chrome)
            self.assertIn("Mode HP Rt7", config_chrome)

            # Logical block 3 SWEEP: one Row, rising signed slope +4.
            # Use the first interior cell; at this zoom the exact 63-tick edge
            # rounds to the preceding instantaneous CONFIG frame.
            _select_filter_at(session, 64)
            self.assertRegex(session.run("screendump"),
                             rf"screen22:\s+Filter \${f0 + 5:02X}:")
            boundary_y = _filter_boundary_row(session, 64)
            session.run(
                f"drag:{_plot_x_for_tick(session, 64)},{boundary_y},"
                f"{_plot_x_for_tick(session, 73)},{boundary_y}"
            )
            dot_y = _filter_dot_row(session, 73)
            session.run(
                f"drag:{_plot_x_for_tick(session, 73)},{dot_y},"
                f"{_plot_x_for_tick(session, 73)},{FILTER_TOP_ROW}"
            )
            _fine_adjust_filter_slope(session, f0 + 5, 4)
            self.assertEqual(
                _sweep_rows(session, "F", f0, 6),
                [
                    (0x90, 0x31, 0x20, 0x00),
                    (0x27, 0x10, 0xFF, 0x00),
                    (0xA0, 0x80, 0xFF, 0x00),
                    (0x13, 0xF8, 0xFF, 0x00),
                    (0xC0, 0xC7, 0xFF, 0x00),
                    (0x09, 0x04, 0xFF, 0x7F),
                ],
            )

            # The filter top-strip END grip becomes a visible loop to block 2.
            # Move focus off the terminal slope first: while its endpoint dot is
            # selected, that dot intentionally has priority over the co-located grip.
            _select_filter_at(session, 62)
            grip_x = _filter_loop_grip_x(session, 73)
            self.assertNotEqual(grip_x, _plot_x_for_tick(session, 73))
            session.run(
                f"drag:{grip_x},{FILTER_TOP_ROW},"
                f"{_plot_x_for_tick(session, 41)},{FILTER_TOP_ROW}"
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 5),
                             (0x09, 0x04, 0xFF, f0 + 2))
            self.assertRegex(
                session.run("screendump"),
                rf"Filter \${f0:02X} LOOP \${f0 + 5:02X}->\${f0 + 2:02X}:",
            )

            after = _full_sound_dump(session.run("sounddump"))
            self.assertEqual(after["wave"], before["wave"])
            self.assertEqual(after["pulse"], before["pulse"])
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[4:8],
                             [f0, p0, 0, w0])

    def test_phase4_filter_response_regions_render_and_edit_in_place(self) -> None:
        """R58: pass-region silhouettes share one absolute cutoff axis and handle."""
        with _master_session() as session:
            f0, _, _ = _build_exact_filter_three_blocks(session)
            canonical = _sweep_rows(session, "F", f0, 6)

            # Production geometry formulas at both rails and midpoint.
            for mode in (0x00, 0x10, 0x20, 0x40, 0x30, 0x50, 0x60, 0x70):
                for cutoff in (0, 1024, 2047):
                    fields = _filter_shape_formula(session.run(f"filtershape:{mode},{cutoff}"))
                    (got_mode, got_cutoff, top, bottom, y,
                     lp_on, lp_top, lp_bottom, bp_on, bp_top, bp_bottom,
                     hp_on, hp_top, hp_bottom) = fields
                    self.assertEqual((got_mode, got_cutoff), (mode, cutoff))
                    span = bottom - top - 1
                    expected_y = bottom - 1 - int(cutoff * span / 2047 + 0.5)
                    self.assertEqual(y, expected_y)
                    self.assertEqual((lp_on, bp_on, hp_on),
                                     (bool(mode & 0x10), bool(mode & 0x20), bool(mode & 0x40)))
                    self.assertEqual((lp_top, lp_bottom), (y, bottom - 1))
                    half = (bottom - top) // 6
                    self.assertEqual((bp_top, bp_bottom),
                                     (max(top, y - half), min(bottom - 1, y + half)))
                    self.assertEqual((hp_top, hp_bottom), (top, y))

            for mode in (0x00, 0x10, 0x20, 0x40, 0x70):
                with self.subTest(mode=f"{mode:02X}"):
                    _select_filter_at(session, 0)
                    _set_filter_mode(session, f0, mode)
                    rows = [entry for entry in _filter_shapes(session.run("filtershape"))
                            if entry[0] == f0 + 1]
                    self.assertEqual(len(rows), 1)
                    self.assertEqual(rows[0][1], mode)
                    self.assertEqual(rows[0][-1], 1)
                    self.assertEqual(
                        _sweep_row(session.run("sweepdump:F"), f0)[0] & 0x70, mode
                    )
                    self.assertEqual(
                        _sweep_row(session.run("sweepdump:F"), f0 + 1), canonical[1]
                    )

                    _, _, x0, x1, _, _, _, y1, _ = rows[0]
                    session.run(f"click:{(x0 + x1) // 2},{FILTER_BOTTOM_ROW}")
                    boundary = [_cursor_at(session, x1, y)
                                for y in range(FILTER_TOP_ROW, FILTER_BOTTOM_ROW + 1)]
                    self.assertIn(2, boundary)  # exactly one cutoff/slope dot
                    self.assertIn(1, boundary)  # remaining boundary resizes duration
                    session.run(f"hover:{x1},{y1}")
                    self.assertRegex(session.run("soundstate"), r"cursor=2 ")
                    before = _sweep_row(session.run("sweepdump:F"), f0 + 1)
                    session.run(f"drag:{x1},{y1},{x1},{y1 - 1}")
                    after = _sweep_row(session.run("sweepdump:F"), f0 + 1)
                    self.assertEqual(after[0], before[0])
                    self.assertNotEqual(after[1], before[1])
                    self.assertEqual(after[2:], before[2:])
                    session.run("key:Ctrl-z")
                    self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 1), before)

    def test_phase5_control_hover_tooltips_and_zoom_shortcut_equivalence(self) -> None:
        """R59: native Alt-H status help identifies every equivalent control."""
        with _master_session() as session:
            def assert_hover(action: str, expected: str) -> None:
                x0, x1, y, _ = _control_bounds(session, action)
                session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
                row = _screen_row(session.run("screendump"), 2)
                self.assertEqual(row[:118].strip(), expected)

            for action, expected in (
                ("se_zoom_out", "Zoom out  Ctrl-Shift-O"),
                ("se_zoom_in", "Zoom in  Ctrl-Shift-I"),
                ("se_fit", "Fit the full sound  Ctrl-Shift-A / Home"),
                ("se_selection", "Zoom to the time selection  Ctrl-Shift-G / End"),
            ):
                with self.subTest(expected=expected):
                    assert_hover(action, expected)

            _new_isolated_wave(session)
            for action, expected in (
                ("se_add", "Insert the selected programme row  Ctrl-Shift-J / Insert"),
                ("se_delete", "Delete the selected programme row  Ctrl-Shift-D / Delete"),
                ("se_wave_prev", "Select the previous wave row  Shift-PageUp"),
                ("se_wave_next", "Select the next wave row  Shift-PageDown"),
                ("se_wave_loop", "Set the wave loop target  Ctrl-L"),
                ("se_lp", "Toggle Filter low-pass  Ctrl-Shift-L"),
                ("se_bp", "Toggle Filter band-pass  Ctrl-Shift-B"),
                ("se_hp", "Toggle Filter high-pass  Ctrl-Shift-H"),
                ("se_route", "Cycle Filter channel route  Ctrl-Shift-R"),
            ):
                assert_hover(action, expected)

            _select_pulse_at(session, 0)
            assert_hover("se_stop", "Stop the selected programme  Ctrl-Shift-S")
            assert_hover("se_carry", "Toggle selected sweep carry value  Ctrl-I")
            _select_filter_at(session, 1)
            assert_hover("se_type", "Toggle Filter sweep/config row type  Ctrl-T")
            assert_hover("se_carry", "Toggle selected sweep carry value  Ctrl-I")
            _select_filter_at(session, 0)
            assert_hover("se_res_down", "Decrease Filter resonance  Ctrl-Shift-3")
            assert_hover("se_res_up", "Increase Filter resonance  Ctrl-Shift-4")

            # The native status timeout is not extended by stationary hover.
            x0, x1, y, _ = _control_bounds(session, "se_zoom_out")
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            session.run("tick:89")
            self.assertIn("Zoom out", _screen_row(session.run("screendump"), 2))
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            session.run("tick:1")
            self.assertEqual(_screen_row(session.run("screendump"), 2)[:118].strip(), "")
            x0, x1, y, _ = _control_bounds(session, "se_zoom_in")
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            self.assertIn("Zoom in", _screen_row(session.run("screendump"), 2))

            # Alt-H is the canonical global help-text preference.
            session.run("key:Alt-h")
            session.run("tick:90")
            x0, x1, y, _ = _control_bounds(session, "se_fit")
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            self.assertEqual(_screen_row(session.run("screendump"), 2)[:118].strip(), "")
            session.run("key:Alt-h")
            session.run("tick:90")
            x0, x1, y, _ = _control_bounds(session, "se_zoom_out")
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            self.assertIn("Zoom out", _screen_row(session.run("screendump"), 2))

            # Menus and dialogs own hover; the background editor must stay silent.
            session.run("tick:90")
            session.run("key:ESC")
            x0, x1, y, _ = _control_bounds(session, "se_zoom_in")
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            self.assertNotIn("Zoom in", _screen_row(session.run("screendump"), 2))
            session.run("key:ESC")
            w0 = _instrument_bytes(session.run("insbytes"))[7]
            _select_wave_row_on_frequency_graph(session, 0, w0)
            _click_control(session, BTN_W1)
            session.run(f"hover:{(x0 + x1 - 1) // 2},{y}")
            self.assertNotIn("Zoom in", _screen_row(session.run("screendump"), 2))
            session.run("key:ESC")

        with _master_session() as mouse, _master_session() as keyboard:
            _click_control(mouse, BTN_ZOOMOUT)
            keyboard.run("key:Ctrl-Shift-o")
            mouse_view = re.search(r"view=([^ ]+)", mouse.run("soundstate")).group(1)
            key_view = re.search(r"view=([^ ]+)", keyboard.run("soundstate")).group(1)
            self.assertEqual(key_view, mouse_view)

    def test_phase5_mouse_and_keyboard_control_matrix_match(self) -> None:
        """R59: keyboard routes call the same state transitions as all edit buttons."""
        with _master_session() as mouse, _master_session() as keyboard:
            def same_sound(label: str) -> None:
                self.assertEqual(
                    _full_sound_dump(keyboard.run("sounddump")),
                    _full_sound_dump(mouse.run("sounddump")), label,
                )

            # View buttons.
            for x, key in ((40, "Ctrl-Shift-o"), (44, "Ctrl-Shift-i"),
                           (50, "Ctrl-Shift-a")):
                _click_control(mouse, x)
                keyboard.run(f"key:{key}")
                self.assertEqual(
                    re.search(r"view=([^ ]+)", keyboard.run("soundstate")).group(1),
                    re.search(r"view=([^ ]+)", mouse.run("soundstate")).group(1), key,
                )

            # New, wave dialogs/navigation and row operations.
            _click_control(mouse, BTN_NEW)
            keyboard.run("key:Ctrl-Shift-n")
            same_sound("New")
            for x, key, prompt in (
                (BTN_W1, "Ctrl-Shift-1", "Wave 1: $"),
                (BTN_W2, "Ctrl-Shift-2", "Wave 2: $"),
                (BTN_LOOP, "Ctrl-l", "Loop target: $"),
            ):
                _click_control(mouse, x)
                keyboard.run(f"key:{key}")
                self.assertIn(prompt, mouse.run("screendump"))
                self.assertIn(prompt, keyboard.run("screendump"))
                mouse.run("key:ESC")
                keyboard.run("key:ESC")
            _click_control(mouse, BTN_ADD)
            keyboard.run("key:Ctrl-Shift-j")
            same_sound("Add")
            _click_control(mouse, BTN_PREV)
            keyboard.run("key:Shift-PAGEUP")
            self.assertEqual(mouse.run("screendump").split("screen22:")[1].splitlines()[0],
                             keyboard.run("screendump").split("screen22:")[1].splitlines()[0])
            _click_control(mouse, BTN_NEXT)
            keyboard.run("key:Shift-PAGEDOWN")
            _click_control(mouse, BTN_DEL)
            keyboard.run("key:Ctrl-Shift-d")
            same_sound("Del")

            # Pulse Stop/Carry and Filter Type/Res/mode/route.
            _select_pulse_at(mouse, 0)
            _select_pulse_at(keyboard, 0)
            _click_control(mouse, 80)
            keyboard.run("key:Ctrl-Shift-s")
            same_sound("Stop")
            _click_control(mouse, 94)
            keyboard.run("key:Ctrl-i")
            same_sound("Carry")

            _select_filter_at(mouse, 0)
            _select_filter_at(keyboard, 0)
            for action, key, label in (
                ("se_lp", "Ctrl-Shift-l", "LP"), ("se_bp", "Ctrl-Shift-b", "BP"),
                ("se_hp", "Ctrl-Shift-h", "HP"),
                ("se_route", "Ctrl-Shift-r", "route"),
                ("se_res_up", "Ctrl-Shift-4", "Res+"),
                ("se_res_down", "Ctrl-Shift-3", "Res-"),
                ("se_type", "Ctrl-t", "Type"),
            ):
                _click_action(mouse, action)
                keyboard.run(f"key:{key}")
                same_sound(label)

            # Selection zoom uses the same pre-existing selection in both sessions.
            for session in (mouse, keyboard):
                session.run("drag:50,7,70,7")
            _click_action(mouse, "se_selection")
            keyboard.run("key:Ctrl-Shift-g")
            self.assertEqual(
                re.search(r"view=([^ ]+)", keyboard.run("soundstate")).group(1),
                re.search(r"view=([^ ]+)", mouse.run("soundstate")).group(1),
            )

    def test_phase4_filter_audition_matrix_and_release_rerender(self) -> None:
        """R52-R55: route/mode/voice PCM and reSID WYSIWYG without loop setup."""
        with _master_session() as session:
            _new_isolated_wave(session)
            ins = _instrument_bytes(session.run("insbytes"))
            f0 = ins[4]
            _set_selected_wave_row(session, 0x00, 0x41)  # audible saw + gate
            session.run("click:10,9")                    # sustain F
            for _ in range(15):
                session.run("key:RIGHT")
            _select_rows_duration(session)

            # Stable audible filter state: cutoff $100, resonance 3, LP, route 1.
            _select_filter_at(session, 0)
            for _ in range(0x20):
                session.run("key:Ctrl-Shift-6")
            for _ in range(3):
                _click_control(session, BTN_RES_PLUS)
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0),
                             (0x90, 0x31, 0x20, 0x00))

            # Give the neutral SWEEP a four-row interior for the later release-only
            # mouse rerender check; its zero slope keeps cutoff constant.
            _select_filter_at(session, 1)
            boundary_y = _filter_boundary_row(session, 2)
            session.run(
                f"drag:{_plot_x_for_tick(session, 2)},{boundary_y},"
                f"{_plot_x_for_tick(session, 41)},{boundary_y}"
            )
            _select_filter_at(session, 0)

            def audition(key: str, voice: int, note: int, mode: int, route: int):
                session.run(f"jamrender:{key},80")
                capture = _capture_fields(session.run("capturestate"))
                recording = session.run(f"recdump:{voice}")
                state = session.run("soundstate")
                session.run(f"keyup:{key}")
                self.assertEqual(
                    {name: capture[name] for name in
                     ("gateOn", "gateOff", "gateHigh", "frameSamples", "instr", "voice")},
                    {
                        "gateOn": 3, "gateOff": 43, "gateHigh": 40,
                        "frameSamples": 480, "instr": 0, "voice": voice + 1,
                    },
                )
                self.assertGreaterEqual(capture["gates"], capture["gateHigh"])
                self.assertGreater(capture["samples"], capture["gateOff"] * 480)
                self.assertIn(capture["onsetSample"], (1439, 1440))
                self.assertRegex(str(capture["hash"]), r"^[0-9a-f]{8}$")
                self.assertGreater(capture["peak"], 0)
                self.assertGreater(capture["sumAbs"], 0)
                # `preview=A/B` is instrument/note, not voice/note. Voice ownership
                # is independently proven by capture.voice and recdump:v above.
                self.assertRegex(state, rf"preview=0/{note}")
                self.assertIn(f"Keyjam Ch {voice + 1}", session.run("screendump"))
                for field, expected in (("mode", mode), ("resonance", 3),
                                        ("route", route), ("cutoff", 0x100)):
                    values = _recorded_hex_values(
                        recording, voice, field, 10 if field == "cutoff" else 16
                    )
                    self.assertTrue(values)
                    with self.subTest(voice=voice + 1, mode=mode, route=route,
                                      field=field):
                        self.assertEqual(set(values), {expected}, field)
                ctrl = _recorded_hex_values(recording, voice, "ctrl")
                self.assertIn(0x41, ctrl)
                self.assertIn(0x40, ctrl)
                return capture, recording

            # Voice 1: mask 0 bypasses, mask 1 filters. LP/BP/HP each changes PCM.
            _set_filter_route(session, f0, 0x00)
            bypass1, _ = audition("q", 0, 48, 0x10, 0x00)
            _set_filter_route(session, f0, 0x01)
            lp1, _ = audition("q", 0, 48, 0x10, 0x01)
            self.assertNotEqual(lp1["hash"], bypass1["hash"])
            self.assertNotEqual(lp1["sumAbs"], bypass1["sumAbs"])
            _set_filter_mode(session, f0, 0x20)
            bp1, _ = audition("q", 0, 48, 0x20, 0x01)
            _set_filter_mode(session, f0, 0x40)
            hp1, _ = audition("q", 0, 48, 0x40, 0x01)
            self.assertEqual(len({lp1["hash"], bp1["hash"], hp1["hash"]}), 3)

            # Voice 2: mask 1 bypasses it; mask 2 filters it.
            _set_filter_mode(session, f0, 0x10)
            session.run("click:10,19")
            session.run("key:RIGHT")
            _set_filter_route(session, f0, 0x01)
            bypass2, _ = audition("q", 1, 48, 0x10, 0x01)
            _set_filter_route(session, f0, 0x02)
            filtered2, _ = audition("q", 1, 48, 0x10, 0x02)
            self.assertNotEqual(filtered2["hash"], bypass2["hash"])

            # Voice 3: mask 2 bypasses it; mask 4 filters it.
            session.run("key:RIGHT")
            _set_filter_route(session, f0, 0x02)
            bypass3, _ = audition("q", 2, 48, 0x10, 0x02)
            _set_filter_route(session, f0, 0x04)
            filtered3, _ = audition("q", 2, 48, 0x10, 0x04)
            self.assertNotEqual(filtered3["hash"], bypass3["hash"])

            # Mask 7 filters all voices without changing resonance 3.
            _set_filter_route(session, f0, 0x07)
            session.run("key:LEFT")
            session.run("key:LEFT")
            all1, _ = audition("q", 0, 48, 0x10, 0x07)
            session.run("key:RIGHT")
            all2, _ = audition("q", 1, 48, 0x10, 0x07)
            session.run("key:RIGHT")
            all3, _ = audition("q", 2, 48, 0x10, 0x07)
            self.assertEqual(len({all1["hash"], all2["hash"], all3["hash"]}), 3)
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0)[1], 0x37)

            # Return to voice 1 and audition C-4, G-3, D-2. D-2 is the baseline.
            session.run("key:LEFT")
            session.run("key:LEFT")
            c4, c4rec = audition("q", 0, 48, 0x10, 0x07)
            g3, g3rec = audition("b", 0, 43, 0x10, 0x07)
            session.run("key:KP_DIV")
            d2, d2rec = audition("x", 0, 26, 0x10, 0x07)
            self.assertEqual(len({c4["hash"], g3["hash"], d2["hash"]}), 3)
            frequencies = [
                _recorded_hex_values(recording, 0, "freq")[1]
                for recording in (c4rec, g3rec, d2rec)
            ]
            self.assertEqual(len(set(frequencies)), 3)
            self.assertRegex(session.run("soundstate"), r"preview=0/26")

            # A drag keeps the D-2 recording and viewport until release, then silently
            # rerenders exactly once from D-2 without another keyjam.
            before_state = session.run("soundstate")
            before_trigger = int(re.search(r"trigger=(\d+)", before_state).group(1))
            before_view = re.search(r"view=([^ ]+)", before_state).group(1)
            x0 = _plot_x_for_tick(session, 10)
            session.run(f"press:{x0},{FILTER_GRAPH_ROW}")
            session.run(f"move:{x0},{FILTER_TOP_ROW}")
            during = session.run("soundstate")
            self.assertEqual(int(re.search(r"trigger=(\d+)", during).group(1)),
                             before_trigger)
            self.assertEqual(re.search(r"view=([^ ]+)", during).group(1), before_view)
            session.run(f"release:{x0},{FILTER_TOP_ROW}")
            after_state = session.run("soundstate")
            self.assertEqual(int(re.search(r"trigger=(\d+)", after_state).group(1)),
                             before_trigger + 1)
            self.assertEqual(re.search(r"view=([^ ]+)", after_state).group(1), before_view)
            self.assertRegex(after_state, r"preview=0/26")

    def test_phase4b_filter_rows_to_four_ticks_clamps_and_undoes(self) -> None:
        """R51/R54: raw duration resize preserves endpoint and clamps only block 1."""
        with _master_session() as session:
            f0, _, _ = _build_exact_filter_three_blocks(session)
            canonical = [
                (0x90, 0x31, 0x20, 0x00),
                (0x27, 0x10, 0xFF, 0x00),
                (0xA0, 0x80, 0xFF, 0x00),
                (0x13, 0xF8, 0xFF, 0x00),
                (0xC0, 0xC7, 0xFF, 0x00),
                (0x09, 0x04, 0xFF, f0 + 2),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 6), canonical)

            session.run("click:10,21")
            session.run("key:LEFT")
            _click_control(session, BTN_FIT)
            _select_filter_at(session, 1)
            anchor = _filter_shape_frames(session.run("filtershape"), f0 + 1)[0]
            target_x = _pointer_cell_for_duration(session, 4, anchor_tick=anchor)
            edge_x, y = _filter_duration_edge(session, f0 + 1)
            session.run(
                f"drag:{edge_x},{y},{target_x},{y}"
            )
            resized = canonical.copy()
            resized[1] = (0x03, 0x7F, 0xFF, 0x00)
            self.assertEqual(_sweep_rows(session, "F", f0, 6), resized)
            chrome = session.run("screendump")
            self.assertIn(f"Filter ${f0 + 1:02X}: 4 Ticks", chrome)
            self.assertRegex(chrome.lower(), r"clamp|limit")

            session.run("key:Ctrl-z")
            self.assertEqual(_sweep_rows(session, "F", f0, 6), canonical)
            chrome = session.run("screendump")
            self.assertIn("Duration unit  Ticks", chrome)
            self.assertIn(f"Filter ${f0 + 1:02X}: 40 Ticks", chrome)

    def test_phase4b_filter_logical_delete_contracts_loop_and_two_undos(self) -> None:
        """R51/R53: logical CONFIG+SWEEP deletion contracts loop, then produces END."""
        with _master_session() as session:
            f0, p0, w0 = _build_exact_filter_three_blocks(session)
            original = [
                (0x90, 0x31, 0x20, 0x00),
                (0x27, 0x10, 0xFF, 0x00),
                (0xA0, 0x80, 0xFF, 0x00),
                (0x13, 0xF8, 0xFF, 0x00),
                (0xC0, 0xC7, 0xFF, 0x00),
                (0x09, 0x04, 0xFF, f0 + 2),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 6), original)

            _click_control(session, BTN_FIT)
            _select_filter_at(session, 42)
            _click_control(session, BTN_DEL)
            compacted = [
                (0x90, 0x31, 0x20, 0x00),
                (0x27, 0x10, 0xFF, 0x00),
                (0xC0, 0xC7, 0xFF, 0x00),
                (0x09, 0x04, 0xFF, f0 + 2),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 4), compacted)
            self.assertRegex(
                session.run("screendump"),
                rf"Filter \${f0:02X} LOOP \${f0 + 3:02X}->\${f0 + 2:02X}:",
            )

            _click_control(session, BTN_FIT)
            _select_filter_at(session, 42)
            _click_control(session, BTN_DEL)
            ended = [(0x90, 0x31, 0x20, 0x00), (0x27, 0x10, 0xFF, 0x7F)]
            self.assertEqual(_sweep_rows(session, "F", f0, 2), ended)
            self.assertRegex(
                session.run("screendump"), rf"Filter \${f0:02X} END \${f0 + 1:02X}:"
            )
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[4:8],
                             [f0, p0, 0, w0])

            session.run("key:Ctrl-z")
            self.assertEqual(_sweep_rows(session, "F", f0, 4), compacted)
            self.assertRegex(
                session.run("screendump"),
                rf"Filter \${f0:02X} LOOP \${f0 + 3:02X}->\${f0 + 2:02X}:",
            )
            session.run("key:Ctrl-z")
            self.assertEqual(_sweep_rows(session, "F", f0, 6), original)
            self.assertRegex(
                session.run("screendump"),
                rf"Filter \${f0:02X} LOOP \${f0 + 5:02X}->\${f0 + 2:02X}:",
            )
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[4:8],
                             [f0, p0, 0, w0])

    def test_canonical_plan_defines_all_requirements_and_sequence(self) -> None:
        text = PLAN.read_text()
        for number in range(40, 73):
            self.assertIn(f"R{number}", text)
        self.assertIn("## 6. Ordered master usage sequence", text)
        self.assertIn("## 4. Canonical byte oracles", text)

    def test_master_sound_creation_sequence(self) -> None:
        """R40-R59: one uninterrupted master session, in the frozen order."""
        with _master_session() as session:
            self.assertIn("serve: ready", session.startup_output)
            self.assertRegex(session.run("soundstate"), r"stepTicks=10 .*preview=0/48")
            self.assertIn("Keyjam Ch 1", session.run("screendump"))

            # Steps 5-6: Rows are explicit and physical key-up cannot shorten 4 rows.
            session.run("click:10,21")
            session.run("key:RIGHT")
            session.run("click:10,20")
            session.run("key:LEFT")
            chrome = session.run("screendump")
            self.assertIn("Gate high 4 Rows = 40 Ticks", chrome)
            session.run("jamrender:q,5")
            session.run("keyup:q")
            session.run("scopefill:20")
            self.assertEqual(_capture_fields(session.run("capturestate"))["gateHigh"], 40)
            session.run("jamrender:b,80")
            self.assertEqual(_capture_fields(session.run("capturestate"))["gateHigh"], 40)
            session.run("keyup:b")

            # Step 7: allocate the private programmes once; all later work keeps them.
            before = _full_sound_dump(session.run("sounddump"))
            w0 = _new_isolated_wave(session)
            ins = _instrument_bytes(session.run("insbytes"))
            f0, p0 = ins[4], ins[5]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), 2),
                [(w0, 0x00, 0x00), (w0 + 1, 0x7E, 0x00)],
            )
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0),
                             (0x00, 0x00, 0x00, 0x7F))
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0),
                             (0x90, 0x01, 0x00, 0x00))
            _master_three_note_checkpoint(self, session, "step 7 / R43")

            # Step 8: all four ADSR values originate from graph-handle gestures.
            _drag_adsr_to_8888(session)
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[:2],
                             [0x88, 0x88])
            _master_three_note_checkpoint(self, session, "step 8 / ADSR 8888")

            # Step 9: wave checkpoint A.
            _set_selected_wave_row(session, 0xB0, 0x81)
            for w1, w2 in ((0x00, 0x04), (0x02, 0x41),
                           (0x01, 0x41), (0x00, 0x41)):
                _click_control(session, BTN_ADD)
                _set_selected_wave_row(session, w1, w2)
            expected_a = [
                (w0 + 0, 0xB0, 0x81), (w0 + 1, 0x00, 0x04),
                (w0 + 2, 0x02, 0x41), (w0 + 3, 0x01, 0x41),
                (w0 + 4, 0x00, 0x41), (w0 + 5, 0x7E, 0x00),
            ]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(expected_a)),
                expected_a,
            )
            _master_three_note_checkpoint(self, session, "step 9 / wave A")

            # Step 10: mutate the same rows into checkpoint B and its absolute loop.
            _mutate_wave_a_to_b(session, w0)
            expected_b = [
                (w0 + 0, 0xC0, 0x81), (w0 + 1, 0x00, 0x02),
                (w0 + 2, 0x00, 0x41), (w0 + 3, 0x00, 0x0C),
                (w0 + 4, 0x0C, 0x41), (w0 + 5, 0x00, 0x0C),
                (w0 + 6, 0x7F, w0 + 2),
            ]
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(expected_b)),
                expected_b,
            )
            _master_three_note_checkpoint(self, session, "step 10 / wave B")

            # Step 11: readjust A/D/R by mouse and sustain through the visible fine key.
            _drag_adsr_to_9327(session)
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[:2],
                             [0x93, 0x27])
            _master_three_note_checkpoint(self, session, "step 11 / ADSR 9327")
            _assert_only_active_sound_changed(
                self, before, _full_sound_dump(session.run("sounddump")),
                w0, p0, f0,
            )

            # Steps 12-13: select the preallocated pulse row and author block 1.
            _click_control(session, BTN_FIT)
            _select_pulse_at(session, 0)
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0),
                             (0x00, 0x00, 0x00, 0x7F))
            y = _pulse_boundary_row(session, 1)
            session.run(
                f"drag:{_plot_x_for_tick(session, 1)},{y},"
                f"{_plot_x_for_tick(session, 40)},{y}"
            )
            dot_y = _pulse_dot_row(session, 40)
            session.run(
                f"drag:{_plot_x_for_tick(session, 40)},{dot_y},"
                f"{_plot_x_for_tick(session, 40)},{PULSE_TOP_ROW}"
            )
            self.assertEqual(_sweep_rows(session, "P", p0, 1),
                             [(0x27, 0x66, 0x00, 0x7F)])
            _master_three_note_checkpoint(self, session, "step 13 / pulse block 1")

            # Step 14: add the 8-row descending, two-wrap block.
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_CARRY)
            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)
            y = _pulse_boundary_row(session, 80)
            session.run(
                f"drag:{_plot_x_for_tick(session, 80)},{y},"
                f"{_plot_x_for_tick(session, 120)},{y}"
            )
            dot_y = _pulse_dot_row(session, 120)
            session.run(
                f"drag:{_plot_x_for_tick(session, 120)},{dot_y},"
                f"{_plot_x_for_tick(session, 120)},{PULSE_GRAPH_ROW}"
            )
            _fine_adjust_pulse_slope(session, p0 + 1, -0x67)
            self.assertEqual(
                _sweep_rows(session, "P", p0, 2),
                [(0x27, 0x66, 0x00, 0x00), (0xCF, 0x67, 0xFF, 0x7F)],
            )
            self.assertIn("Wraps -2", session.run("screendump"))
            _master_three_note_checkpoint(self, session, "step 14 / pulse block 2")

            # Step 15: add the fixed $400 two-row block, still stopped.
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)
            y = _pulse_boundary_row(session, 200)
            session.run(
                f"drag:{_plot_x_for_tick(session, 200)},{y},"
                f"{_plot_x_for_tick(session, 140)},{y}"
            )
            session.run(
                f"drag:{_plot_x_for_tick(session, 130)},{PULSE_GRAPH_ROW},"
                f"{_plot_x_for_tick(session, 130)},{PULSE_BOUNDARY_ROW}"
            )
            _fine_adjust_pulse_start_byte(session, p0 + 2, 0x04)
            _fine_adjust_pulse_slope(session, p0 + 2, 0)
            pulse_three = [
                (0x27, 0x66, 0x00, 0x00),
                (0xCF, 0x67, 0xFF, 0x00),
                (0x13, 0x00, 0x04, 0x7F),
            ]
            self.assertEqual(_sweep_rows(session, "P", p0, 3), pulse_three)
            _master_three_note_checkpoint(self, session, "step 15 / pulse block 3")

            # Step 16: loop block 3 back to block 2 through the visible top grip.
            session.run(
                f"drag:{_plot_x_for_tick(session, 140)},{PULSE_TOP_ROW},"
                f"{_plot_x_for_tick(session, 41)},{PULSE_TOP_ROW}"
            )
            pulse_three[-1] = (0x13, 0x00, 0x04, p0 + 1)
            self.assertEqual(_sweep_rows(session, "P", p0, 3), pulse_three)
            self.assertRegex(
                session.run("screendump"),
                rf"Pulse \${p0:02X} LOOP \${p0 + 2:02X}->\${p0 + 1:02X}:",
            )
            _master_three_note_checkpoint(self, session, "step 16 / pulse loop")

            # Step 17: block 1 becomes four raw ticks and visibly clamps its slope.
            session.run("click:10,21")
            session.run("key:LEFT")
            _click_control(session, BTN_FIT)
            _select_pulse_at(session, 1)
            target_x = _pointer_cell_for_duration(session, 4)
            y = _pulse_boundary_row(session, 40)
            edge_x = _plot_x_for_tick(session, 40)
            session.run(f"drag:{edge_x},{y},{target_x},{y}")
            pulse_resized = [
                (0x03, 0xFF, 0x00, 0x00),
                (0xCF, 0x67, 0xFF, 0x00),
                (0x13, 0x00, 0x04, p0 + 1),
            ]
            self.assertEqual(_sweep_rows(session, "P", p0, 3), pulse_resized)
            self.assertRegex(session.run("screendump").lower(), r"clamp|limit")
            _master_three_note_checkpoint(self, session, "step 17 / pulse raw ticks")

            # Steps 18-19: contraction to self, then END, with one structural undo.
            _select_pulse_at(session, 10)
            _click_control(session, BTN_DEL)
            pulse_compacted = [
                (0x03, 0xFF, 0x00, 0x00),
                (0x13, 0x00, 0x04, p0 + 1),
            ]
            self.assertEqual(_sweep_rows(session, "P", p0, 2), pulse_compacted)
            self.assertRegex(
                session.run("screendump"),
                rf"Pulse \${p0:02X} LOOP \${p0 + 1:02X}->\${p0 + 1:02X}:",
            )
            _master_three_note_checkpoint(self, session, "step 18 / pulse contract")
            _select_pulse_at(session, 10)
            _click_control(session, BTN_DEL)
            self.assertEqual(_sweep_rows(session, "P", p0, 1),
                             [(0x03, 0xFF, 0x00, 0x7F)])
            self.assertRegex(session.run("screendump"),
                             rf"Pulse \${p0:02X} END \${p0:02X}:")
            session.run("key:Ctrl-z")
            self.assertEqual(_sweep_rows(session, "P", p0, 2), pulse_compacted)
            _master_three_note_checkpoint(self, session, "step 19 / pulse END undo")

            # Steps 20-21: return to Rows and build logical filter block 1.
            session.run("click:10,21")
            session.run("key:RIGHT")
            _click_control(session, BTN_FIT)
            _select_filter_at(session, 0)
            self.assertEqual(
                _sweep_rows(session, "F", f0, 2),
                [(0x90, 0x01, 0x00, 0x00), (0x00, 0x00, 0xFF, 0x7F)],
            )
            res_y = _filter_dot_row(session, 0)
            session.run(
                f"drag:{_plot_x_for_tick(session, 0)},{res_y},"
                f"{_plot_x_for_tick(session, 0) + 1},{FILTER_BOTTOM_ROW}"
            )
            _click_control(session, BTN_RES_PLUS)
            _click_control(session, BTN_RES_PLUS)
            for _ in range(0x20):
                session.run("key:Ctrl-Shift-6")
            _select_filter_at(session, 1)
            y = _filter_boundary_row(session, 2)
            session.run(
                f"drag:{_plot_x_for_tick(session, 2)},{y},"
                f"{_plot_x_for_tick(session, 41)},{y}"
            )
            dot_y = _filter_dot_row(session, 41)
            session.run(
                f"drag:{_plot_x_for_tick(session, 41)},{dot_y},"
                f"{_plot_x_for_tick(session, 41)},{FILTER_TOP_ROW}"
            )
            _fine_adjust_filter_slope(session, f0 + 1, 0x10)
            filter_one = [
                (0x90, 0x31, 0x20, 0x00), (0x27, 0x10, 0xFF, 0x7F),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 2), filter_one)
            _master_three_note_checkpoint(self, session, "step 21 / filter block 1")

            # Step 22: append CONFIG+SWEEP block 2 atomically.
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)
            _select_filter_at(session, 41)
            _click_action(session, "se_lp")
            _click_action(session, "se_bp")
            for _ in range(5):
                _click_control(session, BTN_RES_PLUS)
            _set_filter_route(session, f0 + 2, 0x00)
            _select_filter_at(session, 42)
            y = _filter_boundary_row(session, 43)
            session.run(
                f"drag:{_plot_x_for_tick(session, 43)},{y},"
                f"{_plot_x_for_tick(session, 62)},{y}"
            )
            dot_y = _filter_dot_row(session, 62)
            session.run(
                f"drag:{_plot_x_for_tick(session, 62)},{dot_y},"
                f"{_plot_x_for_tick(session, 62)},{FILTER_BOTTOM_ROW}"
            )
            _fine_adjust_filter_slope(session, f0 + 3, -8)
            filter_two = [
                (0x90, 0x31, 0x20, 0x00), (0x27, 0x10, 0xFF, 0x00),
                (0xA0, 0x80, 0xFF, 0x00), (0x13, 0xF8, 0xFF, 0x7F),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 4), filter_two)
            _master_three_note_checkpoint(self, session, "step 22 / filter block 2")

            # Steps 23-24: add block 3, then loop its SWEEP to block 2.
            _click_control(session, BTN_ADD)
            _click_control(session, BTN_FIT)
            _click_control(session, BTN_ZOOMOUT)
            _select_filter_at(session, 62)
            _click_action(session, "se_bp")
            _click_action(session, "se_hp")
            for _ in range(4):
                _click_control(session, BTN_RES_PLUS)
            _set_filter_route(session, f0 + 4, 0x07)
            _select_filter_at(session, 64)
            y = _filter_boundary_row(session, 64)
            session.run(
                f"drag:{_plot_x_for_tick(session, 64)},{y},"
                f"{_plot_x_for_tick(session, 73)},{y}"
            )
            dot_y = _filter_dot_row(session, 73)
            session.run(
                f"drag:{_plot_x_for_tick(session, 73)},{dot_y},"
                f"{_plot_x_for_tick(session, 73)},{FILTER_TOP_ROW}"
            )
            _fine_adjust_filter_slope(session, f0 + 5, 4)
            filter_three = [
                (0x90, 0x31, 0x20, 0x00), (0x27, 0x10, 0xFF, 0x00),
                (0xA0, 0x80, 0xFF, 0x00), (0x13, 0xF8, 0xFF, 0x00),
                (0xC0, 0xC7, 0xFF, 0x00), (0x09, 0x04, 0xFF, 0x7F),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 6), filter_three)
            shapes = {row: (mode, handles) for row, mode, *_, handles
                      in _filter_shapes(session.run("filtershape"))}
            self.assertEqual(
                (shapes.get(f0 + 1), shapes.get(f0 + 3), shapes.get(f0 + 5)),
                ((0x10, 1), (0x20, 1), (0x40, 1)),
            )
            _master_three_note_checkpoint(self, session, "step 23 / filter block 3")
            _select_filter_at(session, 62)
            grip_x = _filter_loop_grip_x(session, 73)
            session.run(
                f"drag:{grip_x},{FILTER_TOP_ROW},"
                f"{_plot_x_for_tick(session, 41)},{FILTER_TOP_ROW}"
            )
            filter_three[-1] = (0x09, 0x04, 0xFF, f0 + 2)
            self.assertEqual(_sweep_rows(session, "F", f0, 6), filter_three)
            _master_three_note_checkpoint(self, session, "step 24 / filter loop")

            # Step 25: resize the first SWEEP to four raw ticks and preserve endpoint.
            session.run("click:10,21")
            session.run("key:LEFT")
            _click_control(session, BTN_FIT)
            _select_filter_at(session, 1)
            anchor = _filter_shape_frames(session.run("filtershape"), f0 + 1)[0]
            target_x = _pointer_cell_for_duration(session, 4, anchor_tick=anchor)
            edge_x, y = _filter_duration_edge(session, f0 + 1)
            session.run(f"drag:{edge_x},{y},{target_x},{y}")
            filter_resized = filter_three.copy()
            filter_resized[1] = (0x03, 0x7F, 0xFF, 0x00)
            self.assertEqual(_sweep_rows(session, "F", f0, 6), filter_resized)
            self.assertRegex(session.run("screendump").lower(), r"clamp|limit")
            _master_three_note_checkpoint(self, session, "step 25 / filter raw ticks")

            # Steps 26-27: delete logical CONFIG+SWEEP pairs, contract, END, undo.
            _click_control(session, BTN_FIT)
            _select_filter_at(session, 6)
            _click_control(session, BTN_DEL)
            filter_compacted = [
                (0x90, 0x31, 0x20, 0x00), (0x03, 0x7F, 0xFF, 0x00),
                (0xC0, 0xC7, 0xFF, 0x00), (0x09, 0x04, 0xFF, f0 + 2),
            ]
            self.assertEqual(_sweep_rows(session, "F", f0, 4), filter_compacted)
            _master_three_note_checkpoint(self, session, "step 26 / filter contract")
            _click_control(session, BTN_FIT)
            _select_filter_at(session, 6)
            _click_control(session, BTN_DEL)
            self.assertEqual(
                _sweep_rows(session, "F", f0, 2),
                [(0x90, 0x31, 0x20, 0x00), (0x03, 0x7F, 0xFF, 0x7F)],
            )
            self.assertRegex(session.run("screendump"),
                             rf"Filter \${f0:02X} END \${f0 + 1:02X}:")
            session.run("key:Ctrl-z")
            self.assertEqual(_sweep_rows(session, "F", f0, 4), filter_compacted)
            _master_three_note_checkpoint(self, session, "step 27 / filter END undo")

            # Steps 28-31: route-mask audibility follows the selected keyjam voice.
            if "Octave 2" in session.run("screendump"):
                session.run("key:KP_MUL")
            _click_control(session, BTN_FIT)
            _select_filter_at(session, 6)  # surviving HP block, governed by resonance-C CONFIG

            def routing_audition(voice: int, mask: int) -> dict[str, int | str]:
                _select_filter_at(session, 6)
                _set_filter_route(session, f0 + 2, mask)
                session.run("jamrender:q,80")
                capture = _capture_fields(session.run("capturestate"))
                recording = session.run(f"recdump:{voice}")
                self.assertEqual(capture["voice"], voice + 1)
                self.assertEqual(capture["gateHigh"], 40)
                self.assertIn(mask, _recorded_hex_values(recording, voice, "route"))
                self.assertIn(0x40, _recorded_hex_values(recording, voice, "mode"))
                session.run("keyup:q")
                return capture

            bypass1 = routing_audition(0, 0x00)
            filtered1 = routing_audition(0, 0x01)
            self.assertNotEqual(filtered1["hash"], bypass1["hash"])

            session.run("click:10,19")
            session.run("key:RIGHT")
            bypass2 = routing_audition(1, 0x01)
            filtered2 = routing_audition(1, 0x02)
            self.assertNotEqual(filtered2["hash"], bypass2["hash"])

            session.run("key:RIGHT")
            bypass3 = routing_audition(2, 0x02)
            filtered3 = routing_audition(2, 0x04)
            self.assertNotEqual(filtered3["hash"], bypass3["hash"])

            all3 = routing_audition(2, 0x07)
            session.run("key:LEFT")
            all2 = routing_audition(1, 0x07)
            session.run("key:LEFT")
            all1 = routing_audition(0, 0x07)
            self.assertNotEqual(all1["hash"], bypass1["hash"])
            self.assertNotEqual(all2["hash"], bypass2["hash"])
            self.assertNotEqual(all3["hash"], bypass3["hash"])
            self.assertEqual(_sweep_row(session.run("sweepdump:F"), f0 + 2)[1], 0xC7)

            # Step 32 leaves D-2 as the durable baseline on voice 1.
            _master_three_note_checkpoint(self, session, "step 32 / final audition")
            self.assertRegex(session.run("soundstate"), r"preview=0/26")

            # Step 33: the classic editor observes exactly the final authored bytes.
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[:2],
                             [0x93, 0x27])
            self.assertEqual(
                _wave_rows(session.run(f"wavedump:0x{w0:02x}"), len(expected_b)),
                expected_b,
            )
            self.assertEqual(_sweep_rows(session, "P", p0, 2), pulse_compacted)
            self.assertEqual(_sweep_rows(session, "F", f0, 4), filter_compacted)
            final_sound = _full_sound_dump(session.run("sounddump"))
            session.run("key:Ctrl-e")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), final_sound)
            self.assertEqual(_instrument_bytes(session.run("insbytes"))[4:8],
                             [f0, p0, 0, w0])


if __name__ == "__main__":
    unittest.main()
