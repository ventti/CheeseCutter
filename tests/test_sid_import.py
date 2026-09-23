"""File -> Import .sid: CheeseCutter .sid -> .ct reverse conversion (ct.sidimport).

The oracle is playback, not bytes. An export purges and renumbers the song, so
the recovered .ct can never equal the original byte for byte. What must hold is
that both songs drive the SID identically. `ct2util sidtrace` prints the 25 SID
registers after every play call, so for each case we compare

    sidtrace(export(original.ct))  ==  sidtrace(export(sid2ct(the .sid)))

Both sides go through today's player, so the check does not depend on which
player version wrote the .sid. For the real old releases in tests/fixtures/sid
the original .sid itself is also compared against the re-export.
"""

from __future__ import annotations

import re
import struct
import subprocess
import tempfile
import unittest
import zlib
from pathlib import Path

from tests.ccdriver_session import CCDriverSession


ROOT = Path(__file__).resolve().parents[1]
CT2UTIL = ROOT / "ct2util"
FIXTURES = ROOT / "tests" / "fixtures" / "sid"
TUNES = sorted(p for p in (ROOT / "tunes").glob("*.ct") if not p.name.startswith("_"))
FRAMES = "2000"

# .ct layout (ct.base.Song.DatafileOffset): "CC2" + zlib(300000-byte buffer)
HEADER = 65536
SONGSPEEDS = HEADER + 5
TITLE = HEADER + 256 + 5
SUBTUNES = TITLE + 40 * 4 + 1024 * 2
ORDERLIST = 1024

# Export variants: every one must round-trip exactly.
VARIANTS = {"default": [], "reloc-2000": ["-r", "0x2000"],
            "reloc-0c00": ["-r", "0x0c00"], "zeropage": ["-zp", "0xf0"]}


