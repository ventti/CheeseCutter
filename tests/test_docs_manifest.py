"""Every tracked document must declare how it stays true.

Documentation rots when a document has no mechanism that would notice it had gone
stale. doc/MANIFEST.toml records that mechanism per document; this test makes the
record honest:

- a tracked doc missing from the manifest fails (you must choose a category)
- a manifest entry whose file is gone fails (no phantom docs)
- a `generator`/`reader` claim that does not exist fails (no phantom mechanisms)
- a doc that looks like session state (plan/audit/loop log/progress report) fails,
  because those belong in .scratch/ rather than in the repository

The first rule is the point: adding a document costs a deliberate decision.
"""

from __future__ import annotations

import re
import subprocess
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "doc/MANIFEST.toml"

CATEGORIES = {"generated", "tested", "decision", "prose", "agent", "vendor"}

# Tracked paths the manifest must account for. Extensionless files (INSTALL, TODO, …)
# are listed explicitly so that adding one is also a deliberate act.
DOC_SUFFIXES = (".md", ".1")
DOC_EXTRAS = ("TODO", "INSTALL", "ChangeLog", "NEWS", "AUTHORS", "doc/README")

# Paths excluded from the requirement: test fixtures and generated goldens are data,
# not documentation.
EXCLUDED_PREFIXES = ("tests/goldens/", "venv/", "guide/pics/")

# Titles//headers that mark session state rather than documentation.
ARTIFACT_PATTERNS = (
    re.compile(r"^#.*\b(progress|loop memory|iteration log)\b", re.I | re.M),
    re.compile(r"^Source: automated code review", re.I | re.M),
    re.compile(r"^Status:.*\bDRAFT / in progress\b", re.I | re.M),
    re.compile(r"survives context resets", re.I),
)


def _tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, text=True, check=True
    ).stdout
    return [p for p in out.split("\0") if p]


def _tracked_docs() -> set[str]:
    docs = set()
    for path in _tracked_files():
        if path.startswith(EXCLUDED_PREFIXES):
            continue
        if path.endswith(DOC_SUFFIXES) or path in DOC_EXTRAS:
            docs.add(path)
    return docs


class DocsManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        with MANIFEST.open("rb") as handle:
            cls.entries = tomllib.load(handle)["doc"]
        cls.by_path = {entry["path"]: entry for entry in cls.entries}

    def test_manifest_is_well_formed(self) -> None:
        self.assertEqual(
            len(self.by_path), len(self.entries), "duplicate path in doc/MANIFEST.toml"
        )
        for entry in self.entries:
            with self.subTest(path=entry["path"]):
                self.assertIn(
                    entry.get("category"),
                    CATEGORIES,
                    f"category must be one of {sorted(CATEGORIES)}",
                )

    def test_every_tracked_doc_is_classified(self) -> None:
        unlisted = sorted(_tracked_docs() - set(self.by_path))
        self.assertEqual(
            unlisted,
            [],
            "These tracked docs are not in doc/MANIFEST.toml. Add an entry naming how each "
            "stays true — or, if it is session state (a plan, audit, review or progress "
            f"log), move it to .scratch/ instead of committing it: {unlisted}",
        )

    def test_no_manifest_entry_is_a_phantom(self) -> None:
        missing = sorted(p for p in self.by_path if not (ROOT / p).exists())
        self.assertEqual(
            missing, [], f"doc/MANIFEST.toml lists files that do not exist: {missing}"
        )

    def test_declared_generators_and_readers_exist(self) -> None:
        for entry in self.entries:
            for field in ("generator", "reader"):
                claim = entry.get(field)
                if claim is None:
                    continue
                with self.subTest(path=entry["path"], field=field):
                    self.assertTrue(
                        (ROOT / claim).exists(),
                        f"{entry['path']} claims {field}={claim!r}, which does not exist",
                    )

    def test_generated_docs_name_their_generator(self) -> None:
        for entry in self.entries:
            if entry["category"] != "generated":
                continue
            with self.subTest(path=entry["path"]):
                self.assertIn(
                    "generator",
                    entry,
                    "a generated doc must name the tool that writes it",
                )

    def test_tested_docs_name_the_test_that_reads_them(self) -> None:
        for entry in self.entries:
            if entry["category"] != "tested":
                continue
            path, reader = entry["path"], entry.get("reader")
            with self.subTest(path=path):
                self.assertIsNotNone(reader, "a tested doc must name its reader")
                self.assertTrue(
                    Path(path).name in (ROOT / reader).read_text(encoding="utf-8"),
                    f"{reader} does not actually reference {path}",
                )

    def test_no_session_artifacts_are_committed(self) -> None:
        offenders = []
        for path in sorted(_tracked_docs()):
            if self.by_path.get(path, {}).get("category") in {"decision", "vendor"}:
                continue
            text = (ROOT / path).read_text(encoding="utf-8", errors="replace")
            for pattern in ARTIFACT_PATTERNS:
                if pattern.search(text):
                    offenders.append(f"{path} (matched {pattern.pattern!r})")
                    break
        self.assertEqual(
            offenders,
            [],
            "These committed docs read as session state rather than documentation. Keep "
            f"working notes in .scratch/ and promote only durable content: {offenders}",
        )


if __name__ == "__main__":
    unittest.main()
