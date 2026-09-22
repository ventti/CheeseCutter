"""R66-R68 portable Sound Editor keyboard contract."""

from __future__ import annotations

import re
import sys
import unittest

from tests.ccdriver_session import ROOT
from tests.test_sound_editor_master_usage import (
    _full_sound_dump,
    _instrument_bytes,
    _master_session,
    _new_isolated_wave,
    _select_pulse_at,
    _select_filter_at,
    _sweep_row,
)


UI_PRIMARY = {
    "se_zoom_out": "Ctrl-Shift-O", "se_zoom_in": "Ctrl-Shift-I",
    "se_fit": "Ctrl-Shift-A", "se_selection": "Ctrl-Shift-G",
    "se_linked": "Ctrl-Shift-E",
    "se_add": "Ctrl-Shift-J", "se_delete": "Ctrl-Shift-D",
    "se_stop": "Ctrl-Shift-S", "se_type": "Ctrl-T", "se_carry": "Ctrl-I",
    "se_new": "Ctrl-Shift-N", "se_wave_prev": "Shift-PageUp",
    "se_wave_next": "Shift-PageDown", "se_wave_1": "Ctrl-Shift-1",
    "se_wave_2": "Ctrl-Shift-2", "se_wave_loop": "Ctrl-L",
    "se_res_down": "Ctrl-Shift-3", "se_res_up": "Ctrl-Shift-4",
    "se_lp": "Ctrl-Shift-L", "se_bp": "Ctrl-Shift-B",
    "se_hp": "Ctrl-Shift-H", "se_route": "Ctrl-Shift-R",
}

RAW_PRIMARY = {
    "se_start_down": "Ctrl-Shift-5", "se_start_up": "Ctrl-Shift-6",
    "se_end_down": "Ctrl-Shift-7", "se_end_up": "Ctrl-Shift-8",
    "se_duration_down": "Ctrl-Shift-9", "se_duration_up": "Ctrl-Shift-0",
    "se_octave_down": "Ctrl-Shift-PageDown", "se_octave_up": "Ctrl-Shift-PageUp",
    "se_instrument_prev": "Ctrl-PageUp", "se_instrument_next": "Ctrl-PageDown",
}

ALL_PRIMARY = UI_PRIMARY | RAW_PRIMARY

ALIASES = {
    "se_fit": "Home", "se_selection": "End", "se_add": "Insert",
    "se_delete": "Delete", "se_octave_down": "Keypad /",
    "se_octave_up": "Keypad *", "se_instrument_prev": "Keypad -",
    "se_instrument_next": "Keypad +",
}

INITIAL_DISABLED = set(ALL_PRIMARY) - {
    "se_zoom_out", "se_zoom_in", "se_fit", "se_linked", "se_new",
    "se_octave_down", "se_octave_up", "se_instrument_prev",
    "se_instrument_next",
}


def _driver_chord(chord: str) -> str:
    chord = chord.replace("PageUp", "PGUP").replace("PageDown", "PGDN")
    parts = chord.split("-")
    if len(parts[-1]) == 1:
        parts[-1] = parts[-1].lower()
    return "-".join(parts)


def _no_mutation_snapshot(session) -> tuple[str, ...]:
    sound = _full_sound_dump(session.run("sounddump"))
    state = re.search(r"state:.*octave=\d+ speed=\d+ mult=\d+", session.run("state")).group(0)
    editor = re.search(r"sound:.*", session.run("soundstate")).group(0)
    instrument = re.search(r"ins[0-9a-f]{2}:(?: [0-9a-f]{2}){8}", session.run("insbytes")).group(0)
    capture = re.search(r"capture:.*", session.run("capturestate")).group(0)
    return (repr(sound), state, editor, instrument, capture)


