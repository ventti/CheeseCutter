"""Golden-master equality gate for the pre-refactor Sound Editor safety net.

Phase 0 of the byte-identical `src/ui/soundedit.d` dedup refactor. Re-runs the
exact deterministic matrix in `tests/soundedit_goldens.py` and asserts every
captured oracle dump is byte-identical to the committed file under
`tests/goldens/`. See that module's header for what the matrix covers and what
is deliberately excluded (screenshots) and why.

A failure here means some later refactor phase changed OBSERVABLE Sound Editor
behaviour, not just internal structure -- the assertion message names the
exact drifting fixture (e.g. `filter_gestures/01_three_block_loop_sweepdump_f`)
so the diff can be inspected directly with:

    diff tests/goldens/<name>.txt <(python3 -c "
        from tests.soundedit_goldens import build_goldens
        print(build_goldens()['<name>'], end='')")

If the Sound Editor's behaviour changed ON PURPOSE (not as part of this
refactor), regenerate with `python -m tests.soundedit_goldens` and review the
diff like any other code change before committing it.
"""

from __future__ import annotations

import unittest

from tests.ccdriver_session import DRIVER
from tests.soundedit_goldens import GOLDEN_DIR, build_goldens, golden_path


class SoundEditorGoldenMasterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        if not DRIVER.exists():
            raise unittest.SkipTest("build ./ccdriver first")

    def test_golden_matrix_is_byte_identical_to_committed_fixtures(self) -> None:
        actual = build_goldens()
        self.assertTrue(actual, "golden matrix produced no captures")

        committed_names = {
            path.relative_to(GOLDEN_DIR).with_suffix("").as_posix()
            for path in GOLDEN_DIR.rglob("*.txt")
        }
        actual_names = set(actual)

        missing_on_disk = sorted(actual_names - committed_names)
        missing_in_matrix = sorted(committed_names - actual_names)
        self.assertEqual(
            missing_on_disk, [],
            "matrix captured names with no committed golden file (run "
            "`python -m tests.soundedit_goldens` to add them): "
            f"{missing_on_disk}",
        )
        self.assertEqual(
            missing_in_matrix, [],
            "committed golden files no longer produced by the matrix (stale "
            f"fixtures under tests/goldens/): {missing_in_matrix}",
        )

        mismatches = []
        for name in sorted(actual_names):
            expected = golden_path(name).read_text()
            if actual[name] != expected:
                mismatches.append(name)
        self.assertEqual(
            mismatches, [],
            "Sound Editor behaviour drifted from the golden master for: "
            f"{mismatches}\n"
            "Regenerate ONLY if this drift is an intentional, reviewed "
            "behaviour change (not part of the byte-identical refactor): "
            "python -m tests.soundedit_goldens",
        )


if __name__ == "__main__":
    unittest.main()
