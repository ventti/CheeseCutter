"""Foreground overlays stay bounded without erasing retained Sound Editor graphs."""

import re
import unittest

from tests.ccdriver_session import CCDriverSession


def overlay_counts(session):
    output = session.run("overlaystats")
    match = re.search(r"overlay: ops=(\d+) masks=(\d+)", output)
    if match is None:
        raise AssertionError(output)
    return tuple(map(int, match.groups()))


class OverlayLifetimeTests(unittest.TestCase):
    def test_idle_menu_and_tooltip_do_not_accumulate(self):
        with CCDriverSession("key:ESC") as session:
            self.assertEqual(overlay_counts(session), (0, 0))
            session.run("key:ESC")
            session.run("key:DOWN")
            self.assertEqual(overlay_counts(session), (1, 1))
            session.run("sleep:1100")  # tooltip becomes a second foreground mask
            session.run("idle:2000")
            self.assertEqual(overlay_counts(session), (2, 2))
            session.run("tick:2000")
            self.assertEqual(overlay_counts(session), (2, 2))
            session.run("key:ESC")
            session.run("idle")
            self.assertEqual(overlay_counts(session), (0, 0))

    def test_palette_masks_are_replaced_and_removed_on_close(self):
        with CCDriverSession("key:ESC", "key:Ctrl-p") as session:
            session.run("idle:2000")
            self.assertEqual(overlay_counts(session), (1, 1))
            session.run("key:ESC")
            self.assertEqual(overlay_counts(session), (0, 0))

    def test_idle_masks_preserve_sound_editor_graphs(self):
        with CCDriverSession("load:tunes/vent-arkijuusto.ct", "key:ESC",
                             "key:Ctrl-e") as session:
            ops, masks = overlay_counts(session)
            self.assertGreater(ops, 0)
            self.assertEqual(masks, 0)
            session.run("key:ESC")
            session.run("key:DOWN")
            ops, masks = overlay_counts(session)
            graph_ops = ops - masks
            self.assertGreater(graph_ops, 0)
            self.assertEqual(masks, 1)
            session.run("idle:2000")
            ops, masks = overlay_counts(session)
            self.assertEqual(ops - masks, graph_ops)
            self.assertIn(masks, (1, 2))  # optional dwell tooltip
            session.run("key:ESC")
            ops, masks = overlay_counts(session)
            self.assertGreater(ops, 0)
            self.assertEqual(masks, 0)

    def test_modal_mask_survives_idle_and_is_removed_on_close(self):
        with CCDriverSession("key:ESC", "key:Ctrl-e", "key:F12") as session:
            ops, masks = overlay_counts(session)
            graph_ops = ops - masks
            self.assertGreater(graph_ops, 0)
            self.assertEqual(masks, 1)
            session.run("idle:2000")
            self.assertEqual(overlay_counts(session), (ops, masks))
            session.run("key:ESC")
            ops, masks = overlay_counts(session)
            self.assertGreater(ops, 0)
            self.assertEqual(masks, 0)


if __name__ == "__main__":
    unittest.main()