class SoundEditorKeyboardPortabilityTests(unittest.TestCase):
    def test_eight_layout_policy_and_os_reserved_denylist(self) -> None:
        """Every frozen primary is semantic and available on all target layouts."""
        # The same semantic whitelist is intentional across all eight layouts:
        # letters/digits/PageUp/PageDown have stable virtual-key identities, while
        # layout-specific AltGr composition is separately rejected at dispatch.
        layouts = ("US", "UK", "DE", "IT", "ES", "FI-SE", "DK", "NO")
        safe_keys = set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") | {"PageUp", "PageDown"}
        forbidden_mods = {"Alt", "Cmd", "Gui", "Super", "Mode"}
        seen = set()
        for layout in layouts:
            for action, chord in ALL_PRIMARY.items():
                parts = chord.split("-")
                key = parts[-1] if parts[-2:] not in (["Page", "Up"], ["Page", "Down"]) \
                    else "".join(parts[-2:])
                mods = set(parts[:-1]) if key not in {"PageUp", "PageDown"} \
                    else set(parts[:-2])
                self.assertIn(key, safe_keys, (layout, action, chord))
                self.assertTrue(mods <= {"Ctrl", "Shift"}, (layout, action, chord))
                self.assertFalse(mods & forbidden_mods, (layout, action, chord))
                self.assertNotIn("Ctrl-Alt", chord)
                self.assertNotRegex(chord, r"Ctrl-(?:Shift-)?(?:Left|Right|Up|Down)$")
        for action, chord in ALL_PRIMARY.items():
            self.assertNotIn(chord, seen, action)
            seen.add(chord)

        # Primary commands fit compact laptop keyboards; keypad/navigation keys
        # are retained only as optional legacy aliases.
        for chord in ALL_PRIMARY.values():
            self.assertNotRegex(chord, r"Keypad|\b(?:Home|End|Insert|Delete)\b")

    def test_registry_matches_frozen_primary_first_and_has_no_unsafe_sound_binding(self) -> None:
        """Runtime registry and generated-help source use the frozen table exactly."""
        with _master_session() as session:
            for action, primary in ALL_PRIMARY.items():
                with self.subTest(action=action):
                    state = session.run(f"shortcutstate:{action}")
                    self.assertRegex(state, rf"keys={re.escape(primary)}(?: / |\n)")
                    expected = primary + (f" / {ALIASES[action]}" if action in ALIASES else "")
                    if sys.platform == "darwin":
                        mac_aliases = {"se_add": "Alt-Return / Insert",
                                       "se_fit": "Cmd-Up / Home",
                                       "se_selection": "Cmd-Down / End"}
                        if action in mac_aliases:
                            expected = primary + " / " + mac_aliases[action]
                    self.assertIn(f"keys={expected}\n", state)

        source = (ROOT / "src/ui/keymap.d").read_text()
        sound = source.split("// --- Visual Sound Editor controls", 1)[1].split(
            "// --- Sequencer", 1
        )[0]
        for unsafe in ("SDLK_LEFTBRACKET", "SDLK_RIGHTBRACKET", "KMOD_ALT"):
            self.assertNotIn(unsafe, sound)

    def test_new_zoom_primary_works_and_old_bracket_is_inert(self) -> None:
        with _master_session() as session:
            before = re.search(r"view=([^ ]+)", session.run("soundstate")).group(1)
            session.run("key:Ctrl-Shift-o")
            after = re.search(r"view=([^ ]+)", session.run("soundstate")).group(1)
            self.assertNotEqual(after, before)
            session.run("key:Ctrl-Shift-a")
            fitted = re.search(r"view=([^ ]+)", session.run("soundstate")).group(1)
            session.run("key:[")
            self.assertEqual(
                re.search(r"view=([^ ]+)", session.run("soundstate")).group(1), fitted
            )

    def test_altgr_gui_and_old_ctrl_arrow_do_not_edit(self) -> None:
        with _master_session() as session:
            before = _full_sound_dump(session.run("sounddump"))
            session.run("key:Mode-RAlt-n")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)
            session.run("key:Ctrl-RAlt-n")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)

            _new_isolated_wave(session)
            p0 = _instrument_bytes(session.run("insbytes"))[5]
            _select_pulse_at(session, 0)
            row_before = _sweep_row(session.run("sweepdump:P"), p0)
            session.run("key:Ctrl-Shift-6")
            row_after = _sweep_row(session.run("sweepdump:P"), p0)
            self.assertNotEqual(row_after[2], row_before[2])
            session.run("key:Ctrl-z")
            session.run("key:Ctrl-Shift-RIGHT")
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0), row_before)
            session.run("key:Gui-6")
            self.assertEqual(_sweep_row(session.run("sweepdump:P"), p0), row_before)

    def test_all_raw_value_primaries_and_exact_modifiers(self) -> None:
        with _master_session() as session:
            _new_isolated_wave(session)
            p0 = _instrument_bytes(session.run("insbytes"))[5]
            _select_pulse_at(session, 0)

            def row() -> tuple[int, int, int, int]:
                return _sweep_row(session.run("sweepdump:P"), p0)

            original = row()
            for key, field in (("5", 2), ("6", 2), ("7", 1), ("8", 1), ("0", 0)):
                with self.subTest(key=key):
                    session.run(f"key:Ctrl-Shift-{key}")
                    self.assertNotEqual(row()[field], original[field])
                    session.run("key:Ctrl-z")
                    self.assertEqual(row(), original)

            # Duration decrement is clamped at zero, so first establish one tick.
            session.run("key:Ctrl-Shift-0")
            one_tick = row()
            session.run("key:Ctrl-Shift-9")
            self.assertEqual(row(), original)
            session.run("key:Ctrl-z")
            self.assertEqual(row(), one_tick)
            session.run("key:Ctrl-z")
            self.assertEqual(row(), original)

            # Extra modifiers and removed Ctrl-arrow paths are inert.
            for key in ("Alt-Ctrl-Shift-6", "Ctrl-Shift-RIGHT", "Ctrl-RIGHT"):
                session.run(f"key:{key}")
                self.assertEqual(row(), original, key)

    def test_octave_instrument_primaries_and_allowed_keypad_aliases(self) -> None:
        with _master_session() as session:
            def octave() -> int:
                return int(re.search(r"octave=(\d+)", session.run("state")).group(1))

            initial_octave = octave()
            session.run("key:Ctrl-Shift-PGDN")
            self.assertEqual(octave(), initial_octave - 1)
            session.run("key:Ctrl-Shift-PGUP")
            self.assertEqual(octave(), initial_octave)
            session.run("key:KP_DIV")
            self.assertEqual(octave(), initial_octave - 1)
            session.run("key:KP_MUL")
            self.assertEqual(octave(), initial_octave)

            def instrument() -> int:
                return int(re.search(r"ins([0-9a-f]{2}):", session.run("insbytes")).group(1), 16)

            initial_instrument = instrument()
            session.run("key:Ctrl-PGDN")
            self.assertEqual(instrument(), initial_instrument + 1)
            session.run("key:Ctrl-PGUP")
            self.assertEqual(instrument(), initial_instrument)
            session.run("key:KP_PLUS")
            self.assertEqual(instrument(), initial_instrument + 1)
            session.run("key:KP_MINUS")
            self.assertEqual(instrument(), initial_instrument)
            for removed in ("+", "-", "Alt-n"):
                session.run(f"key:{removed}")
                self.assertEqual(instrument(), initial_instrument, removed)

    def test_gui_variants_are_sound_noops_and_context_restores(self) -> None:
        with _master_session() as session:
            before = _full_sound_dump(session.run("sounddump"))
            for chord in ALL_PRIMARY.values():
                key = "PGUP" if chord.endswith("PageUp") else \
                    "PGDN" if chord.endswith("PageDown") else chord.rsplit("-", 1)[-1]
                session.run(f"key:Gui-{key.lower()}")
                self.assertEqual(_full_sound_dump(session.run("sounddump")), before, chord)

            self.assertIn("context=sound_editor", session.run("shortcutstate:se_new"))
            session.run("key:Ctrl-e")
            outside = session.run("shortcutstate:se_new")
            self.assertNotIn("context=sound_editor", outside)
            self.assertIn("enabled=false", outside)
            session.run("key:Ctrl-Shift-n")
            self.assertEqual(_full_sound_dump(session.run("sounddump")), before)
            session.run("key:Ctrl-e")
            self.assertIn("context=sound_editor", session.run("shortcutstate:se_new"))

    def test_generated_keyboard_and_help_expose_portable_primaries(self) -> None:
        keyboard = (ROOT / "doc/KEYBOARD.md").read_text()
        section = keyboard.split("## Sound Editor", 1)[1].split("\n## ", 1)[0]
        for primary in ALL_PRIMARY.values():
            self.assertIn(f"`{primary}", section)
        for removed in ("`[`,", "`]`", "`Alt-N`", "`Ctrl-Alt-L`", "`Ctrl-[`"):
            self.assertNotIn(removed, section)
        help_source = (ROOT / "src/ui/help.d").read_text().split(
            "ContextHelp HELPSOUNDEDITOR", 1
        )[1].split("ContextHelp genPlayerContextHelp", 1)[0]
        for primary_hint in ("Ctrl-Shift-O / I", "Ctrl-Shift-5 / 6",
                             "Ctrl-Shift-PgDn/PgUp", "Ctrl-PgUp/PgDn"):
            self.assertIn(primary_hint, help_source)
        for removed in ("Ctrl-Left/Right", "Ctrl-Alt-S", "Alt-Left", "[ / ]"):
            self.assertNotIn(removed, help_source)
        self.assertNotIn("Filter Rt[", help_source)
        self.assertIn("Filter Route", help_source)

        review = (ROOT / "doc/SOUND_EDITOR_USABILITY_REVIEW.md").read_text()
        for official in (
            "https://learn.microsoft.com/en-us/windows/win32/uxguide/inter-keyboard",
            "https://support.microsoft.com/en-gb/windows/keyboard-shortcuts-in-windows-dcc61a57-8ff0-cffe-9796-cb9706c75eec",
            "https://support.apple.com/en-us/102650",
            "https://support.apple.com/en-gb/guide/mac-help/mh35798/mac",
            "https://support.apple.com/en-asia/guide/mac-help/-mh14112/mac",
            "https://help.ubuntu.com/stable/ubuntu-help/keyboard-shortcuts-set.html",
            "https://ubuntu.com/desktop/docs/en/latest/how-to/change-the-default-terminal/",
            "https://help.gnome.org/system-admin-guide/lockdown-command-line.html",
            "https://docs.kde.org/stable_kf6/en/plasma-workspace/kcontrol/screenlocker/index.html",
            "https://docs.kde.org/stable_kf6/en/kwin/kcontrol/kwintabbox/kwintabbox.pdf",
        ):
            self.assertIn(official, review)

    def test_disabled_primaries_are_consumed_without_any_editor_or_audio_mutation(self) -> None:
        """R67: real UI dispatch consumes every disabled primary without fallthrough."""
        with _master_session() as session:
            self.assertEqual(len(INITIAL_DISABLED), 23)
            for action in sorted(set(ALL_PRIMARY) - INITIAL_DISABLED):
                self.assertIn("enabled=true", session.run(f"shortcutstate:{action}"))
            for action in sorted(INITIAL_DISABLED):
                with self.subTest(state="initial", action=action):
                    status = session.run(f"shortcutstate:{action}")
                    self.assertIn("enabled=false", status)
                    before = _no_mutation_snapshot(session)
                    probe = session.run(f"keyprobe:{_driver_chord(ALL_PRIMARY[action])}")
                    self.assertIn(
                        f"shortcut probe: consumed=true action={action} invoked=false", probe
                    )
                    self.assertEqual(_no_mutation_snapshot(session), before)

        # Representative graph states catch predicates that change with ownership:
        # Wave boundaries, Filter CONFIG carry and Filter SWEEP resonance.
        with _master_session() as session:
            _new_isolated_wave(session)
            for action in ("se_wave_prev", "se_wave_next"):
                self.assertIn("enabled=false", session.run(f"shortcutstate:{action}"))
                before = _no_mutation_snapshot(session)
                probe = session.run(f"keyprobe:{_driver_chord(ALL_PRIMARY[action])}")
                self.assertIn(f"action={action} invoked=false", probe)
                self.assertEqual(_no_mutation_snapshot(session), before)

    def test_capacity_disables_new_and_selected_add_without_mutation(self) -> None:
        """R67: real Pulse capacity disables Add and New, then consumes both."""
        with _master_session() as session:
            _new_isolated_wave(session)
            _select_pulse_at(session, 0)

            # Fill through the documented selected-row Add command. This is a real
            # capacity fixture, not a test-only mutation of the canonical tables.
            inserted = 0
            for _ in range(80):
                if "enabled=false" in session.run("shortcutstate:se_add"):
                    break
                session.run(f"key:{_driver_chord(ALL_PRIMARY['se_add'])}")
                inserted += 1
            else:
                self.fail("Pulse Add never reached the production table-capacity predicate")

            self.assertGreater(inserted, 0)
            self.assertEqual(
                _sweep_row(session.run("sweepdump:P"), 0x3F), (0, 0, 0, 0x7F),
                "capacity fixture must move the terminal marker to the final table row",
            )
            for action in ("se_add", "se_new"):
                with self.subTest(action=action):
                    self.assertIn("enabled=false", session.run(f"shortcutstate:{action}"))
                    before = _no_mutation_snapshot(session)
                    probe = session.run(f"keyprobe:{_driver_chord(ALL_PRIMARY[action])}")
                    self.assertIn(
                        f"shortcut probe: consumed=true action={action} invoked=false", probe
                    )
                    self.assertEqual(
                        _no_mutation_snapshot(session), before,
                        "disabled capacity command changed tables, pointers, view or capture",
                    )

            _select_filter_at(session, 0)
            self.assertIn("enabled=false", session.run("shortcutstate:se_carry"))
            before = _no_mutation_snapshot(session)
            probe = session.run(f"keyprobe:{_driver_chord(ALL_PRIMARY['se_carry'])}")
            self.assertIn("action=se_carry invoked=false", probe)
            self.assertEqual(_no_mutation_snapshot(session), before)

            _select_filter_at(session, 1)
            for action in ("se_res_down", "se_res_up"):
                self.assertIn("enabled=false", session.run(f"shortcutstate:{action}"))
                before = _no_mutation_snapshot(session)
                probe = session.run(f"keyprobe:{_driver_chord(ALL_PRIMARY[action])}")
                self.assertIn(f"action={action} invoked=false", probe)
                self.assertEqual(_no_mutation_snapshot(session), before)


if __name__ == "__main__":
    unittest.main()