def ct2util(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([str(CT2UTIL), *args], cwd=ROOT, capture_output=True, text=True)


def read_ct(path: Path) -> bytearray:
    raw = path.read_bytes()
    assert raw[:3] == b"CC2", path
    return bytearray(zlib.decompress(raw[3:]))


def write_ct(path: Path, buf: bytes) -> None:
    path.write_bytes(b"CC2" + zlib.compress(bytes(buf)))


def song_count(sid: Path) -> int:
    return struct.unpack(">H", sid.read_bytes()[14:16])[0]


def psid(code: bytes, load: int = 0x1000) -> bytes:
    """A minimal valid PSID v2 around `code` (init = load, play = load + 3)."""
    header = bytearray(0x7C)
    header[0:4] = b"PSID"
    struct.pack_into(">HHHHHHHI", header, 4, 2, 0x7C, 0, load, load + 3, 1, 1, 0)
    return bytes(header) + struct.pack("<H", load) + code


class SidRoundTrip(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not CT2UTIL.exists():
            raise unittest.SkipTest("ct2util not built (make -f Makefile.mac ct2util)")
        cls._tmp = tempfile.TemporaryDirectory()
        cls.tmp = Path(cls._tmp.name)

    @classmethod
    def tearDownClass(cls):
        cls._tmp.cleanup()

    def export(self, ct: Path, out: Path, *opts: str) -> Path:
        r = ct2util("sid", "-q", *opts, str(ct), "-o", str(out))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return out

    def trace(self, sid: Path, subtune: int = 1) -> list[str]:
        out = self.tmp / f"{sid.stem}.{subtune}.trace"   # never next to a fixture
        r = ct2util("sidtrace", "-q", "-s", str(subtune), "-f", FRAMES, str(sid), "-o", str(out))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return out.read_text().split()

    def convert(self, sid: Path, name: str) -> Path:
        out = self.tmp / f"{name}.ct"
        r = ct2util("sid2ct", str(sid), "-o", str(out))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        return out

    def assertSamePlayback(self, a: list[str], b: list[str], ignore_registers=()):
        self.assertEqual(len(a), len(b))
        for frame, (x, y) in enumerate(zip(a, b)):
            for reg in range(25):
                if reg in ignore_registers:
                    continue
                if x[2 * reg:2 * reg + 2] != y[2 * reg:2 * reg + 2]:
                    self.fail(f"frame {frame}: $d4{reg:02x} differs ({x} vs {y})")

    def roundtrip(self, original: Path, name: str, *export_opts: str) -> Path:
        sid = self.export(original, self.tmp / f"{name}.sid", *export_opts)
        recovered = self.convert(sid, name)
        reexport = self.export(recovered, self.tmp / f"{name}-re.sid")
        for sub in range(1, song_count(sid) + 1):
            with self.subTest(subtune=sub):
                self.assertSamePlayback(self.trace(sid, sub), self.trace(reexport, sub))
        return recovered

    # --- songs exported by today's player --------------------------------

    def test_every_tune_and_export_variant_plays_back_identically(self):
        for tune in TUNES:
            for variant, opts in VARIANTS.items():
                with self.subTest(tune=tune.name, variant=variant):
                    self.roundtrip(tune, f"{tune.stem}-{variant}", *opts)

    def test_multiple_subtunes_and_single_subtune_export(self):
        # No bundled tune has several subtunes: derive three from one by
        # rotating its voices, each at its own speed.
        buf = read_ct(ROOT / "tunes" / "abaddon-starfish.ct")
        voices = [bytes(buf[SUBTUNES + v * ORDERLIST:SUBTUNES + (v + 1) * ORDERLIST])
                  for v in range(3)]
        for sub, (speed, order) in enumerate([(buf[SONGSPEEDS], (0, 1, 2)),
                                              (3, (1, 2, 0)), (7, (2, 0, 1))]):
            for v, src in enumerate(order):
                at = SUBTUNES + (sub * 3 + v) * ORDERLIST
                buf[at:at + ORDERLIST] = voices[src]
            buf[SONGSPEEDS + sub] = speed
        multi = self.tmp / "multi.ct"
        write_ct(multi, buf)

        recovered = self.roundtrip(multi, "multi", "-d", "2")
        got = read_ct(recovered)
        self.assertEqual(list(got[SONGSPEEDS:SONGSPEEDS + 3]), [buf[SONGSPEEDS], 3, 7])
        self.roundtrip(multi, "multi-s3", "-s", "3")

    def test_metadata_is_recovered(self):
        for tune in TUNES:
            with self.subTest(tune=tune.name):
                sid = self.export(tune, self.tmp / f"{tune.stem}-meta.sid")
                orig, got = read_ct(tune), read_ct(self.convert(sid, f"{tune.stem}-meta"))
                for field in range(3):   # title, author, release: 32 bytes each
                    at = TITLE + field * 32
                    self.assertEqual(bytes(orig[at:at + 32]).rstrip(b" \0"),
                                     bytes(got[at:at + 32]).rstrip(b" \0"))
                self.assertEqual(got[HEADER + 2], orig[HEADER + 2], "multiplier")
                self.assertEqual(got[HEADER + 3], orig[HEADER + 3], "SID model")

    # --- real releases made with older players ---------------------------

    def test_real_4_00_era_releases_replay_exactly(self):
        # PSIDs released 2013/14 with older 4.x players (Subtlety: 4.00, which
        # kept the hard-restart SR in a global byte, plus the multispeed CIA
        # wrapper). Recovered and re-exported with today's player, they drive
        # the SID exactly like the original files.
        for name, generation in [("So_You_Died_Man_Up", "4.01-4.06"),
                                 ("Subtlety_Is_Not_My_Business", "4.00")]:
            with self.subTest(sid=name):
                sid = FIXTURES / f"{name}.sid"
                r = ct2util("sid2ct", str(sid), "-o", str(self.tmp / f"{name}.ct"))
                self.assertIn(f"Player: CheeseCutter {generation}", r.stdout)
                reexport = self.export(self.tmp / f"{name}.ct", self.tmp / f"{name}-re.sid")
                self.assertSamePlayback(self.trace(sid), self.trace(reexport))

    def test_2012_release_matches_its_published_song(self):
        # Trouble Every Day (2012) is older than any player in git, and plays
        # differently from today's player even from the author's own upgraded
        # .ct. The recovered song equals that .ct except that the release had
        # instruments 2 and 17 merged (they differ only in sustain/release,
        # edited after the release), which shows up as voice 3 SR ($d40d).
        recovered = self.convert(FIXTURES / "Trouble_Every_Day.sid", "trouble-2012")
        a = self.trace(self.export(ROOT / "tunes" / "abaddon-trouble.ct", self.tmp / "t-orig.sid"))
        b = self.trace(self.export(recovered, self.tmp / "t-re.sid"))
        self.assertSamePlayback(a, b, ignore_registers=(0x0d,))

    # --- not convertible -------------------------------------------------

    def test_non_cheesecutter_files_are_rejected_cleanly(self):
        real = (FIXTURES / "Trouble_Every_Day.sid").read_bytes()
        cases = {
            "other player": (FIXTURES / "not_cheesecutter.sid").read_bytes(),
            "noise": psid(bytes((i * 73 + 11) & 0xFF for i in range(4000))),
            "truncated": real[: len(real) // 2],
            "truncated late": real[:-400],
            "a .ct file": (ROOT / "tunes" / "abaddon-trouble.ct").read_bytes(),
            "empty": b"",
        }
        for name, data in cases.items():
            with self.subTest(case=name):
                path = self.tmp / "bad.sid"
                path.write_bytes(data)
                r = ct2util("sid2ct", str(path), "-o", str(self.tmp / "bad.ct"))
                self.assertNotEqual(r.returncode, 0)
                self.assertIn("not a CheeseCutter 4.x SID", r.stdout)
                self.assertNotIn("core.exception", r.stdout + r.stderr)


def _rows(dump: str) -> dict[int, str]:
    return {int(m.group(1)): m.group(2)
            for m in (re.match(r"screen(\d+):(.*)", line) for line in dump.splitlines()) if m}


def _screen(session: CCDriverSession) -> str:
    return "\n".join(_rows(session.run("screendump")).values())


class EditorSidImport(unittest.TestCase):
    """The editor side, through the driver command and the real menu + picker."""

    GOOD = "tests/fixtures/sid/So_You_Died_Man_Up.sid"
    BAD = "tests/fixtures/sid/not_cheesecutter.sid"
    NOTICE = "Not a CheeseCutter 2.x SID - conversion is not possible."

    def test_import_command_loads_an_unsaved_song(self):
        with CCDriverSession("key:ESC") as s:
            s.run(f"sidimport:{self.GOOD}")
            screen = _screen(s)
            self.assertIn("SID imported (player 4.01-4.06).", screen)
            self.assertIn("so you died. man up!", screen.lower())
            self.assertRegex(screen, r"Filename:\s+\*")   # unnamed, modified

    def test_open_by_extension_imports_a_sid(self):
        with CCDriverSession("key:ESC") as s:
            s.run(f"open:{self.GOOD}")
            self.assertIn("SID imported", _screen(s))

    def test_foreign_sid_shows_notice_until_a_key_is_pressed(self):
        with CCDriverSession("key:ESC") as s:
            s.run(f"sidimport:{self.BAD}")
            self.assertIn(self.NOTICE, _screen(s))
            s.run("key:SPACE")
            self.assertNotIn(self.NOTICE, _screen(s))

    PICKER_TITLE = "Import CheeseCutter .sid"

    def _pick(self, s: CCDriverSession, name: str) -> None:
        """Move the picker's cursor from its first entry (".", two rows under
        the title) down to `name`, then Return. Rows also carry the editor
        behind the picker, so match `name` as a whole token."""
        rows = _rows(s.run("screendump"))
        title = next(y for y, t in sorted(rows.items()) if self.PICKER_TITLE in t)
        token = re.compile(rf"(?<![\w.]){re.escape(name)}(?![\w.])")
        target = next(y for y, t in sorted(rows.items()) if y > title + 1 and token.search(t))
        for _ in range(target - (title + 2)):
            s.run("key:DOWN")
        s.run("key:RETURN")

    def _open_import_dialog_from_menu(self, s: CCDriverSession) -> None:
        rows = _rows(s.run("screendump"))          # Esc Esc: File menu is open
        y = next(y for y, t in sorted(rows.items()) if "Import .sid..." in t)
        s.run(f"hover:{rows[y].index('Import .sid...')},{y}")
        s.run("key:RETURN")
        self.assertIn(self.PICKER_TITLE, _screen(s))
        for part in ("tests", "fixtures", "sid"):
            self._pick(s, part)

    def test_menu_and_picker_import_a_sid(self):
        with CCDriverSession("key:ESC", "key:ESC") as s:
            self._open_import_dialog_from_menu(s)
            self._pick(s, "So_You_Died_Man_Up.sid")
            screen = _screen(s)
            self.assertIn("SID imported", screen)
            self.assertNotIn(self.PICKER_TITLE, screen)   # picker closed

    def test_menu_and_picker_show_notice_for_foreign_sid(self):
        with CCDriverSession("key:ESC", "key:ESC") as s:
            self._open_import_dialog_from_menu(s)
            self._pick(s, "not_cheesecutter.sid")
            self.assertIn(self.NOTICE, _screen(s))

    def test_shortcut_opens_the_picker(self):
        with CCDriverSession("key:ESC") as s:
            s.run("key:Ctrl-Shift-F9")
            self.assertIn(self.PICKER_TITLE, _screen(s))


if __name__ == "__main__":
    unittest.main()
